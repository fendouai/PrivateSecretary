import Testing
@testable import SecretaryKit

private func region(_ text: String, x: Double, y: Double, w: Double = 0.1, h: Double = 0.015) -> OCRRegion {
    OCRRegion(text: text, confidence: 1, x: x, y: y, width: w, height: h)
}

@Test func gmailInboxRowsBecomeMessages() throws {
    let env = try TestEnvironment()
    let now = Date()
    let regions = [
        region("写邮件", x: 0.07, y: 0.22),
        region("Alice", x: 0.25, y: 0.30, w: 0.05),
        region("Project update", x: 0.37, y: 0.30, w: 0.3),
        region("08:10", x: 0.95, y: 0.30, w: 0.03),
        region("Bob", x: 0.25, y: 0.34, w: 0.04),
        region("Invoice for November", x: 0.37, y: 0.34, w: 0.3),
        region("11月7日", x: 0.95, y: 0.34, w: 0.04)
    ]
    let result = try env.ingest(
        "",
        ocr: "收件箱 Alice Project update Bob Invoice for November",
        at: now,
        source: .screen,
        app: "Google Chrome",
        window: "收件箱 - test@example.com - Gmail",
        regions: regions
    )
    #expect(result.accepted)
    let messages = try env.store.listMessages(channel: "email")
    #expect(messages.count == 2)
    #expect(Set(messages.map(\.contactName)) == ["Alice", "Bob"])
    #expect(messages.allSatisfy { $0.channel == "email" })
}

@Test func nonGmailScreenDoesNotCreateMessages() throws {
    let env = try TestEnvironment()
    let result = try env.ingest(
        "普通屏幕内容",
        ocr: "普通屏幕内容",
        source: .screen,
        app: "Safari",
        window: "Example Domain",
        regions: [region("Example Domain", x: 0.4, y: 0.3)]
    )
    #expect(result.accepted)
    #expect(try env.store.listMessages().isEmpty)
}

@Test func gmailExtractorIsIdempotentByVisibleRow() throws {
    let env = try TestEnvironment()
    let now = Date()
    let regions = [
        region("Alice", x: 0.25, y: 0.30, w: 0.05),
        region("Project update", x: 0.37, y: 0.30, w: 0.3),
        region("08:10", x: 0.95, y: 0.30, w: 0.03)
    ]
    _ = try env.ingest(
        "",
        ocr: "收件箱 Alice Project update",
        at: now,
        source: .screen,
        app: "Google Chrome",
        window: "收件箱 - test@example.com - Gmail",
        regions: regions
    )
    _ = try env.ingest(
        "",
        ocr: "收件箱 Alice Project update (updated)",
        at: now.addingTimeInterval(10),
        source: .screen,
        app: "Google Chrome",
        window: "收件箱 - test@example.com - Gmail",
        regions: regions
    )
    #expect(try env.store.listMessages().count == 1)
}

@Test func emailScreenImportCanReprocessAnEpisode() throws {
    let env = try TestEnvironment()
    let now = Date()
    let episode = env.makeEpisode(text: "收件箱", at: now, app: "Google Chrome")
    var gmail = episode
    gmail.windowTitle = "收件箱 - test@example.com - Gmail"
    gmail.ocrText = "收件箱 Alice Project update"
    gmail.ocrRegions = [
        region("Alice", x: 0.25, y: 0.30, w: 0.05),
        region("Project update", x: 0.37, y: 0.30, w: 0.3),
        region("08:10", x: 0.95, y: 0.30, w: 0.03)
    ]
    try env.store.insertEpisode(gmail)
    #expect(try env.service.importGmailMessages(fromEpisodeID: gmail.id) == 1)
    #expect(try env.service.importGmailMessages(fromEpisodeID: gmail.id) == 1)
    #expect(try env.store.listMessages().count == 1)
}
