import Foundation

/// Deterministic feature-hashing embedding. This is intentionally dependency
/// free: it guarantees offline startup and reproducible tests while preserving
/// a pluggable vector channel. A CoreML/MLX sentence encoder can replace this
/// type behind `EmbeddingProviding` without changing retrieval semantics.
public protocol EmbeddingProviding: Sendable {
    var dimensions: Int { get }
    func embed(_ text: String) -> [Float]
}

public struct HashingEmbedder: EmbeddingProviding, Sendable {
    public let dimensions: Int

    public init(dimensions: Int = 384) {
        self.dimensions = max(64, dimensions)
    }

    public func embed(_ text: String) -> [Float] {
        var vector = [Float](repeating: 0, count: dimensions)
        let normalized = TextAnalyzer.normalize(text)
        var features: [String] = TextAnalyzer.tokens(normalized)
        // Character trigrams give partial robustness to ASR/OCR noise and
        // inflections without requiring a tokenizer model.
        let compact = normalized.replacingOccurrences(
            of: #"[^\p{L}\p{N}]"#,
            with: "",
            options: .regularExpression
        )
        let characters = Array(compact)
        if characters.count >= 3 {
            for index in 0..<(characters.count - 2) {
                let trigram = String(characters[index...index + 2])
                if !TextAnalyzer.isCJK(trigram.unicodeScalars.first ?? " ") {
                    features.append("tri:" + trigram)
                }
            }
        }
        for feature in features {
            let hash = Self.fnv1a(feature)
            let index = Int(hash % UInt64(dimensions))
            let sign: Float = (hash & (1 << 63)) == 0 ? 1 : -1
            vector[index] += sign
        }
        var norm: Float = 0
        for value in vector { norm += value * value }
        norm = sqrt(norm)
        if norm > 0 {
            for index in vector.indices { vector[index] /= norm }
        }
        return vector
    }

    public static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        var dot: Float = 0
        var left: Float = 0
        var right: Float = 0
        for index in lhs.indices {
            dot += lhs[index] * rhs[index]
            left += lhs[index] * lhs[index]
            right += rhs[index] * rhs[index]
        }
        guard left > 0, right > 0 else { return 0 }
        return Double(dot / (sqrt(left) * sqrt(right)))
    }

    private static func fnv1a(_ string: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }
}

public struct RetrievalCandidate: Sendable {
    public var summary: MemorySummary
    public var lexical: Double
    public var vector: Double
    public var recency: Double
    public var salience: Double

    public init(summary: MemorySummary, lexical: Double, vector: Double, recency: Double, salience: Double) {
        self.summary = summary
        self.lexical = lexical
        self.vector = vector
        self.recency = recency
        self.salience = salience
    }
}

public final class HybridRetriever: @unchecked Sendable {
    private let store: MemoryStore
    private let config: AppConfig
    private let embedder: EmbeddingProviding
    private var embeddingCache: [String: [Float]] = [:]
    private let cacheLock = NSLock()

    public init(store: MemoryStore, config: AppConfig, embedder: EmbeddingProviding? = nil) {
        self.store = store
        self.config = config
        self.embedder = embedder ?? HashingEmbedder(dimensions: config.retrieval.vectorDimensions)
    }

