import Foundation

public enum JSONCoding {
    public static func encoder(pretty: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = pretty
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func encodeString<T: Encodable>(_ value: T, pretty: Bool = false) throws -> String {
        let data = try encoder(pretty: pretty).encode(value)
        return String(decoding: data, as: UTF8.self)
    }
}

public enum DateCoding {
    private static let lock = NSLock()
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
    private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    public static func iso(_ date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return fractional.string(from: date)
    }

    public static func parseISO(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        defer { lock.unlock() }
        if let date = fractional.date(from: trimmed) { return date }
        if let date = plain.date(from: trimmed) { return date }
        return nil
    }

    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 1970, components.month ?? 1, components.day ?? 1)
    }

    public static func dayStart(_ date: Date, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: date)
    }

    public static func dayInterval(for date: Date, calendar: Calendar = .current) -> DateInterval {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return DateInterval(start: start, end: end)
    }

    public static func dayInterval(dayKey: String, calendar: Calendar = .current) -> DateInterval? {
        guard let date = parseDay(dayKey, calendar: calendar) else { return nil }
        return dayInterval(for: date, calendar: calendar)
    }

    public static func parseDay(_ value: String, calendar: Calendar = .current) -> Date? {
        let parts = value.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else { return nil }
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = day
        components.hour = 0
        guard let date = calendar.date(from: components) else { return nil }
        let validated = calendar.dateComponents([.year, .month, .day], from: date)
        guard validated.year == year, validated.month == month, validated.day == day else {
            return nil
        }
        return date
    }

    public static func human(_ date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }

    public static func timeOnly(_ date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

public enum PSLog {
    public enum Level: String {
        case debug = "DEBUG"
        case info = "INFO"
        case warn = "WARN"
        case error = "ERROR"
    }

    private static let lock = NSLock()
    private static let level: Level = {
        switch ProcessInfo.processInfo.environment["PRIVATE_SECRETARY_LOG_LEVEL"]?.lowercased() {
        case "debug": return .debug
        case "warn": return .warn
        case "error": return .error
        default: return .info
        }
    }()

    public static func debug(_ message: String) { write(.debug, message) }
    public static func info(_ message: String) { write(.info, message) }
    public static func warn(_ message: String) { write(.warn, message) }
    public static func error(_ message: String) { write(.error, message) }

    private static func write(_ messageLevel: Level, _ message: String) {
        let ranks: [Level: Int] = [.debug: 0, .info: 1, .warn: 2, .error: 3]
        guard (ranks[messageLevel] ?? 1) >= (ranks[level] ?? 1) else { return }
        let line = "[\(DateCoding.iso(Date()))] [\(messageLevel.rawValue)] \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        if let data = line.data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }
}

public struct CommandResult: Equatable, Sendable {
    public var exitCode: Int32
    public var stdout: Data
    public var stderr: Data
    public var timedOut: Bool

    public init(exitCode: Int32, stdout: Data, stderr: Data, timedOut: Bool = false) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }

    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

public enum CommandRunnerError: Error, LocalizedError {
    case launchFailed(String)
    case timedOut(seconds: Double)
    case nonZeroExit(code: Int32, stderr: String)
    case outputTooLarge(limit: Int)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let message): return "Failed to launch command: \(message)"
        case .timedOut(let seconds): return "Command timed out after \(seconds)s"
        case .nonZeroExit(let code, let stderr):
            let excerpt = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "Command exited with \(code): \(excerpt.isEmpty ? "no stderr" : String(excerpt.prefix(800)))"
        case .outputTooLarge(let limit): return "Command output exceeded \(limit) bytes"
        }
    }
}

public enum CommandRunner {
    public static func run(
        executable: String,
        arguments: [String],
        stdin: Data? = nil,
        timeoutSeconds: Double = 20,
        maxOutputBytes: Int = 1_048_576,
        environment: [String: String]? = nil
    ) throws -> CommandResult {
        guard !executable.isEmpty else {
            throw CommandRunnerError.launchFailed("empty executable path")
        }
        let process = Process()
        let resolved = executable.hasPrefix("/")
            ? executable
            : (findExecutable(executable) ?? executable)
        if resolved.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: resolved)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [resolved] + arguments
        }
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw CommandRunnerError.launchFailed("\(resolved): \(error.localizedDescription)")
        }

        if let stdin {
            if stdin.count > 8 * 1_024 * 1_024 {
                process.terminate()
                throw CommandRunnerError.outputTooLarge(limit: 8 * 1_024 * 1_024)
            }
            DispatchQueue.global(qos: .utility).async {
                do {
                    try stdinPipe.fileHandleForWriting.write(contentsOf: stdin)
                } catch {
                    PSLog.debug("command stdin closed early: \(error.localizedDescription)")
                }
                try? stdinPipe.fileHandleForWriting.close()
            }
        } else {
            try? stdinPipe.fileHandleForWriting.close()
        }

        let readGroup = DispatchGroup()
        var stdout = Data()
        var stderr = Data()
        let outputLock = NSLock()

        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            outputLock.lock(); stdout = data; outputLock.unlock()
            readGroup.leave()
        }
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            outputLock.lock(); stderr = data; outputLock.unlock()
            readGroup.leave()
        }

        let deadline = Date().addingTimeInterval(max(0.1, timeoutSeconds))
        while process.isRunning && Date() < deadline {
            usleep(20_000)
        }
        var timedOut = false
        if process.isRunning {
            timedOut = true
            process.terminate()
            let killDeadline = Date().addingTimeInterval(1.5)
            while process.isRunning && Date() < killDeadline {
                usleep(20_000)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()
        _ = readGroup.wait(timeout: .now() + 2)
        outputLock.lock()
        let out = stdout
        let err = stderr
        outputLock.unlock()

        if out.count + err.count > maxOutputBytes {
            throw CommandRunnerError.outputTooLarge(limit: maxOutputBytes)
        }
        if timedOut {
            throw CommandRunnerError.timedOut(seconds: timeoutSeconds)
        }
        return CommandResult(exitCode: process.terminationStatus, stdout: out, stderr: err)
    }

    private static func findExecutable(_ name: String) -> String? {
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

public enum FileLock {
    /// Minimal advisory lock used for daemon single-instance protection.
    public final class Lock {
        private let fileDescriptor: Int32
        private let url: URL
        private var held = false

        public init(url: URL) throws {
            self.url = url
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            fileDescriptor = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            guard fileDescriptor >= 0 else {
                throw NSError(domain: "PrivateSecretary.FileLock", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Cannot open lock file \(url.path)"
                ])
            }
            guard flock(fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
                close(fileDescriptor)
                throw NSError(domain: "PrivateSecretary.FileLock", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Another instance holds \(url.path)"
                ])
            }
            held = true
            ftruncate(fileDescriptor, 0)
            let pid = "\(getpid())\n"
            _ = pid.withCString { write(fileDescriptor, $0, strlen($0)) }
        }

        public func unlock() {
            guard held else { return }
            flock(fileDescriptor, LOCK_UN)
            close(fileDescriptor)
            held = false
            try? FileManager.default.removeItem(at: url)
        }

        deinit { unlock() }
    }
}
