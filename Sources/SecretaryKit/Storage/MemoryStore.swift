import Foundation

public final class MemoryStore: @unchecked Sendable {
    public let database: SQLiteDatabase
    public let config: AppConfig
    public let coldArchive: ColdArchive

    public init(databasePath: String, coldArchiveDirectory: String, config: AppConfig = AppConfig()) throws {
        self.config = config
        self.database = try SQLiteDatabase(
            path: databasePath,
            busyTimeoutMilliseconds: config.storage.sqliteBusyTimeoutMilliseconds
        )
        self.coldArchive = ColdArchive(directory: coldArchiveDirectory)
        try migrate()
    }

    public convenience init(paths: AppPaths, config: AppConfig) throws {
        try paths.ensureDirectories()
        try self.init(
            databasePath: paths.databaseFile.path,
            coldArchiveDirectory: paths.coldArchiveDirectory.path,
            config: config
        )
    }

    private func migrate() throws {
        try database.transaction { connection in
            let version = try connection.scalarInt("PRAGMA user_version;")
            guard version < 3 else { return }

            try connection.executeScript("""
            CREATE TABLE IF NOT EXISTS episodes (
                id TEXT PRIMARY KEY,
                started_at REAL NOT NULL,
                ended_at REAL NOT NULL,
                application TEXT,
                window_title TEXT,
                source TEXT NOT NULL,
                audio_origin TEXT NOT NULL,
                transcript TEXT NOT NULL,
                ocr_text TEXT NOT NULL,
                ocr_regions TEXT NOT NULL,
                summary TEXT NOT NULL,
                keywords TEXT NOT NULL,
                salience REAL NOT NULL,
                signals TEXT NOT NULL,
                provenance TEXT NOT NULL,
                access_count INTEGER NOT NULL DEFAULT 0,
                last_accessed_at REAL,
                archived INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL,
                trust TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_episodes_started ON episodes(started_at DESC);
            CREATE INDEX IF NOT EXISTS idx_episodes_archived_started ON episodes(archived, started_at DESC);
            CREATE INDEX IF NOT EXISTS idx_episodes_salience ON episodes(salience DESC);

            CREATE TABLE IF NOT EXISTS semantic_facts (
                id TEXT PRIMARY KEY,
                kind TEXT NOT NULL,
                subject TEXT NOT NULL,
                predicate TEXT NOT NULL,
                object_value TEXT NOT NULL,
                statement TEXT NOT NULL,
                confidence REAL NOT NULL,
                salience REAL NOT NULL,
                status TEXT NOT NULL,
                trust TEXT NOT NULL,
                sources TEXT NOT NULL,
                supersedes_id TEXT,
                superseded_by_id TEXT,
                keywords TEXT NOT NULL,
                evidence_count INTEGER NOT NULL DEFAULT 1,
                access_count INTEGER NOT NULL DEFAULT 0,
                last_accessed_at REAL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_facts_status_updated ON semantic_facts(status, updated_at DESC);
            CREATE INDEX IF NOT EXISTS idx_facts_subject_predicate ON semantic_facts(subject, predicate);

            CREATE TABLE IF NOT EXISTS todos (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                detail TEXT NOT NULL,
                status TEXT NOT NULL,
                intent_type TEXT,
                source_episode_id TEXT,
                due_at REAL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                completed_at REAL,
                FOREIGN KEY(source_episode_id) REFERENCES episodes(id) ON DELETE SET NULL
            );
            CREATE INDEX IF NOT EXISTS idx_todos_status_created ON todos(status, created_at DESC);

            CREATE TABLE IF NOT EXISTS contacts (
                id TEXT PRIMARY KEY,
                display_name TEXT NOT NULL,
                normalized_name TEXT NOT NULL,
                organization TEXT,
                notes TEXT,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_contacts_name ON contacts(normalized_name);
            CREATE INDEX IF NOT EXISTS idx_contacts_updated ON contacts(updated_at DESC);

            CREATE TABLE IF NOT EXISTS contact_channels (
                contact_id TEXT NOT NULL,
                channel TEXT NOT NULL,
                handle TEXT NOT NULL,
                PRIMARY KEY(contact_id, channel, handle),
                UNIQUE(channel, handle),
                FOREIGN KEY(contact_id) REFERENCES contacts(id) ON DELETE CASCADE
            );
            CREATE INDEX IF NOT EXISTS idx_contact_channels_handle ON contact_channels(channel, handle);

            CREATE TABLE IF NOT EXISTS messages (
                id TEXT PRIMARY KEY,
                contact_id TEXT NOT NULL,
                channel TEXT NOT NULL,
                direction TEXT NOT NULL,
                text TEXT NOT NULL,
                timestamp REAL NOT NULL,
                is_read INTEGER NOT NULL DEFAULT 0,
                thread TEXT,
                external_id TEXT,
                dedupe_key TEXT NOT NULL,
                created_at REAL NOT NULL,
                UNIQUE(channel, dedupe_key),
                FOREIGN KEY(contact_id) REFERENCES contacts(id) ON DELETE CASCADE
            );
            CREATE INDEX IF NOT EXISTS idx_messages_timestamp ON messages(timestamp DESC);
            CREATE INDEX IF NOT EXISTS idx_messages_contact ON messages(contact_id, timestamp DESC);
            CREATE INDEX IF NOT EXISTS idx_messages_channel ON messages(channel, timestamp DESC);

            CREATE TABLE IF NOT EXISTS digests (
                date TEXT PRIMARY KEY,
                generated_at REAL NOT NULL,
                markdown TEXT NOT NULL,
                entries TEXT NOT NULL,
                stats TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS intent_audits (
                id TEXT PRIMARY KEY,
                created_at REAL NOT NULL,
                classification TEXT NOT NULL,
                confidence REAL NOT NULL,
                intent_type TEXT,
                routed_text TEXT NOT NULL,
                source_episode_id TEXT,
                reason TEXT NOT NULL,
                policy TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_intent_audits_created ON intent_audits(created_at DESC);

            CREATE TABLE IF NOT EXISTS meta (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );

            CREATE VIRTUAL TABLE IF NOT EXISTS episode_fts USING fts5(
                episode_id UNINDEXED,
                search_text,
                tokenize='unicode61 remove_diacritics 2'
            );
            CREATE VIRTUAL TABLE IF NOT EXISTS fact_fts USING fts5(
                fact_id UNINDEXED,
                search_text,
                tokenize='unicode61 remove_diacritics 2'
            );
            CREATE VIRTUAL TABLE IF NOT EXISTS message_fts USING fts5(
                message_id UNINDEXED,
                search_text,
                tokenize='unicode61 remove_diacritics 2'
            );
            """)

            // Upgrade from the execution-oriented v1/v2 schema. Older task rows
            // become read-only todos. Execution logs and procedural memory are
            // intentionally dropped: v3.1 does not execute tasks.
            if version > 0 {
                let hasTasks = try connection.query(
                    "SELECT name FROM sqlite_master WHERE type='table' AND name='tasks';"
                ).isEmpty == false
                if hasTasks {
                    try connection.executeScript("""
                    INSERT OR IGNORE INTO todos (
                        id, title, detail, status, intent_type, source_episode_id,
                        due_at, created_at, updated_at, completed_at
                    )
                    SELECT
                        id,
                        title,
                        detail,
                        CASE status
                            WHEN 'completed' THEN 'done'
                            WHEN 'cancelled' THEN 'dismissed'
                            WHEN 'failed' THEN 'dismissed'
                            ELSE 'open'
                        END,
                        intent_type,
                        source_episode_id,
                        NULL,
                        created_at,
                        updated_at,
                        completed_at
                    FROM tasks;
                    DROP TABLE IF EXISTS execution_logs;
                    DROP TABLE IF EXISTS procedural_patterns;
                    DROP TABLE IF EXISTS tasks;
                    """)
                }
            }

            try connection.execute("PRAGMA user_version=3;")
        }
    }

