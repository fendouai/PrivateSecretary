import Testing
@testable import SecretaryKit

private struct FuzzGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

@Test func randomTemporalQueriesNeverCrash() {
    var rng = FuzzGenerator(state: 0xDEADBEEF)
    let alphabet = Array("今天昨天上周三下午HNSW参数2026-11-06 last Wednesday !?。，abc")
    let calendar = fixedCalendar()
    let now = fixedNow()
    for _ in 0..<400 {
        let length = Int(rng.next() % 80)
        var chars: [Character] = []
        for _ in 0..<length {
            chars.append(alphabet[Int(rng.next() % UInt64(alphabet.count))])
        }
        let query = String(chars)
        let parsed = QueryTimeParser.parse(query, now: now, calendar: calendar)
        if let range = parsed.range {
            #expect(range.start < range.end)
        }
    }
}

@Test func veryLongInputIsTruncatedAndStoredSafely() throws {
    let env = try TestEnvironment()
    let huge = String(repeating: "很长的上下文 HNSW 参数。", count: 5_000)
    let result = try env.ingest(huge, at: Date())
    #expect(result.accepted)
    let episode = try #require(result.episode)
    #expect(episode.transcript.count <= 20_000)
    let message = try env.store.recordMessage(
        channel: "email",
        contactName: "超长消息联系人",
        handle: "long@example.com",
        direction: .inbound,
        text: huge
    )
    #expect(message.text.count <= 10_000)
}

@Test func invalidImportDataFailsWithoutCreatingRecords() throws {
    let env = try TestEnvironment()
    #expect(throws: (any Error).self) {
        _ = try MessageImporter(service: env.service).importJSON(Data("not json".utf8))
    }
    #expect(try env.store.counts().messages == 0)
    #expect(throws: MemoryServiceError.self) {
        _ = try env.store.addTodo(title: "")
    }
}

@Test func unicodeContactAndMessageRoundTrip() throws {
    let env = try TestEnvironment()
    let contact = try env.store.upsertContact(
        displayName: "张三 🧑‍💻",
        organization: "Acme 日本",
        channels: [ContactChannel(channel: "wechat", handle: "张三_微信")]
    )
    #expect(contact.displayName == "张三 🧑‍💻")
    let message = try env.store.recordMessage(
        channel: "wechat",
        contactName: contact.displayName,
        handle: "张三_微信",
        direction: .inbound,
        text: "HNSW のパラメータ 🚀 を確認してください"
    )
    #expect(try env.store.listMessages(contactID: contact.id).first?.id == message.id)
}

@Test func normalizeAndTruncateHandleGraphemeClusters() {
    let value = String(repeating: "🧑‍💻", count: 100)
    let truncated = TextAnalyzer.truncated(value, limit: 20)
    #expect(truncated.count <= 20)
    #expect(truncated.hasSuffix("…"))
    #expect(TextAnalyzer.normalize("  ＡＢＣ\t１２３  ") == "abc 123")
}
