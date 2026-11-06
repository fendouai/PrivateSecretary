import Foundation

/// Batch importer for local channel adapters. Accepts a JSON array, a JSON
/// object with a `messages` array, a single object, or newline-delimited JSON.
/// Each record is archived; nothing is sent.
public final class MessageImporter: @unchecked Sendable {
    private let service: MemoryService

    public init(service: MemoryService) {
        self.service = service
    }

    public func importJSON(_ data: Data, defaultChannel: String? = nil, now: Date = Date()) throws -> MessageImportReport {
        let objects = try parseObjects(data)
        guard !objects.isEmpty else {
            throw MemoryServiceError.invalidArgument("no message objects found")
        }
        var report = MessageImportReport()
        for (offset, object) in objects.enumerated() {
            do {
                let result = try service.store.recordMessageWithStatus(
                    channel: try string(object, ["channel"]) ?? defaultChannel ?? "",
                    contactName: try string(object, ["contact_name", "contact", "name"]) ?? "",
                    handle: try string(object, ["handle"]),
                    direction: try direction(object["direction"]),
                    text: try string(object, ["text", "body", "content", "message"]) ?? "",
                    timestamp: try date(object["timestamp"] ?? object["at"] ?? object["date"], fallback: now),
                    thread: try string(object, ["thread"]),
                    externalID: try string(object, ["external_id", "externalId"]),
                    isRead: object["is_read"] as? Bool,
                    now: now
                )
                if result.inserted { report.imported += 1 } else { report.duplicates += 1 }
            } catch {
                report.failed += 1
                if report.issues.count < 50 {
                    report.issues.append(MessageImportIssue(
                        index: offset + 1,
                        error: error.localizedDescription
                    ))
                }
            }
        }
        return report
    }

    private func parseObjects(_ data: Data) throws -> [[String: Any]] {
        if let object = try? JSONSerialization.jsonObject(with: data) {
            if let array = object as? [[String: Any]] {
                return array
            }
            if let dictionary = object as? [String: Any] {
                if let messages = dictionary["messages"] as? [[String: Any]] {
                    return messages
                }
                return [dictionary]
            }
            throw MemoryServiceError.invalidArgument("message import root must be an object or array")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw MemoryServiceError.invalidArgument("message import must be UTF-8 JSON or JSONL")
        }
        var objects: [[String: Any]] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            guard let lineData = trimmed.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                throw MemoryServiceError.invalidArgument("invalid JSONL message record")
            }
            objects.append(object)
        }
        return objects
    }

    private func string(_ object: [String: Any], _ keys: [String]) throws -> String? {
        for key in keys {
            if let value = object[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }

    private func direction(_ value: Any?) throws -> MessageDirection {
        guard let raw = value as? String else { return .inbound }
        guard let direction = MessageDirection(rawValue: raw.lowercased()) else {
            throw MemoryServiceError.invalidArgument("direction must be inbound or outbound")
        }
        return direction
    }

    private func date(_ value: Any?, fallback: Date) throws -> Date {
        guard let value else { return fallback }
        guard let string = value as? String, !string.isEmpty else {
            throw MemoryServiceError.invalidArgument("timestamp must be an ISO-8601 string")
        }
        guard let date = DateCoding.parseISO(string) ?? DateCoding.parseDay(string) else {
            throw MemoryServiceError.invalidArgument("timestamp must be ISO-8601 or yyyy-MM-dd")
        }
        return date
    }
}
