import AceCore
import AppKit
import Foundation

/// What to remove. Everything is selected unless the user explicitly chooses to keep something.
struct UninstallOptions: Equatable {
    var player = true
    var docker = true
    var app = true

    var isEmpty: Bool { !player && !docker && !app }
}

/// Removes IINA, Docker Desktop and/or this app with all their data, so that a later install
/// starts from a clean Mac. Things that live in /Applications are removed in one
/// administrator step (one password prompt).
@MainActor
enum Uninstaller {
    static func run(_ options: UninstallOptions, docker: DockerService, player: IINAPlayer,
                    report: (String) -> Void) async throws {
        let home = NSHomeDirectory()
        var rootCommands: [String] = []

        // Keeping Docker but removing this app: take our engine image out of Docker.
        if options.app && !options.docker && docker.isInstalled {
            report(tr("Removing the stream engine…", "Удаляем движок трансляций…"))
            do {
                try await docker.ensureRunning { _ in }
                await docker.removeOwnContainers()
                await docker.removeEngineImages()
                await docker.stopDesktopIfManaged()
            } catch {
                Log.warn("Could not remove the engine image: \(error)")
            }
        }

        if options.docker, let app = docker.appURL {
            report(tr("Removing Docker Desktop…", "Удаляем Docker Desktop…"))
            await docker.quitDesktopCompletely()
            // Official uninstall (docs.docker.com/desktop/uninstall): removes Docker's data and VM.
            let tool = app.appendingPathComponent("Contents/MacOS/uninstall").path
            if FileManager.default.isExecutableFile(atPath: tool) {
                let result = try? await ProcessRunner.run(tool, [], timeout: 900)
                Log.info("Docker uninstall tool: status \(result?.status ?? -1)")
            }
            // Leftovers listed by Docker's docs, plus app state Docker Desktop keeps.
            removeUserItems(home, [
                "Library/Group Containers/group.com.docker",
                ".docker",
                "Library/Containers/com.docker.docker",
                "Library/Application Support/Docker Desktop",
                "Library/Preferences/com.docker.docker.plist",
                "Library/Preferences/com.electron.docker-frontend.plist",
                "Library/Saved Application State/com.electron.docker-frontend.savedState",
                "Library/Logs/Docker Desktop",
                "Library/Caches/com.docker.docker",
                "Library/HTTPStorages/com.docker.docker",
            ])
            rootCommands += [
                "launchctl bootout system/com.docker.vmnetd 2>/dev/null",
                "launchctl bootout system/com.docker.socket 2>/dev/null",
                "rm -f /Library/PrivilegedHelperTools/com.docker.vmnetd /Library/PrivilegedHelperTools/com.docker.socket",
                "rm -f /Library/LaunchDaemons/com.docker.vmnetd.plist /Library/LaunchDaemons/com.docker.socket.plist",
                // CLI links Docker Desktop put into /usr/local/bin (only links that point into Docker.app).
                "for f in /usr/local/bin/*; do if [ -L \"$f\" ] && readlink \"$f\" | grep -q 'Docker.app/'; then rm -f \"$f\"; fi; done",
                "if [ -L /var/run/docker.sock ]; then rm -f /var/run/docker.sock; fi",
                "rm -rf \(ShellQuote.sh(app.path))",
            ]
        }

        if options.player, let iina = player.appURL {
            report(tr("Removing IINA…", "Удаляем IINA…"))
            await player.stop()
            for running in NSRunningApplication.runningApplications(withBundleIdentifier: IINAPlayer.bundleID) {
                running.terminate()
            }
            let id = IINAPlayer.bundleID
            UserDefaults.standard.removePersistentDomain(forName: id)
            removeUserItems(home, [
                "Library/Preferences/\(id).plist",
                "Library/Application Support/\(id)",
                "Library/Caches/\(id)",
                "Library/HTTPStorages/\(id)",
                "Library/WebKit/\(id)",
                "Library/Saved Application State/\(id).savedState",
            ])
            rootCommands.append("rm -rf \(ShellQuote.sh(iina.path))")
        }

        if options.app {
            let bundle = Bundle.main.bundleURL
            if bundle.pathExtension == "app" {
                rootCommands.append("rm -rf \(ShellQuote.sh(bundle.path))")
            }
        }

        if !rootCommands.isEmpty {
            report(tr("Removing apps… macOS will ask for your Mac password.",
                      "Удаляем программы… macOS попросит пароль от Mac."))
            // `true` at the end: the cleanup lines above may legitimately find nothing to remove.
            try await Privileged.run(
                rootCommands.joined(separator: "; ") + "; true",
                prompt: tr("AceStream Player is uninstalling the selected components.",
                           "AceStream Player удаляет выбранные компоненты.")
            )
        }
        Log.info("Uninstall finished")
    }

    /// Last step when the app itself is removed: delete our settings, caches and logs, then quit.
    /// Nothing is logged after this point, so no file gets recreated.
    static func removeOwnDataAndExit() -> Never {
        Log.flush()
        let id = Bundle.main.bundleIdentifier ?? "app.acestreamplayer.mac"
        UserDefaults.standard.removePersistentDomain(forName: id)
        UserDefaults.standard.synchronize()
        removeUserItems(NSHomeDirectory(), [
            "Library/Application Support/AceStreamPlayer",
            "Library/Caches/AceStreamPlayer",
            "Library/Logs/AceStreamPlayer",
            "Library/Preferences/\(id).plist",
            "Library/Saved Application State/\(id).savedState",
            "Library/Caches/\(id)",
            "Library/HTTPStorages/\(id)",
            "Library/WebKit/\(id)",
        ])
        exit(0)
    }

    private static func removeUserItems(_ home: String, _ relativePaths: [String]) {
        let fm = FileManager.default
        for relative in relativePaths {
            let path = home + "/" + relative
            if fm.fileExists(atPath: path) {
                try? fm.removeItem(atPath: path)
            }
        }
    }
}
