import Foundation

public final class CaptureStatusStore: @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public convenience init(paths: AppPaths) {
        self.init(fileURL: paths.runDirectory.appendingPathComponent("capture-status.json"))
    }

    public func write(_ health: CaptureHealth) {
        lock.lock()
        defer { lock.unlock() }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONCoding.encoder(pretty: true).encode(health)
            try data.write(to: fileURL, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            PSLog.warn("cannot write capture status: \(error.localizedDescription)")
        }
    }

    public func read() -> CaptureHealth? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONCoding.decoder().decode(CaptureHealth.self, from: data)
    }
}

public final class MemoryService {
    public let store: MemoryStore
    public let config: AppConfig
    public let paths: AppPaths
    public let retriever: HybridRetriever
    public let pipeline: IngestPipeline
    public let consolidator: Consolidator
    private let captureStatus: CaptureStatusStore

    public init(store: MemoryStore, config: AppConfig, paths: AppPaths) {
        self.store = store
        self.config = config
        self.paths = paths
        self.retriever = HybridRetriever(store: store, config: config)
        self.pipeline = IngestPipeline(store: store, config: config)
        self.consolidator = Consolidator(store: store, config: config)
        self.captureStatus = CaptureStatusStore(paths: paths)
    }

    public convenience init(paths: AppPaths, config: AppConfig) throws {
        let store = try MemoryStore(paths: paths, config: config)
        self.init(store: store, config: config, paths: paths)
    }

    @discardableResult
    public func ingest(_ candidate: CandidatePacket, now: Date? = nil) throws -> IngestResult {
        try pipeline.ingest(candidate, now: now)
    }

    public func recall(
        query: String,
        timeRange: DateInterval? = nil,
        layer: MemoryLayer? = nil,
        limit: Int? = nil,
        now: Date = Date()
    ) throws -> RecallResult {
        try retriever.recall(query: query, timeRange: timeRange, layer: layer, limit: limit, now: now)
    }

    public func drillDown(memoryID: String, now: Date = Date()) throws -> DrillDownResult {
        try retriever.drillDown(memoryID: memoryID, now: now)
    }

    public func digest(dayKey: String? = nil, now: Date = Date()) throws -> DailyDigest? {
        let key = dayKey ?? DateCoding.dayKey(now)
        return try store.digest(date: key)
    }

