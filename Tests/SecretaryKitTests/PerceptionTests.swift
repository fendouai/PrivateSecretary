import Testing
import CoreGraphics
import ImageIO
@testable import SecretaryKit

private func fixtureImage() throws -> CGImage {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/ocr-hnsw.png")
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing OCR fixture"])
    }
    return image
}

private func speechSamples(ms: Int) -> [Float] {
    [Float](repeating: 0.9, count: ms)
}

private func silenceSamples(ms: Int) -> [Float] {
    [Float](repeating: 0.0, count: ms)
}

private struct ThresholdVAD: VoiceActivityDetecting {
    let threshold: Float
    func isSpeech(samples: [Float], sampleRate: Int) -> Bool {
        samples.contains { abs($0) >= threshold }
    }
}

@Test func audioRingEvictsOldestSamples() {
    let ring = AudioRingBuffer(seconds: 1, sampleRate: 10)
    ring.append(Array(repeating: 1, count: 7))
    ring.append(Array(repeating: 2, count: 7))
    #expect(ring.count == 10)
    let snapshot = ring.snapshot()
    #expect(Array(snapshot.prefix(3)) == [1, 1, 1])
    #expect(Array(snapshot.suffix(7)) == Array(repeating: 2, count: 7))
}

@Test func screenEventRingCapacity() {
    let ring = ScreenEventRingBuffer(capacity: 2)
    for index in 0..<3 {
        ring.append(ScreenEvent(
            timestamp: Date(timeIntervalSince1970: Double(index)),
            changedRatio: 0.1,
            regions: [],
            signature: UInt64(index)
        ))
    }
    #expect(ring.count == 2)
    #expect(ring.snapshot().map(\.signature) == [1, 2])
}

@Test func energyVADDistinguishesSpeechFromSilence() {
    let vad = EnergyVAD(threshold: 0.01, zeroCrossingThreshold: 0.01)
    let sampleRate = 16_000
    let speech = (0..<320).map { index in
        Float(0.2 * sin(2 * Double.pi * 220 * Double(index) / Double(sampleRate)))
    }
    let silence = [Float](repeating: 0.0001, count: 320)
    #expect(vad.isSpeech(samples: speech, sampleRate: sampleRate))
    #expect(!vad.isSpeech(samples: silence, sampleRate: sampleRate))
    #expect(!vad.isSpeech(samples: [], sampleRate: sampleRate))
}

@Test func segmenterEmitsSpeechWithPreRoll() throws {
    var config = AppConfig()
    config.capture.vadFrameMilliseconds = 20
    config.capture.preRollMilliseconds = 100
    config.capture.silenceHangoverMilliseconds = 100
    config.capture.minimumSpeechMilliseconds = 100
    config.capture.maximumSegmentSeconds = 5
    let segmenter = AudioSegmenter(
        config: config.capture,
        sampleRate: 1_000,
        vad: ThresholdVAD(threshold: 0.5)
    )
    let start = Date(timeIntervalSince1970: 1_000)
    var segments: [AudioSegment] = []
    segments += segmenter.append(samples: silenceSamples(ms: 200), capturedAt: start)
    segments += segmenter.append(
        samples: speechSamples(ms: 200),
        capturedAt: start.addingTimeInterval(0.2)
    )
    segments += segmenter.append(
        samples: silenceSamples(ms: 200),
        capturedAt: start.addingTimeInterval(0.4)
    )
    #expect(segments.count == 1)
    let segment = try #require(segments.first)
    #expect(segment.durationSeconds >= 0.35)
    #expect(segment.durationSeconds <= 0.8)
    #expect(segment.startedAt < start.addingTimeInterval(0.3))
}

