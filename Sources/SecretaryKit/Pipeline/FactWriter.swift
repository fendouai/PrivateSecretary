import Foundation

/// Single write path for L3 facts. Both real-time ingestion and nightly
/// consolidation use it so dedupe/contradiction/injection rules cannot drift.
public final class FactWriter: @unchecked Sendable {
    private let store: MemoryStore
    private let config: AppConfig
    private let gate: FactQualityGate

    public init(store: MemoryStore, config: AppConfig) {
        self.store = store
        self.config = config
        self.gate = FactQualityGate(config: config)
    }

    public func write(
        candidates: [FactCandidate],
        episode: Episode,
        salience: Double,
        now: Date = Date()
    ) throws -> [SemanticFact] {
        guard !candidates.isEmpty else { return [] }
        var existing = try store.fetchFacts(status: .active, limit: 3_000)
        existing.append(contentsOf: try store.fetchFacts(status: .pendingReview, limit: 500))
        var stored: [SemanticFact] = []

        for candidate in candidates {
            // One episode may mention the same slot repeatedly (stack traces,
            // multiple error lines). Those are evidence, not contradictions.
            let duplicateFromSameEpisode = existing.contains { fact in
                fact.sourceEpisodeIDs.contains(episode.id)
                    && normalized(fact.subject) == normalized(candidate.subject)
                    && normalized(fact.predicate) == normalized(candidate.predicate)
                    && fact.kind == candidate.kind
            }
            if duplicateFromSameEpisode { continue }
            let decision = gate.evaluate(
                candidate,
                salience: salience,
                existingFacts: existing
            )
            switch decision.action {
            case .reject:
                PSLog.debug("fact rejected (\(decision.reason)): \(candidate.statement.prefix(80))")
            case .reinforce:
                guard let existingID = decision.existingFactID,
                      let updated = try store.reinforceFact(
                        id: existingID,
                        episodeID: episode.id,
                        salience: salience,
                        at: now
                      ) else { continue }
                if let index = existing.firstIndex(where: { $0.id == updated.id }) {
                    existing[index] = updated
                }
                stored.append(updated)
            case .insert:
                let fact = makeFact(candidate, episode: episode, status: .active, salience: salience, date: now)
                try store.insertFact(fact)
                existing.append(fact)
                stored.append(fact)
            case .pendingReview:
                let fact = makeFact(
                    candidate,
                    episode: episode,
                    status: .pendingReview,
                    salience: salience,
                    date: now
                )
                try store.insertFact(fact)
                existing.append(fact)
                stored.append(fact)
            case .supersede:
                guard let existingID = decision.existingFactID else { continue }
                let fact = makeFact(
                    candidate,
                    episode: episode,
                    status: .active,
                    salience: salience,
                    date: now,
                    supersedesID: existingID
                )
                try store.supersedeFact(oldID: existingID, with: fact)
                existing.removeAll { $0.id == existingID }
                existing.append(fact)
                stored.append(fact)
            }
        }
        return stored
    }

    private func normalized(_ value: String) -> String {
        TextAnalyzer.normalize(value)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeFact(
        _ candidate: FactCandidate,
        episode: Episode,
        status: FactStatus,
        salience: Double,
        date: Date,
        supersedesID: String? = nil
    ) -> SemanticFact {
        SemanticFact(
            id: "fact_" + UUID().uuidString.lowercased(),
            kind: candidate.kind,
            subject: TextAnalyzer.truncated(candidate.subject, limit: 120),
            predicate: TextAnalyzer.truncated(candidate.predicate, limit: 120),
            object: TextAnalyzer.truncated(candidate.object, limit: 240),
            statement: candidate.statement,
            confidence: candidate.confidence,
            salience: salience,
            status: status,
            trust: episode.trust,
            sourceEpisodeIDs: [episode.id],
            supersedesID: supersedesID,
            keywords: candidate.keywords,
            evidenceCount: 1,
            createdAt: date,
            updatedAt: date
        )
    }
}