    public func generateDigest(
        dayKey: String? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> ConsolidationReport {
        let date: Date
        if let dayKey {
            guard let parsed = DateCoding.parseDay(dayKey, calendar: calendar) else {
                throw MemoryServiceError.invalidArgument("date must be yyyy-MM-dd")
            }
            date = parsed
        } else {
            date = now
        }
        return try consolidator.run(date: date, now: now, calendar: calendar)
    }

    public func todos(status: TodoStatus? = nil, limit: Int = 100) throws -> [TodoItem] {
        try store.fetchTodos(status: status, limit: max(1, min(limit, 500)))
    }

    @discardableResult
    public func addTodo(
        title: String,
        detail: String = "",
        dueAt: Date? = nil,
        now: Date = Date()
    ) throws -> TodoItem {
        try store.addTodo(
            title: title,
            detail: detail,
            dueAt: dueAt,
            now: now
        )
    }

    @discardableResult
    public func updateTodo(
        id: String,
        status: TodoStatus,
        now: Date = Date()
    ) throws -> TodoItem? {
        guard !id.isEmpty else { throw MemoryServiceError.invalidArgument("todo_id is required") }
        return try store.updateTodoStatus(id: id, status: status, at: now)
    }

    @discardableResult
    public func deleteTodo(id: String) throws -> Bool {
        guard !id.isEmpty else { throw MemoryServiceError.invalidArgument("todo_id is required") }
        return try store.deleteTodo(id: id)
    }

    public func timeline(
        in interval: DateInterval,
        includeFacts: Bool = true,
        limit: Int = 300
    ) throws -> TimelineResult {
        guard interval.start < interval.end else {
            throw MemoryServiceError.invalidArgument("timeline start must be before end")
        }
        let maximum = max(1, min(limit, 1_000))
        let episodes = try store.fetchEpisodes(
            in: interval,
            includeArchived: true,
            limit: 5_000
        )
        var entries: [TimelineEntry] = episodes.map { episode in
            TimelineEntry(
                memoryID: episode.id,
                kind: .episode,
                timestamp: episode.startedAt,
                title: episode.displayTitle,
                summary: TextAnalyzer.truncated(episode.summary, limit: 240),
                application: episode.application,
                salience: episode.salience,
                trust: episode.trust
            )
        }
        if includeFacts {
            let facts = try store.fetchFacts(limit: 5_000).filter {
                $0.status == .active
                    && $0.createdAt >= interval.start
                    && $0.createdAt < interval.end
            }
            entries.append(contentsOf: facts.map { fact in
                TimelineEntry(
                    memoryID: fact.id,
                    kind: .fact,
                    timestamp: fact.createdAt,
                    title: "语义事实 · \(fact.kind.rawValue)",
                    summary: TextAnalyzer.truncated(fact.statement, limit: 240),
                    application: nil,
                    salience: fact.salience,
                    trust: fact.trust
                )
            })
        }
        entries.sort { $0.timestamp > $1.timestamp }
        let selected = Array(entries.prefix(maximum)).sorted { $0.timestamp < $1.timestamp }
        return TimelineResult(from: interval.start, to: interval.end, entries: selected)
    }

    @discardableResult
    public func upsertContact(
        displayName: String,
        organization: String? = nil,
        notes: String? = nil,
        channels: [ContactChannel] = [],
        now: Date = Date()
    ) throws -> Contact {
        try store.upsertContact(
            displayName: displayName,
            organization: organization,
            notes: notes,
            channels: channels,
            now: now
        )
    }

    public func contacts(limit: Int = 100, query: String? = nil) throws -> [Contact] {
        try store.listContacts(limit: max(1, min(limit, 500)), query: query)
    }

    @discardableResult
    public func recordMessage(
        channel: String,
        contactName: String,
        handle: String? = nil,
        direction: MessageDirection,
        text: String,
        timestamp: Date = Date(),
        thread: String? = nil,
        externalID: String? = nil,
        isRead: Bool? = nil,
        now: Date = Date()
    ) throws -> ContactMessage {
        try store.recordMessage(
            channel: channel,
            contactName: contactName,
            handle: handle,
            direction: direction,
            text: text,
            timestamp: timestamp,
            thread: thread,
            externalID: externalID,
            isRead: isRead,
            now: now
        )
    }

    public func messages(
        channel: String? = nil,
        contactID: String? = nil,
        unreadOnly: Bool = false,
        query: String? = nil,
        limit: Int = 100
    ) throws -> [ContactMessage] {
        try store.listMessages(
            channel: channel,
            contactID: contactID,
            unreadOnly: unreadOnly,
            query: query,
            limit: max(1, min(limit, 500))
        )
    }

    @discardableResult
    public func mergeContacts(targetID: String, sourceID: String, now: Date = Date()) throws -> Contact? {
        try store.mergeContacts(targetID: targetID, sourceID: sourceID, now: now)
    }

    @discardableResult
    public func markMessageRead(id: String, isRead: Bool = true) throws -> ContactMessage? {
        guard !id.isEmpty else { throw MemoryServiceError.invalidArgument("message_id is required") }
        return try store.markMessageRead(id: id, isRead: isRead)
    }

    public func pendingReviewFacts(limit: Int = 50) throws -> [SemanticFact] {
        Array(try store.fetchFacts(status: .pendingReview, limit: max(1, min(limit, 200))).prefix(limit))
    }

    public func reviewFact(
        id: String,
        action: String,
        correctedStatement: String? = nil,
        now: Date = Date()
    ) throws -> SemanticFact? {
        try store.correctFact(id: id, statement: correctedStatement, action: action, at: now)
    }

    /// Import visible Gmail inbox rows from an already captured screen episode.
    /// This is an OCR-only, local operation; no mail account or network is used.
    @discardableResult
    public func importGmailMessages(fromEpisodeID episodeID: String, now: Date = Date()) throws -> Int {
        guard let episode = try store.fetchEpisode(id: episodeID) else {
            throw MemoryServiceError.notFound("episode")
        }
        let extracted = EmailScreenExtractor.extract(
            windowTitle: episode.windowTitle,
            ocrText: episode.ocrText,
            regions: episode.ocrRegions,
            now: now,
            limit: config.emailScreen.maximumMessagesPerScreen
        )
        guard !extracted.isEmpty else { return 0 }
        for message in extracted {
            _ = try store.recordMessage(
                channel: "email",
                contactName: message.contactName,
                handle: message.handle,
                direction: .inbound,
                text: message.subject,
                timestamp: message.timestamp,
                externalID: message.externalID,
                isRead: true,
                now: now
            )
        }
        return extracted.count
    }

    public func brief(
        dayKey: String? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> DailyBrief {
        let key: String
        let interval: DateInterval
        if let dayKey {
            guard let parsed = DateCoding.parseDay(dayKey, calendar: calendar),
                  let dayInterval = DateCoding.dayInterval(dayKey: dayKey, calendar: calendar) else {
                throw MemoryServiceError.invalidArgument("date must be yyyy-MM-dd")
            }
            key = DateCoding.dayKey(parsed, calendar: calendar)
            interval = dayInterval
        } else {
            key = DateCoding.dayKey(now, calendar: calendar)
            interval = DateCoding.dayInterval(for: now, calendar: calendar)
        }
        let timeline = try timeline(in: interval, includeFacts: true, limit: 500)
        return DailyBrief(
            date: key,
            generatedAt: now,
            from: interval.start,
            to: interval.end,
            timeline: timeline.entries,
            openTodos: try store.openTodos(limit: 200),
            unreadMessages: try store.listMessages(unreadOnly: true, limit: 50),
            contacts: try store.listContacts(limit: 50),
            counts: try store.counts()
        )
    }

    public func status(now: Date = Date()) throws -> ServiceStatus {
        let health = captureStatus.read() ?? CaptureHealth(
            state: "not_running",
            detail: "Capture daemon has not published status yet.",
            permissionGranted: false
        )
        return ServiceStatus(
            databasePath: store.database.databasePath,
            counts: try store.counts(),
            capture: health,
            intentModel: config.intentGate.model.enabled ? config.intentGate.model.executable : "rules",
            extractionModel: config.factGate.model.enabled ? config.factGate.model.executable : "rules",
            generatedAt: now
        )
    }

    public func publishCaptureHealth(_ health: CaptureHealth) {
        captureStatus.write(health)
    }
}
