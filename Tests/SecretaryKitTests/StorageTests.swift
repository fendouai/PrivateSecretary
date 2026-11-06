import Testing
@testable import SecretaryKit

@Test func emptyDatabaseCounts() throws {
    let env = try TestEnvironment()
    let counts = try env.store.counts()
    #expect(counts.episodes == 0)
    #expect(counts.activeFacts == 0)
    #expect(counts.openTodos == 0)
    #expect(counts.contacts == 0)
    #expect(counts.messages == 0)
}

@Test func episodeRoundTrip() throws {
    let env = try TestEnvironment()
    let date = Date(timeIntervalSince1970: 1_760_000_000)
    let episode = env.makeEpisode(text: "HNSW 参数 ef_construction 200", at: date)
    try env.store.insertEpisode(episode)
    let loaded = try #require(try env.store.fetchEpisode(id: episode.id))
    #expect(loaded.id == episode.id)
    #expect(loaded.transcript == episode.transcript)
    #expect(loaded.keywords == episode.keywords)
    #expect(loaded.signals == episode.signals)
    #expect(loaded.trust == .directUserInput)
    #expect(abs(loaded.startedAt.timeIntervalSince1970 - date.timeIntervalSince1970) < 0.001)
}

@Test func lexicalEpisodeSearchAndDelete() throws {
    let env = try TestEnvironment()
    let episode = env.makeEpisode(text: "向量数据库 HNSW ef_search 参数说明", at: Date())
    try env.store.insertEpisode(episode)
    let scores = try env.store.lexicalEpisodeScores(query: "HNSW 参数")
    #expect(scores[episode.id] != nil)
    let missing = try env.store.lexicalEpisodeScores(query: "完全不存在的关键词xyz")
    #expect(missing[episode.id] == nil)
    try env.store.deleteEpisode(id: episode.id)
    #expect(try env.store.fetchEpisode(id: episode.id) == nil)
    #expect(try env.store.lexicalEpisodeScores(query: "HNSW 参数").isEmpty)
}

@Test func factRoundTripAndAccess() throws {
    let env = try TestEnvironment()
    let fact = makeFact()
    try env.store.insertFact(fact)
    let before = try #require(try env.store.fetchFact(id: fact.id))
    #expect(before.statement == fact.statement)
    try env.store.updateFactAccess(id: fact.id, at: Date())
    let after = try #require(try env.store.fetchFact(id: fact.id))
    #expect(after.accessCount == 1)
    #expect(after.lastAccessedAt != nil)
}

@Test func reinforceFactAppendsSourceAndEvidence() throws {
    let env = try TestEnvironment()
    let fact = makeFact(sources: ["ep_one"])
    try env.store.insertFact(fact)
    let updated = try #require(try env.store.reinforceFact(id: fact.id, episodeID: "ep_two", salience: 0.9))
    #expect(updated.sourceEpisodeIDs == ["ep_one", "ep_two"])
    #expect(updated.evidenceCount == 2)
    #expect(abs(updated.salience - 0.9) < 0.0001)
}

@Test func supersedeFactTransaction() throws {
    let env = try TestEnvironment()
    let old = makeFact(object: "vim", statement: "用户偏好 vim")
    try env.store.insertFact(old)
    let new = makeFact(object: "zed", statement: "用户偏好 zed", confidence: 0.95)
    try env.store.supersedeFact(oldID: old.id, with: new)
    let oldAfter = try #require(try env.store.fetchFact(id: old.id))
    let newAfter = try #require(try env.store.fetchFact(id: new.id))
    #expect(oldAfter.status == .superseded)
    #expect(oldAfter.supersededByID == new.id)
    #expect(newAfter.supersedesID == old.id)
    #expect(newAfter.status == .active)
}

@Test func todoLifecycleIsUserManagedOnly() throws {
    let env = try TestEnvironment()
    let todo = try env.store.addTodo(
        title: "周五前提交 HNSW 参数对比",
        detail: "参数对比",
        intentType: .todo,
        dueAt: nil
    )
    #expect(todo.status == .open)
    #expect(todo.intentType == .todo)
    #expect(try env.store.openTodos().count == 1)
    let done = try #require(try env.store.updateTodoStatus(id: todo.id, status: .done))
    #expect(done.status == .done)
    #expect(done.completedAt != nil)
    #expect(try env.store.openTodos().isEmpty)
    let reopen = try #require(try env.store.updateTodoStatus(id: todo.id, status: .open))
    #expect(reopen.status == .open)
    #expect(reopen.completedAt == nil)
    let dismissed = try #require(try env.store.updateTodoStatus(id: todo.id, status: .dismissed))
    #expect(dismissed.status == .dismissed)
    #expect(try env.store.fetchTodos(status: .dismissed).count == 1)
}

