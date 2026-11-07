import Foundation
import SecretaryKit

enum CLIError: Error, LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}

struct CLIArguments {
    var positionals: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    init(tokens: [String], valueOptions: Set<String>, flagOptions: Set<String>) throws {
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token.hasPrefix("--"), token.count > 2 {
                let stripped = String(token.dropFirst(2))
                if let equals = stripped.firstIndex(of: "=") {
                    let key = String(stripped[..<equals])
                    let value = String(stripped[stripped.index(after: equals)...])
                    options[key] = value
                } else if valueOptions.contains(stripped) {
                    index += 1
                    guard index < tokens.count else {
                        throw CLIError.message("--\(stripped) requires a value")
                    }
                    options[stripped] = tokens[index]
                } else if flagOptions.contains(stripped) {
                    flags.insert(stripped)
                } else {
                    throw CLIError.message("Unknown option --\(stripped)")
                }
            } else if token == "-h" {
                flags.insert("help")
            } else if token.hasPrefix("-") && token.count > 1 {
                throw CLIError.message("Unknown option \(token)")
            } else {
                positionals.append(token)
            }
            index += 1
        }
    }
}

final class CLIRunner {
    private var home: URL?
    private var jsonOutput = false

    static let helpText = """
    Private Secretary \(PrivateSecretaryVersion.current)
    Read-only local memory, timeline, todos, contacts and messages.

    USAGE
      secretary [--home <dir>] <command> [options]

    COMMANDS
      init [--force]                 Create config + database
      status [--json]                Health, counts, capture state
      ingest [options]               Ingest one candidate packet
        --file <path>                CandidatePacket JSON
        --stdin                      Read candidate JSON or transcript from stdin
        --transcript <text>          Transcript text
        --ocr <text>                 OCR text
        --app <name> --window <title>
        --origin manual|microphone|system|mixed
        --source manual|audio|screen|combined
        --at <ISO-8601>              Capture timestamp
        --json
      recall <query> [--layer L2|L3|all] [--limit N]
             [--from <date>] [--to <date>] [--json]
      drill <memory_id> [--json]
      digest [yyyy-MM-dd] [--json]
      consolidate [yyyy-MM-dd] [--yesterday] [--json]
      brief [yyyy-MM-dd] [--json]  Timeline + open todos + unread messages + contacts
      context [yyyy-MM-dd]          Paste-ready Markdown context for an agent
      dashboard [yyyy-MM-dd] [--output path] [--open] [--json]
      timeline [yyyy-MM-dd] [--days N] [--no-facts] [--limit N] [--json]
      todos [--status open|done|dismissed|all] [--limit N] [--json]
      todo add <title> [--detail text] [--due ISO-8601]
      todo update <todo_id> --status open|done|dismissed
      todo delete <todo_id>
      contacts [--query text] [--limit N] [--json]
      contact add --name <name> [--org text] [--note text]
                  [--channel kind:handle,...]
      messages [--channel name] [--contact id] [--unread] [--search text]
               [--limit N] [--json]
      message add --channel <name> --contact <name> --text <text>
                  [--handle <id>] [--direction inbound|outbound]
                  [--at ISO-8601] [--thread text] [--external-id id]
      message import --file <path> | --stdin [--channel default] [--json]
      contact merge <source_id> --into <target_id>
      review list [--json]
      review accept|reject|correct <fact_id> [--statement text]
      demo                           Seed a safe demo in an empty home
      soak [--events N] [--queries N] [--days N] [--json]
                                     Ephemeral ingestion + retrieval benchmark
      doctor [--json]
      forget <episode_id>
      purge --all --yes              Delete all memories and cold archive
      version

    GLOBAL
      --home <dir>                   Default ~/.private-secretary (or PRIVATE_SECRETARY_HOME)
      --json                         Machine-readable output where supported
    """

    func run(arguments: [String]) throws {
        var tokens = arguments
        if let index = tokens.firstIndex(of: "--home") {
            guard index + 1 < tokens.count else { throw CLIError.message("--home requires a path") }
            home = URL(fileURLWithPath: (tokens[index + 1] as NSString).expandingTildeInPath, isDirectory: true)
            tokens.removeSubrange(index...(index + 1))
        } else if let homeToken = tokens.first(where: { $0.hasPrefix("--home=") }) {
            let value = String(homeToken.dropFirst("--home=".count))
            home = URL(fileURLWithPath: (value as NSString).expandingTildeInPath, isDirectory: true)
            tokens.removeAll { $0 == homeToken }
        }
        jsonOutput = tokens.contains("--json")
        tokens.removeAll { $0 == "--json" }

        guard let command = tokens.first else {
            print(Self.helpText)
            return
        }
        let rest = Array(tokens.dropFirst())
        if command == "--help" || command == "-h" || command == "help" {
            print(Self.helpText)
            return
        }
        if command == "version" || command == "--version" {
            print(PrivateSecretaryVersion.current)
            return
        }
        if command == "init" {
            try runInit(rest)
            return
        }
        if command == "demo" {
            try runDemo(rest)
            return
        }
        if command == "soak" {
            try runSoak(rest)
            return
        }
        let paths = AppPaths(home: home)
        let config = try AppConfigLoader.loadOrCreate(paths: paths)
        let service = try MemoryService(paths: paths, config: config)
        switch command {
        case "status": try runStatus(service, rest)
        case "ingest": try runIngest(service, rest)
        case "recall": try runRecall(service, rest)
        case "drill": try runDrill(service, rest)
        case "digest": try runDigest(service, rest)
        case "consolidate": try runConsolidate(service, rest)
        case "brief": try runBrief(service, rest)
        case "context": try runContext(service, rest)
        case "dashboard": try runDashboard(service, rest)
        case "timeline": try runTimeline(service, rest)
        case "todos": try runTodos(service, rest)
        case "todo": try runTodo(service, rest)
        case "contacts": try runContacts(service, rest)
        case "contact": try runContact(service, rest)
        case "messages": try runMessages(service, rest)
        case "message": try runMessage(service, rest)
        case "review": try runReview(service, rest)
        case "doctor": try runDoctor(paths: paths, config: config, service: service, arguments: rest)
        case "forget": try runForget(service, rest)
        case "purge": try runPurge(service, rest)
        default:
            throw CLIError.message("Unknown command: \(command)\n\n\(Self.helpText)")
        }
    }

