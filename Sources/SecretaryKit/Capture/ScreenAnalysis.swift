import Foundation
import CoreGraphics

public struct ScreenDelta: Equatable, Sendable {
    public var changed: Bool
    public var changedRatio: Double
    public var regions: [CGRect]
    public var signature: UInt64
    public var isFirstFrame: Bool

    public init(
        changed: Bool,
        changedRatio: Double,
        regions: [CGRect],
        signature: UInt64,
        isFirstFrame: Bool = false
    ) {
        self.changed = changed
        self.changedRatio = changedRatio
        self.regions = regions
        self.signature = signature
        self.isFirstFrame = isFirstFrame
    }
}

/// Downscaled block/pixel differential. Operates on a 64×36 grayscale
/// thumbnail: cheap enough for every ScreenCaptureKit frame, while still
/// producing normalized regions for OCR cropping/filtering.
public final class ScreenDiffer: @unchecked Sendable {
    public static let thumbnailWidth = 64
    public static let thumbnailHeight = 36

    private let threshold: Double
    private let pixelDelta: Double
    private var previous: [UInt8]?
    private let lock = NSLock()

    public init(threshold: Double = 0.018, pixelDelta: Double = 0.08) {
        self.threshold = threshold
        self.pixelDelta = pixelDelta
    }

    public func reset() {
        lock.lock()
        previous = nil
        lock.unlock()
    }

    public func analyze(image: CGImage) -> ScreenDelta {
        let pixels = Self.thumbnail(from: image)
        return analyze(luma: pixels)
    }

    public func analyze(luma: [UInt8]) -> ScreenDelta {
        lock.lock()
        defer { lock.unlock() }
        let first = previous == nil
        let signature = Self.fnv1a(luma)
        guard let previous, previous.count == luma.count else {
            self.previous = luma
            return ScreenDelta(
                changed: true,
                changedRatio: 1,
                regions: [CGRect(x: 0, y: 0, width: 1, height: 1)],
                signature: signature,
                isFirstFrame: first
            )
        }
        var changedMask = [Bool](repeating: false, count: luma.count)
        var changedCount = 0
        for index in luma.indices {
            let difference = abs(Double(luma[index]) - Double(previous[index])) / 255.0
            if difference >= pixelDelta {
                changedMask[index] = true
                changedCount += 1
            }
        }
        self.previous = luma
        let ratio = Double(changedCount) / Double(max(1, luma.count))
        let regions = changedCount == 0 ? [] : Self.regions(mask: changedMask)
        return ScreenDelta(
            changed: ratio >= threshold,
            changedRatio: ratio,
            regions: regions,
            signature: signature
        )
    }

    public static func thumbnail(from image: CGImage) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: thumbnailWidth * thumbnailHeight)
        guard let context = CGContext(
            data: &pixels,
            width: thumbnailWidth,
            height: thumbnailHeight,
            bitsPerComponent: 8,
            bytesPerRow: thumbnailWidth,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return pixels }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: thumbnailWidth, height: thumbnailHeight))
        return pixels
    }

    private static func regions(mask: [Bool]) -> [CGRect] {
        var rowRects: [CGRect] = []
        for row in 0..<thumbnailHeight {
            var start: Int?
            for column in 0...thumbnailWidth {
                let changed = column < thumbnailWidth && mask[row * thumbnailWidth + column]
                if changed, start == nil {
                    start = column
                } else if !changed, let begin = start {
                    rowRects.append(CGRect(
                        x: Double(begin) / Double(thumbnailWidth),
                        y: Double(row) / Double(thumbnailHeight),
                        width: Double(column - begin) / Double(thumbnailWidth),
                        height: 1.0 / Double(thumbnailHeight)
                    ))
                    start = nil
                }
            }
        }
        // Merge vertical neighbors with overlapping x ranges. Bounded loop keeps
        // pathological full-screen changes cheap.
        var merged = rowRects
        var didMerge = true
        var iterations = 0
        while didMerge && iterations < 12 {
            didMerge = false
            iterations += 1
            var output: [CGRect] = []
            for rect in merged {
                if let index = output.firstIndex(where: {
                    abs($0.minY + $0.height - rect.minY) < 0.0001
                        && $0.minX < rect.maxX && rect.minX < $0.maxX
                }) {
                    output[index] = output[index].union(rect)
                    didMerge = true
                } else {
                    output.append(rect)
                }
            }
            merged = output
        }
        return merged.sorted {
            if abs($0.minY - $1.minY) > 0.001 { return $0.minY < $1.minY }
            return $0.minX < $1.minX
        }.prefix(12).map { $0 }
    }

    private static func fnv1a(_ bytes: [UInt8]) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }
}