@Test func todoDeleteAndIdempotentStatus() throws {
    let env = try TestEnvironment()
    let todo = try env.store.addTodo(title: "可删除待办")
    #expect(try env.store.updateTodoStatus(id: todo.id, status: .open)?.status == .open)
    #expect(try env.store.deleteTodo(id: todo.id))
    #expect(!(try env.store.deleteTodo(id: todo.id)))
    #expect(try env.store.fetchTodo(id: todo.id) == nil)
}

@Test func digestUpsertAndFetch() throws {
    let env = try TestEnvironment()
    let stats = DigestStats(
        episodeCount: 1,
        significantEpisodeCount: 1,
        factCount: 0,
        todoCount: 1,
        archivedEpisodeCount: 0
    )
    let digest = DailyDigest(date: "2026-11-06", markdown: "# Daily", entries: [], stats: stats)
    try env.store.upsertDigest(digest)
    #expect(try env.store.digest(date: "2026-11-06")?.markdown == "# Daily")
    try env.store.upsertDigest(DailyDigest(
        date: "2026-11-06",
        markdown: "# Updated",
        entries: [],
        stats: stats
    ))
    #expect(try env.store.digest(date: "2026-11-06")?.markdown == "# Updated")
    #expect(try env.store.digests().count == 1)
}

@Test func purgeAllClearsData() throws {
    let env = try TestEnvironment()
    try env.store.insertEpisode(env.makeEpisode(text: "会被清除", at: Date()))
    try env.store.insertFact(makeFact())
    _ = try env.store.addTodo(title: "待办")
    _ = try env.store.recordMessage(
        channel: "email",
        contactName: "张三",
        handle: "zhangsan@example.com",
        direction: .inbound,
        text: "消息"
    )
    try env.store.purgeAll()
    let counts = try env.store.counts()
    #expect(counts.episodes == 0)
    #expect(counts.activeFacts == 0)
    #expect(counts.openTodos == 0)
    #expect(counts.contacts == 0)
    #expect(counts.messages == 0)
    #expect(try env.store.lexicalEpisodeScores(query: "清除").isEmpty)
}

@Test func coldArchiveRoundTripAndDelete() throws {
    let env = try TestEnvironment()
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let episode = env.makeEpisode(id: "ep_cold", text: "归档内容 HNSW", at: date)
    let url = try env.store.coldArchive.append(episode)
    #expect(FileManager.default.fileExists(atPath: url.path))
    #expect(try env.store.coldArchive.load(episodeID: episode.id, startedAt: date)?.transcript == episode.transcript)
    #expect(try env.store.coldArchive.delete(episodeID: episode.id, startedAt: date))
    #expect(try env.store.coldArchive.load(episodeID: episode.id, startedAt: date) == nil)
}

@Test func concurrentReadsAreSerializedSafely() throws {
    let env = try TestEnvironment()
    let episode = env.makeEpisode(text: "并发读取", at: Date())
    try env.store.insertEpisode(episode)
    let group = DispatchGroup()
    let lock = NSLock()
    var failures: [String] = []
    for _ in 0..<20 {
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            do {
                _ = try env.store.fetchEpisode(id: episode.id)
            } catch {
                lock.lock()
                failures.append(error.localizedDescription)
                lock.unlock()
            }
        }
    }
    #expect(group.wait(timeout: .now() + 5) == .success)
    #expect(failures.isEmpty)
}