    private func runInit(_ tokens: [String]) throws {
        let args = try CLIArguments(tokens: tokens, valueOptions: [], flagOptions: ["force"])
        guard args.positionals.isEmpty else { throw CLIError.message("init takes no positional arguments") }
        if !args.flags.contains("force"), !jsonOutput {
            print("Initializing Private Secretary…")
        }
        let paths = AppPaths(home: home)
        let config = try AppConfigLoader.loadOrCreate(paths: paths, forceDefault: args.flags.contains("force"))
        let store = try MemoryStore(paths: paths, config: config)
        _ = try store.counts()
        let payload: [String: Any] = [
            "status": "initialized",
            "home": paths.home.path,
            "config": paths.configFile.path,
            "database": paths.databaseFile.path,
            "version": PrivateSecretaryVersion.current
        ]
        if jsonOutput {
            print(try Self.jsonText(payload))
        } else {
            print("✓ Config:   \(paths.configFile.path)")
            print("✓ Memory:   \(paths.databaseFile.path)")
            print("✓ Cold:     \(paths.coldArchiveDirectory.path)")
            print("Next: configure capture.whisperModel, run `secretary doctor`, then `secretary demo`.")
        }
    }

    private func runStatus(_ service: MemoryService, _ tokens: [String]) throws {
        let args = try CLIArguments(tokens: tokens, valueOptions: [], flagOptions: [])
        guard args.positionals.isEmpty else { throw CLIError.message("status takes no arguments") }
        let status = try service.status()
        if jsonOutput {
            print(try Self.jsonString(status))
        } else {
            print("Private Secretary \(status.version)")
            print("Database: \(status.databasePath)")
            print("Memory:   \(status.counts.episodes) episodes (\(status.counts.archivedEpisodes) archived) · \(status.counts.activeFacts) facts")
            print("People:   \(status.counts.contacts) contacts · \(status.counts.messages) messages")
            print("Todos:    \(status.counts.openTodos) open · Review: \(status.counts.pendingReviewFacts) pending facts · Digests: \(status.counts.digests)")
            print("Capture:  \(status.capture.state) — \(status.capture.detail ?? "no detail")")
            print("Models:   intent=\(status.intentModel) extraction=\(status.extractionModel)")
        }
    }

