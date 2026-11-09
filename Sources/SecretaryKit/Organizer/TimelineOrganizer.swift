import Foundation

public struct TimelineTodoCandidate: Equatable, Sendable {
    public var title: String
    public var detail: String
    public var dueDate: String?
    public var confidence: Double
    public var evidence: String

    public init(title: String, detail: String = "", dueDate: String? = nil, confidence: Double = 0.7, evidence: String = "") {
        self.title = title
        self.detail = detail
        self.dueDate = dueDate
        self.confidence = confidence
        self.evidence = evidence
    }
}

public struct TimelineMessageCandidate: Equatable, Sendable {
    public var channel: String
    public var contactName: String
    public var handle: String?
    public var direction: MessageDirection
    public var text: String
    public var confidence: Double

    public init(
        channel: String,
        contactName: String,
        handle: String? = nil,
        direction: MessageDirection = .inbound,
        text: String,
        confidence: Double = 0.7
    ) {
        self.channel = channel
        self.contactName = contactName
        self.handle = handle
        self.direction = direction
        self.text = text
        self.confidence = confidence
    }
}

public protocol TimelineModelExtracting: Sendable {
    func extractTodos(from episode: Episode) throws -> [TimelineTodoCandidate]
    func extractMessages(from episode: Episode) throws -> [TimelineMessageCandidate]
}

public struct OrganizerReport: Codable, Equatable, Sendable {
    public var episodesScanned: Int
    public var episodesOrganized: Int
    public var episodesSkipped: Int
    public var todosCreated: Int
    public var messagesCreated: Int
    public var contacts: Int
    public var errors: [String]

    public init(
        episodesScanned: Int = 0,
        episodesOrganized: Int = 0,
        episodesSkipped: Int = 0,
        todosCreated: Int = 0,
        messagesCreated: Int = 0,
        contacts: Int = 0,
        errors: [String] = []
    ) {
        self.episodesScanned = episodesScanned
        self.episodesOrganized = episodesOrganized
        self.episodesSkipped = episodesSkipped
        self.todosCreated = todosCreated
        self.messagesCreated = messagesCreated
        self.contacts = contacts
        self.errors = errors
    }
}

/// Extracts todos and contact messages from already captured L2 timeline
/// episodes. It is deliberately separate from the capture daemon so it can be
/// backfilled and scheduled without touching TCC-protected processes.
public final class TimelineOrganizer {
    private let store: MemoryStore
    private let config: AppConfig
    private let paths: AppPaths
    private let model: (any TimelineModelExtracting)?
    private let stateURL: URL

    private static let ownApplications = [
        "private secretary", "privatesecretary", "loginwindow",
        "qq音乐", "usernotificationcenter", "wallpaper", "systemuiserver"
    ]
    private static let todoApplications = [
        "notes", "textedit", "文本编辑", "obsidian", "notion",
        "pages", "numbers", "microsoft word", "microsoft excel", "word", "excel"
    ]
    private static let communicationApplications = [
        "mail", "messages", "slack", "lark", "飞书", "feishu", "wechat", "微信",
        "telegram", "whatsapp", "discord", "outlook"
    ]
    private static let communicationHints = [
        "gmail", "mail.google", "outlook", "slack", "lark", "feishu",
        "wechat", "微信", "telegram", "whatsapp", "discord", "收件箱", "邮件"
    ]

    public init(
        store: MemoryStore,
        config: AppConfig,
        paths: AppPaths,
        model: (any TimelineModelExtracting)? = nil
    ) {
        self.store = store
        self.config = config
        self.paths = paths
        if let model {
            self.model = model
        } else if config.factGate.model.enabled {
            self.model = ModelCommandClient(config: config.factGate.model)
        } else {
            self.model = nil
        }
        self.stateURL = paths.runDirectory.appendingPathComponent("organizer-state.json")
    }

