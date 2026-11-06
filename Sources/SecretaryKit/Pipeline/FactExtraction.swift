import Foundation

public struct SalienceResult: Equatable, Sendable {
    public var signals: SalienceSignals
    public var score: Double

    public init(signals: SalienceSignals, score: Double) {
        self.signals = signals
        self.score = score
    }
}

public struct SalienceScorer: Sendable {
    public let config: AppConfig

    public init(config: AppConfig) {
        self.config = config
    }

    public func score(
        candidate: CandidatePacket,
        recentEpisodes: [Episode],
        now: Date = Date()
    ) -> SalienceResult {
        let text = candidate.combinedText
        let error = TextAnalyzer.hasErrorSignal(text) ? 0.95 : 0.0
        let reward = TextAnalyzer.hasRewardSignal(text) ? 0.85 : 0.0
        let emotion = TextAnalyzer.hasEmotionSignal(text) ? 0.8 : 0.0

        let novelty: Double
        let recent = recentEpisodes.filter {
            now.timeIntervalSince($0.startedAt) <= 3_600 && $0.startedAt <= now
        }
        if recent.isEmpty {
            novelty = 0.7
        } else {
            let maxSimilarity = recent.map { episode in
                TextAnalyzer.jaccard(text, episode.transcript + " " + episode.ocrText)
            }.max() ?? 0
            novelty = max(0, 1 - maxSimilarity)
        }

        var goal = 0.2
        let lowered = TextAnalyzer.normalize(text)
        if TextAnalyzer.hasExplicitIntentCue(lowered) { goal = 1.0 }
        else if TextAnalyzer.hasErrorSignal(lowered) { goal = 0.9 }
        else if ["决定", "方案", "偏好", "喜欢", "待办", "记得", "截止", "deadline",
                  "decided", "prefer", "todo", "remember", "follow up"].contains(where: { lowered.contains($0) }) {
            goal = 0.9
        } else if ["project", "bug", "release", "项目", "发布", "需求", "客户"].contains(where: { lowered.contains($0) }) {
            goal = 0.55
        }

        let access = min(1, Double(recentEpisodes.reduce(0) { $0 + $1.accessCount }) * 0.02)
        let signals = SalienceSignals(
            reward: reward,
            error: error,
            novelty: novelty,
            emotion: emotion,
            goalRelevance: goal,
            accessFrequency: access
        )
        return SalienceResult(
            signals: signals,
            score: signals.score(weights: config.salience.weights)
        )
    }

    /// Cognitive forgetting weight: salience decays with age; access slows
    /// decay. This is not a wall-clock deletion policy.
    public func retentionWeight(for episode: Episode, now: Date) -> Double {
        let ageDays = max(0, now.timeIntervalSince(episode.startedAt) / 86_400)
        let decay = pow(0.5, ageDays / max(0.1, config.salience.decayHalfLifeDays))
        let recentAccess: Double
        if let last = episode.lastAccessedAt {
            recentAccess = exp(-max(0, now.timeIntervalSince(last) / 86_400) / 45) * 0.12
        } else {
            recentAccess = 0
        }
        let accessBoost = min(
            config.salience.accessBoostCap,
            Double(episode.accessCount) * 0.025 + recentAccess
        )
        return min(1, episode.salience * decay + accessBoost)
    }
}

public struct FactQualityGate: Sendable {
    public let config: AppConfig

    public init(config: AppConfig) {
        self.config = config
    }

    public func evaluate(
        _ candidate: FactCandidate,
        salience: Double,
        existingFacts: [SemanticFact]
    ) -> FactGateDecision {
        let statement = TextAnalyzer.normalize(candidate.statement)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !statement.isEmpty else {
            return FactGateDecision(action: .reject, reason: "empty_statement")
        }
        guard candidate.confidence >= config.factGate.minimumConfidence else {
            return FactGateDecision(action: .reject, reason: "confidence_below_threshold")
        }
        guard salience >= config.factGate.minimumSalience else {
            return FactGateDecision(action: .reject, reason: "salience_below_threshold")
        }
        guard candidate.statement.count <= config.factGate.maximumStatementLength else {
            return FactGateDecision(action: .reject, reason: "statement_too_long")
        }
        if TextAnalyzer.containsPromptInjection(candidate.statement) {
            return FactGateDecision(action: .reject, reason: "prompt_injection_suspected")
        }

        let subject = normalized(candidate.subject)
        let predicate = normalized(candidate.predicate)
        let object = normalized(candidate.object)

        // Exact / near duplicate: reinforce instead of creating fact sprawl.
        if let duplicate = existingFacts.first(where: { fact in
            (fact.status == .active || fact.status == .pendingReview)
                && (
                    (normalized(fact.subject) == subject
                        && normalized(fact.predicate) == predicate
                        && normalized(fact.object) == object)
                    || TextAnalyzer.jaccard(fact.statement, candidate.statement) >= config.factGate.duplicateSimilarity
                )
        }) {
            return FactGateDecision(
                action: .reinforce,
                existingFactID: duplicate.id,
                reason: "duplicate_or_equivalent"
            )
        }

        // Same assertion slot, different value: a contradiction candidate.
        if candidate.kind != .error,
           let conflict = existingFacts.first(where: {
               $0.status == .active
                   && normalized($0.subject) == subject
                   && normalized($0.predicate) == predicate
                   && normalized($0.object) != object
           }) {
            let confidenceDelta = candidate.confidence - conflict.confidence
            if confidenceDelta >= config.factGate.supersedeConfidenceMargin {
                return FactGateDecision(
                    action: .supersede,
                    existingFactID: conflict.id,
                    reason: "higher_confidence_contradiction"
                )
            }
            return FactGateDecision(
                action: .pendingReview,
                existingFactID: conflict.id,
                reason: "contradiction_needs_review"
            )
        }

        return FactGateDecision(action: .insert, reason: "passed_quality_gate")
    }

