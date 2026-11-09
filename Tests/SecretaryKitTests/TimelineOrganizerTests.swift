import Testing
@testable import SecretaryKit

private struct FakeTimelineModel: TimelineModelExtracting {
    var todos: [TimelineTodoCandidate] = []
    var messages: [TimelineMessageCandidate] = []

    func extractTodos(from episode: Episode) throws -> [TimelineTodoCandidate] { todos }
    func extractMessages(from episode: Episode) throws -> [TimelineMessageCandidate] { messages }
}

@Test func organizerBackfillsTodosAndIsIdempotent() throws {
    let env = try TestEnvironment()
    let episode = env.makeEpisode(text: "我明天下午三点前把预算表发给欧阳。", at: Date(), app: "Notes")
    try env.store.insertEpisode(episode)
    let organizer = TimelineOrganizer(
        store: env.store,
        config: env.config,
        paths: env.paths,
        model: FakeTimelineModel(todos: [
            TimelineTodoCandidate(title: "把预算表发给欧阳", detail: "明天下午三点前", confidence: 0.9)
        ])
    )
    let first = try organizer.organize()
    #expect(first.todosCreated == 1)
    #expect(try env.store.fetchTodos(status: .open).count == 1)
    let second = try organizer.organize()
    #expect(second.todosCreated == 0)
    #expect(second.episodesSkipped == 1)
}

@Test func organizerExtractsChatMessagesAndContacts() throws {
    let env = try TestEnvironment()
    var episode = env.makeEpisode(text: "Slack: Alice: 明天下午三点开会", at: Date(), app: "Slack")
    episode.source = .screen
    episode.audioOrigin = .manual
    try env.store.insertEpisode(episode)
    let organizer = TimelineOrganizer(
        store: env.store,
        config: env.config,
        paths: env.paths,
        model: FakeTimelineModel(messages: [
            TimelineMessageCandidate(channel: "chat", contactName: "Alice", text: "明天下午三点开会", confidence: 0.9)
        ])
    )
    let report = try organizer.organize()
    #expect(report.messagesCreated == 1)
    #expect(report.contacts == 1)
    #expect(try env.store.listMessages(channel: "chat").first?.contactName == "Alice")
}

@Test func organizerImportsGmailRowsWithoutLLM() throws {
    let env = try TestEnvironment()
    let now = Date()
    var episode = env.makeEpisode(text: "收件箱", at: now, app: "Google Chrome")
    episode.source = .screen
    episode.windowTitle = "收件箱 - test@example.com - Gmail"
    episode.ocrText = "收件箱 Alice Project update"
    episode.ocrRegions = [
        OCRRegion(text: "Alice", confidence: 1, x: 0.25, y: 0.30, width: 0.05, height: 0.015),
        OCRRegion(text: "Project update", confidence: 1, x: 0.37, y: 0.30, width: 0.30, height: 0.015),
        OCRRegion(text: "08:10", confidence: 1, x: 0.95, y: 0.30, width: 0.03, height: 0.015)
    ]
    try env.store.insertEpisode(episode)
    let organizer = TimelineOrganizer(store: env.store, config: env.config, paths: env.paths, model: FakeTimelineModel())
    let report = try organizer.organize()
    #expect(report.messagesCreated == 1)
    #expect(try env.store.listMessages(channel: "email").count == 1)
}

@Test func organizerDoesNotDuplicateExplicitTodo() throws {
    let env = try TestEnvironment()
    _ = try env.store.addTodo(title: "记一下明天下午三点和欧阳确认量子计算预算")
    let episode = env.makeEpisode(text: "明天下午三点和欧阳确认量子计算预算。", at: Date(), app: "Notes")
    try env.store.insertEpisode(episode)
    let organizer = TimelineOrganizer(
        store: env.store,
        config: env.config,
        paths: env.paths,
        model: FakeTimelineModel(todos: [
            TimelineTodoCandidate(title: "确认量子计算预算", confidence: 0.9)
        ])
    )
    let report = try organizer.organize()
    #expect(report.todosCreated == 0)
    #expect(try env.store.fetchTodos().count == 1)
}

@Test func organizerIgnoresBrowserDocsForMessages() throws {
    let env = try TestEnvironment()
    var episode = env.makeEpisode(text: "公众号 视频 收入变现 OverView", at: Date(), app: "Google Chrome")
    episode.source = .screen
    episode.windowTitle = "PrivateSecretary docs"
    episode.ocrText = "公众号 视频 收入变现 OverView"
    try env.store.insertEpisode(episode)
    let organizer = TimelineOrganizer(
        store: env.store,
        config: env.config,
        paths: env.paths,
        model: FakeTimelineModel(messages: [
            TimelineMessageCandidate(channel: "email", contactName: "匿名", text: "不该入库", confidence: 0.9)
        ])
    )
    let report = try organizer.organize()
    #expect(report.messagesCreated == 0)
}
