import Foundation
import CoreGraphics

public struct DoctorCheck: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var status: String
    public var detail: String

    public init(id: String, status: String, detail: String) {
        self.id = id
        self.status = status
        self.detail = detail
    }
}

public struct DoctorReport: Codable, Equatable, Sendable {
    public var generatedAt: Date
    public var checks: [DoctorCheck]

    public init(generatedAt: Date = Date(), checks: [DoctorCheck]) {
        self.generatedAt = generatedAt
        self.checks = checks
    }

    public var hasFailure: Bool {
        checks.contains { $0.status == "fail" }
    }
}

public enum SystemDiagnostics {
    public static func run(
        paths: AppPaths,
        config: AppConfig,
        store: MemoryStore
    ) -> DoctorReport {
        var checks: [DoctorCheck] = []
        do {
            let counts = try store.counts()
            checks.append(DoctorCheck(
                id: "database",
                status: "ok",
                detail: "\(paths.databaseFile.path) · \(counts.episodes) episodes / \(counts.activeFacts) facts"
            ))
        } catch {
            checks.append(DoctorCheck(id: "database", status: "fail", detail: error.localizedDescription))
        }

        checks.append(DoctorCheck(
            id: "config",
            status: config.validationErrors.isEmpty ? "ok" : "fail",
            detail: config.validationErrors.isEmpty
                ? paths.configFile.path
                : config.validationErrors.joined(separator: "; ")
        ))

        let screenPermission = CGPreflightScreenCaptureAccess()
        checks.append(DoctorCheck(
            id: "screen_recording_tcc",
            status: screenPermission ? "ok" : "warn",
            detail: screenPermission
                ? "Screen Recording permission is granted for the current process identity."
                : "Not granted. Demo/CLI/MCP work; live capture needs System Settings → Privacy & Security → Screen Recording, then restart the daemon."
        ))

        if config.capture.whisperModel.isEmpty {
            checks.append(DoctorCheck(
                id: "asr",
                status: "warn",
                detail: "whisperModel is empty. Screen OCR works; system-audio segments will be skipped. Set capture.whisperModel or use a CoreML ASR adapter."
            ))
        } else {
            let modelPath = (config.capture.whisperModel as NSString).expandingTildeInPath
            let exists = FileManager.default.fileExists(atPath: modelPath)
            checks.append(DoctorCheck(
                id: "asr",
                status: exists ? "ok" : "fail",
                detail: exists ? "ASR model: \(modelPath)" : "ASR model not found: \(modelPath)"
            ))
        }

        if let whisper = locateExecutable(config.capture.whisperBinary) {
            checks.append(DoctorCheck(id: "asr_binary", status: "ok", detail: whisper))
        } else {
            checks.append(DoctorCheck(
                id: "asr_binary",
                status: "warn",
                detail: "\(config.capture.whisperBinary) not found on PATH; install whisper.cpp or configure capture.whisperBinary."
            ))
        }

        checks.append(DoctorCheck(
            id: "ocr",
            status: "ok",
            detail: "Apple Vision OCR (on-device) is available. Languages: \(config.capture.ocrLanguages.joined(separator: ", ")); no image ever persists."
        ))

        if config.intentGate.model.enabled {
            let exists = FileManager.default.isExecutableFile(
                atPath: (config.intentGate.model.executable as NSString).expandingTildeInPath
            )
            checks.append(DoctorCheck(
                id: "intent_model",
                status: exists ? "ok" : "fail",
                detail: exists ? config.intentGate.model.executable : "Configured intent model is not executable."
            ))
        } else {
            checks.append(DoctorCheck(
                id: "intent_model",
                status: "ok",
                detail: "Rules-only intent gate. LLM adapter disabled; deterministic and low power."
            ))
        }

        let status = CaptureStatusStore(paths: paths).read()
        checks.append(DoctorCheck(
            id: "capture_daemon",
            status: status == nil ? "warn" : (status?.state == "running" ? "ok" : "warn"),
            detail: status.map { "\($0.state): \($0.detail ?? "")" } ?? "No capture status published; daemon is not running."
        ))

        return DoctorReport(checks: checks)
    }

    public static func locateExecutable(_ name: String) -> String? {
        if name.contains("/") {
            let path = (name as NSString).expandingTildeInPath
            return FileManager.default.isExecutableFile(atPath: path) ? path : nil
        }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let directories = path.split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        for directory in directories {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}
