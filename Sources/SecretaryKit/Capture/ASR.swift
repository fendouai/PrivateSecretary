import Foundation

public protocol TranscriptionProviding: Sendable {
    func transcribe(samples: [Float], sampleRate: Int) throws -> String
    var name: String { get }
}

public enum ASRError: Error, LocalizedError {
    case notConfigured
    case binaryUnavailable(String)
    case modelUnavailable(String)
    case invalidAudio
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "ASR is not configured. Set capture.whisperModel to a whisper.cpp model path."
        case .binaryUnavailable(let path): return "ASR binary not found: \(path)"
        case .modelUnavailable(let path): return "ASR model not found: \(path)"
        case .invalidAudio: return "Invalid or empty audio segment"
        case .failed(let message): return "ASR failed: \(message)"
        }
    }
}

public enum WAVWriter {
    public static func pcm16Mono(samples: [Float], sampleRate: Int) -> Data {
        let clipped = samples.map { max(-1, min(1, $0)) }
        let dataSize = clipped.count * 2
        var data = Data(capacity: 44 + dataSize)
        func appendASCII(_ string: String) {
            data.append(contentsOf: string.utf8)
        }
        func appendUInt32(_ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        func appendUInt16(_ value: UInt16) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        appendASCII("RIFF")
        appendUInt32(UInt32(36 + dataSize))
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendUInt32(16)
        appendUInt16(1) // PCM
        appendUInt16(1) // mono
        appendUInt32(UInt32(sampleRate))
        appendUInt32(UInt32(sampleRate * 2))
        appendUInt16(2)
        appendUInt16(16)
        appendASCII("data")
        appendUInt32(UInt32(dataSize))
        for sample in clipped {
            let intSample = Int16(max(-32_768, min(32_767, sample * 32_767)))
            appendUInt16(UInt16(bitPattern: intSample))
        }
        return data
    }
}

public final class WhisperCLITranscriber: TranscriptionProviding, @unchecked Sendable {
    private let config: CaptureConfig
    private let temporaryDirectory: URL
    private let lock = NSLock()

    public init(config: CaptureConfig, temporaryDirectory: URL) {
        self.config = config
        self.temporaryDirectory = temporaryDirectory
    }

    public var name: String {
        config.whisperModel.isEmpty ? "whisper:unconfigured" : "whisper:\(config.whisperLanguage)"
    }

    public func transcribe(samples: [Float], sampleRate: Int) throws -> String {
        guard !config.whisperModel.isEmpty else { throw ASRError.notConfigured }
        guard !samples.isEmpty else { throw ASRError.invalidAudio }
        let binary = SystemDiagnostics.locateExecutable(config.whisperBinary)
        guard let binary else { throw ASRError.binaryUnavailable(config.whisperBinary) }
        let modelPath = (config.whisperModel as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw ASRError.modelUnavailable(modelPath)
        }

        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let file = temporaryDirectory.appendingPathComponent("asr-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: file) }
        try WAVWriter.pcm16Mono(samples: resample(samples, from: sampleRate, to: 16_000), sampleRate: 16_000)
            .write(to: file, options: [.atomic])

        let result = try CommandRunner.run(
            executable: binary,
            arguments: [
                "-m", modelPath,
                "-f", file.path,
                "-l", config.whisperLanguage,
                "-t", "\(max(1, config.whisperThreads))",
                "-nt",
                "-np"
            ],
            timeoutSeconds: 180,
            maxOutputBytes: 2_097_152
        )
        guard result.exitCode == 0 else {
            throw ASRError.failed(result.stderrString.isEmpty ? "exit \(result.exitCode)" : result.stderrString)
        }
        let cleaned = result.stdoutString
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                !line.isEmpty
                    && !line.contains("BLANK_AUDIO")
                    && !line.hasPrefix("[")
                    && !line.hasPrefix("(")
            }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned
    }

    private func resample(_ samples: [Float], from inputRate: Int, to outputRate: Int) -> [Float] {
        guard inputRate != outputRate, !samples.isEmpty, inputRate > 0, outputRate > 0 else {
            return samples
        }
        let ratio = Double(outputRate) / Double(inputRate)
        let outputCount = max(1, Int(Double(samples.count) * ratio))
        var output = [Float](repeating: 0, count: outputCount)
        for index in 0..<outputCount {
            let position = Double(index) / ratio
            let lower = min(samples.count - 1, Int(position))
            let upper = min(samples.count - 1, lower + 1)
            let fraction = Float(position - Double(lower))
            output[index] = samples[lower] * (1 - fraction) + samples[upper] * fraction
        }
        return output
    }
}
