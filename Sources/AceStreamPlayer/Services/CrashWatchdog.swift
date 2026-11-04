import Foundation

/// A tiny shell process that outlives the app only if the app dies unexpectedly.
/// When this app's PID disappears it removes our engine container and closes our IINA.
/// On a normal stop/quit we terminate the watchdog first, so it never fires.
@MainActor
final class CrashWatchdog {
    private var process: Process?

    private static let script = """
    APP_PID="$1"; DOCKER="$2"; NAME="$3"; PIDFILE="$4"; STOP_DOCKER="$5"
    while kill -0 "$APP_PID" 2>/dev/null; do sleep 2; done
    if [ -f "$PIDFILE" ]; then
      P=$(cat "$PIDFILE" 2>/dev/null)
      [ -n "$P" ] && kill "$P" 2>/dev/null
      rm -f "$PIDFILE"
    fi
    "$DOCKER" rm -f "$NAME" >/dev/null 2>&1
    if [ "$STOP_DOCKER" = "1" ] && [ -z "$("$DOCKER" ps -q 2>/dev/null)" ]; then
      "$DOCKER" desktop stop --timeout 60 >/dev/null 2>&1 || \
        osascript -e 'tell application id "com.docker.docker" to quit' >/dev/null 2>&1
    fi
    exit 0
    """

    func arm(dockerCLI: String, environment: [String: String], stopDocker: Bool) {
        disarm()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [
            "-c", Self.script, "acestreamplayer-watchdog",
            String(getpid()), dockerCLI, DockerService.containerName, AppPaths.playerPIDFile.path,
            stopDocker ? "1" : "0",
        ]
        p.environment = environment
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            process = p
        } catch {
            Log.warn("Crash watchdog could not start: \(error)")
        }
    }

    func disarm() {
        if let p = process, p.isRunning { p.terminate() }
        process = nil
    }
}
