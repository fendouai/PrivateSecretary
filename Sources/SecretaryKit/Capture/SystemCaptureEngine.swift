import Foundation
import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreImage
import CoreGraphics
import Carbon
import AVFoundation

/// ScreenCaptureKit adapter. This is the only component that touches raw
/// pixels/audio; it publishes structured CandidatePackets and never writes
/// frames or waveforms to disk.
public final class SystemCaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public typealias CandidateHandler = @Sendable (CandidatePacket) -> Void
    public typealias HealthHandler = @Sendable (CaptureHealth) -> Void

    private let config: AppConfig
    private let paths: AppPaths
    private let ocr: any OCRProviding
    private let transcriber: any TranscriptionProviding
    private let onCandidate: CandidateHandler
    private let onHealth: HealthHandler

    private let stateLock = NSLock()
    private let screenQueue = DispatchQueue(label: "com.privatesecretary.capture.screen", qos: .utility)
    private let audioQueue = DispatchQueue(label: "com.privatesecretary.capture.audio", qos: .userInitiated)
    private let asrQueue = DispatchQueue(label: "com.privatesecretary.capture.asr", qos: .utility)
    private var stream: SCStream?
    private var running = false
    private var microphoneActive = false
    private var lastFrameAt: Date?
    private var lastAudioSegmentAt: Date?
    private var screenshotsProcessed = 0
    private var ocrFramesProcessed = 0
    private var audioSecondsProcessed = 0.0
    private var audioSegmentsProcessed = 0
    private var sessionStartedAt: Date?
    private var lastHealthWrite = Date.distantPast
    private var lastOCRText = ""
    private var lastOCRAt = Date.distantPast
    private var asrErrorReported = false
    private var pcmFormatWarningReported = false
    private var stopRequested = false

    private let differ: ScreenDiffer
    private let screenRing: ScreenEventRingBuffer
    private let audioRing: AudioRingBuffer
    private let segmenter: AudioSegmenter
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    public init(
        config: AppConfig,
        paths: AppPaths,
        ocr: (any OCRProviding)? = nil,
        transcriber: (any TranscriptionProviding)? = nil,
        onCandidate: @escaping CandidateHandler,
        onHealth: @escaping HealthHandler
    ) {
        self.config = config
        self.paths = paths
        self.ocr = ocr ?? VisionOCRService(
            languages: config.capture.ocrLanguages,
            minimumConfidence: config.capture.ocrMinimumConfidence
        )
        self.transcriber = transcriber ?? WhisperCLITranscriber(
            config: config.capture,
            temporaryDirectory: paths.temporaryDirectory
        )
        self.onCandidate = onCandidate
        self.onHealth = onHealth
        self.differ = ScreenDiffer(threshold: config.capture.frameDiffThreshold)
        self.screenRing = ScreenEventRingBuffer(capacity: config.capture.screenRingFrames)
        self.audioRing = AudioRingBuffer(seconds: config.capture.audioRingSeconds, sampleRate: 16_000)
        self.segmenter = AudioSegmenter(config: config.capture, sampleRate: 16_000)
        super.init()
    }

    public var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    public func start() async throws {
        guard CGPreflightScreenCaptureAccess() else {
            let health = CaptureHealth(
                state: "capture_unavailable",
                detail: "Screen Recording permission is not granted. Grant it in System Settings → Privacy & Security → Screen Recording and restart secretaryd.",
                permissionGranted: false
            )
            onHealth(health)
            throw CaptureError.permissionDenied
        }
        if withStateLock({ running }) { return }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw CaptureError.noDisplay
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let streamConfig = SCStreamConfiguration()
        let maxWidth = 1_920.0
        let scale = min(1.0, maxWidth / Double(max(1, display.width)))
        streamConfig.width = max(640, Int(Double(display.width) * scale))
        streamConfig.height = max(360, Int(Double(display.height) * scale))
        streamConfig.minimumFrameInterval = CMTime(
            value: Int64(max(100, config.capture.frameIntervalMilliseconds)),
            timescale: 1_000
        )
        streamConfig.showsCursor = false
        streamConfig.capturesAudio = true
        streamConfig.sampleRate = 16_000
        streamConfig.channelCount = 1
        streamConfig.excludesCurrentProcessAudio = true
        if config.capture.microphoneEnabled {
            if #available(macOS 15.0, *) {
                if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
                    streamConfig.captureMicrophone = true
                    microphoneActive = true
                } else {
                    PSLog.warn("microphone permission not granted; continuing with system audio only")
                }
            } else {
                PSLog.warn("microphone capture requires macOS 15; continuing with system audio only")
            }
        }

        let stream = SCStream(filter: filter, configuration: streamConfig, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: screenQueue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        try await stream.startCapture()
        withStateLock {
            self.stream = stream
            self.running = true
            self.screenshotsProcessed = 0
            self.ocrFramesProcessed = 0
            self.audioSecondsProcessed = 0
            self.audioSegmentsProcessed = 0
            self.sessionStartedAt = Date()
        }
        publishHealth(state: "running", detail: microphoneActive ? "system + microphone audio, screen deltas" : "system audio + screen deltas")
    }

    public func stop() async {
        let stream = withStateLock { () -> SCStream? in
            stopRequested = true
            let current = self.stream
            self.stream = nil
            running = false
            return current
        }
        if let stream {
            try? await stream.stopCapture()
        }
        let segments = segmenter.flush()
        for segment in segments {
            processAudioSegment(segment)
        }
        publishHealth(state: "stopped", detail: "capture stopped")
    }

    // MARK: - SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .screen:
            handleScreen(sampleBuffer)
        case .audio:
            handleAudio(sampleBuffer)
        case .microphone:
            if #available(macOS 15.0, *) {
                handleAudio(sampleBuffer)
            }
        @unknown default:
            break
        }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        stateLock.lock()
        running = false
        stateLock.unlock()
        PSLog.error("capture stream stopped: \(error.localizedDescription)")
        publishHealth(state: "capture_unavailable", detail: error.localizedDescription)
    }

    // MARK: - Screen

    private func handleScreen(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let timestamp = Date()
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(image, from: image.extent) else { return }
        let delta = differ.analyze(image: cgImage)
        screenRing.append(ScreenEvent(
            timestamp: timestamp,
            changedRatio: delta.changedRatio,
            regions: delta.regions,
            signature: delta.signature
        ))
        withStateLock {
            screenshotsProcessed += 1
            lastFrameAt = timestamp
        }

        guard delta.changed, !delta.regions.isEmpty || delta.isFirstFrame else { return }
        // Do not OCR while the system is in secure keyboard input (password
        // entry, auth prompts). This is defense in depth, not a guarantee that
        // every sensitive UI is marked by the OS.
        guard !IsSecureEventInputEnabled() else { return }
        guard timestamp.timeIntervalSince(lastOCRAt) >= 0.9 else { return }
        lastOCRAt = timestamp

        let app = currentApplication()
        guard !isExcluded(app.name) else { return }
        do {
            var regions = try ocr.recognize(
                image: cgImage,
                changedRegions: delta.isFirstFrame ? nil : delta.regions
            )
            if regions.isEmpty, !delta.isFirstFrame {
                // Coordinate-system or destructive-diff edge case: rather than
                // silently losing a screen, fall back to one full-frame OCR.
                regions = try ocr.recognize(image: cgImage, changedRegions: nil)
            }
            guard !regions.isEmpty else { return }
            let text = regions.map(\.text).joined(separator: "\n")
            let normalized = TextAnalyzer.normalize(text)
            guard normalized.count >= config.capture.ocrMinimumNewCharacters else { return }
            guard normalized != lastOCRText else { return }
            lastOCRText = normalized
            withStateLock { ocrFramesProcessed += 1 }
            let candidate = CandidatePacket(
                capturedAt: timestamp,
                source: .screen,
                audioOrigin: .manual,
                application: app.name,
                windowTitle: app.windowTitle,
                transcript: "",
                ocrText: text,
                ocrRegions: regions,
                screenFrameCount: 1
            )
            onCandidate(candidate)
            maybePublishHealth()
        } catch {
            PSLog.warn("OCR failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Audio

    private func handleAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let converted = PCMExtractor.samples(from: sampleBuffer) else {
            if !pcmFormatWarningReported {
                pcmFormatWarningReported = true
                PSLog.warn("capture audio format is not Float32; audio segments are unavailable until the format is supported")
            }
            return
        }
        let samples = PCMExtractor.linearResample(
            converted.samples,
            from: converted.sampleRate,
            to: 16_000
        )
        guard !samples.isEmpty else { return }
        let duration = Double(samples.count) / 16_000
        let timestamp = Date()
        withStateLock { audioSecondsProcessed += duration }
        audioRing.append(samples)
        let segments = segmenter.append(
            samples: samples,
            capturedAt: timestamp.addingTimeInterval(-duration)
        )
        for segment in segments {
            withStateLock {
                lastAudioSegmentAt = Date()
                audioSegmentsProcessed += 1
            }
            processAudioSegment(segment)
        }
        maybePublishHealth()
    }

    private func processAudioSegment(_ segment: AudioSegment) {
        guard segment.durationSeconds >= 0.2 else { return }
        asrQueue.async { [weak self] in
            guard let self else { return }
            do {
                let text = try self.transcriber.transcribe(
                    samples: segment.samples,
                    sampleRate: segment.sampleRate
                )
                let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard TextAnalyzer.meaningfulCharacterRatio(cleaned) >= 0.25, cleaned.count >= 2 else { return }
                let app = self.currentApplication()
                let candidate = CandidatePacket(
                    capturedAt: segment.endedAt,
                    source: .audio,
                    audioOrigin: self.microphoneActive ? .mixed : .system,
                    application: app.name,
                    windowTitle: app.windowTitle,
                    transcript: cleaned,
                    audioDurationSeconds: segment.durationSeconds
                )
                self.onCandidate(candidate)
                self.asrErrorReported = false
                self.maybePublishHealth()
            } catch {
                if !self.asrErrorReported {
                    self.asrErrorReported = true
                    PSLog.warn("ASR unavailable: \(error.localizedDescription)")
                    self.publishHealth(
                        state: "running",
                        detail: "screen capture active; ASR unavailable: \(error.localizedDescription)"
                    )
                }
            }
        }
    }

    private func withStateLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    // MARK: - Metadata / health

    private func currentApplication() -> (name: String?, windowTitle: String?) {
        guard let app = NSWorkspace.shared.frontmostApplication else { return (nil, nil) }
        let name = app.localizedName
        var windowTitle: String?
        if let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] {
            for window in windows {
                guard let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                      pid == app.processIdentifier,
                      let layer = window[kCGWindowLayer as String] as? Int,
                      layer == 0 else { continue }
                if let title = window[kCGWindowName as String] as? String, !title.isEmpty {
                    windowTitle = title
                    break
                }
            }
        }
        return (name, windowTitle)
    }

    private func isExcluded(_ application: String?) -> Bool {
        guard let application else { return false }
        let normalized = application.lowercased()
        return config.privacy.excludedApplications.contains {
            normalized == $0.lowercased() || normalized.hasPrefix($0.lowercased())
        }
    }

    private func maybePublishHealth() {
        let now = Date()
        let should = withStateLock { () -> Bool in
            if now.timeIntervalSince(lastHealthWrite) >= config.daemon.healthIntervalSeconds {
                lastHealthWrite = now
                return true
            }
            return false
        }
        guard should else { return }
        publishHealth(state: "running", detail: microphoneActive ? "system + microphone audio, screen deltas" : "system audio + screen deltas")
    }

    private func publishHealth(state: String, detail: String?) {
        let health = withStateLock {
            CaptureHealth(
                state: state,
                detail: detail,
                permissionGranted: state == "running",
                lastFrameAt: lastFrameAt,
                lastAudioSegmentAt: lastAudioSegmentAt,
                screenshotsProcessed: screenshotsProcessed,
                ocrFramesProcessed: ocrFramesProcessed,
                audioSecondsProcessed: audioSecondsProcessed,
                audioSegmentsProcessed: audioSegmentsProcessed,
                sessionStartedAt: sessionStartedAt
            )
        }
        onHealth(health)
    }
}

