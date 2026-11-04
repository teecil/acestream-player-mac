import Foundation

struct ProcessResult {
    let status: Int32
    let stdout: String
    let stderr: String

    var ok: Bool { status == 0 }
    var combinedOutput: String { stdout + "\n" + stderr }
}

enum ProcessRunnerError: Error, LocalizedError {
    case launchFailed(String)
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let detail): return "Не удалось запустить служебную команду: \(detail)"
        case .timedOut(let command): return "Служебная команда не ответила вовремя (\(command))"
        }
    }
}

/// Collects stdout/stderr of a child process; optionally streams lines.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    private var outLine = Data()
    private var errLine = Data()
    private var timedOut = false
    private let onLine: (@Sendable (String) -> Void)?

    init(onLine: (@Sendable (String) -> Void)?) {
        self.onLine = onLine
    }

    func append(_ chunk: Data, isError: Bool) {
        var lines: [String] = []
        lock.lock()
        if isError { err.append(chunk) } else { out.append(chunk) }
        if onLine != nil {
            if isError {
                errLine.append(chunk)
                lines = Self.drainLines(&errLine)
            } else {
                outLine.append(chunk)
                lines = Self.drainLines(&outLine)
            }
        }
        lock.unlock()
        if let onLine { lines.forEach(onLine) }
    }

    private static func drainLines(_ buffer: inout Data) -> [String] {
        var lines: [String] = []
        while let nl = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let lineData = buffer[buffer.startIndex..<nl]
            let line = String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            if !line.isEmpty { lines.append(line) }
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        return lines
    }

    func markTimedOut() {
        lock.lock(); timedOut = true; lock.unlock()
    }

    var wasTimedOut: Bool {
        lock.lock(); defer { lock.unlock() }
        return timedOut
    }

    func result(status: Int32) -> ProcessResult {
        lock.lock(); defer { lock.unlock() }
        return ProcessResult(
            status: status,
            stdout: String(decoding: out, as: UTF8.self),
            stderr: String(decoding: err, as: UTF8.self)
        )
    }
}

/// Runs command-line tools asynchronously, with timeout and Task cancellation support.
enum ProcessRunner {
    static func run(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval? = nil,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessResult {
        try Task.checkCancellation()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        let collector = OutputCollector(onLine: onLine)
        let label = ([URL(fileURLWithPath: executable).lastPathComponent] + arguments.prefix(2)).joined(separator: " ")

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
                let readers = DispatchGroup()
                readers.enter()
                readers.enter()

                process.terminationHandler = { finished in
                    DispatchQueue.global(qos: .utility).async {
                        // A grandchild may keep a pipe open; don't wait for it forever.
                        _ = readers.wait(timeout: .now() + 3)
                        if collector.wasTimedOut {
                            continuation.resume(throwing: ProcessRunnerError.timedOut(label))
                        } else {
                            continuation.resume(returning: collector.result(status: finished.terminationStatus))
                        }
                    }
                }

                do {
                    try process.run()
                } catch {
                    readers.leave()
                    readers.leave()
                    continuation.resume(throwing: ProcessRunnerError.launchFailed(error.localizedDescription))
                    return
                }

                for (pipe, isError) in [(outPipe, false), (errPipe, true)] {
                    let handle = pipe.fileHandleForReading
                    DispatchQueue.global(qos: .utility).async {
                        while true {
                            let chunk = handle.availableData
                            if chunk.isEmpty { break }
                            collector.append(chunk, isError: isError)
                        }
                        readers.leave()
                    }
                }

                if let timeout {
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                        if process.isRunning {
                            collector.markTimedOut()
                            process.terminate()
                        }
                    }
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}
