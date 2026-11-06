import Foundation

public extension MemoryStore {
    func insertTodo(_ todo: TodoItem) throws {
        try database.transaction { connection in
            try connection.execute("""
            INSERT INTO todos (
                id, title, detail, status, intent_type, source_episode_id,
                due_at, created_at, updated_at, completed_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """, [
                .text(todo.id),
                .text(todo.title),
                .text(todo.detail),
                .text(todo.status.rawValue),
                .optionalText(todo.intentType?.rawValue),
                .optionalText(todo.sourceEpisodeID),
                todo.dueAt.map { .real($0.epoch) } ?? .null,
                .real(todo.createdAt.epoch),
                .real(todo.updatedAt.epoch),
                todo.completedAt.map { .real($0.epoch) } ?? .null
            ])
        }
    }

    func addTodo(
        title: String,
        detail: String = "",
        intentType: IntentType? = nil,
        sourceEpisodeID: String? = nil,
        dueAt: Date? = nil,
        now: Date = Date()
    ) throws -> TodoItem {
        let cleanTitle = TextAnalyzer.truncated(
            title.trimmingCharacters(in: .whitespacesAndNewlines),
            limit: 300
        )
        guard !cleanTitle.isEmpty else {
            throw MemoryServiceError.invalidArgument("todo title must not be empty")
        }
        let todo = TodoItem(
            id: "todo_" + UUID().uuidString.lowercased(),
            title: cleanTitle,
            detail: TextAnalyzer.truncated(detail, limit: 2_000),
            intentType: intentType,
            sourceEpisodeID: sourceEpisodeID,
            dueAt: dueAt,
            createdAt: now,
            updatedAt: now
        )
        try insertTodo(todo)
        return todo
    }

    func fetchTodo(id: String) throws -> TodoItem? {
        try database.read { connection in
            try connection.query("SELECT * FROM todos WHERE id = ?;", [.text(id)])
                .first.map(Self.todo(from:))
        }
    }

    func fetchTodos(status: TodoStatus? = nil, limit: Int = 100) throws -> [TodoItem] {
        try database.read { connection in
            var sql = "SELECT * FROM todos"
            var bindings: [SQLiteValue] = []
            if let status {
                sql += " WHERE status = ?"
                bindings.append(.text(status.rawValue))
            }
            sql += " ORDER BY created_at DESC LIMIT ?;"
            bindings.append(.integer(Int64(max(1, limit))))
            return try connection.query(sql, bindings).map(Self.todo(from:))
        }
    }

    func openTodos(limit: Int = 200) throws -> [TodoItem] {
        try fetchTodos(status: .open, limit: limit)
    }

    @discardableResult
    func updateTodoStatus(id: String, status: TodoStatus, at date: Date = Date()) throws -> TodoItem? {
        guard let todo = try fetchTodo(id: id) else { return nil }
        guard todo.status != status else { return todo }
        let completedAt = status == .done ? date : nil
        try database.transaction { connection in
            try connection.execute("""
            UPDATE todos SET status = ?, updated_at = ?, completed_at = ? WHERE id = ?;
            """, [
                .text(status.rawValue),
                .real(date.epoch),
                completedAt.map { .real($0.epoch) } ?? .null,
                .text(id)
            ])
        }
        return try fetchTodo(id: id)
    }

    func deleteTodo(id: String) throws -> Bool {
        try database.transaction { connection in
            let changes = try connection.execute("DELETE FROM todos WHERE id = ?;", [.text(id)])
            return changes > 0
        }
    }

    static func todo(from row: SQLiteRow) -> TodoItem {
        TodoItem(
            id: row.string("id") ?? "",
            title: row.string("title") ?? "",
            detail: row.string("detail") ?? "",
            status: TodoStatus(rawValue: row.string("status") ?? "") ?? .open,
            intentType: row.string("intent_type").flatMap(IntentType.init(rawValue:)),
            sourceEpisodeID: row.string("source_episode_id"),
            dueAt: row.date("due_at"),
            createdAt: row.date("created_at") ?? Date(),
            updatedAt: row.date("updated_at") ?? Date(),
            completedAt: row.date("completed_at")
        )
    }
}