@Test func deletingEpisodeRemovesSoleSourceFactsAndTrimsSharedFacts() throws {
    let env = try TestEnvironment()
    let first = env.makeEpisode(id: "ep_delete_a", text: "用户偏好 vim", at: Date())
    let second = env.makeEpisode(id: "ep_delete_b", text: "用户偏好 vim", at: Date())
    try env.store.insertEpisode(first)
    try env.store.insertEpisode(second)
    let sole = makeFact(id: "fact_sole", sources: [first.id])
    let shared = makeFact(id: "fact_shared", sources: [first.id, second.id])
    try env.store.insertFact(sole)
    try env.store.insertFact(shared)
    try env.store.deleteEpisode(id: first.id)
    #expect(try env.store.fetchFact(id: sole.id) == nil)
    let remaining = try #require(try env.store.fetchFact(id: shared.id))
    #expect(remaining.sourceEpisodeIDs == [second.id])
    #expect(remaining.evidenceCount == 1)
}

@Test func purgeVacuumAndSecureDeleteKeepDatabaseUsable() throws {
    let env = try TestEnvironment()
    let episode = env.makeEpisode(text: "敏感内容 secure delete", at: Date())
    try env.store.insertEpisode(episode)
    try env.store.insertFact(makeFact(sources: [episode.id]))
    try env.store.purgeAll()
    #expect(try env.store.counts().episodes == 0)
    try env.store.insertEpisode(env.makeEpisode(text: "purge 后仍可写入", at: Date()))
    #expect(try env.store.counts().episodes == 1)
}

@Test func contactUpsertMergesByHandleAndName() throws {
    let env = try TestEnvironment()
    let first = try env.store.upsertContact(
        displayName: "张三",
        organization: "Acme",
        channels: [ContactChannel(channel: "email", handle: "zhangsan@example.com")]
    )
    let second = try env.store.upsertContact(
        displayName: "张三",
        channels: [ContactChannel(channel: "lark", handle: "zhangsan_lark")]
    )
    #expect(first.id == second.id)
    let loaded = try #require(try env.store.fetchContact(id: first.id))
    #expect(loaded.channels.count == 2)
    #expect(loaded.organization == "Acme")
}

@Test func messageRecordingDeduplicatesAndAggregatesContact() throws {
    let env = try TestEnvironment()
    let first = try env.store.recordMessage(
        channel: "Email",
        contactName: "张三",
        handle: "zhangsan@example.com",
        direction: .inbound,
        text: "HNSW 参数对比请周五前发我",
        timestamp: Date(timeIntervalSince1970: 1_760_000_000),
        externalID: "mail-1"
    )
    let duplicate = try env.store.recordMessage(
        channel: "email",
        contactName: "张三",
        handle: "zhangsan@example.com",
        direction: .inbound,
        text: "HNSW 参数对比请周五前发我",
        timestamp: Date(timeIntervalSince1970: 1_760_000_100),
        externalID: "mail-1"
    )
    #expect(first.id == duplicate.id)
    let second = try env.store.recordMessage(
        channel: "email",
        contactName: "张三",
        handle: "zhangsan@example.com",
        direction: .outbound,
        text: "收到，我整理好后发你",
        timestamp: Date(timeIntervalSince1970: 1_760_000_200),
        externalID: "mail-2",
        isRead: true
    )
    #expect(first.contactID == second.contactID)
    let contacts = try env.store.listContacts()
    #expect(contacts.count == 1)
    #expect(contacts.first?.messageCount == 2)
    #expect(contacts.first?.lastMessageSnippet == "收到，我整理好后发你")
    let messages = try env.store.listMessages()
    #expect(messages.count == 2)
    #expect(messages.first?.direction == .outbound)
    let unread = try env.store.listMessages(unreadOnly: true)
    #expect(unread.count == 1)
    let marked = try #require(try env.store.markMessageRead(id: first.id))
    #expect(marked.isRead)
    #expect(try env.store.listMessages(unreadOnly: true).isEmpty)
}

@Test func messagesCanBeFilteredByChannelAndContact() throws {
    let env = try TestEnvironment()
    _ = try env.store.recordMessage(
        channel: "wechat",
        contactName: "李四",
        handle: "lisi_wx",
        direction: .inbound,
        text: "微信消息"
    )
    _ = try env.store.recordMessage(
        channel: "lark",
        contactName: "王五",
        handle: "wangwu_lark",
        direction: .inbound,
        text: "飞书消息"
    )
    #expect(try env.store.listMessages(channel: "wechat").count == 1)
    let contact = try #require(try env.store.listContacts().first { $0.displayName == "王五" })
    #expect(try env.store.listMessages(contactID: contact.id).first?.text == "飞书消息")
}
