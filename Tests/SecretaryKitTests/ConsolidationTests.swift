import Testing
@testable import SecretaryKit

private struct ArchiveFixture {
    let env: TestEnvironment
    let now: Date

    init(configure: (inout AppConfig) -> Void) throws {
        env = try TestEnvironment(configure: configure)
        now = fixedNow()
    }
}

private struct ConsolidationFixture {
    let env: TestEnvironment
    let calendar: Calendar
    let now: Date

    init() throws {
        env = try TestEnvironment { config in
            config.salience.threshold = 0.3
        }
        calendar = fixedCalendar()
        now = fixedNow()
    }
}

@Test func digestContainsMemoryIDsAndCounts() throws {
    let fixture = try ConsolidationFixture()
    let meeting = try fixture.env.ingest("我们决定采用 HNSW 加 BM25 混合检索", at: fixture.now, app: "TencentMeeting")
    let terminal = try fixture.env.ingest(
        "",
        ocr: "ERROR: cannot resolve dependency",
        at: fixture.now,
        source: .screen,
        app: "Terminal"
    )
    let meetingEpisode = try #require(meeting.episode)
    let terminalEpisode = try #require(terminal.episode)
    let report = try fixture.env.service.generateDigest(
        dayKey: "2026-11-06",
        now: fixture.now,
        calendar: fixture.calendar
    )
    #expect(report.date == "2026-11-06")
    #expect(report.digest.stats.episodeCount == 2)
    #expect(report.digest.markdown.contains(meetingEpisode.id))
    #expect(report.digest.markdown.contains(terminalEpisode.id))
    #expect(report.digest.entries.contains { $0.memoryID == meetingEpisode.id && $0.layer == .l2 })
    #expect(report.digest.entries.contains { $0.memoryID == terminalEpisode.id })
    #expect(try fixture.env.store.digest(date: "2026-11-06") != nil)
}

@Test func lowSalienceEpisodeExcludedFromSignificantEntries() throws {
    let fixture = try ConsolidationFixture()
    let episode = fixture.env.makeEpisode(text: "例行屏幕内容", at: fixture.now, salience: 0.1)
    try fixture.env.store.insertEpisode(episode)
    let report = try fixture.env.service.generateDigest(
        dayKey: "2026-11-06",
        now: fixture.now,
        calendar: fixture.calendar
    )
    #expect(report.digest.stats.episodeCount == 1)
    #expect(report.digest.stats.significantEpisodeCount == 0)
    #expect(!report.digest.entries.contains { $0.memoryID == episode.id })
    #expect(report.digest.markdown.contains("没有超过显著性阈值"))
}

@Test func consolidationExtractsMissingFacts() throws {
    let fixture = try ConsolidationFixture()
    let episode = fixture.env.makeEpisode(text: "我们决定采用 HNSW 混合检索", at: fixture.now, salience: 0.8)
    try fixture.env.store.insertEpisode(episode)
    #expect(try fixture.env.store.facts(forEpisodeID: episode.id).isEmpty)
    let report = try fixture.env.service.generateDigest(
        dayKey: "2026-11-06",
        now: fixture.now,
        calendar: fixture.calendar
    )
    #expect(report.factsCreated >= 1)
    #expect(!(try fixture.env.store.facts(forEpisodeID: episode.id)).isEmpty)
    #expect(report.digest.markdown.contains("decision"))
}

@Test func clusterGroupsByAppAndGap() throws {
    let fixture = try ConsolidationFixture()
    let base = fixture.now
    let episodes = [
        fixture.env.makeEpisode(text: "a", at: base, app: "A"),
        fixture.env.makeEpisode(text: "b", at: base.addingTimeInterval(100), app: "A"),
        fixture.env.makeEpisode(text: "c", at: base.addingTimeInterval(500), app: "B"),
        fixture.env.makeEpisode(text: "d", at: base.addingTimeInterval(2_000), app: "A")
    ]
    let clusters = Consolidator.cluster(episodes: episodes, maximumGap: 300)
    #expect(clusters.count == 3)
    #expect(clusters[0].episodeIDs.count == 2)
    #expect(clusters[1].application == "B")
}

