@testable import SecretaryKit

final class TestEnvironment {
    let root: URL
    let paths: AppPaths
    let config: AppConfig
    let store: MemoryStore
    let service: MemoryService

    init(configure: (inout AppConfig) -> Void = { _ in }) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("private-secretary-tests-\(UUID().uuidString)", isDirectory: true)
        var config = AppConfig()
        configure(&config)
        self.config = config
        paths = AppPaths(home: root)
        try paths.ensureDirectories()
        store = try MemoryStore(paths: paths, config: config)
        service = MemoryService(store: store, config: config, paths: paths)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func ingest(
        _ text: String,
        ocr: String = "",
        at date: Date = Date(),
        origin: AudioOrigin = .manual,
        source: CandidateSource = .manual,
        app: String = "Notes",
        window: String = "Test",
        regions: [OCRRegion] = [],
        duration: Double = 0
    ) throws -> IngestResult {
        try service.ingest(CandidatePacket(
            capturedAt: date,
            source: source,
            audioOrigin: origin,
            application: app,
            windowTitle: window,
            transcript: text,
            ocrText: ocr,
            ocrRegions: regions,
            audioDurationSeconds: duration
        ), now: date)
    }

    func makeEpisode(
        id: String = "ep_" + UUID().uuidString.lowercased(),
        text: String,
        at date: Date,
        app: String = "Notes",
        salience: Double = 0.7
    ) -> Episode {
        Episode(
            id: id,
            startedAt: date,
            endedAt: date.addingTimeInterval(10),
            application: app,
            windowTitle: "Window",
            source: .manual,
            audioOrigin: .manual,
            transcript: text,
            ocrText: "",
            ocrRegions: [],
            summary: TextAnalyzer.summary(text, limit: 200),
            keywords: TextAnalyzer.keywords(text),
            salience: salience,
            signals: SalienceSignals(novelty: 0.7, goalRelevance: 0.8),
            provenance: [Provenance(kind: "test", capturedAt: date)],
            createdAt: date,
            trust: .directUserInput
        )
    }
}

func makeFact(
    id: String = "fact_" + UUID().uuidString.lowercased(),
    subject: String = "用户",
    predicate: String = "偏好",
    object: String = "vim",
    statement: String = "用户偏好 vim",
    confidence: Double = 0.85,
    salience: Double = 0.6,
    status: FactStatus = .active,
    sources: [String] = ["ep_source"]
) -> SemanticFact {
    SemanticFact(
        id: id,
        kind: .preference,
        subject: subject,
        predicate: predicate,
        object: object,
        statement: statement,
        confidence: confidence,
        salience: salience,
        status: status,
        trust: .untrustedObservedContent,
        sourceEpisodeIDs: sources,
        keywords: TextAnalyzer.keywords(statement),
        createdAt: Date(),
        updatedAt: Date()
    )
}

func fixedCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    calendar.locale = Locale(identifier: "zh_CN")
    calendar.firstWeekday = 2
    return calendar
}

func fixedNow() -> Date {
    DateCoding.parseISO("2026-11-06T05:30:00Z")!
}

func localDate(_ calendar: Calendar, _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
    var components = DateComponents()
    components.calendar = calendar
    components.timeZone = calendar.timeZone
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    return calendar.date(from: components)!
}

func jsonObject(_ string: String) -> [String: Any] {
    guard let data = string.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return [:]
    }
    return object
}

func mcpText(_ response: [String: Any]) -> String {
    guard let result = response["result"] as? [String: Any],
          let content = result["content"] as? [[String: Any]],
          let text = content.first?["text"] as? String else {
        return ""
    }
    return text
}

func mcpResultObject(_ response: [String: Any]) -> [String: Any] {
    jsonObject(mcpText(response))
}
