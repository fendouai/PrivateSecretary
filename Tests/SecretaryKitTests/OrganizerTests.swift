import Testing
import Foundation
@testable import SecretaryKit

@Test func timelineIsChronologicalAndIncludesFacts() throws {
    let env = try TestEnvironment()
    let calendar = fixedCalendar()
    let now = fixedNow()
    let early = try env.ingest("我们决定采用 HNSW 混合检索", at: now.addingTimeInterval(-3_600), app: "Notes")
    let late = try env.ingest("视频里讲了 BM25 参数", at: now.addingTimeInterval(-600), origin: .system, source: .audio, app: "Safari")
    let result = try env.service.timeline(in: DateCoding.dayInterval(for: now, calendar: calendar))
    #expect(result.entries.count >= 2)
    #expect(result.entries.map(\.timestamp) == result.entries.map(\.timestamp).sorted())
    let ids = Set(result.entries.map(\.memoryID))
    #expect(ids.contains(early.episode!.id))
    #expect(ids.contains(late.episode!.id))
    #expect(result.entries.contains { $0.kind == .fact && $0.memoryID == early.facts.first?.id })
}

@Test func timelineCanExcludeFactsAndRespectsLimit() throws {
    let env = try TestEnvironment()
    let now = fixedNow()
    for index in 0..<6 {
        _ = try env.ingest(
            "独立记录 \(index) HNSW 参数",
            at: now.addingTimeInterval(Double(index) * 60),
            app: "App\(index)"
        )
    }
    let result = try env.service.timeline(
        in: DateCoding.dayInterval(for: now, calendar: fixedCalendar()),
        includeFacts: false,
        limit: 3
    )
    #expect(result.entries.count == 3)
    #expect(result.entries.allSatisfy { $0.kind == .episode })
}

@Test func timelineExcludesOutsideRange() throws {
    let env = try TestEnvironment()
    let now = fixedNow()
    _ = try env.ingest("今天的记忆", at: now)
    let yesterday = now.addingTimeInterval(-86_400)
    let result = try env.service.timeline(in: DateCoding.dayInterval(for: yesterday, calendar: fixedCalendar()))
    #expect(result.entries.isEmpty)
}

@Test func serviceTodoAndMessageConvenienceMethods() throws {
    let env = try TestEnvironment()
    let todo = try env.service.addTodo(title: "整理 HNSW 参数")
    #expect(try env.service.todos(status: .open).contains { $0.id == todo.id })
    #expect(try env.service.updateTodo(id: todo.id, status: .done)?.status == .done)
    let message = try env.service.recordMessage(
        channel: "email",
        contactName: "张三",
        handle: "zhangsan@example.com",
        direction: .inbound,
        text: "参数对比请周五前发我"
    )
    #expect(try env.service.messages(channel: "email").count == 1)
    #expect(try env.service.contacts().first?.displayName == "张三")
    #expect(try env.service.markMessageRead(id: message.id)?.isRead == true)
    #expect(try env.service.contacts().first?.messageCount == 1)
}

@Test func deletingEpisodeAlsoDeletesDerivedTodo() throws {
    let env = try TestEnvironment()
    let ingested = try env.ingest("帮我记一下 HNSW 参数对比")
    let todo = try #require(ingested.todo)
    let episode = try #require(ingested.episode)
    try env.store.deleteEpisode(id: episode.id)
    #expect(try env.store.fetchTodo(id: todo.id) == nil)
}

@Test func migrationFromLegacyTaskSchemaCreatesTodos() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ps-migration-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = AppPaths(home: root)
    try paths.ensureDirectories()
    let oldDB = try SQLiteDatabase(path: paths.databaseFile.path)
    try oldDB.transaction { connection in
        try connection.executeScript("""
        CREATE TABLE tasks (
            id TEXT PRIMARY KEY,
            intent_type TEXT NOT NULL,
            title TEXT NOT NULL,
            detail TEXT NOT NULL,
            risk TEXT NOT NULL,
            confidence REAL NOT NULL,
            status TEXT NOT NULL,
            source_episode_id TEXT,
            routed_text TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            claimed_at REAL,
            claimed_by TEXT,
            completed_at REAL,
            outcome TEXT,
            failure_reason TEXT
        );
        INSERT INTO tasks (
            id, intent_type, title, detail, risk, confidence, status,
            source_episode_id, routed_text, created_at, updated_at,
            claimed_at, claimed_by, completed_at, outcome, failure_reason
        ) VALUES (
            'task_legacy', 'record', '旧任务', 'from v2', 'auto', 0.9, 'completed',
            NULL, '旧任务', 1000, 1001, 1000, 'codex', 1001, 'done', NULL
        );
        PRAGMA user_version=2;
        """)
    }
    let store = try MemoryStore(paths: paths, config: AppConfig())
    let todos = try store.fetchTodos()
    #expect(todos.count == 1)
    #expect(todos.first?.id == "task_legacy")
    #expect(todos.first?.status == .done)
    #expect(try store.counts().openTodos == 0)
}