    private func runIngest(_ service: MemoryService, _ tokens: [String]) throws {
        let args = try CLIArguments(
            tokens: tokens,
            valueOptions: ["file", "transcript", "ocr", "app", "window", "origin", "source", "at"],
            flagOptions: ["stdin"]
        )
        var candidate: CandidatePacket
        if let file = args.options["file"] {
            let data = try Data(contentsOf: URL(fileURLWithPath: (file as NSString).expandingTildeInPath))
            candidate = try JSONCoding.decoder().decode(CandidatePacket.self, from: data)
        } else if args.flags.contains("stdin") {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            if let decoded = try? JSONCoding.decoder().decode(CandidatePacket.self, from: data) {
                candidate = decoded
            } else {
                let text = String(decoding: data, as: UTF8.self)
                candidate = CandidatePacket(source: .manual, audioOrigin: .manual, transcript: text)
            }
        } else {
            let text = args.options["transcript"] ?? args.positionals.joined(separator: " ")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CLIError.message("ingest requires --file, --stdin, --transcript, or positional text")
            }
            let origin = try parseOrigin(args.options["origin"]) ?? .manual
            let source = try parseSource(args.options["source"]) ?? (args.options["ocr"] == nil ? .manual : .combined)
            candidate = CandidatePacket(
                source: source,
                audioOrigin: origin,
                application: args.options["app"],
                windowTitle: args.options["window"],
                transcript: text,
                ocrText: args.options["ocr"] ?? ""
            )
        }
        if let raw = args.options["at"] {
            guard let date = DateCoding.parseISO(raw) ?? DateCoding.parseDay(raw) else {
                throw CLIError.message("--at must be ISO-8601 or yyyy-MM-dd")
            }
            candidate.capturedAt = date
        }
        let result = try service.ingest(candidate)
        if jsonOutput {
            print(try Self.jsonString(result))
        } else if !result.accepted {
            print("Dropped: \(result.reason ?? "unknown")")
        } else {
            print("✓ Episode \(result.episode?.id ?? "?")")
            print("  Salience: \(String(format: "%.3f", result.episode?.salience ?? 0))")
            for fact in result.facts {
                print("  L3 [\(fact.status.rawValue)] \(fact.statement) (\(fact.id))")
            }
            if let intent = result.intent {
                print("  Intent: \(intent.classification.rawValue) \(intent.intentType?.rawValue ?? "-") confidence=\(String(format: "%.2f", intent.confidence))")
            }
            if let todo = result.todo {
                print("  Todo:   \(todo.id) [\(todo.status.rawValue)] \(todo.title)")
                print("          Captured only; not executed.")
            }
        }
    }

    private func runRecall(_ service: MemoryService, _ tokens: [String]) throws {
        let args = try CLIArguments(
            tokens: tokens,
            valueOptions: ["layer", "limit", "from", "to"],
            flagOptions: []
        )
        let query = args.positionals.joined(separator: " ")
        guard !query.isEmpty else { throw CLIError.message("recall requires a query") }
        let layer = try parseLayer(args.options["layer"])
        let limit = args.options["limit"].flatMap(Int.init)
        if args.options["limit"] != nil, limit == nil {
            throw CLIError.message("--limit must be an integer")
        }
        var range: DateInterval?
        let start = args.options["from"].flatMap(Self.parseDate)
        let end = args.options["to"].flatMap(Self.parseDateEnd)
        if start != nil || end != nil {
            let intervalStart = start ?? Date(timeIntervalSince1970: 0)
            let intervalEnd = end ?? Date().addingTimeInterval(1)
            guard intervalStart < intervalEnd else {
                throw CLIError.message("--from must be before --to")
            }
            range = DateInterval(start: intervalStart, end: intervalEnd)
        }
        let result = try service.recall(query: query, timeRange: range, layer: layer, limit: limit)
        if jsonOutput {
            print(try Self.jsonString(result))
            return
        }
        print("Query: \(result.query)")
        if let parsed = result.parsedTimeRange {
            print("Time:  \(DateCoding.iso(parsed.start)) → \(DateCoding.iso(parsed.end))")
        }
        print("Found: \(result.results.count)")
        for (index, memory) in result.results.enumerated() {
            print("")
            print("\(index + 1). [\(memory.layer.rawValue)] \(memory.title) · \(DateCoding.human(memory.timestamp)) · score \(String(format: "%.3f", memory.score))")
            print("   \(memory.summary)")
            print("   \(memory.id)")
        }
        print("\n\(result.note)")
    }

    private func runDrill(_ service: MemoryService, _ tokens: [String]) throws {
        let args = try CLIArguments(tokens: tokens, valueOptions: [], flagOptions: [])
        guard let id = args.positionals.first else { throw CLIError.message("drill requires a memory_id") }
        let result = try service.drillDown(memoryID: id)
        if jsonOutput {
            print(try Self.jsonString(result))
        } else if let content = result.content {
            print("Memory: \(content.id) [L2] \(content.displayTitle) · \(DateCoding.human(content.startedAt))")
            print("Trust:  \(content.trust.rawValue)")
            print("Salience: \(String(format: "%.3f", content.salience)) · archived=\(result.archived) cold=\(result.coldArchiveLoaded)")
            print("\nTranscript:\n\(content.transcript.isEmpty ? "（empty）" : content.transcript)")
            print("\nOCR:\n\(content.ocrText.isEmpty ? "（empty）" : content.ocrText)")
            print("\nProvenance:")
            for p in content.provenance {
                print("- \(p.kind) \(p.reference ?? "") \(p.detail ?? "")")
            }
            print("\n⚠️  \(result.warning)")
        } else if let fact = result.fact {
            print("Memory: \(fact.id) [L3] [\(fact.kind.rawValue)] \(fact.status.rawValue)")
            print("Trust: \(fact.trust.rawValue)")
            print("Statement: \(fact.statement)")
            print("Subject/predicate/object: \(fact.subject) / \(fact.predicate) / \(fact.object)")
            print("Confidence: \(String(format: "%.2f", fact.confidence)) · evidence=\(fact.evidenceCount)")
            print("Sources: \(fact.sourceEpisodeIDs.joined(separator: ", "))")
            print("Supersedes: \(fact.supersedesID ?? "-") · superseded_by: \(fact.supersededByID ?? "-")")
            print("\n⚠️  \(result.warning)")
        }
    }

    private func runDigest(_ service: MemoryService, _ tokens: [String]) throws {
        let args = try CLIArguments(tokens: tokens, valueOptions: ["date"], flagOptions: [])
        let key = args.options["date"] ?? args.positionals.first
        guard let digest = try service.digest(dayKey: key) else {
            throw CLIError.message("No digest for \(key ?? DateCoding.dayKey(Date())). Run `secretary consolidate` first.")
        }
        if jsonOutput {
            print(try Self.jsonString(digest))
        } else {
            print(digest.markdown)
        }
    }

    private func runConsolidate(_ service: MemoryService, _ tokens: [String]) throws {
        let args = try CLIArguments(tokens: tokens, valueOptions: ["date"], flagOptions: ["yesterday"])
        var key = args.options["date"] ?? args.positionals.first
        if args.flags.contains("yesterday"), key == nil {
            let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
            key = DateCoding.dayKey(yesterday)
        }
        let report = try service.generateDigest(dayKey: key)
        if jsonOutput {
            print(try Self.jsonString(report))
        } else {
            print(report.digest.markdown)
            print("Facts created: \(report.factsCreated) · superseded: \(report.factsSuperseded) · pending review: \(report.factsPendingReview)")
            print("Archived: \(report.archivedEpisodes) · took \(String(format: "%.0f", report.durationMilliseconds)) ms")
        }
    }

    private func runBrief(_ service: MemoryService, _ tokens: [String]) throws {
        let args = try CLIArguments(tokens: tokens, valueOptions: ["date"], flagOptions: [])
        guard args.positionals.count <= 1 else { throw CLIError.message("brief takes at most one date") }
        let key = args.options["date"] ?? args.positionals.first
        let brief = try service.brief(dayKey: key)
        if jsonOutput {
            print(try Self.jsonString(brief))
            return
        }
        print("# Private Secretary Brief · \(brief.date)")
        print("")
        print("Timeline: \(brief.timeline.count) · Open todos: \(brief.openTodos.count) · Unread messages: \(brief.unreadMessages.count) · Contacts: \(brief.contacts.count)")
        print("")
        print("## Timeline")
        if brief.timeline.isEmpty {
            print("(no memory entries)")
        } else {
            for entry in brief.timeline.prefix(20) {
                let layer = entry.kind == .episode ? "L2" : "L3"
                print("- \(DateCoding.timeOnly(entry.timestamp)) [\(layer)] \(entry.title) — \(entry.summary)")
            }
        }
        print("")
        print("## Open todos")
        if brief.openTodos.isEmpty {
            print("(none)")
        } else {
            for todo in brief.openTodos.prefix(20) {
                print("- [ ] \(todo.title)  \(todo.id)")
            }
        }
        print("")
        print("## Unread messages")
        if brief.unreadMessages.isEmpty {
            print("(none)")
        } else {
            for message in brief.unreadMessages.prefix(20) {
                print("- \(message.contactName) · \(message.channel): \(TextAnalyzer.truncated(message.text, limit: 160))")
            }
        }
        print("")
        print("## Contacts")
        if brief.contacts.isEmpty {
            print("(none)")
        } else {
            for contact in brief.contacts.prefix(20) {
                print("- \(contact.displayName) · \(contact.messageCount) messages")
            }
        }
    }

    private func runContext(_ service: MemoryService, _ tokens: [String]) throws {
        let args = try CLIArguments(tokens: tokens, valueOptions: ["date"], flagOptions: [])
        guard args.positionals.count <= 1 else { throw CLIError.message("context takes at most one date") }
        let key = args.options["date"] ?? args.positionals.first
        let brief = try service.brief(dayKey: key)
        if jsonOutput {
            print(try Self.jsonString(brief))
        } else {
            print(ContextExporter.markdown(brief), terminator: "")
        }
    }

    private func runDashboard(_ service: MemoryService, _ tokens: [String]) throws {
        let args = try CLIArguments(
            tokens: tokens,
            valueOptions: ["date", "output"],
            flagOptions: ["open"]
        )
        guard args.positionals.count <= 1 else { throw CLIError.message("dashboard takes at most one date") }
        let key = args.options["date"] ?? args.positionals.first
        let brief = try service.brief(dayKey: key)
        let html = DashboardRenderer.render(brief)
        let output: URL
        if let path = args.options["output"] {
            output = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        } else {
            try FileManager.default.createDirectory(
                at: service.paths.exportsDirectory,
                withIntermediateDirectories: true
            )
            output = service.paths.exportsDirectory
                .appendingPathComponent("dashboard-\(brief.date).html")
        }
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try html.write(to: output, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
        if args.flags.contains("open") {
            _ = try? CommandRunner.run(executable: "/usr/bin/open", arguments: [output.path], timeoutSeconds: 5)
        }
        if jsonOutput {
            print(try Self.jsonText([
                "path": output.path,
                "date": brief.date,
                "timeline": brief.timeline.count,
                "open_todos": brief.openTodos.count,
                "unread_messages": brief.unreadMessages.count
            ]))
        } else {
            print("Dashboard written to \(output.path)")
            print("Timeline \(brief.timeline.count) · open todos \(brief.openTodos.count) · unread messages \(brief.unreadMessages.count)")
        }
    }

    private func runTimeline(_ service: MemoryService, _ tokens: [String]) throws {
        let args = try CLIArguments(
            tokens: tokens,
            valueOptions: ["date", "days", "limit"],
            flagOptions: ["no-facts"]
        )
        guard args.positionals.count <= 1 else { throw CLIError.message("timeline takes at most one date") }
        let calendar = Calendar.current
        let key = args.options["date"] ?? args.positionals.first
        let endDay: Date
        if let key {
            guard let parsed = DateCoding.parseDay(key, calendar: calendar) else {
                throw CLIError.message("timeline date must be yyyy-MM-dd")
            }
            endDay = parsed
        } else {
            endDay = calendar.startOfDay(for: Date())
        }
        let days = min(max(args.options["days"].flatMap(Int.init) ?? 1, 1), 90)
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: endDay) ?? endDay
        let end = calendar.date(byAdding: .day, value: 1, to: endDay) ?? endDay.addingTimeInterval(86_400)
        let limit = args.options["limit"].flatMap(Int.init) ?? 300
        let result = try service.timeline(
            in: DateInterval(start: start, end: end),
            includeFacts: !args.flags.contains("no-facts"),
            limit: limit
        )
        if jsonOutput {
            print(try Self.jsonString(result))
            return
        }
        print("Timeline: \(DateCoding.dayKey(start, calendar: calendar)) → \(DateCoding.dayKey(end.addingTimeInterval(-1), calendar: calendar))")
        var currentDay = ""
        for entry in result.entries {
            let day = DateCoding.dayKey(entry.timestamp, calendar: calendar)
            if day != currentDay {
                currentDay = day
                print("\n## \(day)")
            }
            let layer = entry.kind == .episode ? "L2" : "L3"
            print("\(DateCoding.timeOnly(entry.timestamp, calendar: calendar)) [\(layer)] \(entry.title) — \(entry.summary)")
            print("  \(entry.memoryID)")
        }
        if result.entries.isEmpty { print("(no memory entries)") }
    }

    private func runTodos(_ service: MemoryService, _ tokens: [String]) throws {
        let args = try CLIArguments(tokens: tokens, valueOptions: ["status", "limit"], flagOptions: [])
        let status = try todoStatus(args.options["status"]) 
        let limit = args.options["limit"].flatMap(Int.init) ?? 100
        let todos = try service.todos(status: status, limit: limit)
        let payload = try todos.map { try Self.jsonDictionary($0) }
        if jsonOutput {
            print(try Self.jsonText(["count": todos.count, "todos": payload]))
            return
        }
        print("Todos: \(todos.count) (\(args.options["status"] ?? "open"))")
        print("Read-only list. Private Secretary never executes these items.")
        for todo in todos {
            let marker = todo.status == .done ? "x" : (todo.status == .dismissed ? "-" : " ")
            var line = "[\(marker)] \(todo.id)  \(todo.title)"
            if let due = todo.dueAt { line += "  due \(DateCoding.iso(due))" }
            print(line)
        }
    }

    private func runTodo(_ service: MemoryService, _ tokens: [String]) throws {
        guard let action = tokens.first else {
            throw CLIError.message("todo requires add|update|delete")
        }
        let rest = Array(tokens.dropFirst())
        switch action {
        case "add":
            let args = try CLIArguments(tokens: rest, valueOptions: ["detail", "due"], flagOptions: [])
            let title = args.positionals.joined(separator: " ")
            guard !title.isEmpty else { throw CLIError.message("todo add requires a title") }
            let due = try optionalDate(args.options["due"])
            let todo = try service.addTodo(
                title: title,
                detail: args.options["detail"] ?? "",
                dueAt: due
            )
            if jsonOutput {
                print(try Self.jsonString(todo))
            } else {
                print("Added todo \(todo.id): \(todo.title)")
            }
        case "update":
            let args = try CLIArguments(tokens: rest, valueOptions: ["status"], flagOptions: [])
            guard let id = args.positionals.first else { throw CLIError.message("todo update requires a todo_id") }
            guard let raw = args.options["status"],
                  let status = TodoStatus(rawValue: raw.lowercased()) else {
                throw CLIError.message("--status must be open, done, or dismissed")
            }
            guard let todo = try service.updateTodo(id: id, status: status) else {
                throw CLIError.message("Todo not found: \(id)")
            }
            if jsonOutput {
                print(try Self.jsonString(todo))
            } else {
                print("Todo \(todo.id) → \(todo.status.rawValue)")
            }
        case "delete":
            let args = try CLIArguments(tokens: rest, valueOptions: [], flagOptions: [])
            guard let id = args.positionals.first else { throw CLIError.message("todo delete requires a todo_id") }
            guard try service.deleteTodo(id: id) else { throw CLIError.message("Todo not found: \(id)") }
            print("Deleted todo \(id)")
        default:
            throw CLIError.message("todo requires add|update|delete")
        }
    }

    private func runContacts(_ service: MemoryService, _ tokens: [String]) throws {
        let args = try CLIArguments(tokens: tokens, valueOptions: ["query", "limit"], flagOptions: [])
        let contacts = try service.contacts(
            limit: args.options["limit"].flatMap(Int.init) ?? 100,
            query: args.options["query"] ?? args.positionals.joined(separator: " ")
        )
        if jsonOutput {
            print(try Self.jsonString(ContactsResult(contacts: contacts)))
            return
        }
        print("Contacts: \(contacts.count)")
        for contact in contacts {
            let handles = contact.channels.map { "\($0.channel):\($0.handle)" }.joined(separator: ", ")
            let last = contact.lastMessageAt.map { DateCoding.human($0) } ?? "no messages"
            print("\n\(contact.displayName)  [\(contact.id)]")
            if let organization = contact.organization, !organization.isEmpty {
                print("  org: \(organization)")
            }
            if !handles.isEmpty { print("  channels: \(handles)") }
            print("  messages: \(contact.messageCount) · last: \(last)")
            if let snippet = contact.lastMessageSnippet {
                print("  latest: \(TextAnalyzer.truncated(snippet, limit: 120))")
            }
        }
    }

    private func runContact(_ service: MemoryService, _ tokens: [String]) throws {
        if tokens.first == "merge" {
            let args = try CLIArguments(
                tokens: Array(tokens.dropFirst()),
                valueOptions: ["into"],
                flagOptions: []
            )
            guard let sourceID = args.positionals.first,
                  let targetID = args.options["into"], !targetID.isEmpty else {
                throw CLIError.message("contact merge requires <source_id> --into <target_id>")
            }
            guard let contact = try service.mergeContacts(targetID: targetID, sourceID: sourceID) else {
                throw CLIError.message("Contact not found: \(sourceID) or \(targetID)")
            }
            if jsonOutput {
                print(try Self.jsonString(contact))
            } else {
                print("Merged \(sourceID) into \(contact.id) (\(contact.displayName))")
            }
            return
        }
        guard tokens.first == "add" else {
            throw CLIError.message("contact requires add|merge")
        }
        let args = try CLIArguments(
            tokens: Array(tokens.dropFirst()),
            valueOptions: ["name", "org", "note", "channel"],
            flagOptions: []
        )
        guard let name = args.options["name"], !name.isEmpty else {
            throw CLIError.message("contact add requires --name")
        }
        let channels = try parseChannels(args.options["channel"])
        let contact = try service.upsertContact(
            displayName: name,
            organization: args.options["org"],
            notes: args.options["note"],
            channels: channels
        )
        if jsonOutput {
            print(try Self.jsonString(contact))
        } else {
            print("Contact \(contact.id): \(contact.displayName) · \(contact.channels.count) channel(s)")
        }
    }

    private func runMessages(_ service: MemoryService, _ tokens: [String]) throws {
        let args = try CLIArguments(
            tokens: tokens,
            valueOptions: ["channel", "contact", "search", "limit"],
            flagOptions: ["unread"]
        )
        let messages = try service.messages(
            channel: args.options["channel"],
            contactID: args.options["contact"],
            unreadOnly: args.flags.contains("unread"),
            query: args.options["search"],
            limit: args.options["limit"].flatMap(Int.init) ?? 100
        )
        if jsonOutput {
            print(try Self.jsonString(MessagesResult(messages: messages)))
            return
        }
        print("Messages: \(messages.count)")
        for message in messages {
            let direction = message.direction == .inbound ? "←" : "→"
            let unread = message.isRead ? "" : " · unread"
            print("\n\(DateCoding.human(message.timestamp))  \(direction) \(message.contactName) · \(message.channel)\(unread)")
            print("  \(TextAnalyzer.truncated(message.text, limit: 260))")
            print("  \(message.id)")
        }
    }

    private func runMessage(_ service: MemoryService, _ tokens: [String]) throws {
        if tokens.first == "import" {
            let args = try CLIArguments(
                tokens: Array(tokens.dropFirst()),
                valueOptions: ["file", "channel"],
                flagOptions: ["stdin"]
            )
            let data: Data
            if let file = args.options["file"] {
                data = try Data(contentsOf: URL(fileURLWithPath: (file as NSString).expandingTildeInPath))
            } else if args.flags.contains("stdin") {
                data = FileHandle.standardInput.readDataToEndOfFile()
            } else {
                throw CLIError.message("message import requires --file or --stdin")
            }
            let report = try MessageImporter(service: service).importJSON(
                data,
                defaultChannel: args.options["channel"]
            )
            if jsonOutput {
                print(try Self.jsonString(report))
            } else {
                print("Imported \(report.imported) · duplicates \(report.duplicates) · failed \(report.failed)")
                for issue in report.issues {
                    print("  #\(issue.index): \(issue.error)")
                }
            }
            return
        }
        guard tokens.first == "add" || tokens.first == "record" else {
            throw CLIError.message("message requires add|import")
        }
        let args = try CLIArguments(
            tokens: Array(tokens.dropFirst()),
            valueOptions: ["channel", "contact", "handle", "direction", "text", "at", "thread", "external-id"],
            flagOptions: ["read"]
        )
        guard let channel = args.options["channel"], !channel.isEmpty else {
            throw CLIError.message("message add requires --channel")
        }
        guard let contact = args.options["contact"], !contact.isEmpty else {
            throw CLIError.message("message add requires --contact")
        }
        guard let text = args.options["text"], !text.isEmpty else {
            throw CLIError.message("message add requires --text")
        }
        let direction = try parseDirection(args.options["direction"])
        let timestamp = try optionalDate(args.options["at"]) ?? Date()
        let message = try service.recordMessage(
            channel: channel,
            contactName: contact,
            handle: args.options["handle"],
            direction: direction,
            text: text,
            timestamp: timestamp,
            thread: args.options["thread"],
            externalID: args.options["external-id"],
            isRead: args.flags.contains("read") ? true : nil
        )
        if jsonOutput {
            print(try Self.jsonString(message))
        } else {
            print("Recorded (not sent): \(message.id) · \(message.contactName) · \(message.channel)")
        }
    }

    private func todoStatus(_ raw: String?) throws -> TodoStatus? {
        guard let raw, !raw.isEmpty else { return .open }
        if raw.lowercased() == "all" { return nil }
        guard let status = TodoStatus(rawValue: raw.lowercased()) else {
            throw CLIError.message("--status must be open, done, dismissed, or all")
        }
        return status
    }

    private func parseDirection(_ raw: String?) throws -> MessageDirection {
        guard let raw, !raw.isEmpty else { return .inbound }
        guard let direction = MessageDirection(rawValue: raw.lowercased()) else {
            throw CLIError.message("--direction must be inbound or outbound")
        }
        return direction
    }

    private func parseChannels(_ raw: String?) throws -> [ContactChannel] {
        guard let raw, !raw.isEmpty else { return [] }
        return try raw.split(separator: ",").map { part in
            let pieces = part.split(separator: ":", maxSplits: 1).map(String.init)
            guard pieces.count == 2, !pieces[0].isEmpty, !pieces[1].isEmpty else {
                throw CLIError.message("--channel must be kind:handle, comma-separated")
            }
            return ContactChannel(channel: pieces[0], handle: pieces[1])
        }
    }

    private func optionalDate(_ raw: String?) throws -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        guard let date = DateCoding.parseISO(raw) ?? DateCoding.parseDay(raw) else {
            throw CLIError.message("date must be ISO-8601 or yyyy-MM-dd")
        }
        return date
    }

    private func runReview(_ service: MemoryService, _ tokens: [String]) throws {
        guard let action = tokens.first else { throw CLIError.message("review requires list|accept|reject|correct") }
        let rest = Array(tokens.dropFirst())
        if action == "list" {
            let args = try CLIArguments(tokens: rest, valueOptions: ["limit"], flagOptions: [])
            let facts = try service.pendingReviewFacts(limit: args.options["limit"].flatMap(Int.init) ?? 50)
            if jsonOutput {
                print(try Self.jsonString(facts))
            } else if facts.isEmpty {
                print("No facts pending review.")
            } else {
                for fact in facts {
                    print("\(fact.id) · \(fact.statement) · confidence=\(String(format: "%.2f", fact.confidence))")
                }
            }
            return
        }
        guard ["accept", "reject", "correct"].contains(action) else {
            throw CLIError.message("review action must be list, accept, reject, or correct")
        }
        let args = try CLIArguments(tokens: rest, valueOptions: ["statement"], flagOptions: [])
        guard let id = args.positionals.first else { throw CLIError.message("review \(action) requires a fact_id") }
        guard let fact = try service.reviewFact(
            id: id,
            action: action,
            correctedStatement: args.options["statement"]
        ) else {
            throw CLIError.message("Fact not found: \(id)")
        }
        print("Fact \(fact.id) → \(fact.status.rawValue)")
    }

    private func runDoctor(paths: AppPaths, config: AppConfig, service: MemoryService, arguments: [String]) throws {
        let args = try CLIArguments(tokens: arguments, valueOptions: [], flagOptions: [])
        guard args.positionals.isEmpty else { throw CLIError.message("doctor takes no arguments") }
        let report = SystemDiagnostics.run(paths: paths, config: config, store: service.store)
        if jsonOutput {
            print(try Self.jsonString(report))
        } else {
            for check in report.checks {
                let symbol = check.status == "ok" ? "✓" : (check.status == "warn" ? "⚠" : "✗")
                print("\(symbol) \(check.id): \(check.detail)")
            }
            print("\nFailure: \(report.hasFailure)")
        }
        if report.hasFailure {
            throw CLIError.message("Doctor found blocking failures.")
        }
    }

    private func runForget(_ service: MemoryService, _ tokens: [String]) throws {
        let args = try CLIArguments(tokens: tokens, valueOptions: [], flagOptions: [])
        guard let id = args.positionals.first else { throw CLIError.message("forget requires an episode_id") }
        guard try service.store.fetchEpisode(id: id) != nil else {
            throw CLIError.message("Episode not found: \(id)")
        }
        try service.store.deleteEpisode(id: id)
        print("Deleted episode, cold copy (if any), and facts derived only from it: \(id)")
    }

    private func runPurge(_ service: MemoryService, _ tokens: [String]) throws {
        let args = try CLIArguments(tokens: tokens, valueOptions: [], flagOptions: ["all", "yes"])
        guard args.flags.contains("all"), args.flags.contains("yes") else {
            throw CLIError.message("purge is destructive and requires: secretary purge --all --yes")
        }
        guard args.positionals.isEmpty else { throw CLIError.message("purge takes no positional arguments") }
        try service.store.purgeAll()
        print("All memories, todos, contacts, messages, digests, and cold archives have been deleted.")
    }

    private func runSoak(_ tokens: [String]) throws {
        let args = try CLIArguments(
            tokens: tokens,
            valueOptions: ["events", "queries", "days", "seed"],
            flagOptions: ["keep"]
        )
        guard args.positionals.isEmpty else { throw CLIError.message("soak takes no positional arguments") }
        let events = min(max(args.options["events"].flatMap(Int.init) ?? 1_000, 1), 20_000)
        let queryCount = min(max(args.options["queries"].flatMap(Int.init) ?? 50, 1), 1_000)
        let days = min(max(args.options["days"].flatMap(Int.init) ?? 2, 1), 30)
        let seed = args.options["seed"].flatMap(UInt64.init) ?? 0xC0FFEE
        let ephemeral = home == nil && !args.flags.contains("keep")
        let benchmarkHome: URL
        if let home {
            benchmarkHome = home
        } else {
            benchmarkHome = FileManager.default.temporaryDirectory
                .appendingPathComponent("private-secretary-soak-\(UUID().uuidString)", isDirectory: true)
        }
        let benchmarkPaths = AppPaths(home: benchmarkHome)
        try benchmarkPaths.ensureDirectories()
        let benchmarkConfig = try AppConfigLoader.loadOrCreate(paths: benchmarkPaths)
        let benchmarkService = try MemoryService(paths: benchmarkPaths, config: benchmarkConfig)
        let now = Date()
        let calendar = Calendar.current
        var generator = SeededGenerator(seed: seed)
        let templates = [
            "项目 Alpha 的检索实验记录编号 %d：HNSW 参数 ef_search 调整为 %d，召回率随参数变化。",
            "日常笔记编号 %d：整理向量数据库的学习材料和 BM25 权重说明。",
            "终端构建日志编号 %d：npm ERR! code ERESOLVE，依赖树无法解析，需要调整 peer dependency。",
            "会议记录编号 %d：我们决定采用 HNSW 加 BM25 的混合检索方案，并记录参数对比。",
            "客户讨论编号 %d：本周需求评审通过，下一步补充离线记忆和隐私说明。",
            "个人偏好记录编号 %d：我偏好先做关键词过滤，再做语义召回。",
            "学习笔记编号 %d：HNSW 的 M 和 ef_construction 影响索引质量与构建时间。",
            "运行记录编号 %d：测试通过，部署成功，版本标签已经更新。"
        ]
        let apps = ["Xcode", "Terminal", "Safari", "Notes", "TencentMeeting", "Mail", "Figma"]
        let started = Date()
        var accepted = 0
        var todoCount = 0
        var factCount = 0
        for index in 0..<events {
            let template = templates[index % templates.count]
            let unique = "run\(index)-s\(generator.next() % 100_000)"
            let text = String(format: template, index, Int(generator.next() % 1_024)) + " 唯一标记 \(unique)"
            let secondsAgo = Double(generator.next() % UInt64(max(1, days * 86_400)))
            let date = now.addingTimeInterval(-secondsAgo)
            let app = apps[Int(generator.next() % UInt64(apps.count))]
            let result = try benchmarkService.ingest(CandidatePacket(
                capturedAt: date,
                source: .manual,
                audioOrigin: .manual,
                application: app,
                windowTitle: "Stress Window",
                transcript: text
            ), now: date)
            if result.accepted { accepted += 1 }
            todoCount += result.todo == nil ? 0 : 1
            factCount += result.facts.count
        }
        let ingestSeconds = Date().timeIntervalSince(started)
        let queries = [
            "HNSW 参数", "项目 Alpha 检索实验", "构建错误依赖解析", "混合检索方案",
            "客户需求评审", "隐私和记忆", "BM25 权重", "部署成功", "上周的决策", "向量数据库"
        ]
        _ = try benchmarkService.recall(query: "HNSW 参数", now: now)
        var latencies: [Double] = []
        var resultCount = 0
        for index in 0..<queryCount {
            let query = queries[index % queries.count]
            let begin = Date()
            let result = try benchmarkService.recall(query: query, now: now)
            latencies.append(Date().timeIntervalSince(begin) * 1_000)
            resultCount += result.results.count
        }
        latencies.sort()
        func percentile(_ value: Double) -> Double {
            guard !latencies.isEmpty else { return 0 }
            let index = min(latencies.count - 1, Int(Double(latencies.count - 1) * value))
            return latencies[index]
        }
        let p50 = percentile(0.5)
        let p95 = percentile(0.95)
        let maxLatency = latencies.last ?? 0
        let consolidateStarted = Date()
        let report = try benchmarkService.generateDigest(dayKey: DateCoding.dayKey(now), now: now, calendar: calendar)
        let consolidateMilliseconds = Date().timeIntervalSince(consolidateStarted) * 1_000
        let counts = try benchmarkService.store.counts()
        let dbSize = (try? FileManager.default.attributesOfItem(atPath: benchmarkPaths.databaseFile.path)[.size] as? NSNumber)?.intValue ?? 0
        let payload: [String: Any] = [
            "events_requested": events,
            "events_accepted": accepted,
            "events_dropped": events - accepted,
            "todos_created": todoCount,
            "facts_created": factCount,
            "ingest_seconds": ingestSeconds,
            "ingest_per_second": ingestSeconds > 0 ? Double(accepted) / ingestSeconds : 0,
            "queries": queryCount,
            "retrieval_p50_ms": p50,
            "retrieval_p95_ms": p95,
            "retrieval_max_ms": maxLatency,
            "results_returned": resultCount,
            "consolidate_ms": consolidateMilliseconds,
            "memory_counts": try Self.jsonObject(counts),
            "digest_entries": report.digest.entries.count,
            "database_bytes": dbSize,
            "ephemeral_home": ephemeral ? benchmarkPaths.home.path : NSNull(),
            "home": benchmarkPaths.home.path
        ]
        if jsonOutput {
            print(try Self.jsonText(payload))
        } else {
            print("Soak: \(accepted)/\(events) events accepted in \(String(format: "%.2f", ingestSeconds))s (\(String(format: "%.0f", Double(accepted) / max(ingestSeconds, 0.001)))/s)")
            print("Retrieval: p50 \(String(format: "%.1f", p50)) ms · p95 \(String(format: "%.1f", p95)) ms · max \(String(format: "%.1f", maxLatency)) ms over \(queryCount) queries")
            print("Memory: \(counts.episodes) episodes · \(counts.activeFacts) facts · \(counts.openTodos) open todos · \(counts.messages) messages · digest entries \(report.digest.entries.count)")
            print("Database: \(dbSize / 1_024) KiB · consolidation \(String(format: "%.0f", consolidateMilliseconds)) ms")
            print("Home: \(benchmarkPaths.home.path)")
        }
        if ephemeral {
            try? FileManager.default.removeItem(at: benchmarkPaths.home)
        }
    }

    private static func jsonObject<T: Encodable>(_ value: T) throws -> Any {
        let data = try JSONCoding.encoder().encode(value)
        return try JSONSerialization.jsonObject(with: data)
    }

    private static func jsonDictionary<T: Encodable>(_ value: T) throws -> [String: Any] {
        let object = try jsonObject(value)
        guard let dictionary = object as? [String: Any] else {
            throw CLIError.message("Expected a JSON object")
        }
        return dictionary
    }

    private func runDemo(_ tokens: [String]) throws {
        let args = try CLIArguments(tokens: tokens, valueOptions: [], flagOptions: [])
        guard args.positionals.isEmpty else { throw CLIError.message("demo takes no arguments") }
        let paths = AppPaths(home: home)
        let config = try AppConfigLoader.loadOrCreate(paths: paths)
        let service = try MemoryService(paths: paths, config: config)
        let seeded = try DemoScenario.seedIfNeeded(service: service)
        if jsonOutput {
            print(try Self.jsonString(seeded.digest))
            return
        }
        if !seeded.seeded {
            print("Demo already seeded at this home. Showing today's digest.")
        } else {
            let counts = try service.store.counts()
            print("✓ Seeded \(seeded.results.filter(\.accepted).count) episodes and \(seeded.results.reduce(0) { $0 + ($1.todo == nil ? 0 : 1) }) todos.")
            print("✓ Aggregated \(counts.contacts) contacts and \(counts.messages) messages across email, Lark, WeChat and Telegram.")
            print("✓ Generated today's digest with memory_id indexes.")
        }
        print("")
        print(seeded.digest?.markdown ?? "No digest yet.")
        print("""

        Try:
          secretary recall "视频里 HNSW 参数说了什么"
          secretary recall "上周三决定的方案" --layer L3
          secretary todos
          secretary timeline
          secretary contacts
          secretary messages
          secretary drill <memory_id>
        """)
    }

    private func parseOrigin(_ raw: String?) throws -> AudioOrigin? {
        guard let raw else { return nil }
        guard let origin = AudioOrigin(rawValue: raw) else {
            throw CLIError.message("--origin must be manual, microphone, system, or mixed")
        }
        return origin
    }

    private func parseSource(_ raw: String?) throws -> CandidateSource? {
        guard let raw else { return nil }
        guard let source = CandidateSource(rawValue: raw) else {
            throw CLIError.message("--source must be manual, audio, screen, or combined")
        }
        return source
    }

    private func parseLayer(_ raw: String?) throws -> MemoryLayer? {
        guard let raw else { return nil }
        switch raw.uppercased() {
        case "L2": return .l2
        case "L3": return .l3
        case "ALL": return nil
        default: throw CLIError.message("--layer must be L2, L3, or all")
        }
    }

    private static func parseDate(_ string: String) -> Date? {
        DateCoding.parseISO(string) ?? DateCoding.parseDay(string)
    }

    private static func parseDateEnd(_ string: String) -> Date? {
        if let date = DateCoding.parseISO(string) { return date }
        if let day = DateCoding.parseDay(string) {
            return Calendar.current.date(byAdding: .day, value: 1, to: day)
        }
        return nil
    }

    private static func jsonString<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONCoding.encoder(pretty: true).encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    private static func jsonText(_ object: Any) throws -> String {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw CLIError.message("Cannot serialize JSON response")
        }
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        return String(decoding: data, as: UTF8.self)
    }
}


private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
