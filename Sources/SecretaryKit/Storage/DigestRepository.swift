import Foundation

public extension MemoryStore {
    func upsertDigest(_ digest: DailyDigest) throws {
        let entries = try encodeJSON(digest.entries)
        let stats = try encodeJSON(digest.stats)
        try database.transaction { connection in
            try connection.execute("""
            INSERT INTO digests(date, generated_at, markdown, entries, stats)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(date) DO UPDATE SET
                generated_at = excluded.generated_at,
                markdown = excluded.markdown,
                entries = excluded.entries,
                stats = excluded.stats;
            """, [
                .text(digest.date),
                .real(digest.generatedAt.epoch),
                .text(digest.markdown),
                .text(entries),
                .text(stats)
            ])
        }
    }

    func digest(date: String) throws -> DailyDigest? {
        try database.read { connection in
            try connection.query("SELECT * FROM digests WHERE date = ?;", [.text(date)])
                .first.map(Self.digest(from:))
        }
    }

    func digests(limit: Int = 30) throws -> [DailyDigest] {
        try database.read { connection in
            try connection.query("SELECT * FROM digests ORDER BY date DESC LIMIT ?;", [.integer(Int64(limit))])
                .map(Self.digest(from:))
        }
    }

    func insertIntentAudit(_ audit: IntentAudit) throws {
        try database.transaction { connection in
            try connection.execute("""
            INSERT INTO intent_audits (
                id, created_at, classification, confidence, intent_type, routed_text,
                source_episode_id, reason, policy
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """, [
                .text(audit.id),
                .real(audit.createdAt.epoch),
                .text(audit.classification.rawValue),
                .real(audit.confidence),
                .optionalText(audit.intentType?.rawValue),
                .text(audit.routedText),
                .optionalText(audit.sourceEpisodeID),
                .text(audit.reason),
                .text(audit.policy)
            ])
        }
    }

    func intentAudits(limit: Int = 100) throws -> [IntentAudit] {
        try database.read { connection in
            try connection.query("SELECT * FROM intent_audits ORDER BY created_at DESC LIMIT ?;", [.integer(Int64(limit))])
                .map(Self.audit(from:))
        }
    }

    static func digest(from row: SQLiteRow) -> DailyDigest {
        let decoder = JSONCoding.decoder()
        func decode<T: Decodable>(_ type: T.Type, _ string: String, fallback: T) -> T {
            guard let data = string.data(using: .utf8),
                  let value = try? decoder.decode(type, from: data) else { return fallback }
            return value
        }
        return DailyDigest(
            date: row.string("date") ?? "",
            generatedAt: row.date("generated_at") ?? Date(),
            markdown: row.string("markdown") ?? "",
            entries: decode([DigestEntry].self, row.string("entries") ?? "[]", fallback: []),
            stats: decode(
                DigestStats.self,
                row.string("stats") ?? "{}",
                fallback: DigestStats(
                    episodeCount: 0,
                    significantEpisodeCount: 0,
                    factCount: 0,
                    todoCount: 0,
                    archivedEpisodeCount: 0
                )
            )
        )
    }

    static func audit(from row: SQLiteRow) -> IntentAudit {
        IntentAudit(
            id: row.string("id") ?? "",
            createdAt: row.date("created_at") ?? Date(),
            classification: IntentClassification(rawValue: row.string("classification") ?? "") ?? .none,
            confidence: row.double("confidence") ?? 0,
            intentType: row.string("intent_type").flatMap(IntentType.init(rawValue:)),
            routedText: row.string("routed_text") ?? "",
            sourceEpisodeID: row.string("source_episode_id"),
            reason: row.string("reason") ?? "",
            policy: row.string("policy") ?? ""
        )
    }
}
