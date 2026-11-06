import Foundation

public struct EpisodeCluster: Equatable, Sendable {
    public var application: String?
    public var start: Date
    public var end: Date
    public var episodeIDs: [String]

    public init(application: String?, start: Date, end: Date, episodeIDs: [String]) {
        self.application = application
        self.start = start
        self.end = end
        self.episodeIDs = episodeIDs
    }
}

public final class Consolidator: @unchecked Sendable {
    private let store: MemoryStore
    private let config: AppConfig
    private let extractor: any FactExtracting
    private let factWriter: FactWriter
    private let salienceScorer: SalienceScorer

    public init(store: MemoryStore, config: AppConfig, extractor: (any FactExtracting)? = nil) {
        self.store = store
        self.config = config
        self.extractor = extractor ?? CompositeFactExtractor(config: config)
        self.factWriter = FactWriter(store: store, config: config)
        self.salienceScorer = SalienceScorer(config: config)
    }

    public func run(
        date: Date = Date(),
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> ConsolidationReport {
        let started = Date()
        let interval = DateCoding.dayInterval(for: date, calendar: calendar)
        let dayKey = DateCoding.dayKey(date, calendar: calendar)
        let episodes = try store.fetchEpisodes(
            in: interval,
            includeArchived: false,
            limit: config.consolidation.maximumEpisodesPerRun
        )
        let clusters = Self.cluster(
            episodes: episodes,
            maximumGap: config.consolidation.maximumClusterGapSeconds
        )
        let episodesByID = Dictionary(uniqueKeysWithValues: episodes.map { ($0.id, $0) })
        let significant = clusters.flatMap { cluster -> [Episode] in
            let selected = cluster.episodeIDs
                .compactMap { episodesByID[$0] }
                .filter { $0.salience >= config.salience.threshold }
                .sorted { $0.salience > $1.salience }
                .prefix(4)
            return Array(selected)
        }.sorted { $0.salience > $1.salience }

        var generatedFacts: [SemanticFact] = []
        if config.consolidation.extractMissingFacts {
            for episode in significant {
                let existing = try store.facts(forEpisodeID: episode.id)
                guard existing.isEmpty else { continue }
                do {
                    let candidates = try extractor.extract(from: episode, salience: episode.salience)
                    if !candidates.isEmpty {
                        generatedFacts.append(contentsOf: try factWriter.write(
                            candidates: candidates,
                            episode: episode,
                            salience: episode.salience,
                            now: episode.startedAt
                        ))
                    }
                } catch {
                    PSLog.warn("consolidation extraction failed for \(episode.id): \(error.localizedDescription)")
                }
            }
        }

        let archivedCount = try forget(now: now)
        let todos = try store.fetchTodos(limit: 1_000).filter {
            $0.createdAt >= interval.start && $0.createdAt < interval.end
        }
        let dayEpisodeIDs = Set(episodes.map(\.id))
        let allFacts = try store.fetchFacts(limit: 5_000)
        let relevantFacts = allFacts.filter { fact in
            !Set(fact.sourceEpisodeIDs).isDisjoint(with: dayEpisodeIDs)
                && (fact.status == .active || fact.status == .pendingReview)
        }
        let activeRelevant = relevantFacts.filter { $0.status == .active }
        let pendingRelevant = relevantFacts.filter { $0.status == .pendingReview }

        let entries = makeDigestEntries(
            significantEpisodes: significant,
            facts: activeRelevant,
            interval: interval
        )
        let stats = DigestStats(
            episodeCount: episodes.count,
            significantEpisodeCount: significant.count,
            factCount: activeRelevant.count,
            todoCount: todos.count,
            archivedEpisodeCount: archivedCount
        )
        let markdown = renderMarkdown(
            dayKey: dayKey,
            episodes: episodes,
            significant: significant,
            facts: activeRelevant,
            todos: todos,
            archivedCount: archivedCount,
            stats: stats
        )
        let digest = DailyDigest(
            date: dayKey,
            generatedAt: now,
            markdown: markdown,
            entries: entries,
            stats: stats
        )
        try store.upsertDigest(digest)

        let duration = Date().timeIntervalSince(started) * 1_000
        let supersededCount = allFacts.filter {
            $0.status == .superseded
                && $0.updatedAt >= interval.start
                && $0.updatedAt < interval.end
        }.count
        return ConsolidationReport(
            date: dayKey,
            digest: digest,
            factsCreated: generatedFacts.count,
            factsSuperseded: supersededCount,
            factsPendingReview: pendingRelevant.count,
            archivedEpisodes: archivedCount,
            durationMilliseconds: duration
        )
    }

    public func forget(now: Date = Date()) throws -> Int {
        let cutoff = now.addingTimeInterval(-config.salience.minimumRetentionDays * 86_400)
        guard cutoff > Date(timeIntervalSince1970: 0) else { return 0 }
        let candidates = try store.fetchEpisodes(
            in: DateInterval(start: Date(timeIntervalSince1970: 0), end: cutoff),
            includeArchived: false,
            limit: 5_000
        )
        var archived = 0
        for episode in candidates {
            let weight = salienceScorer.retentionWeight(for: episode, now: now)
            guard weight < config.salience.archiveBelowWeight else { continue }
            do {
                if try store.archiveEpisode(episode) { archived += 1 }
            } catch {
                PSLog.error("failed to archive \(episode.id): \(error.localizedDescription)")
            }
        }
        return archived
    }

    public static func cluster(episodes: [Episode], maximumGap: TimeInterval) -> [EpisodeCluster] {
        let sorted = episodes.sorted { $0.startedAt < $1.startedAt }
        var clusters: [EpisodeCluster] = []
        for episode in sorted {
            if var last = clusters.last,
               last.application == episode.application,
               episode.startedAt.timeIntervalSince(last.end) <= maximumGap {
                last.end = max(last.end, episode.endedAt)
                last.episodeIDs.append(episode.id)
                clusters[clusters.count - 1] = last
            } else {
                clusters.append(EpisodeCluster(
                    application: episode.application,
                    start: episode.startedAt,
                    end: episode.endedAt,
                    episodeIDs: [episode.id]
                ))
            }
        }
        return clusters
    }

    private func makeDigestEntries(
        significantEpisodes: [Episode],
        facts: [SemanticFact],
        interval: DateInterval
    ) -> [DigestEntry] {
        let maximum = max(1, config.consolidation.maximumDigestEntries)
        let episodeBudget = max(1, maximum / 2)
        let factBudget = max(0, maximum - episodeBudget)
        let selectedEpisodes = significantEpisodes
            .sorted { $0.salience > $1.salience }
            .prefix(episodeBudget)
        var entries: [DigestEntry] = selectedEpisodes.map { episode in
            DigestEntry(
                memoryID: episode.id,
                layer: .l2,
                timestamp: episode.startedAt,
                title: episode.displayTitle,
                summary: TextAnalyzer.truncated(episode.summary, limit: 240),
                kind: "episode",
                salience: episode.salience
            )
        }
        let selectedFacts = facts
            .filter { $0.salience >= config.salience.threshold }
            .sorted { $0.salience > $1.salience }
            .prefix(factBudget)
        entries.append(contentsOf: selectedFacts.map { fact in
            DigestEntry(
                memoryID: fact.id,
                layer: .l3,
                timestamp: fact.updatedAt >= interval.start && fact.updatedAt < interval.end
                    ? fact.updatedAt
                    : interval.start,
                title: "语义事实 · \(fact.kind.rawValue)",
                summary: TextAnalyzer.truncated(fact.statement, limit: 240),
                kind: fact.kind.rawValue,
                salience: fact.salience
            )
        })
        return entries.sorted { $0.timestamp < $1.timestamp }
    }

    private func renderMarkdown(
        dayKey: String,
        episodes: [Episode],
        significant: [Episode],
        facts: [SemanticFact],
        todos: [TodoItem],
        archivedCount: Int,
        stats: DigestStats
    ) -> String {
        var lines: [String] = []
        lines.append("# 私人秘书日报 · \(dayKey)")
        lines.append("")
        lines.append("> 由 \(episodes.count) 条情景记忆、\(stats.factCount) 条语义事实巩固而成。日报是索引，不是记忆本身；使用 `drill_down(memory_id)` 查看来源。")
        lines.append("")
        lines.append("## 关键情景")
        if significant.isEmpty {
            lines.append("- 今日没有超过显著性阈值的情景。")
        } else {
            let shown = significant.sorted { $0.startedAt < $1.startedAt }
            for episode in shown.prefix(config.consolidation.maximumDigestEntries) {
                let app = Self.escape(episode.displayTitle)
                let time = DateCoding.timeOnly(episode.startedAt)
                let summary = Self.escape(TextAnalyzer.truncated(episode.summary, limit: 220))
                lines.append("- **\(time) · \(app)** — \(summary) (`\(episode.id)`)")
            }
        }
        lines.append("")
        lines.append("## 语义事实")
        if facts.isEmpty {
            lines.append("- 暂无通过质量门的语义事实。")
        } else {
            for fact in facts.sorted(by: { $0.salience > $1.salience }).prefix(12) {
                let source = fact.sourceEpisodeIDs.first ?? "unknown"
                lines.append("- **[\(fact.kind.rawValue)]** \(Self.escape(fact.statement)) (`\(fact.id)` ← `\(source)`)")
            }
        }
        lines.append("")
        lines.append("## 待办")
        if todos.isEmpty {
            lines.append("- 今日没有新增待办。")
        } else {
            for todo in todos.sorted(by: { $0.createdAt < $1.createdAt }) {
                let marker = todo.status == .done ? "x" : " "
                lines.append("- [\(marker)] `\(todo.id)` \(Self.escape(todo.title))")
            }
        }
        lines.append("")
        lines.append("## 遗忘")
        if archivedCount == 0 {
            lines.append("- 今日没有新增归档。")
        } else {
            lines.append("- 今日将 \(archivedCount) 条低权重情景移入 cold 层；摘要与 provenance 仍可检索。")
        }
        lines.append("")
        lines.append("## 统计")
        lines.append("- 情景：\(stats.episodeCount)（显著 \(stats.significantEpisodeCount)）")
        lines.append("- 事实：\(stats.factCount)；待审查：\(self.pendingCount())")
        lines.append("- 待办：\(stats.todoCount)")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private func pendingCount() -> Int {
        (try? store.counts().pendingReviewFacts) ?? 0
    }

    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "`", with: "'")
            .replacingOccurrences(of: "[", with: "［")
            .replacingOccurrences(of: "]", with: "］")
            .replacingOccurrences(of: "<", with: "＜")
            .replacingOccurrences(of: ">", with: "＞")
    }
}
