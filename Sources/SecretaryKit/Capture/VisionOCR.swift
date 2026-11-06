import Foundation
import CoreGraphics
import Vision

public protocol OCRProviding: Sendable {
    func recognize(image: CGImage, changedRegions: [CGRect]?) throws -> [OCRRegion]
    var name: String { get }
}

public final class VisionOCRService: OCRProviding, @unchecked Sendable {
    private let languages: [String]
    private let minimumConfidence: Double

    public init(languages: [String], minimumConfidence: Double = 0.35) {
        self.languages = languages
        self.minimumConfidence = min(1, max(0, minimumConfidence))
    }

    public var name: String { "vision" }

    public func recognize(image: CGImage, changedRegions: [CGRect]? = nil) throws -> [OCRRegion] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if !languages.isEmpty {
            request.recognitionLanguages = languages
        }
        request.minimumTextHeight = 0.008
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        guard let observations = request.results else { return [] }

        var regions: [OCRRegion] = []
        var seen = Set<String>()
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let confidence = Double(candidate.confidence)
            guard confidence >= minimumConfidence else { continue }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let box = observation.boundingBox
            // Vision uses bottom-left origin; memory uses top-left.
            let region = OCRRegion(
                text: text,
                confidence: confidence,
                x: box.minX,
                y: 1 - box.maxY,
                width: box.width,
                height: box.height
            )
            if let changedRegions, !changedRegions.isEmpty {
                let intersects = changedRegions.contains { changed in
                    let overlap = changed.intersection(CGRect(
                        x: region.x, y: region.y, width: region.width, height: region.height
                    ))
                    return !overlap.isNull && overlap.width > 0 && overlap.height > 0
                }
                guard intersects else { continue }
            }
            let key = TextAnalyzer.normalize(text)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            regions.append(region)
        }
        return regions.sorted {
            if abs($0.y - $1.y) > 0.01 { return $0.y < $1.y }
            return $0.x < $1.x
        }
    }
}
