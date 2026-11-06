import Foundation

public struct ScreenEvent: Codable, Equatable, Sendable {
    public var timestamp: Date
    public var changedRatio: Double
    public var regions: [CGRect]
    public var signature: UInt64

    public init(timestamp: Date, changedRatio: Double, regions: [CGRect], signature: UInt64) {
        self.timestamp = timestamp
        self.changedRatio = changedRatio
        self.regions = regions
        self.signature = signature
    }
}

/// Thread-safe L0 audio ring. It holds only the current processing window and
/// is never persisted.
public final class AudioRingBuffer: @unchecked Sendable {
    public let sampleRate: Int
    public let capacitySamples: Int
    private var storage: [Float] = []
    private let lock = NSLock()

    public init(seconds: Int, sampleRate: Int = 16_000) {
        self.sampleRate = max(1, sampleRate)
        self.capacitySamples = max(1, seconds * self.sampleRate)
        storage.reserveCapacity(capacitySamples)
    }

    public func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        storage.append(contentsOf: samples)
        if storage.count > capacitySamples {
            storage.removeFirst(storage.count - capacitySamples)
        }
    }

    public func snapshot() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }

    public func clear() {
        lock.lock()
        storage.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}

/// L0 screen events. Pixels are intentionally never retained: the ring keeps a
/// transient perceptual signature and changed regions, enough for the current
/// processing window without creating a screen-recording archive.
public final class ScreenEventRingBuffer: @unchecked Sendable {
    public let capacity: Int
    private var events: [ScreenEvent] = []
    private let lock = NSLock()

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    public func append(_ event: ScreenEvent) {
        lock.lock()
        events.append(event)
        if events.count > capacity { events.removeFirst(events.count - capacity) }
        lock.unlock()
    }

    public func snapshot() -> [ScreenEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return events.count
    }
}

public protocol VoiceActivityDetecting: Sendable {
    func isSpeech(samples: [Float], sampleRate: Int) -> Bool
}

/// Dependency-free VAD used by the reference implementation. It deliberately
/// exposes the same seam as a Silero CoreML detector so the model can be
/// swapped without touching segmentation or capture state.
public struct EnergyVAD: VoiceActivityDetecting {
    public var threshold: Double
    public var zeroCrossingThreshold: Double

    public init(threshold: Double = 0.012, zeroCrossingThreshold: Double = 0.02) {
        self.threshold = threshold
        self.zeroCrossingThreshold = zeroCrossingThreshold
    }

    public func isSpeech(samples: [Float], sampleRate: Int) -> Bool {
        guard !samples.isEmpty else { return false }
        var sum: Double = 0
        var crossings = 0
        var previous = samples[0]
        for sample in samples {
            let value = Double(sample)
            sum += value * value
            if (sample >= 0) != (previous >= 0) { crossings += 1 }
            previous = sample
        }
        let rms = sqrt(sum / Double(samples.count))
        let zeroCrossingRate = Double(crossings) / Double(samples.count)
        return rms >= threshold && zeroCrossingRate >= zeroCrossingThreshold
    }
}

public struct AudioSegment: Equatable, Sendable {
    public var samples: [Float]
    public var sampleRate: Int
    public var startedAt: Date
    public var endedAt: Date

    public init(samples: [Float], sampleRate: Int, startedAt: Date, endedAt: Date) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.startedAt = startedAt
        self.endedAt = endedAt
    }

    public var durationSeconds: Double {
        Double(samples.count) / Double(max(1, sampleRate))
    }
}

/// Streaming segmentation with pre-roll and hangover. It frames arbitrary
/// capture buffers into fixed VAD windows, then emits speech segments only.
public final class AudioSegmenter: @unchecked Sendable {
    private struct TimedFrame {
        var samples: [Float]
        var start: Date
    }

    public let sampleRate: Int
    public let frameSamples: Int
    private let vad: any VoiceActivityDetecting
    private let config: CaptureConfig
    private let preRollSamples: Int
    private let hangoverSamples: Int
    private let minimumSpeechSamples: Int
    private let maximumSamples: Int

    private let lock = NSLock()
    private var pending: [Float] = []
    private var pendingStart: Date?
    private var preRoll: [TimedFrame] = []
    private var active: [TimedFrame] = []
    private var speechSamples = 0
    private var silenceSamples = 0
    private var isActive = false