@Test func segmenterDropsTooShortSpeech() {
    var config = AppConfig()
    config.capture.vadFrameMilliseconds = 20
    config.capture.minimumSpeechMilliseconds = 200
    config.capture.silenceHangoverMilliseconds = 80
    let segmenter = AudioSegmenter(
        config: config.capture,
        sampleRate: 1_000,
        vad: ThresholdVAD(threshold: 0.5)
    )
    let start = Date()
    _ = segmenter.append(samples: speechSamples(ms: 60), capturedAt: start)
    let segments = segmenter.append(
        samples: silenceSamples(ms: 200),
        capturedAt: start.addingTimeInterval(0.06)
    )
    #expect(segments.isEmpty)
}

@Test func segmenterFlushEmitsActiveSpeech() {
    var config = AppConfig()
    config.capture.vadFrameMilliseconds = 20
    config.capture.minimumSpeechMilliseconds = 100
    config.capture.silenceHangoverMilliseconds = 500
    let segmenter = AudioSegmenter(
        config: config.capture,
        sampleRate: 1_000,
        vad: ThresholdVAD(threshold: 0.5)
    )
    _ = segmenter.append(samples: speechSamples(ms: 200), capturedAt: Date())
    let flushed = segmenter.flush()
    #expect(flushed.count == 1)
    #expect((flushed.first?.durationSeconds ?? 0) > 0.1)
}

@Test func screenFirstFrameIsWholeScreenChange() {
    let differ = ScreenDiffer(threshold: 0.01, pixelDelta: 0.1)
    let pixels = [UInt8](repeating: 10, count: ScreenDiffer.thumbnailWidth * ScreenDiffer.thumbnailHeight)
    let delta = differ.analyze(luma: pixels)
    #expect(delta.changed)
    #expect(delta.isFirstFrame)
    #expect(delta.changedRatio == 1)
}

@Test func screenIdenticalFrameHasNoChange() {
    let differ = ScreenDiffer(threshold: 0.01, pixelDelta: 0.1)
    let pixels = [UInt8](repeating: 20, count: ScreenDiffer.thumbnailWidth * ScreenDiffer.thumbnailHeight)
    _ = differ.analyze(luma: pixels)
    let delta = differ.analyze(luma: pixels)
    #expect(!delta.changed)
    #expect(delta.changedRatio == 0)
    #expect(delta.regions.isEmpty)
}

@Test func screenChangedRegionIsDetected() {
    let differ = ScreenDiffer(threshold: 0.001, pixelDelta: 0.1)
    var pixels = [UInt8](repeating: 10, count: ScreenDiffer.thumbnailWidth * ScreenDiffer.thumbnailHeight)
    _ = differ.analyze(luma: pixels)
    for row in 10..<14 {
        for column in 5..<20 {
            pixels[row * ScreenDiffer.thumbnailWidth + column] = 220
        }
    }
    let delta = differ.analyze(luma: pixels)
    #expect(delta.changed)
    #expect(delta.changedRatio > 0)
    #expect(!delta.regions.isEmpty)
    let expected = CGRect(
        x: 5.0 / 64.0,
        y: 10.0 / 36.0,
        width: 15.0 / 64.0,
        height: 4.0 / 36.0
    )
    #expect(delta.regions.contains { $0.intersects(expected) })
}

@Test func screenImageThumbnailAndAnalysis() throws {
    let image = try fixtureImage()
    let differ = ScreenDiffer(threshold: 0.001, pixelDelta: 0.05)
    #expect(differ.analyze(image: image).changed)
    #expect(!differ.analyze(image: image).changed)
}

@Test func visionRecognizesTextAndReturnsTopLeftRegions() throws {
    let image = try fixtureImage()
    let service = VisionOCRService(languages: ["en-US"], minimumConfidence: 0.2)
    let regions = try service.recognize(image: image, changedRegions: nil)
    let text = regions.map(\.text).joined(separator: " ").lowercased()
    #expect(text.contains("hnsw"), "OCR text was: \(text)")
    #expect(text.contains("200"), "OCR text was: \(text)")
    #expect(regions.allSatisfy { $0.y >= 0 && $0.y <= 1 && $0.x >= 0 && $0.x <= 1 })
}

