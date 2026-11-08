import Foundation
import SecretaryKit

/// The menu bar app is the TCC responsible process for capture. The embedded
/// helper is spawned as a child of the app so Screen Recording permission is
/// inherited consistently. A standalone launchd daemon has a different TCC
/// identity and is intentionally not used by the app.
final class ServiceSupervisor {
    private var child: Process?

    func start(paths: AppPaths, forceRestart: Bool = false) throws {
        if !forceRestart && FileManager.default.fileExists(atPath: paths.socketFile.path) {
            return
        }
        if forceRestart, let child, child.isRunning {
            child.terminate()
            child.waitUntilExit()
            self.child = nil
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
        guard let child, child.isRunning else {
            self.child = nil
            return
        }
        child.terminate()
        child.waitUntilExit()
        self.child = nil
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