    public func organize(
        since: Date? = nil,
        limit: Int = 1_000,
        force: Bool = false,
        dryRun: Bool = false
    ) throws -> OrganizerReport {
        let interval = since.map { DateInterval(start: $0, end: Date()) }
        let episodes = try store.fetchEpisodes(in: interval, includeArchived: false, limit: max(1, min(limit, 5_000)))
            .sorted { $0.startedAt < $1.startedAt }
        var processed = loadState()
        var report = OrganizerReport()
        report.episodesScanned = episodes.count
        var existingTodos = try store.fetchTodos(status: nil, limit: 1_000)

        for episode in episodes {
            if !force && processed.contains(episode.id) {
                report.episodesSkipped += 1
                continue
            }
            if isNoise(episode) {
                report.episodesSkipped += 1
                if !dryRun { processed.insert(episode.id) }
                continue
            }
            let canTodo = todoEligible(episode) && model != nil
            let gmail = isStrictGmailInbox(episode)
            let canMessages = messageEligible(episode)
            if !canTodo && !gmail && !canMessages {
                report.episodesSkipped += 1
                if !dryRun { processed.insert(episode.id) }
                continue
            }

            do {
                if gmail {
                    let extracted = EmailScreenExtractor.extract(
                        windowTitle: episode.windowTitle,
                        ocrText: episode.ocrText,
                        regions: episode.ocrRegions,
                        now: episode.endedAt,
                        limit: config.emailScreen.maximumMessagesPerScreen
                    )
                    for message in extracted {
                        if dryRun {
                            report.messagesCreated += 1
                        } else {
                            let result = try store.recordMessageWithStatus(
                                channel: "email",
                                contactName: message.contactName,
                                handle: message.handle,
                                direction: .inbound,
                                text: message.subject,
                                timestamp: message.timestamp,
                                externalID: message.externalID,
                                isRead: true,
                                now: episode.endedAt
                            )
                            if result.inserted { report.messagesCreated += 1 }
                        }
                    }
                }

                if canMessages, !gmail, let model {
                    let candidates = try model.extractMessages(from: episode)
                    for candidate in candidates where candidate.confidence >= 0.55 {
                        let text = candidate.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        let contact = candidate.contactName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard contact.count >= 2, text.count >= 2 else { continue }
                        let externalID = "timeline-msg-" + Self.fnv("\(candidate.channel)|\(contact.lowercased())|\(text)")
                        if dryRun {
                            report.messagesCreated += 1
                        } else {
                            let result = try store.recordMessageWithStatus(
                                channel: candidate.channel,
                                contactName: contact,
                                handle: candidate.handle,
                                direction: candidate.direction,
                                text: text,
                                timestamp: episode.endedAt,
                                externalID: externalID,
                                isRead: true,
                                now: episode.endedAt
                            )
                            if result.inserted { report.messagesCreated += 1 }
                        }
                    }
                }

                if canTodo, let model {
                    let candidates = try model.extractTodos(from: episode)
                    for candidate in candidates where candidate.confidence >= 0.55 {
                        let title = candidate.title.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard title.count >= 3, title.count <= 300 else { continue }
                        guard !TextAnalyzer.containsPromptInjection(title) else { continue }
                        guard !Self.looksLikeUI(title) else { continue }
                        if existingTodos.contains(where: { Self.isDuplicateTodo($0.title, title) }) {
                            continue
                        }
                        let dueAt = parseDue(candidate.dueDate, episode: episode)
                        if dryRun {
                            report.todosCreated += 1
                            existingTodos.append(TodoItem(
                                id: "dry_\(UUID().uuidString)",
                                title: title,
                                detail: candidate.detail,
                                intentType: .todo,
                                sourceEpisodeID: episode.id,
                                dueAt: dueAt
                            ))
                        } else {
                            let detail = [
                                "Timeline extraction",
                                "Source: \(episode.application ?? "unknown") / \(episode.windowTitle ?? "unknown")",
                                candidate.detail,
                                candidate.evidence.isEmpty ? nil : "Evidence: \(candidate.evidence)",
                                "Episode: \(episode.id)"
                            ].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
                            let todo = try store.addTodo(
                                title: title,
                                detail: detail,
                                intentType: .todo,
                                sourceEpisodeID: episode.id,
                                dueAt: dueAt,
                                now: episode.endedAt
                            )
                            existingTodos.append(todo)
                            report.todosCreated += 1
                        }
                    }
                }

                report.episodesOrganized += 1
                if !dryRun { processed.insert(episode.id) }
            } catch {
                report.episodesSkipped += 1
                if report.errors.count < 20 {
                    report.errors.append("\(episode.id): \(error.localizedDescription)")
                }
            }
        }

        if !dryRun {
            saveState(processed)
        }
        report.contacts = (try? store.listContacts(limit: 1_000).count) ?? 0
        return report
    }

