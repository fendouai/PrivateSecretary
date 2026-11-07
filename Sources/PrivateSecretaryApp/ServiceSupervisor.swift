import Foundation
import SecretaryKit

final class ServiceSupervisor {
    private var child: Process?
    private let label = "com.privatesecretary.daemon"

    func start(paths: AppPaths, forceRestart: Bool = false) throws {
        if !forceRestart && FileManager.default.fileExists(atPath: paths.socketFile.path) {
            return
        }
        if forceRestart, launchAgentPlist() != nil {
            _ = try? CommandRunner.run(
                executable: "/bin/launchctl",
                arguments: ["kickstart", "-k", "gui/\(getuid())/\(label)"],
                timeoutSeconds: 10
            )
            return
        }
        if forceRestart, let child, child.isRunning {
            child.terminate()
            child.waitUntilExit()
            self.child = nil
        }
        let plist = launchAgentPlist()
        if let plist {
            if !isLaunchAgentLoaded() {
                _ = try? CommandRunner.run(
                    executable: "/bin/launchctl",
                    arguments: ["bootstrap", "gui/\(getuid())", plist.path],
                    timeoutSeconds: 10
                )
            }
            let result = try CommandRunner.run(
                executable: "/bin/launchctl",
                arguments: ["kickstart", "-k", "gui/\(getuid())/\(label)"],
                timeoutSeconds: 10
            )
            if result.exitCode != 0 {
                throw NSError(domain: "PrivateSecretary.App", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "launchctl kickstart failed: \(result.stderrString)"
                ])
            }
            return
        }

        guard let helper = helperExecutable() else {
            throw NSError(domain: "PrivateSecretary.App", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "No embedded secretaryd helper found. Run scripts/install.sh first."
            ])
        }
        try paths.ensureDirectories()
        let log = paths.logDirectory.appendingPathComponent("menubar-daemon.log")
        if !FileManager.default.fileExists(atPath: log.path) {
            FileManager.default.createFile(atPath: log.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: helper)
        process.arguments = ["--home", paths.home.path, "--capture", "system"]
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        child = process
    }

    func stop() {
        if let child, child.isRunning {
            child.terminate()
            child.waitUntilExit()
            self.child = nil
            return
        }
        guard FileManager.default.fileExists(atPath: launchAgentPlist()?.path ?? "") else { return }
        _ = try? CommandRunner.run(
            executable: "/bin/launchctl",
            arguments: ["bootout", "gui/\(getuid())/\(label)"],
            timeoutSeconds: 10
        )
    }

    private func launchAgentPlist() -> URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func isLaunchAgentLoaded() -> Bool {
        let result = try? CommandRunner.run(
            executable: "/bin/launchctl",
            arguments: ["print", "gui/\(getuid())/\(label)"],
            timeoutSeconds: 5
        )
        return result?.exitCode == 0
    }

    private func helperExecutable() -> String? {
        if let env = ProcessInfo.processInfo.environment["PRIVATE_SECRETARY_DAEMON"],
           FileManager.default.isExecutableFile(atPath: env) {
            return env
        }
        let bundleHelper = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/secretaryd").path
        if FileManager.default.isExecutableFile(atPath: bundleHelper) {
            return bundleHelper
        }
        if let executable = Bundle.main.executableURL {
            let sibling = executable.deletingLastPathComponent().appendingPathComponent("secretaryd").path
            if FileManager.default.isExecutableFile(atPath: sibling) { return sibling }
        }
        return SystemDiagnostics.locateExecutable("secretaryd")
    }
}
