import Foundation

public extension MemoryStore {
    @discardableResult
    func upsertContact(
        displayName: String,
        organization: String? = nil,
        notes: String? = nil,
        channels: [ContactChannel] = [],
        now: Date = Date()
    ) throws -> Contact {
        let name = TextAnalyzer.truncated(
            displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            limit: 200
        )
        guard !name.isEmpty else {
            throw MemoryServiceError.invalidArgument("contact display name must not be empty")
        }
        let cleanedChannels = channels.compactMap { channel -> ContactChannel? in
            let channelName = channel.channel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let handle = channel.handle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !channelName.isEmpty, !handle.isEmpty else { return nil }
            return ContactChannel(channel: channelName, handle: handle)
        }
        let normalized = Self.normalizedContactName(name)

        let contactID: String = try database.transaction { connection in
            var identifier: String?
            for channel in cleanedChannels {
                identifier = try connection.query("""
                SELECT contact_id FROM contact_channels
                WHERE channel = ? AND handle = ? LIMIT 1;
                """, [.text(channel.channel), .text(channel.handle)])
                    .first?.string("contact_id")
                if identifier != nil { break }
            }
            if identifier == nil {
                identifier = try connection.query("""
                SELECT id FROM contacts WHERE normalized_name = ?
                ORDER BY updated_at DESC LIMIT 1;
                """, [.text(normalized)]).first?.string("id")
            }
            let id = identifier ?? "contact_" + UUID().uuidString.lowercased()
            if identifier == nil {
                try connection.execute("""
                INSERT INTO contacts(id, display_name, normalized_name, organization, notes, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?);
                """, [
                    .text(id), .text(name), .text(normalized),
                    .optionalText(organization), .optionalText(notes),
                    .real(now.epoch), .real(now.epoch)
                ])
            } else {
                try connection.execute("""
                UPDATE contacts
                SET display_name = ?, organization = COALESCE(?, organization),
                    notes = COALESCE(?, notes), updated_at = ?
                WHERE id = ?;
                """, [
                    .text(name), .optionalText(organization), .optionalText(notes),
                    .real(now.epoch), .text(id)
                ])
            }
            for channel in cleanedChannels {
                try connection.execute("""
                INSERT OR IGNORE INTO contact_channels(contact_id, channel, handle)
                VALUES (?, ?, ?);
                """, [.text(id), .text(channel.channel), .text(channel.handle)])
            }
            return id
        }
        return try fetchContact(id: contactID) ?? Contact(
            id: contactID,
            displayName: name,
            organization: organization,
            notes: notes,
            channels: cleanedChannels,
            createdAt: now,
            updatedAt: now
        )
    }

    func fetchContact(id: String) throws -> Contact? {
        try database.read { connection in
            guard let row = try connection.query(
                "SELECT * FROM contacts WHERE id = ?;",
                [.text(id)]
            ).first else { return nil }
            let channels = try channels(for: [id], connection: connection)[id] ?? []
            let stats = try messageStats(for: [id], connection: connection)[id]
            return Self.contact(from: row, channels: channels, stats: stats)
        }
    }

