import Foundation

public final class IngestPipeline: @unchecked Sendable {
    public let store: MemoryStore
    public let config: AppConfig
    public let intentGate: IntentGate
    private let extractor: any FactExtracting
    private let salienceScorer: SalienceScorer
    private let factWriter: FactWriter

    public init(
        store: MemoryStore,
        config: AppConfig,
        extractor: (any FactExtracting)? = nil,
        intentGate: IntentGate? = nil
    ) {
        self.store = store
        self.config = config
        self.extractor = extractor ?? CompositeFactExtractor(config: config)
        self.intentGate = intentGate ?? IntentGate(config: config)
        self.salienceScorer = SalienceScorer(config: config)
        self.factWriter = FactWriter(store: store, config: config)
    }

    public func ingest(_ rawCandidate: CandidatePacket, now: Date? = nil) throws -> IngestResult {
        let now = now ?? Date()
        var candidate = rawCandidate
        candidate.transcript = sanitize(candidate.transcript)
        candidate.ocrText = sanitize(candidate.ocrText)
        candidate.ocrRegions = Array(candidate.ocrRegions.prefix(200))

        if let application = candidate.application, isExcluded(application) {
            return IngestResult(accepted: false, reason: "excluded_application")
        }

        let combined = candidate.combinedText
        guard !combined.isEmpty else {
            return IngestResult(accepted: false, reason: "empty_candidate")
        }
        guard combined.count >= 4 else {
            return IngestResult(accepted: false, reason: "text_too_short")
        }
        guard TextAnalyzer.meaningfulCharacterRatio(combined) >= 0.25 else {
            return IngestResult(accepted: false, reason: "not_meaningful_text")
        }

        let recent = try store.recentEpisodes(
            since: candidate.capturedAt.addingTimeInterval(-config.intentGate.duplicateWindowSeconds),
            limit: 50
        )
        if let duplicate = recent.first(where: {
            TextAnalyzer.jaccard(combined, $0.transcript + " " + $0.ocrText) >= config.intentGate.duplicateSimilarity
        }) {
            return IngestResult(accepted: false, reason: "duplicate_of:\(duplicate.id)")
        }

        let salience = salienceScorer.score(candidate: candidate, recentEpisodes: recent, now: now)
        let startedAt = candidate.audioDurationSeconds > 0
            ? candidate.capturedAt.addingTimeInterval(-candidate.audioDurationSeconds)
            : candidate.capturedAt
        let episodeID = "ep_" + UUID().uuidString.lowercased()
        var provenance: [Provenance] = []
        if !candidate.transcript.isEmpty {
            provenance.append(Provenance(
                kind: candidate.source == .audio || candidate.source == .combined ? "asr" : "manual_text",
                reference: "candidate:\(candidate.id)",
                detail: "origin=\(candidate.audioOrigin.rawValue);duration=\(String(format: "%.1f", candidate.audioDurationSeconds))s",
                capturedAt: candidate.capturedAt
            ))
        }
        if !candidate.ocrText.isEmpty {
            provenance.append(Provenance(
                kind: "ocr",
                reference: "candidate:\(candidate.id)",
                detail: "regions=\(candidate.ocrRegions.count);frames=\(candidate.screenFrameCount)",
                capturedAt: candidate.capturedAt
            ))
        }
        if provenance.isEmpty {
            provenance.append(Provenance(
                kind: "manual",
                reference: "candidate:\(candidate.id)",
                capturedAt: candidate.capturedAt
            ))
        }

        let summary = TextAnalyzer.summary(
            candidate.transcript.isEmpty ? candidate.ocrText : candidate.transcript
                + (candidate.ocrText.isEmpty ? "" : "\n" + candidate.ocrText),
            limit: 240
        )
        let episode = Episode(
            id: episodeID,
            startedAt: startedAt,
            endedAt: candidate.capturedAt,
            application: candidate.application?.trimmingCharacters(in: .whitespacesAndNewlines),
            windowTitle: candidate.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
            source: candidate.source,
            audioOrigin: candidate.audioOrigin,
            transcript: candidate.transcript,
            ocrText: candidate.ocrText,
            ocrRegions: candidate.ocrRegions,
            summary: summary,
            keywords: TextAnalyzer.keywords(combined, limit: 10),
            salience: salience.score,
            signals: salience.signals,
            provenance: provenance,
            trust: candidate.trust
        )
        try store.insertEpisode(episode)

        var facts: [SemanticFact] = []
        do {
            facts = try extractAndStoreFacts(episode: episode)
        } catch {
            PSLog.error("fact extraction failed for \(episode.id): \(error.localizedDescription)")
        }

        let intent = intentGate.evaluate(candidate: candidate, now: now)
        var todo: TodoItem?
        if intent.classification != .none {
            try store.insertIntentAudit(IntentAudit(
                createdAt: now,
                classification: intent.classification,
                confidence: intent.confidence,
                intentType: intent.intentType,
                routedText: intent.routedText,
                sourceEpisodeID: episode.id,
                reason: intent.reason,
                policy: intent.classification == .explicit ? "todo_list" : "not_added"
            ))
        }

        if intent.classification == .explicit,
           let intentType = intent.intentType,
           intent.confidence >= config.intentGate.explicitThreshold {
            let detailLines = [
                "Intent: \(intentType.rawValue)",
                "Source: \(candidate.application ?? "unknown") / \(candidate.windowTitle ?? "unknown")",
                "Episode: \(episode.id)",
                "Mode: todo-only (no automatic execution)"
            ]
            todo = try store.addTodo(
                title: intent.routedText,
                detail: detailLines.joined(separator: "\n"),
                intentType: intentType,
                sourceEpisodeID: episode.id,
                now: now
            )
        }

        return IngestResult(
            accepted: true,
            episode: episode,
            facts: facts,
            intent: intent,
            todo: todo
        )
    }

    private func extractAndStoreFacts(episode: Episode) throws -> [SemanticFact] {
        let candidates = try extractor.extract(from: episode, salience: episode.salience)
        return try factWriter.write(
            candidates: candidates,
            episode: episode,
            salience: episode.salience,
            now: episode.startedAt
        )
    }

    private func sanitize(_ text: String) -> String {
        let cleaned = text
            .replacingOccurrences(of: "\u{0000}", with: " ")
            .unicodeScalars
            .map { scalar -> Character in
                if CharacterSet.controlCharacters.contains(scalar) && scalar != "\n" && scalar != "\t" {
                    return " "
                }
                return Character(scalar)
            }
        return TextAnalyzer.truncated(String(cleaned), limit: 20_000)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isExcluded(_ application: String) -> Bool {
        let normalized = application.lowercased()
        return config.privacy.excludedApplications.contains {
            normalized == $0.lowercased() || normalized.hasPrefix($0.lowercased())
        }
    }
}
