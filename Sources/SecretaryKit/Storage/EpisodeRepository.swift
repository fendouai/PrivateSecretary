import Foundation

public extension MemoryStore {
    func insertEpisode(_ episode: Episode) throws {
        let ocrRegions = try encodeJSON(episode.ocrRegions)
        let signals = try encodeJSON(episode.signals)
        let provenance = try encodeJSON(episode.provenance)
        let keywords = try encodeJSON(episode.keywords)
        let searchText = TextAnalyzer.tokens(
            [episode.summary, episode.transcript, episode.ocrText,
             episode.application ?? "", episode.windowTitle ?? "", episode.keywords.joined(separator: " ")]
                .joined(separator: " ")
        ).joined(separator: " ")

        try database.transaction { connection in
            try connection.execute("""
            INSERT INTO episodes (
                id, started_at, ended_at, application, window_title, source, audio_origin,
                transcript, ocr_text, ocr_regions, summary, keywords, salience, signals,
                provenance, access_count, last_accessed_at, archived, created_at, trust
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """, [
                .text(episode.id),
                .real(episode.startedAt.epoch),
                .real(episode.endedAt.epoch),
                .text(episode.application ?? ""),
                .text(episode.windowTitle ?? ""),
                .text(episode.source.rawValue),
                .text(episode.audioOrigin.rawValue),
                .text(episode.transcript),
                .text(episode.ocrText),
                .text(ocrRegions),
                .text(episode.summary),
                .text(keywords),
                .real(episode.salience),
                .text(signals),
                .text(provenance),
                .integer(Int64(episode.accessCount)),
                episode.lastAccessedAt.map { .real($0.epoch) } ?? .null,
                .integer(Int64(episode.archived ? 1 : 0)),
                .real(episode.createdAt.epoch),
                .text(episode.trust.rawValue)
            ])
            try connection.execute(
                "INSERT INTO episode_fts(episode_id, search_text) VALUES(?, ?);",
                [.text(episode.id), .text(searchText)]
            )
        }
    }

    func fetchEpisode(id: String) throws -> Episode? {
        try database.read { connection in
            try connection.query("SELECT * FROM episodes WHERE id = ?;", [.text(id)])
                .first.map(Self.episode(from:))
        }
    }

    func fetchEpisodes(
        in interval: DateInterval? = nil,
        includeArchived: Bool = false,
        limit: Int = 5_000
    ) throws -> [Episode] {
        try database.read { connection in
            var sql = "SELECT * FROM episodes WHERE 1=1"
            var bindings: [SQLiteValue] = []
            if !includeArchived {
                sql += " AND archived = 0"
            }
            if let interval {
                sql += " AND started_at >= ? AND started_at < ?"
                bindings.append(.real(interval.start.epoch))
                bindings.append(.real(interval.end.epoch))
            }
            sql += " ORDER BY started_at DESC LIMIT ?;"
            bindings.append(.integer(Int64(max(1, limit))))
            return try connection.query(sql, bindings).map(Self.episode(from:))
        }
    }

    func recentEpisodes(since: Date, limit: Int = 100) throws -> [Episode] {
        try database.read { connection in
            try connection.query("""
            SELECT * FROM episodes
            WHERE started_at >= ? AND archived = 0
            ORDER BY started_at DESC LIMIT ?;
            """, [.real(since.epoch), .integer(Int64(limit))])
                .map(Self.episode(from:))
        }
    }

    func latestEpisode(before date: Date) throws -> Episode? {
        try database.read { connection in
            try connection.query(
                "SELECT * FROM episodes WHERE started_at <= ? ORDER BY started_at DESC LIMIT 1;",
                [.real(date.epoch)]
            ).first.map(Self.episode(from:))
        }
    }

    func updateEpisodeAccess(id: String, at date: Date) throws {
        try database.transaction { connection in
            try connection.execute("""
            UPDATE episodes SET access_count = access_count + 1, last_accessed_at = ?
            WHERE id = ?;
            """, [.real(date.epoch), .text(id)])
        }
    }

