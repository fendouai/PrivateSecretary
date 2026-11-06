import Foundation

public extension MemoryStore {
    func insertFact(_ fact: SemanticFact) throws {
        try database.transaction { connection in
            try Self.insertFact(fact, connection: connection)
        }
    }

    static func insertFact(_ fact: SemanticFact, connection: SQLiteConnection) throws {
        let sources = try JSONEncoder().encode(fact.sourceEpisodeIDs)
        let keywords = try JSONEncoder().encode(fact.keywords)
        let sourcesString = String(decoding: sources, as: UTF8.self)
        let keywordsString = String(decoding: keywords, as: UTF8.self)
        try connection.execute("""
        INSERT INTO semantic_facts (
            id, kind, subject, predicate, object_value, statement, confidence, salience,
            status, trust, sources, supersedes_id, superseded_by_id, keywords,
            evidence_count, access_count, last_accessed_at, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """, [
            .text(fact.id),
            .text(fact.kind.rawValue),
            .text(fact.subject),
            .text(fact.predicate),
            .text(fact.object),
            .text(fact.statement),
            .real(fact.confidence),
            .real(fact.salience),
            .text(fact.status.rawValue),
            .text(fact.trust.rawValue),
            .text(sourcesString),
            .optionalText(fact.supersedesID),
            .optionalText(fact.supersededByID),
            .text(keywordsString),
            .integer(Int64(fact.evidenceCount)),
            .integer(Int64(fact.accessCount)),
            fact.lastAccessedAt.map { .real($0.epoch) } ?? .null,
            .real(fact.createdAt.epoch),
            .real(fact.updatedAt.epoch)
        ])
        let search = TextAnalyzer.tokens(
            [fact.statement, fact.subject, fact.predicate, fact.object, fact.keywords.joined(separator: " ")]
                .joined(separator: " ")
        ).joined(separator: " ")
        try connection.execute(
            "INSERT INTO fact_fts(fact_id, search_text) VALUES(?, ?);",
            [.text(fact.id), .text(search)]
        )
    }

    func fetchFact(id: String) throws -> SemanticFact? {
        try database.read { connection in
            try connection.query("SELECT * FROM semantic_facts WHERE id = ?;", [.text(id)])
                .first.map(Self.fact(from:))
        }
    }

    func fetchFacts(status: FactStatus? = nil, limit: Int = 2_000) throws -> [SemanticFact] {
        try database.read { connection in
            var sql = "SELECT * FROM semantic_facts"
            var bindings: [SQLiteValue] = []
            if let status {
                sql += " WHERE status = ?"
                bindings.append(.text(status.rawValue))
            }
            sql += " ORDER BY updated_at DESC LIMIT ?;"
            bindings.append(.integer(Int64(max(1, limit))))
            return try connection.query(sql, bindings).map(Self.fact(from:))
        }
    }

    func facts(forEpisodeID episodeID: String, limit: Int = 100) throws -> [SemanticFact] {
        // Source IDs are stored as a JSON array. Avoid LIKE false positives by
        // decoding in Swift over a bounded candidate set.
        try database.read { connection in
            try connection.query("""
            SELECT * FROM semantic_facts
            WHERE sources LIKE ?
            ORDER BY updated_at DESC LIMIT ?;
            """, [.text("%\(episodeID)%"), .integer(Int64(limit))])
                .map(Self.fact(from:))
                .filter { $0.sourceEpisodeIDs.contains(episodeID) }
        }
    }

    func reinforceFact(
        id: String,
        episodeID: String,
        salience: Double,
        at date: Date = Date()
    ) throws -> SemanticFact? {
        guard let fact = try fetchFact(id: id) else { return nil }
        var sources = fact.sourceEpisodeIDs
        if !sources.contains(episodeID) { sources.append(episodeID) }
        let sourcesJSON = try encodeJSON(sources)
        try database.transaction { connection in
            try connection.execute("""
            UPDATE semantic_facts
            SET sources = ?, evidence_count = evidence_count + 1,
                salience = MAX(salience, ?), updated_at = ?
            WHERE id = ?;
            """, [.text(sourcesJSON), .real(salience), .real(date.epoch), .text(id)])
        }
        return try fetchFact(id: id)
    }

    func setFactStatus(id: String, status: FactStatus, at date: Date = Date()) throws {
        try database.transaction { connection in
            try connection.execute(
                "UPDATE semantic_facts SET status = ?, updated_at = ? WHERE id = ?;",
                [.text(status.rawValue), .real(date.epoch), .text(id)]
            )
        }
    }