public enum CaptureError: Error, LocalizedError {
    case permissionDenied
    case noDisplay
    case unsupportedAudioFormat(String)
    case streamFailed(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Screen Recording permission denied (terminal TCC state)."
        case .noDisplay: return "No display available for ScreenCaptureKit."
        case .unsupportedAudioFormat(let message): return "Unsupported audio format: \(message)"
        case .streamFailed(let message): return "Capture stream failed: \(message)"
        }
    }
}

public enum PCMExtractor {
    public struct Result: Sendable {
        public var samples: [Float]
        public var sampleRate: Int
    }

    public static func samples(from sampleBuffer: CMSampleBuffer) -> Result? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }
        let asbd = asbdPointer.pointee
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return nil }
        let channels = Int(asbd.mChannelsPerFrame)
        guard channels >= 1 else { return nil }
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        guard isFloat, asbd.mBitsPerChannel == 32 else { return nil }

        let bufferListSize = MemoryLayout<AudioBufferList>.size
            + (channels - 1) * MemoryLayout<AudioBuffer>.size
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: bufferListSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        let audioBufferList = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferList,
            bufferListSize: bufferListSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return nil }
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        var output = [Float](repeating: 0, count: frameCount)
        if channels == 1, let first = buffers.first, let data = first.mData {
            let count = min(frameCount, Int(first.mDataByteSize) / MemoryLayout<Float>.size)
            let pointer = data.bindMemory(to: Float.self, capacity: count)
            for index in 0..<count { output[index] = pointer[index] }
        } else if isNonInterleaved {
            for channel in 0..<min(channels, buffers.count) {
                guard let data = buffers[channel].mData else { continue }
                let count = min(frameCount, Int(buffers[channel].mDataByteSize) / MemoryLayout<Float>.size)
                let pointer = data.bindMemory(to: Float.self, capacity: count)
                for index in 0..<count { output[index] += pointer[index] / Float(channels) }
            }
        } else if let first = buffers.first, let data = first.mData {
            let pointer = data.bindMemory(to: Float.self, capacity: frameCount * channels)
            for frame in 0..<frameCount {
                var sum: Float = 0
                for channel in 0..<channels { sum += pointer[frame * channels + channel] }
                output[frame] = sum / Float(channels)
            }
        } else {
            return nil
        }
        return Result(samples: output, sampleRate: Int(asbd.mSampleRate))
    }

    public static func linearResample(_ samples: [Float], from inputRate: Int, to outputRate: Int) -> [Float] {
        guard !samples.isEmpty, inputRate > 0, outputRate > 0, inputRate != outputRate else {
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