@Test func changedRegionFilterCanExcludeText() throws {
    let image = try fixtureImage()
    let service = VisionOCRService(languages: ["en-US"], minimumConfidence: 0.2)
    let regions = try service.recognize(
        image: image,
        changedRegions: [CGRect(x: 0, y: 0.9, width: 1, height: 0.1)]
    )
    #expect(regions.isEmpty)
}

@Test func wavHeaderAndDataSize() {
    let data = WAVWriter.pcm16Mono(samples: [0, 0.5, -0.5], sampleRate: 16_000)
    #expect(data.count == 44 + 6)
    #expect(String(decoding: data[0..<4], as: UTF8.self) == "RIFF")
    #expect(String(decoding: data[8..<12], as: UTF8.self) == "WAVE")
    #expect(String(decoding: data[36..<40], as: UTF8.self) == "data")
}

@Test func linearResampleLength() {
    let samples = [Float](repeating: 0.1, count: 480)
    let output = PCMExtractor.linearResample(samples, from: 48_000, to: 16_000)
    #expect(output.count == 160)
    #expect(abs(output[0] - 0.1) < 0.0001)
}

@Test func whisperUnavailableWithoutConfig() {
    var config = AppConfig()
    config.capture.whisperModel = ""
    let transcriber = WhisperCLITranscriber(
        config: config.capture,
        temporaryDirectory: FileManager.default.temporaryDirectory
    )
    #expect(throws: ASRError.self) {
        _ = try transcriber.transcribe(samples: [0.1], sampleRate: 16_000)
    }
}

@Test func whisperEmptySamples() {
    var config = AppConfig()
    config.capture.whisperModel = "/tmp/missing.bin"
    let transcriber = WhisperCLITranscriber(
        config: config.capture,
        temporaryDirectory: FileManager.default.temporaryDirectory
    )
    #expect(throws: ASRError.self) {
        _ = try transcriber.transcribe(samples: [], sampleRate: 16_000)
    }
}

@Test func whisperRealModelWhenConfigured() throws {
    guard let model = ProcessInfo.processInfo.environment["PRIVATE_SECRETARY_TEST_WHISPER_MODEL"],
          FileManager.default.fileExists(atPath: model),
          FileManager.default.isExecutableFile(atPath: "/usr/bin/say"),
          SystemDiagnostics.locateExecutable("ffmpeg") != nil else {
        return
    }
    let temp = FileManager.default.temporaryDirectory
        .appendingPathComponent("ps-asr-\(UUID().uuidString).aiff")
    let raw = FileManager.default.temporaryDirectory
        .appendingPathComponent("ps-asr-\(UUID().uuidString).f32le")
    defer {
        try? FileManager.default.removeItem(at: temp)
        try? FileManager.default.removeItem(at: raw)
    }
    _ = try CommandRunner.run(
        executable: "/usr/bin/say",
        arguments: ["-o", temp.path, "HNSW parameters two hundred"],
        timeoutSeconds: 20
    )
    _ = try CommandRunner.run(
        executable: SystemDiagnostics.locateExecutable("ffmpeg")!,
        arguments: ["-y", "-i", temp.path, "-ar", "16000", "-ac", "1", "-f", "f32le", raw.path],
        timeoutSeconds: 30
    )
    let data = try Data(contentsOf: raw)
    let samples = data.withUnsafeBytes { bytes in
        Array(bytes.bindMemory(to: Float.self))
    }
    var config = AppConfig()
    config.capture.whisperModel = model
    config.capture.whisperLanguage = "en"
    config.capture.whisperBinary = "whisper-cli"
    let transcriber = WhisperCLITranscriber(
        config: config.capture,
        temporaryDirectory: FileManager.default.temporaryDirectory
    )
    let text = try transcriber.transcribe(samples: samples, sampleRate: 16_000)
    #expect(!text.isEmpty)
    #expect(text.lowercased().contains("hnsw") || text.contains("200"))
}
