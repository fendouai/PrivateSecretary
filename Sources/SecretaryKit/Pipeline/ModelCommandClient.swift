import Foundation

public struct ModelIntentOutput: Codable, Equatable, Sendable {
    public var classification: IntentClassification
    public var confidence: Double
    public var intentType: IntentType?
    public var routedText: String

    enum CodingKeys: String, CodingKey {
        case classification
        case confidence
        case intentType = "intent_type"
        case routedText = "routed_text"
    }

    public init(
        classification: IntentClassification,
        confidence: Double,
        intentType: IntentType?,
        routedText: String
    ) {
        self.classification = classification
        self.confidence = min(1, max(0, confidence))
        self.intentType = intentType
        self.routedText = routedText
    }
}

public protocol IntentClassifying: Sendable {
    func classify(text: String, context: [String: String]) throws -> ModelIntentOutput?
    var name: String { get }
}

public final class ModelCommandClient: @unchecked Sendable, IntentClassifying {
    public let config: CommandModelConfig

    public init(config: CommandModelConfig) {
        self.config = config
    }

    public var name: String {
        guard config.enabled, !config.executable.isEmpty else { return "rules" }
        return "command:\(config.executable)"
    }

    public func classify(text: String, context: [String: String]) throws -> ModelIntentOutput? {
        guard config.enabled, !config.executable.isEmpty else { return nil }
        var payload: [String: Any] = [
            "task": "classify_intent",
            "version": 1,
            "text": text
        ]
        for (key, value) in context { payload[key] = value }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let result = try CommandRunner.run(
            executable: config.executable,
            arguments: config.arguments,
            stdin: data,
            timeoutSeconds: config.timeoutSeconds,
            maxOutputBytes: config.maxOutputBytes
        )
        guard result.exitCode == 0 else {
            throw CommandRunnerError.nonZeroExit(code: result.exitCode, stderr: result.stderrString)
        }
        return try JSONCoding.decoder().decode(ModelIntentOutput.self, from: result.stdout)
    }

    public func extractFacts(from episode: Episode) throws -> [FactCandidate] {
        guard config.enabled, !config.executable.isEmpty else { return [] }
        let payload: [String: Any] = [
            "task": "extract_facts",
            "version": 1,
            "episode": [
                "id": episode.id,
                "timestamp": DateCoding.iso(episode.startedAt),
                "application": episode.application ?? "",
                "window_title": episode.windowTitle ?? "",
                "transcript": episode.transcript,
                "ocr_text": episode.ocrText,
                "source": episode.source.rawValue
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let result = try CommandRunner.run(
            executable: config.executable,
            arguments: config.arguments,
            stdin: data,
            timeoutSeconds: config.timeoutSeconds,
            maxOutputBytes: config.maxOutputBytes
        )
        guard result.exitCode == 0 else {
            throw CommandRunnerError.nonZeroExit(code: result.exitCode, stderr: result.stderrString)
        }
        struct Response: Decodable { var facts: [ModelFact] }
        struct ModelFact: Decodable {
            var kind: String
            var subject: String?
            var predicate: String?
            var object: String?
            var statement: String
            var confidence: Double?
            var keywords: [String]?
        }
        let response = try JSONCoding.decoder().decode(Response.self, from: result.stdout)
        return response.facts.prefix(12).compactMap { raw in
            let statement = raw.statement.trimmingCharacters(in: .whitespacesAndNewlines)
            guard statement.count >= 3, statement.count <= 320 else { return nil }
            if TextAnalyzer.containsPromptInjection(statement) { return nil }
            return FactCandidate(
                kind: FactKind(rawValue: raw.kind) ?? .fact,
                subject: raw.subject ?? "未知",
                predicate: raw.predicate ?? raw.kind,
                object: raw.object ?? statement,
                statement: statement,
                confidence: raw.confidence ?? 0.75,
                keywords: raw.keywords ?? TextAnalyzer.keywords(statement, limit: 6)
            )
        }
    }
}

extension ModelCommandClient: TimelineModelExtracting {
    public func extractTodos(from episode: Episode) throws -> [TimelineTodoCandidate] {
        guard config.enabled, !config.executable.isEmpty else { return [] }
        let payload: [String: Any] = [
            "task": "extract_todos",
            "version": 1,
            "episode": [
                "id": episode.id,
                "timestamp": DateCoding.iso(episode.startedAt),
                "application": episode.application ?? "",
                "window_title": episode.windowTitle ?? "",
                "transcript": episode.transcript,
                "ocr_text": episode.ocrText,
                "source": episode.source.rawValue
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let result = try CommandRunner.run(
            executable: config.executable,
            arguments: config.arguments,
            stdin: data,
            timeoutSeconds: config.timeoutSeconds,
            maxOutputBytes: config.maxOutputBytes
        )
        guard result.exitCode == 0 else {
            throw CommandRunnerError.nonZeroExit(code: result.exitCode, stderr: result.stderrString)
        }
        struct Response: Decodable { var todos: [Item] }
        struct Item: Decodable {
            var title: String
            var detail: String?
            var due_at: String?
            var confidence: Double?
            var evidence: String?
        }
        let response = try JSONCoding.decoder().decode(Response.self, from: result.stdout)
        return response.todos.prefix(8).map {
            TimelineTodoCandidate(
                title: $0.title.trimmingCharacters(in: .whitespacesAndNewlines),
                detail: $0.detail ?? "",
                dueDate: $0.due_at,
                confidence: $0.confidence ?? 0.7,
                evidence: $0.evidence ?? ""
            )
        }
    }

    public func extractMessages(from episode: Episode) throws -> [TimelineMessageCandidate] {
        guard config.enabled, !config.executable.isEmpty else { return [] }
        let payload: [String: Any] = [
            "task": "extract_messages",
            "version": 1,
            "episode": [
                "id": episode.id,
                "timestamp": DateCoding.iso(episode.startedAt),
                "application": episode.application ?? "",
                "window_title": episode.windowTitle ?? "",
                "transcript": episode.transcript,
                "ocr_text": episode.ocrText,
                "source": episode.source.rawValue
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let result = try CommandRunner.run(
            executable: config.executable,
            arguments: config.arguments,
            stdin: data,
            timeoutSeconds: config.timeoutSeconds,
            maxOutputBytes: config.maxOutputBytes
        )
        guard result.exitCode == 0 else {
            throw CommandRunnerError.nonZeroExit(code: result.exitCode, stderr: result.stderrString)
        }
        struct Response: Decodable { var messages: [Item] }
        struct Item: Decodable {
            var channel: String
            var contact: String
            var handle: String?
            var direction: String?
            var text: String
            var confidence: Double?
        }
        let response = try JSONCoding.decoder().decode(Response.self, from: result.stdout)
        return response.messages.prefix(12).compactMap { item in
            let contact = item.contact.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard contact.count >= 2, text.count >= 2 else { return nil }
            return TimelineMessageCandidate(
                channel: item.channel,
                contactName: contact,
                handle: item.handle,
                direction: MessageDirection(rawValue: item.direction ?? "") ?? .inbound,
                text: text,
                confidence: item.confidence ?? 0.7
            )
        }
    }
}