    public func recall(
        query: String,
        timeRange: DateInterval? = nil,
        layer: MemoryLayer? = nil,
        limit: Int? = nil,
        now: Date = Date()
    ) throws -> RecallResult {
        let parsed = QueryTimeParser.parse(query, now: now)
        let effectiveRange = timeRange ?? parsed.range
        let effectiveQuery = parsed.query
        let maxLimit = max(1, min(limit ?? config.retrieval.defaultLimit, config.retrieval.maximumLimit))
        let queryTokens = TextAnalyzer.tokens(effectiveQuery)
        let queryVector = embedder.embed(effectiveQuery)

        var results: [RetrievalCandidate] = []
        let includeL2 = layer == nil || layer == .l2
        let includeL3 = layer == nil || layer == .l3

        if includeL2 {
            let episodes = try store.fetchEpisodeSearchDocuments(
                in: effectiveRange,
                limit: config.retrieval.candidateLimit
            )
            let lexical = try store.lexicalEpisodeScores(query: effectiveQuery)
            for episode in episodes {
                let vector = max(0, HashingEmbedder.cosine(
                    queryVector,
                    embedding(
                        key: "ep:\(episode.id):\(episode.archived ? "arch" : "hot")",
                        text: episode.summary + " " + (episode.application ?? "")
                    )
                ))
                let lexicalScore = lexical[episode.id] ?? 0
                if !queryTokens.isEmpty, lexicalScore == 0, vector < 0.15 { continue }
                let ageDays = max(0, now.timeIntervalSince(episode.startedAt) / 86_400)
                let recency = exp(-ageDays / max(0.1, config.retrieval.recencyHalfLifeDays))
                let summary = TextAnalyzer.truncated(
                    episode.summary,
                    limit: config.retrieval.summaryCharacterLimit
                )
                let memory = MemorySummary(
                    id: episode.id,
                    layer: .l2,
                    timestamp: episode.startedAt,
                    title: episode.application ?? "音频片段",
                    summary: summary.isEmpty ? "（已归档，无摘要）" : summary,
                    application: episode.application,
                    kind: episode.archived ? "episode_archived" : "episode",
                    score: 0,
                    salience: episode.salience,
                    trust: episode.trust
                )
                results.append(RetrievalCandidate(
                    summary: memory,
                    lexical: lexicalScore,
                    vector: vector,
                    recency: recency,
                    salience: episode.salience * (episode.archived ? 0.65 : 1)
                ))
            }
        }

        if includeL3 {
            let facts = try store.fetchFactSearchDocuments(limit: config.retrieval.candidateLimit)
            let lexical = try store.lexicalFactScores(query: effectiveQuery)
            for fact in facts {
                if let effectiveRange {
                    let createdAtInRange = fact.createdAt >= effectiveRange.start
                        && fact.createdAt < effectiveRange.end
                    let updatedAtInRange = fact.updatedAt >= effectiveRange.start
                        && fact.updatedAt < effectiveRange.end
                    if !createdAtInRange && !updatedAtInRange { continue }
                }
                let vector = max(0, HashingEmbedder.cosine(
                    queryVector,
                    embedding(
                        key: "fact:\(fact.id):\(Int(fact.updatedAt.timeIntervalSince1970))",
                        text: fact.statement + " " + fact.keywords.joined(separator: " ")
                    )
                ))
                let lexicalScore = lexical[fact.id] ?? 0
                if !queryTokens.isEmpty, lexicalScore == 0, vector < 0.15 { continue }
                let ageDays = max(0, now.timeIntervalSince(fact.updatedAt) / 86_400)
                let recency = exp(-ageDays / max(0.1, config.retrieval.recencyHalfLifeDays))
                let memory = MemorySummary(
                    id: fact.id,
                    layer: .l3,
                    timestamp: fact.updatedAt,
                    title: "语义事实 · \(fact.kind.rawValue)",
                    summary: TextAnalyzer.truncated(
                        fact.statement,
                        limit: config.retrieval.summaryCharacterLimit
                    ),
                    application: nil,
                    kind: fact.kind.rawValue,
                    score: 0,
                    salience: fact.salience,
                    trust: fact.trust
                )
                results.append(RetrievalCandidate(
                    summary: memory,
                    lexical: lexicalScore,
                    vector: vector,
                    recency: recency,
                    salience: fact.salience
                ))
            }
        }

        for index in results.indices {
            let candidate = results[index]
            let score = config.retrieval.lexicalWeight * candidate.lexical
                + config.retrieval.vectorWeight * candidate.vector
                + config.retrieval.recencyWeight * candidate.recency
                + config.retrieval.salienceWeight * candidate.salience
            var summary = candidate.summary
            summary.score = min(1, max(0, score))
            results[index].summary = summary
        }

        results.sort {
            if abs($0.summary.score - $1.summary.score) > 0.000_001 {
                return $0.summary.score > $1.summary.score
            }
            return $0.summary.timestamp > $1.summary.timestamp
        }
        let top = results.prefix(maxLimit).map(\.summary)
        let note: String
        if top.isEmpty {
            note = "No matching memories. Try a broader query or a wider time range."
        } else {
            note = "Summaries only. Call drill_down(memory_id) for the full record."
        }
        return RecallResult(
            query: effectiveQuery,
            parsedTimeRange: parsed.range,
            results: Array(top),
            note: note
        )
    }

    private func embedding(key: String, text: String) -> [Float] {
        cacheLock.lock()
        if let cached = embeddingCache[key] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()
        let vector = embedder.embed(text)
        cacheLock.lock()
        if embeddingCache.count > 50_000 { embeddingCache.removeAll(keepingCapacity: true) }
        embeddingCache[key] = vector
        cacheLock.unlock()
        return vector
    }

    public func drillDown(memoryID: String, now: Date = Date()) throws -> DrillDownResult {
        if memoryID.hasPrefix("fact_") {
            guard let fact = try store.fetchFact(id: memoryID) else {
                throw MemoryServiceError.notFound(memoryID)
            }
            try store.updateFactAccess(id: fact.id, at: now)
            return DrillDownResult(
                memoryID: fact.id,
                layer: .l3,
                trust: fact.trust,
                fact: fact
            )
        }

        let episodeID = memoryID.hasPrefix("ep_") ? memoryID : memoryID
        guard let episode = try store.fetchEpisode(id: episodeID) else {
            throw MemoryServiceError.notFound(memoryID)
        }
        var content = episode
        var usedCold = false
        if episode.archived, episode.transcript.isEmpty, episode.ocrText.isEmpty {
            if let archived = store.coldArchive.load(episodeID: episode.id, startedAt: episode.startedAt) {
                content = archived
                usedCold = true
            }
        }
        try store.updateEpisodeAccess(id: episode.id, at: now)
        return DrillDownResult(
            memoryID: episode.id,
            layer: .l2,
            trust: episode.trust,
            content: content,
            archived: episode.archived,
            coldArchiveLoaded: usedCold
        )
    }
}

public enum MemoryServiceError: Error, LocalizedError, Equatable {
    case notFound(String)
    case invalidArgument(String)
    case conflict(String)
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let id): return "Memory not found: \(id)"
        case .invalidArgument(let message): return "Invalid argument: \(message)"
        case .conflict(let message): return "Conflict: \(message)"
        case .unavailable(let message): return "Unavailable: \(message)"
        }
    }
}