    func deleteEpisode(id: String) throws {
        let episode = try fetchEpisode(id: id)
        let derivedFacts = try facts(forEpisodeID: id, limit: 5_000)
        try database.transaction { connection in
            for fact in derivedFacts {
                var sources = fact.sourceEpisodeIDs
                sources.removeAll { $0 == id }
                if sources.isEmpty {
                    // The fact was derived only from the episode being forgotten;
                    // deleting the episode must delete its content too.
                    try connection.execute("DELETE FROM fact_fts WHERE fact_id = ?;", [.text(fact.id)])
                    try connection.execute("DELETE FROM semantic_facts WHERE id = ?;", [.text(fact.id)])
                } else {
                    let sourcesJSON = try JSONEncoder().encode(sources)
                    try connection.execute("""
                    UPDATE semantic_facts
                    SET sources = ?, evidence_count = ?, updated_at = ?
                    WHERE id = ?;
                    """, [
                        .text(String(decoding: sourcesJSON, as: UTF8.self)),
                        .integer(Int64(max(1, sources.count))),
                        .real(Date().epoch),
                        .text(fact.id)
                    ])
                }
            }
            try connection.execute("DELETE FROM episode_fts WHERE episode_id = ?;", [.text(id)])
            try connection.execute("DELETE FROM todos WHERE source_episode_id = ?;", [.text(id)])
            try connection.execute("DELETE FROM episodes WHERE id = ?;", [.text(id)])
        }
        if let episode, config.privacy.purgeColdArchiveOnDelete {
            _ = try? coldArchive.delete(episodeID: id, startedAt: episode.startedAt)
        }
        try? database.checkpoint()
    }

    /// Moves full observed text out of the hot database. The summary remains
    /// searchable so an old memory can still be discovered and drilled into.
    func archiveEpisode(_ episode: Episode) throws -> Bool {
        guard !episode.archived else { return false }
        let url = try coldArchive.append(episode)
        let searchText = TextAnalyzer.tokens(
            [episode.summary, episode.application ?? "", episode.keywords.joined(separator: " ")]
                .joined(separator: " ")
        ).joined(separator: " ")
        try database.transaction { connection in
            try connection.execute("""
            UPDATE episodes
            SET archived = 1, transcript = '', ocr_text = '', ocr_regions = '[]'
            WHERE id = ?;
            """, [.text(episode.id)])
            try connection.execute("DELETE FROM episode_fts WHERE episode_id = ?;", [.text(episode.id)])
            try connection.execute(
                "INSERT INTO episode_fts(episode_id, search_text) VALUES(?, ?);",
                [.text(episode.id), .text(searchText)]
            )
        }
        PSLog.debug("Archived episode \(episode.id) to \(url.lastPathComponent)")
        return true
    }

    /// Returns a normalized lexical relevance score in 0...1 keyed by id.
    func lexicalEpisodeScores(query: String, limit: Int = 250) throws -> [String: Double] {
        let tokens = Array(TextAnalyzer.tokens(query).prefix(24))
        guard !tokens.isEmpty else { return [:] }
        let ftsQuery = tokens
            .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            .joined(separator: " OR ")
        return try database.read { connection in
            let rows = try connection.query("""
            SELECT episode_id, bm25(episode_fts) AS rank
            FROM episode_fts WHERE episode_fts MATCH ?
            ORDER BY rank LIMIT ?;
            """, [.text(ftsQuery), .integer(Int64(limit))])
            var scores: [String: Double] = [:]
            for row in rows {
                guard let id = row.string("episode_id"), let rank = row.double("rank") else { continue }
                scores[id] = 1.0 / (1.0 + exp(rank))
            }
            return scores
        }
    }

    static func episode(from row: SQLiteRow) -> Episode {
        let decoder = JSONCoding.decoder()
        func decode<T: Decodable>(_ type: T.Type, _ json: String, fallback: T) -> T {
            guard let data = json.data(using: .utf8) else { return fallback }
            return (try? decoder.decode(type, from: data)) ?? fallback
        }
        return Episode(
            id: row.string("id") ?? "",
            startedAt: row.date("started_at") ?? Date(timeIntervalSince1970: 0),
            endedAt: row.date("ended_at") ?? Date(timeIntervalSince1970: 0),
            application: row.string("application"),
            windowTitle: row.string("window_title"),
            source: CandidateSource(rawValue: row.string("source") ?? "") ?? .manual,
            audioOrigin: AudioOrigin(rawValue: row.string("audio_origin") ?? "") ?? .manual,
            transcript: row.string("transcript") ?? "",
            ocrText: row.string("ocr_text") ?? "",
            ocrRegions: decode([OCRRegion].self, row.string("ocr_regions") ?? "[]", fallback: []),
            summary: row.string("summary") ?? "",
            keywords: decode([String].self, row.string("keywords") ?? "[]", fallback: []),
            salience: row.double("salience") ?? 0,
            signals: decode(SalienceSignals.self, row.string("signals") ?? "{}", fallback: SalienceSignals()),
            provenance: decode([Provenance].self, row.string("provenance") ?? "[]", fallback: []),
            accessCount: row.int("access_count") ?? 0,
            lastAccessedAt: row.date("last_accessed_at"),
            archived: row.bool("archived") ?? false,
            createdAt: row.date("created_at") ?? Date(),
            trust: TrustLevel(rawValue: row.string("trust") ?? "") ?? .untrustedObservedContent
        )
    }
}