    func listContacts(limit: Int = 100, query: String? = nil) throws -> [Contact] {
        try database.read { connection in
            var sql = """
            SELECT c.*, COUNT(m.id) AS message_count,
                   MAX(m.timestamp) AS last_message_at,
                   (SELECT text FROM messages m2 WHERE m2.contact_id = c.id
                    ORDER BY m2.timestamp DESC LIMIT 1) AS last_message_snippet
            FROM contacts c
            LEFT JOIN messages m ON m.contact_id = c.id
            """
            var bindings: [SQLiteValue] = []
            if let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sql += " WHERE c.normalized_name LIKE ? OR c.display_name LIKE ?"
                let pattern = "%\(query.lowercased())%"
                bindings.append(.text(pattern))
                bindings.append(.text(pattern))
            }
            sql += """
             GROUP BY c.id
             ORDER BY COALESCE(MAX(m.timestamp), c.updated_at) DESC
             LIMIT ?;
            """
            bindings.append(.integer(Int64(max(1, limit))))
            let rows = try connection.query(sql, bindings)
            let ids = rows.compactMap { $0.string("id") }
            let channelMap = try channels(for: ids, connection: connection)
            let statsMap = try messageStats(for: ids, connection: connection)
            return rows.map { row in
                let id = row.string("id") ?? ""
                return Self.contact(
                    from: row,
                    channels: channelMap[id] ?? [],
                    stats: statsMap[id]
                )
            }
        }
    }

    @discardableResult
    func recordMessage(
        channel rawChannel: String,
        contactName: String,
        handle: String? = nil,
        direction: MessageDirection,
        text rawText: String,
        timestamp: Date = Date(),
        thread: String? = nil,
        externalID: String? = nil,
        isRead: Bool? = nil,
        now: Date = Date()
    ) throws -> ContactMessage {
        let channel = rawChannel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !channel.isEmpty, channel.count <= 60 else {
            throw MemoryServiceError.invalidArgument("channel must be a non-empty string (<=60 chars)")
        }
        let name = contactName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw MemoryServiceError.invalidArgument("contact_name must not be empty")
        }
        let text = TextAnalyzer.truncated(
            rawText.trimmingCharacters(in: .whitespacesAndNewlines),
            limit: 10_000
        )
        guard !text.isEmpty else {
            throw MemoryServiceError.invalidArgument("message text must not be empty")
        }
        let cleanHandle = handle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let read = isRead ?? (direction == .outbound)

        let result: (messageID: String, contactID: String, inserted: Bool) = try database.transaction { connection in
            var contactID: String?
            if let cleanHandle, !cleanHandle.isEmpty {
                contactID = try connection.query("""
                SELECT contact_id FROM contact_channels
                WHERE channel = ? AND handle = ? LIMIT 1;
                """, [.text(channel), .text(cleanHandle)]).first?.string("contact_id")
            }
            if contactID == nil {
                contactID = try connection.query("""
                SELECT id FROM contacts WHERE normalized_name = ?
                ORDER BY updated_at DESC LIMIT 1;
                """, [.text(Self.normalizedContactName(name))]).first?.string("id")
            }
            let identifier = contactID ?? "contact_" + UUID().uuidString.lowercased()
            if contactID == nil {
                try connection.execute("""
                INSERT INTO contacts(id, display_name, normalized_name, organization, notes, created_at, updated_at)
                VALUES (?, ?, ?, NULL, NULL, ?, ?);
                """, [
                    .text(identifier), .text(name), .text(Self.normalizedContactName(name)),
                    .real(now.epoch), .real(now.epoch)
                ])
            }
            if let cleanHandle, !cleanHandle.isEmpty {
                try connection.execute("""
                INSERT OR IGNORE INTO contact_channels(contact_id, channel, handle)
                VALUES (?, ?, ?);
                """, [.text(identifier), .text(channel), .text(cleanHandle)])
            }

            let dedupe = externalID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? externalID!.trimmingCharacters(in: .whitespacesAndNewlines)
                : Self.messageDedupeKey(
                    channel: channel,
                    direction: direction,
                    contactID: identifier,
                    timestamp: timestamp,
                    text: text
                )
            if let existing = try connection.query("""
            SELECT id FROM messages WHERE channel = ? AND dedupe_key = ? LIMIT 1;
            """, [.text(channel), .text(dedupe)]).first?.string("id") {
                return (existing, identifier, false)
            }

            let messageID = "msg_" + UUID().uuidString.lowercased()
            try connection.execute("""
            INSERT INTO messages (
                id, contact_id, channel, direction, text, timestamp, is_read,
                thread, external_id, dedupe_key, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """, [
                .text(messageID), .text(identifier), .text(channel),
                .text(direction.rawValue), .text(text), .real(timestamp.epoch),
                .integer(Int64(read ? 1 : 0)), .optionalText(thread),
                .optionalText(externalID), .text(dedupe), .real(now.epoch)
            ])
            let search = TextAnalyzer.tokens(text + " " + name).joined(separator: " ")
            try connection.execute(
                "INSERT INTO message_fts(message_id, search_text) VALUES(?, ?);",
                [.text(messageID), .text(search)]
            )
            try connection.execute("""
            UPDATE contacts SET updated_at = ? WHERE id = ?;
            """, [.real(now.epoch), .text(identifier)])
            return (messageID, identifier, true)
        }

        guard let message = try fetchMessage(id: result.messageID) else {
            throw MemoryServiceError.unavailable("message was written but could not be read back")
        }
        return message
    }

    func fetchMessage(id: String) throws -> ContactMessage? {
        try database.read { connection in
            guard let row = try connection.query("""
            SELECT m.*, c.display_name AS contact_name
            FROM messages m JOIN contacts c ON c.id = m.contact_id
            WHERE m.id = ?;
            """, [.text(id)]).first else { return nil }
            return Self.message(from: row)
        }
    }

    func listMessages(
        channel: String? = nil,
        contactID: String? = nil,
        unreadOnly: Bool = false,
        limit: Int = 100
    ) throws -> [ContactMessage] {
        try database.read { connection in
            var sql = """
            SELECT m.*, c.display_name AS contact_name
            FROM messages m JOIN contacts c ON c.id = m.contact_id
            WHERE 1=1
            """
            var bindings: [SQLiteValue] = []
            if let channel, !channel.isEmpty {
                sql += " AND m.channel = ?"
                bindings.append(.text(channel.lowercased()))
            }
            if let contactID, !contactID.isEmpty {
                sql += " AND m.contact_id = ?"
                bindings.append(.text(contactID))
            }
            if unreadOnly { sql += " AND m.is_read = 0" }
            sql += " ORDER BY m.timestamp DESC LIMIT ?;"
            bindings.append(.integer(Int64(max(1, limit))))
            return try connection.query(sql, bindings).map(Self.message(from:))
        }
    }

    @discardableResult
    func markMessageRead(id: String, isRead: Bool = true, now: Date = Date()) throws -> ContactMessage? {
        try database.transaction { connection in
            try connection.execute(
                "UPDATE messages SET is_read = ? WHERE id = ?;",
                [.integer(Int64(isRead ? 1 : 0)), .text(id)]
            )
        }
        return try fetchMessage(id: id)
    }

    static func normalizedContactName(_ name: String) -> String {
        TextAnalyzer.normalize(name)
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
    }

    struct ContactStats {
        var count: Int
        var lastAt: Date?
        var snippet: String?
    }

    private func channels(
        for contactIDs: [String],
        connection: SQLiteConnection
    ) throws -> [String: [ContactChannel]] {
        guard !contactIDs.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: contactIDs.count).joined(separator: ",")
        let rows = try connection.query("""
        SELECT contact_id, channel, handle FROM contact_channels
        WHERE contact_id IN (\(placeholders))
        ORDER BY channel, handle;
        """, contactIDs.map { .text($0) })
        var result: [String: [ContactChannel]] = [:]
        for row in rows {
            guard let id = row.string("contact_id"),
                  let channel = row.string("channel"),
                  let handle = row.string("handle") else { continue }
            result[id, default: []].append(ContactChannel(channel: channel, handle: handle))
        }
        return result
    }

    private func messageStats(
        for contactIDs: [String],
        connection: SQLiteConnection
    ) throws -> [String: ContactStats] {
        guard !contactIDs.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: contactIDs.count).joined(separator: ",")
        let rows = try connection.query("""
        SELECT contact_id, COUNT(*) AS c, MAX(timestamp) AS last_at
        FROM messages WHERE contact_id IN (\(placeholders))
        GROUP BY contact_id;
        """, contactIDs.map { .text($0) })
        var stats: [String: ContactStats] = [:]
        for row in rows {
            guard let id = row.string("contact_id") else { continue }
            stats[id] = ContactStats(count: row.int("c") ?? 0, lastAt: row.date("last_at"), snippet: nil)
        }
        return stats
    }

    static func contact(
        from row: SQLiteRow,
        channels: [ContactChannel],
        stats: ContactStats?
    ) -> Contact {
        Contact(
            id: row.string("id") ?? "",
            displayName: row.string("display_name") ?? "",
            organization: row.string("organization"),
            notes: row.string("notes"),
            channels: channels,
            messageCount: stats?.count ?? row.int("message_count") ?? 0,
            lastMessageAt: stats?.lastAt ?? row.date("last_message_at"),
            lastMessageSnippet: row.string("last_message_snippet"),
            createdAt: row.date("created_at") ?? Date(),
            updatedAt: row.date("updated_at") ?? Date()
        )
    }

    static func message(from row: SQLiteRow) -> ContactMessage {
        ContactMessage(
            id: row.string("id") ?? "",
            contactID: row.string("contact_id") ?? "",
            contactName: row.string("contact_name") ?? "Unknown",
            channel: row.string("channel") ?? "unknown",
            direction: MessageDirection(rawValue: row.string("direction") ?? "") ?? .inbound,
            text: row.string("text") ?? "",
            timestamp: row.date("timestamp") ?? Date(),
            isRead: row.bool("is_read") ?? false,
            thread: row.string("thread"),
            externalID: row.string("external_id"),
            createdAt: row.date("created_at") ?? Date()
        )
    }

    private static func messageDedupeKey(
        channel: String,
        direction: MessageDirection,
        contactID: String,
        timestamp: Date,
        text: String
    ) -> String {
        let source = "\(channel)|\(direction.rawValue)|\(contactID)|\(Int(timestamp.timeIntervalSince1970))|\(text)"
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in source.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "auto-%016llx", hash)
    }
}
