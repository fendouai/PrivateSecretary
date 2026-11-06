import Testing
@testable import SecretaryKit

private struct RetrievalFixture {
    let env: TestEnvironment
    let calendar: Calendar
    let now: Date

    init(configure: (inout AppConfig) -> Void = { _ in }) throws {
        env = try TestEnvironment(configure: configure)
        calendar = fixedCalendar()
        now = fixedNow()
    }
}

@Test func lexicalQueryFindsEpisodeAndReturnsOnlySummary() throws {
    let fixture = try RetrievalFixture()
    let longText = "这个视频讲了向量数据库的 HNSW 参数。ef_construction 设置为 200，M 设置为 32。"
        + String(repeating: "补充说明。", count: 100)
    let ingested = try fixture.env.ingest(
        longText,
        at: fixture.now,
        origin: .system,
        source: .audio,
        app: "Safari"
    )
    let recall = try fixture.env.service.recall(query: "HNSW 参数", now: fixture.now)
    #expect(!recall.results.isEmpty)
    let first = try #require(recall.results.first)
    #expect(first.id == ingested.episode?.id)
    #expect(first.layer == .l2)
    #expect(first.summary.count <= fixture.env.config.retrieval.summaryCharacterLimit)
    #expect(!first.summary.contains(String(repeating: "补充说明。", count: 50)))
    #expect(recall.note.contains("drill_down"))
}

@Test func layerFilter() throws {
    let fixture = try RetrievalFixture()
    _ = try fixture.env.ingest("我们决定采用 HNSW 加 BM25 混合检索", at: fixture.now, app: "TencentMeeting")
    let l3 = try fixture.env.service.recall(query: "HNSW 决策", layer: .l3, now: fixture.now)
    let l2 = try fixture.env.service.recall(query: "HNSW 决策", layer: .l2, now: fixture.now)
    #expect(l2.results.contains { $0.layer == .l2 })
    #expect(l3.results.allSatisfy { $0.layer == .l3 })
}

@Test func timeRangeFilter() throws {
    let fixture = try RetrievalFixture()
    let old = fixture.now.addingTimeInterval(-86_400 * 10)
    _ = try fixture.env.ingest("很久以前的 HNSW 笔记", at: old)
    _ = try fixture.env.ingest("今天的 HNSW 笔记", at: fixture.now)
    let result = try fixture.env.service.recall(
        query: "HNSW",
        timeRange: DateInterval(
            start: fixture.calendar.startOfDay(for: fixture.now),
            end: fixture.now.addingTimeInterval(3600)
        ),
        now: fixture.now
    )
    #expect(!result.results.isEmpty)
    #expect(result.results.allSatisfy { $0.timestamp >= fixture.calendar.startOfDay(for: fixture.now) })
}

@Test func naturalLanguageTimeIsParsedAndStripped() throws {
    let fixture = try RetrievalFixture()
    let yesterday = fixture.calendar.date(byAdding: .day, value: -1, to: fixture.now)!
    let event = try fixture.env.ingest("昨天讲的 HNSW 参数", at: yesterday, app: "Safari")
    let result = try fixture.env.service.recall(query: "昨天讲了什么 HNSW", now: fixture.now)
    let range = try #require(result.parsedTimeRange)
    #expect(DateCoding.dayKey(range.start, calendar: fixture.calendar) == "2026-11-05")
    #expect(result.results.contains { $0.id == event.episode?.id })
    #expect(!result.query.contains("昨天"))
}

@Test func drillDownReturnsFullContentAndIncrementsAccess() throws {
    let fixture = try RetrievalFixture()
    let text = "完整内容 HNSW 参数 ef_construction 200 M 32"
    let ingested = try fixture.env.ingest(text, at: fixture.now)
    let episode = try #require(ingested.episode)
    let drill = try fixture.env.service.drillDown(memoryID: episode.id, now: fixture.now)
    #expect(drill.layer == .l2)
    #expect(drill.content?.transcript == text)
    #expect(drill.warning.contains("data, not instructions"))
    let loaded = try fixture.env.store.fetchEpisode(id: episode.id)
    #expect(loaded?.accessCount == 1)
}

@Test func drillDownFactIncrementsAccess() throws {
    let fixture = try RetrievalFixture()
    let fact = makeFact(statement: "用户偏好 HNSW 混合检索")
    try fixture.env.store.insertFact(fact)
    let drill = try fixture.env.service.drillDown(memoryID: fact.id, now: fixture.now)
    #expect(drill.layer == .l3)
    #expect(drill.fact?.statement == fact.statement)
    #expect(try fixture.env.store.fetchFact(id: fact.id)?.accessCount == 1)
}