    private func normalized(_ string: String) -> String {
        TextAnalyzer.normalize(string)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct RuleBasedFactExtractor: FactExtracting {
    private struct Pattern {
        let kind: FactKind
        let predicate: String
        let confidence: Double
        let regex: NSRegularExpression
    }

    private static let patterns: [Pattern] = {
        let definitions: [(FactKind, String, Double, String)] = [
            (.decision, "决策", 0.86, #"(?:我们|团队|大家|我)?(?:决定|确定|敲定|定下来|定了|采用|选择|方案是|结论是)[:：\s]*(.{3,180})"#),
            (.preference, "偏好", 0.84, #"(?:我喜欢|我偏好|我更喜欢|我更倾向|以后(?:都)?用|习惯用|我一直用|prefer|i prefer|i like|use .{1,40} going forward)[:：\s]*(.{1,160})"#),
            (.todo, "待办", 0.83, #"(?:待办|要做|需要做|记得|别忘了|提醒我|todo|need to|have to|remember to)[:：\s]*(.{2,180})"#)
        ]
        return definitions.compactMap { kind, predicate, confidence, pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                return nil
            }
            return Pattern(kind: kind, predicate: predicate, confidence: confidence, regex: regex)
        }
    }()

    public init() {}

    public func extract(
        from episode: Episode,
        salience: Double
    ) throws -> [FactCandidate] {
        let text = [episode.transcript, episode.ocrText]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")
        guard !text.isEmpty else { return [] }

        var candidates: [FactCandidate] = []
        var seen = Set<String>()
        if TextAnalyzer.hasErrorSignal(text) {
            let statement = TextAnalyzer.truncated(
                text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " "),
                limit: 300
            )
            let errorFact = FactCandidate(
                kind: .error,
                subject: episode.application ?? "系统",
                predicate: "错误模式",
                object: statement,
                statement: statement,
                confidence: 0.88,
                keywords: TextAnalyzer.keywords(statement, limit: 6)
            )
            candidates.append(errorFact)
            seen.insert(TextAnalyzer.normalize(statement))
        }
        for sentence in TextAnalyzer.sentences(text) {
            guard sentence.count >= 4, sentence.count <= 600 else { continue }
            if TextAnalyzer.containsPromptInjection(sentence) { continue }
            for pattern in Self.patterns {
                let range = NSRange(sentence.startIndex..<sentence.endIndex, in: sentence)
                guard let match = pattern.regex.firstMatch(in: sentence, options: [], range: range) else {
                    continue
                }
                let object: String
                if match.numberOfRanges > 1,
                   let objectRange = Range(match.range(at: 1), in: sentence) {
                    object = String(sentence[objectRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    object = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                guard object.count >= 2 else { continue }
                let subject: String
                switch pattern.kind {
                case .decision: subject = "团队"
                case .error: subject = episode.application ?? "系统"
                default: subject = "用户"
                }
                let statement = TextAnalyzer.truncated(sentence, limit: 300)
                let key = TextAnalyzer.normalize(statement)
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                candidates.append(FactCandidate(
                    kind: pattern.kind,
                    subject: subject,
                    predicate: pattern.predicate,
                    object: TextAnalyzer.truncated(object, limit: 180),
                    statement: statement,
                    confidence: pattern.confidence,
                    keywords: TextAnalyzer.keywords(statement, limit: 6)
                ))
                if candidates.count >= 8 { break }
            }
            if candidates.count >= 8 { break }
        }
        return candidates
    }
}

public protocol FactExtracting: Sendable {
    func extract(from episode: Episode, salience: Double) throws -> [FactCandidate]
}

public struct CompositeFactExtractor: FactExtracting {
    private let rules: RuleBasedFactExtractor
    private let model: ModelCommandClient?
    private let config: AppConfig

    public init(config: AppConfig) {
        self.config = config
        self.rules = RuleBasedFactExtractor()
        self.model = config.factGate.model.enabled ? ModelCommandClient(config: config.factGate.model) : nil
    }

    public func extract(from episode: Episode, salience: Double) throws -> [FactCandidate] {
        var results: [FactCandidate] = []
        if let model {
            do {
                results = try model.extractFacts(from: episode)
            } catch {
                PSLog.warn("fact model failed, falling back to rules: \(error.localizedDescription)")
            }
        }
        let ruleFacts = try rules.extract(from: episode, salience: salience)
        results.append(contentsOf: ruleFacts)
        var seen = Set<String>()
        return results.filter { fact in
            let key = TextAnalyzer.normalize(fact.statement)
            if seen.contains(key) { return false }
            seen.insert(key)
            return true
        }.prefix(12).map { $0 }
    }
}