    /// Atomically supersedes an old fact with a new one and records both links.
    func supersedeFact(oldID: String, with fact: SemanticFact) throws {
        var newFact = fact
        newFact.supersedesID = oldID
        newFact.updatedAt = Date()
        try database.transaction { connection in
            try connection.execute("""
            UPDATE semantic_facts
            SET status = 'superseded', superseded_by_id = ?, updated_at = ?
            WHERE id = ?;
            """, [.text(newFact.id), .real(newFact.updatedAt.epoch), .text(oldID)])
            try Self.insertFact(newFact, connection: connection)
        }
    }

    func correctFact(
        id: String,
        statement: String?,
        action: String,
        at date: Date = Date()
    ) throws -> SemanticFact? {
        guard let fact = try fetchFact(id: id) else { return nil }
        let normalizedAction = action.lowercased()
        var newStatement = fact.statement
        var newStatus = fact.status
        switch normalizedAction {
        case "accept", "approve":
            newStatus = .active
        case "reject", "retract":
            newStatus = .retracted
        case "correct", "update":
            guard let statement, !statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw NSError(domain: "PrivateSecretary.Memory", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "corrected_statement is required for action=correct"
                ])
            }
            newStatement = TextAnalyzer.truncated(statement, limit: config.factGate.maximumStatementLength)
            newStatus = .active
        default:
            throw NSError(domain: "PrivateSecretary.Memory", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "action must be accept, reject, or correct"
            ])
        }
        let keywords = try encodeJSON(TextAnalyzer.keywords(newStatement, limit: 10))
        try database.transaction { connection in
            try connection.execute("""
            UPDATE semantic_facts
            SET statement = ?, status = ?, keywords = ?, updated_at = ?
            WHERE id = ?;
            """, [
                .text(newStatement), .text(newStatus.rawValue), .text(keywords),
                .real(date.epoch), .text(id)
            ])
            let search = TextAnalyzer.tokens(
                newStatement + " " + fact.subject + " " + fact.predicate + " " + fact.object
            ).joined(separator: " ")
            try connection.execute("DELETE FROM fact_fts WHERE fact_id = ?;", [.text(id)])
            try connection.execute(
                "INSERT INTO fact_fts(fact_id, search_text) VALUES(?, ?);",
                [.text(id), .text(search)]
            )
        }
        return try fetchFact(id: id)
    }

    func updateFactAccess(id: String, at date: Date) throws {
        try database.transaction { connection in
            try connection.execute("""
            UPDATE semantic_facts SET access_count = access_count + 1, last_accessed_at = ?
            WHERE id = ?;
            """, [.real(date.epoch), .text(id)])
        }
    }

    func lexicalFactScores(query: String, limit: Int = 250) throws -> [String: Double] {
        let tokens = Array(TextAnalyzer.tokens(query).prefix(24))
        guard !tokens.isEmpty else { return [:] }
        let ftsQuery = tokens
            .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            .joined(separator: " OR ")
        return try database.read { connection in
            let rows = try connection.query("""
            SELECT fact_id, bm25(fact_fts) AS rank
            FROM fact_fts WHERE fact_fts MATCH ?
            ORDER BY rank LIMIT ?;
            """, [.text(ftsQuery), .integer(Int64(limit))])
            var scores: [String: Double] = [:]
            for row in rows {
                guard let id = row.string("fact_id"), let rank = row.double("rank") else { continue }
                scores[id] = 1.0 / (1.0 + exp(rank))
            }
            return scores
        }
    }

    static func fact(from row: SQLiteRow) -> SemanticFact {
        let decoder = JSONCoding.decoder()
        func decode<T: Decodable>(_ type: T.Type, _ json: String, fallback: T) -> T {
            guard let data = json.data(using: .utf8) else { return fallback }
            return (try? decoder.decode(type, from: data)) ?? fallback
        }
        return SemanticFact(
            id: row.string("id") ?? "",
            kind: FactKind(rawValue: row.string("kind") ?? "") ?? .fact,
            subject: row.string("subject") ?? "",
            predicate: row.string("predicate") ?? "",
            object: row.string("object_value") ?? "",
            statement: row.string("statement") ?? "",
            confidence: row.double("confidence") ?? 0,
            salience: row.double("salience") ?? 0,
            status: FactStatus(rawValue: row.string("status") ?? "") ?? .pendingReview,
            trust: TrustLevel(rawValue: row.string("trust") ?? "") ?? .untrustedObservedContent,
            sourceEpisodeIDs: decode([String].self, row.string("sources") ?? "[]", fallback: []),
            supersedesID: row.string("supersedes_id"),
            supersededByID: row.string("superseded_by_id"),
            keywords: decode([String].self, row.string("keywords") ?? "[]", fallback: []),
            evidenceCount: row.int("evidence_count") ?? 1,
            accessCount: row.int("access_count") ?? 0,
            lastAccessedAt: row.date("last_accessed_at"),
            createdAt: row.date("created_at") ?? Date(),
            updatedAt: row.date("updated_at") ?? Date()
        )
    }
}