    // MARK: - Meta

    public func setMeta(_ key: String, _ value: String) throws {
        try database.transaction { connection in
            try connection.execute(
                "INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value;",
                [.text(key), .text(value)]
            )
        }
    }

    public func meta(_ key: String) throws -> String? {
        try database.read { connection in
            try connection.query("SELECT value FROM meta WHERE key = ?;", [.text(key)]).first?.string("value")
        }
    }

    // MARK: - Counts

    public func counts() throws -> MemoryCounts {
        try database.read { connection in
            func count(_ sql: String, _ bindings: [SQLiteValue] = []) throws -> Int {
                try connection.query(sql, bindings).first?.int("c") ?? 0
            }
            return MemoryCounts(
                episodes: try count("SELECT COUNT(*) AS c FROM episodes;"),
                archivedEpisodes: try count("SELECT COUNT(*) AS c FROM episodes WHERE archived = 1;"),
                activeFacts: try count("SELECT COUNT(*) AS c FROM semantic_facts WHERE status = 'active';"),
                pendingReviewFacts: try count("SELECT COUNT(*) AS c FROM semantic_facts WHERE status = 'pending_review';"),
                openTodos: try count("SELECT COUNT(*) AS c FROM todos WHERE status = 'open';"),
                digests: try count("SELECT COUNT(*) AS c FROM digests;"),
                contacts: try count("SELECT COUNT(*) AS c FROM contacts;"),
                messages: try count("SELECT COUNT(*) AS c FROM messages;")
            )
        }
    }

    public func purgeAll() throws {
        try database.transaction { connection in
            try connection.execute("DELETE FROM todos;")
            try connection.execute("DELETE FROM message_fts;")
            try connection.execute("DELETE FROM messages;")
            try connection.execute("DELETE FROM contact_channels;")
            try connection.execute("DELETE FROM contacts;")
            try connection.execute("DELETE FROM digests;")
            try connection.execute("DELETE FROM intent_audits;")
            try connection.execute("DELETE FROM semantic_facts;")
            try connection.execute("DELETE FROM episodes;")
            try connection.execute("DELETE FROM episode_fts;")
            try connection.execute("DELETE FROM fact_fts;")
            try connection.execute("DELETE FROM meta;")
        }
        try? database.checkpoint()
        try database.vacuum()
        coldArchive.purgeAll()
    }

    // MARK: - Encoding helpers

    func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONCoding.encoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    func decodeJSON<T: Decodable>(_ type: T.Type, from string: String, fallback: T) -> T {
        guard let data = string.data(using: .utf8) else { return fallback }
        return (try? JSONCoding.decoder().decode(type, from: data)) ?? fallback
    }
}

public extension Date {
    var epoch: Double { timeIntervalSince1970 }
}
