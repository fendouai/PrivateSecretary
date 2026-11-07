import Testing
@testable import SecretaryKit

private func importer(for env: TestEnvironment) -> MessageImporter {
    MessageImporter(service: env.service)
}

@Test func messageImporterHandlesJSONLAndPartialFailures() throws {
    let env = try TestEnvironment()
    let jsonl = """
    {"channel":"email","contact_name":"张三","handle":"zs@example.com","text":"第一条","external_id":"a"}
    {"channel":"email","contact_name":"张三","handle":"zs@example.com","text":"第一条","external_id":"a"}
    {"channel":"lark","contact_name":"李四","handle":"ls_lark","text":"第二条","external_id":"b"}
    {"channel":"email","text":"missing contact","external_id":"c"}
    """
    let report = try importer(for: env).importJSON(Data(jsonl.utf8))
    #expect(report.imported == 2)
    #expect(report.duplicates == 1)
    #expect(report.failed == 1)
    #expect(report.issues.count == 1)
    #expect(report.total == 4)
    #expect(try env.store.listContacts().count == 2)
}

@Test func messageImporterUsesDefaultChannelAndSingleObject() throws {
    let env = try TestEnvironment()
    let json = """
    {"contact_name":"王五","handle":"wangwu_tg","text":"单条消息"}
    """
    let report = try importer(for: env).importJSON(Data(json.utf8), defaultChannel: "telegram")
    #expect(report.imported == 1)
    let message = try #require(try env.store.listMessages().first)
    #expect(message.channel == "telegram")
    #expect(message.contactName == "王五")
}

@Test func messageFTSQueryFindsBodyAndContact() throws {
    let env = try TestEnvironment()
    _ = try env.store.recordMessage(
        channel: "email",
        contactName: "张三",
        handle: "zs@example.com",
        direction: .inbound,
        text: "HNSW benchmark 的结果发我"
    )
    _ = try env.store.recordMessage(
        channel: "lark",
        contactName: "李四",
        handle: "ls_lark",
        direction: .inbound,
        text: "周报记得更新"
    )
    #expect(try env.store.listMessages(query: "benchmark").count == 1)
    #expect(try env.store.listMessages(query: "李四").count == 1)
    #expect(try env.store.listMessages(query: "不存在的词xyz").isEmpty)
}

@Test func mergeContactsMovesHandlesAndMessages() throws {
    let env = try TestEnvironment()
    let target = try env.store.upsertContact(
        displayName: "张三",
        channels: [ContactChannel(channel: "email", handle: "zs@example.com")]
    )
    let source = try env.store.upsertContact(
        displayName: "张三（飞书）",
        channels: [ContactChannel(channel: "lark", handle: "zs_lark")]
    )
    _ = try env.store.recordMessage(
        channel: "lark",
        contactName: source.displayName,
        handle: "zs_lark",
        direction: .inbound,
        text: "飞书消息"
    )
    let merged = try #require(try env.store.mergeContacts(targetID: target.id, sourceID: source.id))
    #expect(merged.id == target.id)
    #expect(merged.channels.count == 2)
    #expect(try env.store.fetchContact(id: source.id) == nil)
    #expect(try env.store.listMessages(contactID: target.id).count == 1)
    #expect(try env.store.listContacts().count == 1)
}

@Test func briefCombinesTimelineTodosMessagesAndContacts() throws {
    let env = try TestEnvironment()
    let now = Date()
    _ = try env.ingest("帮我记一下 HNSW 参数对比", at: now)
    _ = try env.store.recordMessage(
        channel: "email",
        contactName: "张三",
        handle: "zs@example.com",
        direction: .inbound,
        text: "参数对比请周五前发我"
    )
    let brief = try env.service.brief(dayKey: DateCoding.dayKey(now), now: now)
    #expect(!brief.timeline.isEmpty)
    #expect(brief.openTodos.count == 1)
    #expect(brief.unreadMessages.count == 1)
    #expect(brief.contacts.count == 1)
    #expect(brief.counts.messages == 1)
}

@Test func dashboardEscapesInjectedHTML() throws {
    let env = try TestEnvironment()
    let now = Date()
    _ = try env.ingest("决定采用 <script>alert('x')</script> & HNSW", at: now)
    _ = try env.store.recordMessage(
        channel: "email",
        contactName: "<img src=x onerror=alert(1)>",
        handle: "x@example.com",
        direction: .inbound,
        text: "</script><script>alert(2)</script>"
    )
    let brief = try env.service.brief(dayKey: DateCoding.dayKey(now), now: now)
    let html = DashboardRenderer.render(brief)
    #expect(html.contains("Timeline"))
    #expect(html.contains("Open todos"))
    #expect(html.contains("Unread messages"))
    #expect(!html.contains("<script>alert"))
    #expect(!html.contains("<img src=x"))
    #expect(html.contains("&lt;script&gt;"))
    #expect(html.contains("Content-Security-Policy"))
}

@Test func concurrentDuplicateMessagesInsertOnce() throws {
    let env = try TestEnvironment()
    let group = DispatchGroup()
    let lock = NSLock()
    var ids = Set<String>()
    var errors: [String] = []
    for index in 0..<8 {
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            do {
                let message = try env.store.recordMessage(
                    channel: "email",
                    contactName: "并发联系人",
                    handle: "race@example.com",
                    direction: .inbound,
                    text: "同一条消息",
                    externalID: "race-1"
                )
                lock.lock(); ids.insert(message.id); lock.unlock()
            } catch {
                lock.lock(); errors.append("\(index): \(error.localizedDescription)"); lock.unlock()
            }
        }
    }
    #expect(group.wait(timeout: .now() + 10) == .success)
    #expect(errors.isEmpty)
    #expect(ids.count == 1)
    #expect(try env.store.listMessages().count == 1)
}

@Test func sqlLikeInputsAreBoundLiterally() throws {
    let env = try TestEnvironment()
    let hostile = "Robert'); DROP TABLE contacts;--"
    let contact = try env.store.upsertContact(displayName: hostile)
    #expect(contact.displayName == hostile)
    _ = try env.store.recordMessage(
        channel: "email",
        contactName: hostile,
        handle: "hostile@example.com",
        direction: .inbound,
        text: "正常消息"
    )
    _ = try env.store.listMessages(query: "\"; DROP TABLE messages; --")
    #expect(try env.store.counts().contacts == 1)
    #expect(try env.store.counts().messages == 1)
}

@Test func contextExporterProducesPasteReadyMarkdown() throws {
    let env = try TestEnvironment()
    let now = Date()
    _ = try env.ingest("帮我记一下 HNSW 参数对比", at: now)
    _ = try env.store.recordMessage(
        channel: "email",
        contactName: "张三",
        handle: "zs@example.com",
        direction: .inbound,
        text: "请周五前发我 <b>参数对比</b>"
    )
    let brief = try env.service.brief(dayKey: DateCoding.dayKey(now), now: now)
    let markdown = ContextExporter.markdown(brief)
    #expect(markdown.contains("# Private Secretary context"))
    #expect(markdown.contains("## Timeline"))
    #expect(markdown.contains("## Open todos"))
    #expect(markdown.contains("## Unread messages"))
    #expect(markdown.contains("## Contacts"))
    #expect(markdown.contains("- [ ]"))
    #expect(markdown.contains("<b>参数对比</b>"))
    #expect(!markdown.contains("<script>"))
}