@Test func digestListsCapturedTodosWithoutExecutingThem() throws {
    let fixture = try ConsolidationFixture()
    let ingested = try fixture.env.ingest("帮我记一下周五前提交 HNSW 参数对比", at: fixture.now)
    let todo = try #require(ingested.todo)
    let report = try fixture.env.service.generateDigest(
        dayKey: "2026-11-06",
        now: fixture.now,
        calendar: fixture.calendar
    )
    #expect(report.digest.stats.todoCount == 1)
    #expect(report.digest.markdown.contains("[ ]"))
    #expect(report.digest.markdown.contains(todo.id))
    #expect(try fixture.env.store.fetchTodo(id: todo.id)?.status == .open)
}

@Test func forgettingArchivesLowWeightOldEpisodeAndKeepsSummary() throws {
    let fixture = try ArchiveFixture { config in
        config.salience.minimumRetentionDays = 1
        config.salience.decayHalfLifeDays = 1
        config.salience.archiveBelowWeight = 0.5
    }
    let oldDate = fixture.now.addingTimeInterval(-86_400 * 20)
    let episode = fixture.env.makeEpisode(
        text: "旧的低权重 HNSW 记录，应该被归档",
        at: oldDate,
        salience: 0.2
    )
    try fixture.env.store.insertEpisode(episode)
    let count = try Consolidator(store: fixture.env.store, config: fixture.env.config).forget(now: fixture.now)
    #expect(count == 1)
    let stored = try fixture.env.store.fetchEpisode(id: episode.id)
    #expect(stored?.archived == true)
    #expect(stored?.transcript == "")
    #expect(stored?.summary.contains("HNSW") == true)
    #expect(!fixture.env.store.coldArchive.files().isEmpty)
}

@Test func highSalienceOldEpisodeNotArchived() throws {
    let fixture = try ArchiveFixture { config in
        config.salience.minimumRetentionDays = 1
        config.salience.decayHalfLifeDays = 100
        config.salience.archiveBelowWeight = 0.3
    }
    let episode = fixture.env.makeEpisode(
        text: "重要的旧决策",
        at: fixture.now.addingTimeInterval(-86_400 * 2),
        salience: 0.9
    )
    try fixture.env.store.insertEpisode(episode)
    let count = try Consolidator(store: fixture.env.store, config: fixture.env.config).forget(now: fixture.now)
    #expect(count == 0)
    #expect(try fixture.env.store.fetchEpisode(id: episode.id)?.archived == false)
}

@Test func digestCanBeGeneratedTwice() throws {
    let fixture = try ConsolidationFixture()
    _ = try fixture.env.ingest("我们决定采用方案 A", at: fixture.now)
    let first = try fixture.env.service.generateDigest(
        dayKey: "2026-11-06",
        now: fixture.now,
        calendar: fixture.calendar
    )
    let second = try fixture.env.service.generateDigest(
        dayKey: "2026-11-06",
        now: fixture.now.addingTimeInterval(10),
        calendar: fixture.calendar
    )
    #expect(first.digest.date == second.digest.date)
    #expect(try fixture.env.store.digests().count == 1)
    #expect(try fixture.env.store.fetchFacts().count == 1)
}

@Test func emptyDayDigest() throws {
    let fixture = try ConsolidationFixture()
    let report = try fixture.env.service.generateDigest(
        dayKey: "2026-11-01",
        now: fixture.now,
        calendar: fixture.calendar
    )
    #expect(report.digest.stats.episodeCount == 0)
    #expect(report.digest.markdown.contains("没有超过显著性阈值"))
    #expect(try fixture.env.store.digest(date: "2026-11-01") != nil)
}

@Test func markdownEscapesUntrustedBrackets() throws {
    let fixture = try ConsolidationFixture()
    let episode = fixture.env.makeEpisode(
        text: "[click](javascript:alert(1)) HNSW",
        at: fixture.now,
        salience: 0.9
    )
    try fixture.env.store.insertEpisode(episode)
    let report = try fixture.env.service.generateDigest(
        dayKey: "2026-11-06",
        now: fixture.now,
        calendar: fixture.calendar
    )
    #expect(!report.digest.markdown.contains("[click](javascript"))
    #expect(report.digest.markdown.contains("［click］") || report.digest.markdown.contains("click"))
}
