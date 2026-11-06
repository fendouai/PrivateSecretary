import Foundation

public struct EpisodeSearchDocument: Sendable {
    public var id: String
    public var startedAt: Date
    public var summary: String
    public var application: String?
    public var salience: Double
    public var archived: Bool
    public var trust: TrustLevel

    public init(
        id: String,
        startedAt: Date,
        summary: String,
        application: String?,
        salience: Double,
        archived: Bool,
        trust: TrustLevel
    ) {
        self.id = id
        self.startedAt = startedAt
        self.summary = summary
        self.application = application
        self.salience = salience
        self.archived = archived
        self.trust = trust
    }
}

public struct FactSearchDocument: Sendable {
    public var id: String
    public var statement: String
    public var kind: FactKind
    public var createdAt: Date
    public var updatedAt: Date
    public var salience: Double
    public var trust: TrustLevel
    public var keywords: [String]

    public init(
        id: String,
        statement: String,
        kind: FactKind,
        createdAt: Date,
        updatedAt: Date,
        salience: Double,
        trust: TrustLevel,
        keywords: [String]
    ) {
        self.id = id
        self.statement = statement
        self.kind = kind
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.salience = salience
        self.trust = trust
        self.keywords = keywords
    }
}

public extension MemoryStore {
    /// Narrow projection for retrieval: avoids decoding full transcripts/OCR
    /// for every candidate on every query.
    func fetchEpisodeSearchDocuments(
        in interval: DateInterval? = nil,
        limit: Int = 10_000
    ) throws -> [EpisodeSearchDocument] {
        try database.read { connection in
            var sql = """
            SELECT id, started_at, summary, application, salience, archived, trust
            FROM episodes WHERE 1=1
            """
            var bindings: [SQLiteValue] = []
            if let interval {
                sql += " AND started_at >= ? AND started_at < ?"
                bindings.append(.real(interval.start.epoch))
                bindings.append(.real(interval.end.epoch))
            }
            sql += " ORDER BY started_at DESC LIMIT ?;"
            bindings.append(.integer(Int64(max(1, limit))))
            return try connection.query(sql, bindings).map { row in
                EpisodeSearchDocument(
                    id: row.string("id") ?? "",
                    startedAt: row.date("started_at") ?? Date(timeIntervalSince1970: 0),
                    summary: row.string("summary") ?? "",
                    application: row.string("application"),
                    salience: row.double("salience") ?? 0,
                    archived: row.bool("archived") ?? false,
                    trust: TrustLevel(rawValue: row.string("trust") ?? "") ?? .untrustedObservedContent
                )
            }
        }
    }

    func fetchFactSearchDocuments(limit: Int = 10_000) throws -> [FactSearchDocument] {
        try database.read { connection in
            try connection.query("""
            SELECT id, statement, kind, created_at, updated_at, salience, trust, keywords
            FROM semantic_facts WHERE status = 'active'
            ORDER BY updated_at DESC LIMIT ?;
            """, [.integer(Int64(max(1, limit)))])
                .map { row in
                    let keywords = (try? JSONCoding.decoder().decode(
                        [String].self,
                        from: Data((row.string("keywords") ?? "[]").utf8)
                    )) ?? []
                    return FactSearchDocument(
                        id: row.string("id") ?? "",
                        statement: row.string("statement") ?? "",
                        kind: FactKind(rawValue: row.string("kind") ?? "") ?? .fact,
                        createdAt: row.date("created_at") ?? Date(timeIntervalSince1970: 0),
                        updatedAt: row.date("updated_at") ?? Date(timeIntervalSince1970: 0),
                        salience: row.double("salience") ?? 0,
                        trust: TrustLevel(rawValue: row.string("trust") ?? "") ?? .untrustedObservedContent,
                        keywords: keywords
                    )
                }
        }
    }
}
