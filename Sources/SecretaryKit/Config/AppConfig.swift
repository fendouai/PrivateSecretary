import Foundation

public struct AppPaths: Sendable {
    public let home: URL

    public init(home: URL? = nil) {
        if let home {
            self.home = home.standardizedFileURL
        } else if let env = ProcessInfo.processInfo.environment["PRIVATE_SECRETARY_HOME"], !env.isEmpty {
            self.home = URL(fileURLWithPath: (env as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            self.home = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".private-secretary", isDirectory: true)
        }
    }

    public var configFile: URL { home.appendingPathComponent("config.json") }
    public var databaseFile: URL { home.appendingPathComponent("secretary.sqlite") }
    public var coldArchiveDirectory: URL { home.appendingPathComponent("cold", isDirectory: true) }
    public var logDirectory: URL { home.appendingPathComponent("logs", isDirectory: true) }
    public var runDirectory: URL { home.appendingPathComponent("run", isDirectory: true) }
    public var temporaryDirectory: URL { home.appendingPathComponent("tmp", isDirectory: true) }
    public var exportsDirectory: URL { home.appendingPathComponent("exports", isDirectory: true) }
    public var socketFile: URL { runDirectory.appendingPathComponent("secretaryd.sock") }
    public var pidFile: URL { runDirectory.appendingPathComponent("secretaryd.pid") }
    public var daemonLog: URL { logDirectory.appendingPathComponent("secretaryd.log") }
    public var consolidationLog: URL { logDirectory.appendingPathComponent("consolidate.log") }

    public func ensureDirectories() throws {
        let fm = FileManager.default
        for directory in [home, coldArchiveDirectory, logDirectory, runDirectory, temporaryDirectory, exportsDirectory] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
    }
}

public struct StorageConfig: Codable, Equatable, Sendable {
    public var sqliteBusyTimeoutMilliseconds: Int = 4_000
}

public struct PrivacyConfig: Codable, Equatable, Sendable {
    public var excludedApplications: [String] = [
        "Keychain Access", "1Password", "1Password 8", "Bitwarden", "LastPass"
    ]
    public var purgeColdArchiveOnDelete: Bool = true
}

public struct CaptureConfig: Codable, Equatable, Sendable {
    public var vadThreshold: Double = 0.012
    public var vadFrameMilliseconds: Int = 20
    public var preRollMilliseconds: Int = 320
    public var silenceHangoverMilliseconds: Int = 720
    public var minimumSpeechMilliseconds: Int = 420
    public var maximumSegmentSeconds: Double = 28
    public var audioRingSeconds: Int = 60
    public var screenRingFrames: Int = 30
    public var frameDiffThreshold: Double = 0.018
    public var frameIntervalMilliseconds: Int = 900
    public var microphoneEnabled: Bool = false
    public var whisperBinary: String = "whisper-cli"
    public var whisperModel: String = ""
    public var whisperLanguage: String = "zh"
    public var whisperThreads: Int = 4
    public var ocrLanguages: [String] = ["zh-Hans", "en-US"]
    public var ocrMinimumConfidence: Double = 0.35
    public var ocrMinimumNewCharacters: Int = 4
}

public struct CommandModelConfig: Codable, Equatable, Sendable {
    public var enabled: Bool = false
    public var executable: String = ""
    public var arguments: [String] = []
    public var timeoutSeconds: Double = 20
    public var maxOutputBytes: Int = 1_048_576
}

public struct IntentGateConfig: Codable, Equatable, Sendable {
    public var enabled: Bool = true
    public var explicitThreshold: Double = 0.8
    public var uncertainThreshold: Double = 0.42
    public var minimumTextLength: Int = 4
    public var minimumRuleConfidence: Double = 0.82
    public var duplicateSimilarity: Double = 0.92
    public var duplicateWindowSeconds: Double = 120
    public var appThrottleSeconds: Double = 30
    public var maximumRoutedTextLength: Int = 160
    public var model: CommandModelConfig = CommandModelConfig()
}

public struct FactGateConfig: Codable, Equatable, Sendable {
    public var minimumConfidence: Double = 0.68
    public var minimumSalience: Double = 0.28
    public var duplicateSimilarity: Double = 0.9
    public var supersedeConfidenceMargin: Double = 0.08
    public var maximumStatementLength: Int = 320
    public var model: CommandModelConfig = CommandModelConfig()
}

public struct SalienceConfig: Codable, Equatable, Sendable {
    public var threshold: Double = 0.30
    public var weights = SalienceWeights()
    public var decayHalfLifeDays: Double = 21
    public var minimumRetentionDays: Double = 14
    public var archiveBelowWeight: Double = 0.1
    public var accessBoostCap: Double = 0.2
}

public struct ConsolidationConfig: Codable, Equatable, Sendable {
    public var maximumDigestEntries: Int = 20
    public var maximumClusterGapSeconds: Double = 600
    public var maximumEpisodesPerRun: Int = 5_000
    public var extractMissingFacts: Bool = true
}

public struct RetrievalConfig: Codable, Equatable, Sendable {
    public var defaultLimit: Int = 8
    public var maximumLimit: Int = 20
    public var candidateLimit: Int = 10_000
    public var vectorDimensions: Int = 384
    public var summaryCharacterLimit: Int = 280
    public var lexicalWeight: Double = 0.52
    public var vectorWeight: Double = 0.30
    public var recencyWeight: Double = 0.10
    public var salienceWeight: Double = 0.08
    public var recencyHalfLifeDays: Double = 30
}

public struct DaemonConfig: Codable, Equatable, Sendable {
    public var maximumRequestBytes: Int = 2_097_152
    public var healthIntervalSeconds: Double = 30
}

public struct AppConfig: Codable, Equatable, Sendable {
    public var storage = StorageConfig()
    public var privacy = PrivacyConfig()
    public var capture = CaptureConfig()
    public var intentGate = IntentGateConfig()
    public var factGate = FactGateConfig()
    public var salience = SalienceConfig()
    public var consolidation = ConsolidationConfig()
    public var retrieval = RetrievalConfig()
    public var daemon = DaemonConfig()

