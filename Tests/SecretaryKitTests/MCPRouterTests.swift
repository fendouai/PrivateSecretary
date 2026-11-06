import Testing
@testable import SecretaryKit

private struct MCPFixture {
    let env: TestEnvironment
    let router: MCPRouter
    let calendar: Calendar
    let now: Date

    init() throws {
        env = try TestEnvironment()
        router = MCPRouter(service: env.service)
        calendar = fixedCalendar()
        now = fixedNow()
    }

    func request(_ object: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: object)
        let line = String(decoding: data, as: UTF8.self)
        guard let response = router.handle(line: line) else { return [:] }
        return jsonObject(response)
    }

    func call(_ name: String, _ arguments: [String: Any] = [:]) throws -> [String: Any] {
        try request([
            "jsonrpc": "2.0",
            "id": 99,
            "method": "tools/call",
            "params": ["name": name, "arguments": arguments]
        ])
    }
}

@Test func initializeNegotiatesProtocolVersion() throws {
    let fixture = try MCPFixture()
    let response = try fixture.request([
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": [
            "protocolVersion": "2025-03-26",
            "capabilities": [:],
            "clientInfo": ["name": "test", "version": "1"]
        ]
    ])
    let result = response["result"] as? [String: Any]
    #expect(result?["protocolVersion"] as? String == "2025-03-26")
    #expect((result?["serverInfo"] as? [String: Any])?["name"] as? String == "private-secretary")
    #expect((result?["instructions"] as? String)?.contains("never executes") == true)
}

@Test func unknownProtocolVersionFallsBack() throws {
    let fixture = try MCPFixture()
    let response = try fixture.request([
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": ["protocolVersion": "1999-01-01"]
    ])
    #expect((response["result"] as? [String: Any])?["protocolVersion"] as? String == MCPProtocol.latestVersion)
}

@Test func notificationHasNoResponse() throws {
    let fixture = try MCPFixture()
    let data = try JSONSerialization.data(withJSONObject: [
        "jsonrpc": "2.0",
        "method": "notifications/initialized"
    ])
    #expect(fixture.router.handle(line: String(decoding: data, as: UTF8.self)) == nil)
}

@Test func ping() throws {
    let fixture = try MCPFixture()
    let response = try fixture.request(["jsonrpc": "2.0", "id": 2, "method": "ping"])
    #expect(response["result"] != nil)
}