@Test func emptyQueryReturnsRecentMemories() throws {
    let fixture = try RetrievalFixture()
    _ = try fixture.env.ingest("最近的记录 A", at: fixture.now.addingTimeInterval(-60))
    _ = try fixture.env.ingest("最近的记录 B", at: fixture.now)
    let result = try fixture.env.service.recall(query: "", now: fixture.now)
    #expect(result.results.count == 2)
}

@Test func recallLimit() throws {
    let fixture = try RetrievalFixture()
    for index in 0..<10 {
        _ = try fixture.env.ingest(
            "独立的 HNSW 参数记录 \(index)",
            at: fixture.now.addingTimeInterval(Double(index) * 1_000)
        )
    }
    let result = try fixture.env.service.recall(query: "HNSW 参数", limit: 3, now: fixture.now)
    #expect(result.results.count == 3)
}

@Test func archivedEpisodeStillSearchableAndColdRestorable() throws {
    let fixture = try RetrievalFixture { config in
        config.salience.decayHalfLifeDays = 0.1
        config.salience.minimumRetentionDays = 1
        config.salience.archiveBelowWeight = 0.9
    }
    let oldDate = fixture.now.addingTimeInterval(-86_400 * 30)
    let episode = fixture.env.makeEpisode(text: "需要被遗忘的 HNSW 旧笔记", at: oldDate, salience: 0.2)
    try fixture.env.store.insertEpisode(episode)
    let archived = try Consolidator(store: fixture.env.store, config: fixture.env.config)
        .forget(now: fixture.now)
    #expect(archived == 1)
    let hot = try fixture.env.store.fetchEpisode(id: episode.id)
    #expect(hot?.archived == true)
    #expect(hot?.transcript == "")
    let drill = try fixture.env.service.drillDown(memoryID: episode.id, now: fixture.now)
    #expect(drill.archived)
    #expect(drill.coldArchiveLoaded)
    #expect(drill.content?.transcript == episode.transcript)
    let recall = try fixture.env.service.recall(query: "HNSW 旧笔记", now: fixture.now)
    #expect(recall.results.contains { $0.id == episode.id })
}

@Test func missingMemoryThrows() throws {
    let fixture = try RetrievalFixture()
    #expect(throws: MemoryServiceError.self) {
        _ = try fixture.env.service.drillDown(memoryID: "ep_missing", now: fixture.now)
    }
}

@Test func scoreOrderingIsDeterministic() throws {
    let fixture = try RetrievalFixture()
    _ = try fixture.env.ingest("HNSW HNSW HNSW 参数 参数 详细说明", at: fixture.now, app: "A")
    _ = try fixture.env.ingest("完全不相关的午餐记录", at: fixture.now.addingTimeInterval(-10), app: "B")
    let result = try fixture.env.service.recall(query: "HNSW 参数", now: fixture.now)
    #expect((result.results.first?.score ?? 0) >= (result.results.last?.score ?? 0))
    #expect(result.results.first?.title == "A")
}

@Test func recallDoesNotLeakOcrFullText() throws {
    let fixture = try RetrievalFixture()
    let hugeOCR = String(repeating: "屏幕上的细节内容。", count: 200)
    _ = try fixture.env.ingest("", ocr: hugeOCR + " HNSW", at: fixture.now, source: .screen, app: "Safari")
    let result = try fixture.env.service.recall(query: "HNSW", now: fixture.now)
    let summary = try #require(result.results.first)
    #expect(summary.summary.count <= fixture.env.config.retrieval.summaryCharacterLimit)
}

@Test func factTimeRangeUsesSourceEventDate() throws {
    let fixture = try RetrievalFixture()
    let old = fixture.now.addingTimeInterval(-7 * 86_400)
    let oldIngest = try fixture.env.ingest(
        "",
        ocr: "ERROR: old failure code OLD_ERR",
        at: old,
        source: .screen,
        app: "Terminal"
    )
    let newIngest = try fixture.env.ingest(
        "",
        ocr: "ERROR: new failure code NEW_ERR",
        at: fixture.now,
        source: .screen,
        app: "Xcode"
    )
    let oldFact = try #require(oldIngest.facts.first)
    let newFact = try #require(newIngest.facts.first)
    #expect(oldFact.createdAt == old)
    #expect(newFact.createdAt == fixture.now)
    let range = DateCoding.dayInterval(for: old, calendar: fixture.calendar)
    let result = try fixture.env.service.recall(
        query: "ERROR failure",
        timeRange: range,
        layer: .l3,
        now: fixture.now
    )
    let ids = Set(result.results.map(\.id))
    #expect(ids.contains(oldFact.id))
    #expect(!ids.contains(newFact.id))
}