    public init() {}

    public var validationErrors: [String] {
        var errors: [String] = []
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { errors.append(message) }
        }
        check(capture.vadThreshold > 0 && capture.vadThreshold < 1, "capture.vadThreshold must be in (0, 1)")
        check(capture.frameDiffThreshold > 0 && capture.frameDiffThreshold < 1, "capture.frameDiffThreshold must be in (0, 1)")
        check(capture.audioRingSeconds >= 5 && capture.audioRingSeconds <= 600, "capture.audioRingSeconds must be 5...600")
        check(capture.screenRingFrames >= 1 && capture.screenRingFrames <= 600, "capture.screenRingFrames must be 1...600")
        check(intentGate.explicitThreshold > 0 && intentGate.explicitThreshold <= 1, "intentGate.explicitThreshold must be in (0, 1]")
        check(intentGate.uncertainThreshold >= 0 && intentGate.uncertainThreshold <= intentGate.explicitThreshold, "intentGate.uncertainThreshold must be <= explicitThreshold")
        check(factGate.minimumConfidence >= 0 && factGate.minimumConfidence <= 1, "factGate.minimumConfidence must be in [0, 1]")
        check(factGate.minimumSalience >= 0 && factGate.minimumSalience <= 1, "factGate.minimumSalience must be in [0, 1]")
        check(salience.threshold >= 0 && salience.threshold <= 1, "salience.threshold must be in [0, 1]")
        check(salience.decayHalfLifeDays > 0, "salience.decayHalfLifeDays must be positive")
        check(retrieval.defaultLimit > 0 && retrieval.defaultLimit <= retrieval.maximumLimit, "retrieval.defaultLimit must be in 1...maximumLimit")
        check(retrieval.vectorDimensions >= 64, "retrieval.vectorDimensions must be >= 64")
        check(consolidation.maximumDigestEntries >= 1, "consolidation.maximumDigestEntries must be >= 1")
        return errors
    }
}

public enum ConfigError: Error, LocalizedError {
    case invalid(String)
    case unreadable(String)
    case cannotWrite(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let message): return "Invalid configuration: \(message)"
        case .unreadable(let message): return "Cannot read configuration: \(message)"
        case .cannotWrite(let message): return "Cannot write configuration: \(message)"
        }
    }
}

public enum AppConfigLoader {
    public static func loadOrCreate(paths: AppPaths, forceDefault: Bool = false) throws -> AppConfig {
        try paths.ensureDirectories()
        if !FileManager.default.fileExists(atPath: paths.configFile.path) || forceDefault {
            let config = AppConfig()
            try save(config, to: paths.configFile)
            return config
        }
        return try load(from: paths.configFile)
    }

    public static func load(from url: URL) throws -> AppConfig {
        do {
            let data = try Data(contentsOf: url)
            let config = try decodeMerged(data)
            let errors = config.validationErrors
            guard errors.isEmpty else { throw ConfigError.invalid(errors.joined(separator: "; ")) }
            return config
        } catch let error as ConfigError {
            throw error
        } catch {
            throw ConfigError.unreadable("\(url.path): \(error.localizedDescription)")
        }
    }

    public static func decodeMerged(_ data: Data) throws -> AppConfig {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let defaultsData = try encoder.encode(AppConfig())
        guard var defaults = try JSONSerialization.jsonObject(with: defaultsData) as? [String: Any] else {
            throw ConfigError.invalid("default config is not an object")
        }
        guard let user = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConfigError.invalid("config root must be an object")
        }
        merge(base: &defaults, overlay: user)
        let mergedData = try JSONSerialization.data(withJSONObject: defaults)
        return try JSONDecoder().decode(AppConfig.self, from: mergedData)
    }

    private static func merge(base: inout [String: Any], overlay: [String: Any]) {
        for (key, value) in overlay {
            if let nestedBase = base[key] as? [String: Any], let nestedOverlay = value as? [String: Any] {
                var nested = nestedBase
                merge(base: &nested, overlay: nestedOverlay)
                base[key] = nested
            } else {
                base[key] = value
            }
        }
    }

    public static func save(_ config: AppConfig, to url: URL) throws {
        let errors = config.validationErrors
        guard errors.isEmpty else { throw ConfigError.invalid(errors.joined(separator: "; ")) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try encoder.encode(config).write(to: url, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw ConfigError.cannotWrite("\(url.path): \(error.localizedDescription)")
        }
    }
}