@Test func toolsListIsReadOnlyOrganizerSurface() throws {
    let fixture = try MCPFixture()
    let response = try fixture.request(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
    let tools = (response["result"] as? [String: Any])?["tools"] as? [[String: Any]]
    let names = Set((tools ?? []).compactMap { $0["name"] as? String })
    for required in [
        "recall", "drill_down", "get_timeline", "get_digest", "generate_daily_digest",
        "list_todos", "add_todo", "update_todo", "list_contacts", "upsert_contact",
        "list_messages", "record_message", "mark_message_read", "list_review_items",
        "review_fact", "get_status"
    ] {
        #expect(names.contains(required), "missing \(required)")
    }
    #expect(names.count == 16)
    #expect(!names.contains("claim_task"))
    #expect(!names.contains("complete_task"))
    #expect(!names.contains("get_procedural_pattern"))
    for tool in tools ?? [] {
        #expect(tool["inputSchema"] != nil)
        #expect((tool["inputSchema"] as? [String: Any])?["type"] as? String == "object")
    }
}

@Test func unknownMethodReturnsJSONRPCError() throws {
    let fixture = try MCPFixture()
    let response = try fixture.request(["jsonrpc": "2.0", "id": 3, "method": "does/not/exist"])
    #expect((response["error"] as? [String: Any])?["code"] as? Int == -32601)
}

@Test func malformedJSONReturnsParseError() throws {
    let fixture = try MCPFixture()
    let response = fixture.router.handle(line: "{not json")
    let object = jsonObject(response ?? "")
    #expect((object["error"] as? [String: Any])?["code"] as? Int == -32700)
}

@Test func recallFoldAndDrillDown() throws {
    let fixture = try MCPFixture()
    let ingested = try fixture.env.ingest(
        "视频里讲了 HNSW 的 ef_construction 参数",
        at: fixture.now,
        origin: .system,
        source: .audio,
        app: "Safari"
    )
    let response = try fixture.call("recall", ["query": "HNSW 参数"])
    #expect((response["result"] as? [String: Any])?["isError"] as? Bool == false)
    let payload = mcpResultObject(response)
    let results = payload["results"] as? [[String: Any]]
    #expect(results?.count == 1)
    let memoryID = try #require(results?.first?["id"] as? String)
    let drill = try fixture.call("drill_down", ["memory_id": memoryID])
    let drillPayload = mcpResultObject(drill)
    #expect(drillPayload["layer"] as? String == "L2")
    #expect(ingested.episode?.id == memoryID)
}

@Test func recallRejectsMissingQuery() throws {
    let fixture = try MCPFixture()
    let response = try fixture.call("recall", [:])
    #expect((response["result"] as? [String: Any])?["isError"] as? Bool == true)
}

@Test func getTimelineReturnsMemoryEntries() throws {
    let fixture = try MCPFixture()
    let ingested = try fixture.env.ingest(
        "我们决定采用 HNSW 混合检索",
        at: fixture.now,
        app: "TencentMeeting"
    )
    let response = try fixture.call("get_timeline", ["date": DateCoding.dayKey(fixture.now, calendar: fixture.calendar)])
    #expect((response["result"] as? [String: Any])?["isError"] as? Bool == false)
    let payload = mcpResultObject(response)
    let entries = payload["entries"] as? [[String: Any]]
    #expect(entries?.contains { ($0["memoryID"] as? String) == ingested.episode?.id } == true)
    #expect(entries?.contains { ($0["kind"] as? String) == "fact" } == true)
}

@Test func todoToolsAreListOnlyForExecution() throws {
    let fixture = try MCPFixture()
    let ingested = try fixture.env.ingest("帮我记一下周五前提交 HNSW 参数对比", at: fixture.now)
    let todo = try #require(ingested.todo)
    let listed = mcpResultObject(try fixture.call("list_todos", ["status": "open"]))
    #expect(listed["count"] as? Int == 1)
    let todos = listed["todos"] as? [[String: Any]]
    #expect(todos?.first?["id"] as? String == todo.id)
    let closed = mcpResultObject(try fixture.call("update_todo", [
        "todo_id": todo.id,
        "status": "done"
    ]))
    #expect((closed["todo"] as? [String: Any])?["status"] as? String == "done")
    #expect(try fixture.env.store.fetchTodo(id: todo.id)?.status == .done)
    let added = mcpResultObject(try fixture.call("add_todo", [
        "title": "手动待办",
        "detail": "仅记录"
    ]))
    #expect((added["todo"] as? [String: Any])?["title"] as? String == "手动待办")
    let done = mcpResultObject(try fixture.call("list_todos", ["status": "all"]))
    #expect(done["count"] as? Int == 2)
}

@Test func contactAndMessageToolsAggregateChannels() throws {
    let fixture = try MCPFixture()
    let recorded = mcpResultObject(try fixture.call("record_message", [
        "channel": "email",
        "contact_name": "张三",
        "handle": "zhangsan@example.com",
        "direction": "inbound",
        "text": "HNSW 参数对比请周五前发我",
        "external_id": "mcp-mail-1"
    ]))
    let message = recorded["message"] as? [String: Any]
    let messageID = try #require(message?["id"] as? String)
    #expect(message?["contactName"] as? String == "张三")
    let duplicate = mcpResultObject(try fixture.call("record_message", [
        "channel": "email",
        "contact_name": "张三",
        "handle": "zhangsan@example.com",
        "direction": "inbound",
        "text": "HNSW 参数对比请周五前发我",
        "external_id": "mcp-mail-1"
    ]))
    #expect((duplicate["message"] as? [String: Any])?["id"] as? String == messageID)
    _ = try fixture.call("record_message", [
        "channel": "lark",
        "contact_name": "张三",
        "handle": "zhangsan_lark",
        "direction": "inbound",
        "text": "评审改到周一下午"
    ])
    let contacts = mcpResultObject(try fixture.call("list_contacts", [:]))
    let contactList = contacts["contacts"] as? [[String: Any]]
    #expect(contacts["count"] as? Int == 1)
    #expect((contactList?.first?["channels"] as? [[String: Any]])?.count == 2)
    let messages = mcpResultObject(try fixture.call("list_messages", ["channel": "email"]))
    #expect(messages["count"] as? Int == 1)
    let read = mcpResultObject(try fixture.call("mark_message_read", ["message_id": messageID]))
    #expect((read["message"] as? [String: Any])?["isRead"] as? Bool == true)
    let contact = mcpResultObject(try fixture.call("upsert_contact", [
        "display_name": "李四",
        "channels": [["channel": "wechat", "handle": "lisi_wx"]]
    ]))
    #expect((contact["contact"] as? [String: Any])?["displayName"] as? String == "李四")
}

@Test func digestTools() throws {
    let fixture = try MCPFixture()
    _ = try fixture.env.ingest("我们决定采用方案 A", at: fixture.now)
    let day = DateCoding.dayKey(fixture.now, calendar: fixture.calendar)
    let missing = mcpResultObject(try fixture.call("get_digest", ["date": day]))
    #expect(missing["found"] as? Bool == false)
    let generated = try fixture.call("generate_daily_digest", ["date": day])
    #expect((generated["result"] as? [String: Any])?["isError"] as? Bool == false)
    let generatedPayload = mcpResultObject(generated)
    #expect(generatedPayload["date"] as? String == day)
    let digest = mcpResultObject(try fixture.call("get_digest", ["date": day]))
    #expect(digest["found"] as? Bool == true)
    #expect(digest["digest"] != nil)
}

@Test func reviewTools() throws {
    let fixture = try MCPFixture()
    let fact = makeFact(status: .pendingReview)
    try fixture.env.store.insertFact(fact)
    let listed = mcpResultObject(try fixture.call("list_review_items", [:]))
    #expect(listed["count"] as? Int == 1)
    let reviewed = mcpResultObject(try fixture.call("review_fact", [
        "fact_id": fact.id,
        "action": "correct",
        "corrected_statement": "用户最终偏好 zed"
    ]))
    #expect(reviewed["status"] as? String == "updated")
    #expect(try fixture.env.store.fetchFact(id: fact.id)?.status == .active)
}

@Test func statusTool() throws {
    let fixture = try MCPFixture()
    fixture.env.service.publishCaptureHealth(CaptureHealth(
        state: "capture_unavailable",
        detail: "permission denied",
        permissionGranted: false
    ))
    let payload = mcpResultObject(try fixture.call("get_status", [:]))
    #expect(payload["version"] as? String == PrivateSecretaryVersion.current)
    let capture = payload["capture"] as? [String: Any]
    #expect(capture?["state"] as? String == "capture_unavailable")
}

@Test func unknownToolIsErrorResult() throws {
    let fixture = try MCPFixture()
    let response = try fixture.call("nonexistent_tool", [:])
    #expect((response["result"] as? [String: Any])?["isError"] as? Bool == true)
}

@Test func generateDigestInvalidDateIsError() throws {
    let fixture = try MCPFixture()
    let response = try fixture.call("generate_daily_digest", ["date": "not-a-date"])
    #expect((response["result"] as? [String: Any])?["isError"] as? Bool == true)
}