    public init(config: CaptureConfig, sampleRate: Int = 16_000, vad: (any VoiceActivityDetecting)? = nil) {
        self.config = config
        self.sampleRate = max(1, sampleRate)
        self.frameSamples = max(1, self.sampleRate * max(10, config.vadFrameMilliseconds) / 1_000)
        self.vad = vad ?? EnergyVAD(threshold: config.vadThreshold)
        self.preRollSamples = self.sampleRate * max(0, config.preRollMilliseconds) / 1_000
        self.hangoverSamples = self.sampleRate * max(0, config.silenceHangoverMilliseconds) / 1_000
        self.minimumSpeechSamples = self.sampleRate * max(0, config.minimumSpeechMilliseconds) / 1_000
        self.maximumSamples = Int(Double(self.sampleRate) * max(1, config.maximumSegmentSeconds))
    }

    @discardableResult
    public func append(samples: [Float], capturedAt: Date) -> [AudioSegment] {
        lock.lock()
        defer { lock.unlock() }
        guard !samples.isEmpty else { return [] }
        if pending.isEmpty { pendingStart = capturedAt }
        pending.append(contentsOf: samples)
        var emitted: [AudioSegment] = []
        while pending.count >= frameSamples {
            let frame = Array(pending.prefix(frameSamples))
            pending.removeFirst(frameSamples)
            let start = pendingStart ?? capturedAt
            pendingStart = start.addingTimeInterval(Double(frameSamples) / Double(sampleRate))
            if let segment = process(frame: frame, start: start) {
                emitted.append(segment)
            }
        }
        return emitted
    }

    public func flush() -> [AudioSegment] {
        lock.lock()
        defer { lock.unlock() }
        var emitted: [AudioSegment] = []
        if isActive, speechSamples >= minimumSpeechSamples, let first = active.first {
            let samples = active.flatMap(\.samples)
            let final = Array(samples.prefix(maximumSamples))
            let end = first.start.addingTimeInterval(Double(final.count) / Double(sampleRate))
            emitted.append(AudioSegment(
                samples: final,
                sampleRate: sampleRate,
                startedAt: first.start,
                endedAt: end
            ))
        }
        preRoll.removeAll()
        active.removeAll()
        pending.removeAll()
        pendingStart = nil
        speechSamples = 0
        silenceSamples = 0
        isActive = false
        return emitted
    }

    private func process(frame: [Float], start: Date) -> AudioSegment? {
        let speech = vad.isSpeech(samples: frame, sampleRate: sampleRate)
        let timed = TimedFrame(samples: frame, start: start)

        if !isActive {
            preRoll.append(timed)
            let preRollCount = preRoll.reduce(0) { $0 + $1.samples.count }
            if preRollCount > preRollSamples {
                var excess = preRollCount - preRollSamples
                while excess > 0, !preRoll.isEmpty {
                    let remove = min(excess, preRoll[0].samples.count)
                    if remove == preRoll[0].samples.count {
                        preRoll.removeFirst()
                    } else {
                        preRoll[0].samples.removeFirst(remove)
                        preRoll[0].start = preRoll[0].start.addingTimeInterval(Double(remove) / Double(sampleRate))
                    }
                    excess -= remove
                }
            }
            if speech {
                active = preRoll
                preRoll.removeAll(keepingCapacity: true)
                isActive = true
                speechSamples = frame.count
                silenceSamples = 0
            }
            return nil
        }

        active.append(timed)
        if speech {
            speechSamples += frame.count
            silenceSamples = 0
        } else {
            silenceSamples += frame.count
        }
        let total = active.reduce(0) { $0 + $1.samples.count }
        if total >= maximumSamples || silenceSamples >= hangoverSamples {
            let segment = makeSegmentIfLongEnough()
            reset()
            // Preserve the current frame as pre-roll for a following utterance
            // if the segment ended due to max length while speech continues.
            if speech {
                preRoll = [timed]
            }
            return segment
        }
        return nil
    }

    private func makeSegmentIfLongEnough() -> AudioSegment? {
        guard isActive, let first = active.first, speechSamples >= minimumSpeechSamples else {
            return nil
        }
        var samples = active.flatMap(\.samples)
        if samples.count > maximumSamples {
            samples = Array(samples.prefix(maximumSamples))
        }
        guard !samples.isEmpty else { return nil }
        let end = first.start.addingTimeInterval(Double(samples.count) / Double(sampleRate))
        return AudioSegment(
            samples: samples,
            sampleRate: sampleRate,
            startedAt: first.start,
            endedAt: end
        )
    }

    private func reset() {
        active.removeAll(keepingCapacity: true)
        speechSamples = 0
        silenceSamples = 0
        isActive = false
    }
}