    private func isNoise(_ episode: Episode) -> Bool {
        let app = (episode.application ?? "").lowercased()
        if Self.ownApplications.contains(where: { app == $0 || app.hasPrefix($0) }) { return true }
        let text = episode.transcript + "\n" + episode.ocrText
        return text.trimmingCharacters(in: .whitespacesAndNewlines).count < 10
    }

    private func todoEligible(_ episode: Episode) -> Bool {
        let app = (episode.application ?? "").lowercased()
        switch episode.source {
        case .audio:
            return episode.audioOrigin.allowsTodoCapture
        case .manual:
            return true
        case .combined:
            return episode.audioOrigin.allowsTodoCapture
        case .screen:
            return Self.todoApplications.contains(where: { app == $0 || app.hasPrefix($0) })
        }
    }

    private func isStrictGmailInbox(_ episode: Episode) -> Bool {
        let title = (episode.windowTitle ?? "").lowercased()
        guard title.contains("gmail") else { return false }
        let looksLikeInbox = title.contains("收件箱") || title.contains("inbox")
        let hasGmailChrome = (episode.ocrText.lowercased().contains("mail.google.com") || title.contains("gmail"))
        return looksLikeInbox && hasGmailChrome
    }

    private func messageEligible(_ episode: Episode) -> Bool {
        guard episode.source == .screen || episode.source == .combined else { return false }
        let app = (episode.application ?? "").lowercased()
        // Browser pages are only handled by the deterministic Gmail inbox
        // extractor. Never let the small local model turn docs/blogs into
        // contacts.
        if app.contains("chrome") || app.contains("safari") || app.contains("firefox") || app.contains("arc") {
            return false
        }
        return Self.communicationApplications.contains(where: { app == $0 || app.hasPrefix($0) })
    }

    private func parseDue(_ raw: String?, episode: Episode) -> Date? {
        guard let raw, let due = DateCoding.parseDay(raw) else { return nil }
        // Small local models hallucinate years. Only accept a due date near the
        // evidence, otherwise let the user set it explicitly.
        let delta = due.timeIntervalSince(episode.startedAt)
        guard delta >= -86_400 * 30, delta <= 86_400 * 120 else { return nil }
        return due
    }

    private static func isDuplicateTodo(_ existing: String, _ candidate: String) -> Bool {
        let left = TextAnalyzer.normalize(existing)
        let right = TextAnalyzer.normalize(candidate)
        guard !left.isEmpty, !right.isEmpty else { return false }
        if left == right { return true }
        let longer = left.count >= right.count ? left : right
        let shorter = left.count >= right.count ? right : left
        if shorter.count >= 4 && longer.contains(shorter) { return true }
        return TextAnalyzer.jaccard(left, right) >= 0.62
    }

    private static func looksLikeUI(_ title: String) -> Bool {
        let lowered = TextAnalyzer.normalize(title)
        let blocked = ["overview", "timeline", "contacts", "settings", "open todos", "messages", "service", "capture service", "第1-50行", "点击", "按钮"]
        if blocked.contains(where: { lowered.contains($0) }) { return true }
        return lowered.hasPrefix("http://") || lowered.hasPrefix("https://")
    }

    private func loadState() -> Set<String> {
        guard let data = try? Data(contentsOf: stateURL),
              let ids = try? JSONCoding.decoder().decode([String].self, from: data) else {
            return []
        }
        return Set(ids)
    }

    private func saveState(_ ids: Set<String>) {
        do {
            try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONCoding.encoder(pretty: false).encode(ids.sorted())
            try data.write(to: stateURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
        } catch {
            PSLog.warn("cannot save organizer state: \(error.localizedDescription)")
        }
    }

    private static func fnv(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}
