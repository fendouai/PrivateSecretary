import Foundation

public struct EmailScreenMessage: Equatable, Sendable {
    public var contactName: String
    public var handle: String?
    public var subject: String
    public var timestamp: Date
    public var externalID: String

    public init(contactName: String, handle: String?, subject: String, timestamp: Date, externalID: String) {
        self.contactName = contactName
        self.handle = handle
        self.subject = subject
        self.timestamp = timestamp
        self.externalID = externalID
    }
}

/// Extracts visible Gmail inbox rows from OCR regions. This is deliberately
/// conservative: it only recognizes Gmail window titles and inbox-style
/// sender/subject/time rows, never reads other applications or sends anything.
public enum EmailScreenExtractor {
    public static func isGmail(windowTitle: String?, ocrText: String) -> Bool {
        let title = (windowTitle ?? "").lowercased()
        if title.contains("gmail") { return true }
        let text = ocrText.lowercased()
        return text.contains("mail.google.com") || (text.contains("gmail") && text.contains("收件箱"))
    }

    public static func extract(
        windowTitle: String?,
        ocrText: String,
        regions: [OCRRegion],
        now: Date = Date(),
        calendar: Calendar = .current,
        limit: Int = 30
    ) -> [EmailScreenMessage] {
        guard isGmail(windowTitle: windowTitle, ocrText: ocrText), !regions.isEmpty else { return [] }
        let timeRegions = regions.compactMap { region -> (OCRRegion, GmailTime)? in
            guard region.x >= 0.90,
                  region.y >= 0.24,
                  region.y < 0.96,
                  let parsed = parseTime(region.text, now: now, calendar: calendar) else { return nil }
            return (region, parsed)
        }
        guard !timeRegions.isEmpty else { return [] }

        var result: [EmailScreenMessage] = []
        var seen = Set<String>()
        for (timeRegion, time) in timeRegions.sorted(by: { $0.0.y < $1.0.y }) {
            let rowRegions = regions.filter { abs($0.y - timeRegion.y) <= 0.012 }
            let sender = senderText(in: rowRegions, timeRegion: timeRegion)
            let subject = subjectText(in: rowRegions, timeRegion: timeRegion)
            guard let sender, let subject, !subject.isEmpty else { continue }
            let handle = emailHandle(in: sender)
            let displayName = sender.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !displayName.isEmpty else { continue }
            let key = dedupeKey(sender: displayName, subject: subject, time: timeRegion.text)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(EmailScreenMessage(
                contactName: displayName,
                handle: handle,
                subject: subject,
                timestamp: time.date,
                externalID: key
            ))
            if result.count >= max(1, min(limit, 100)) { break }
        }
        return result
    }

    private struct GmailTime {
        var date: Date
    }

    private static func senderText(in row: [OCRRegion], timeRegion: OCRRegion) -> String? {
        let candidates = row.filter { region in
            region.x >= 0.20 && region.x < 0.36 &&
            region.width < 0.16 &&
            region.text.count >= 2 &&
            abs(region.y - timeRegion.y) <= 0.012
        }
        let text = candidates.min(by: { abs($0.x - 0.25) < abs($1.x - 0.25) })?.text
        return clean(text)
    }

    private static func subjectText(in row: [OCRRegion], timeRegion: OCRRegion) -> String? {
        let candidates = row
            .filter { $0.x >= 0.35 && $0.x < 0.90 && $0.text.count >= 2 }
            .sorted { $0.x < $1.x }
        let text = candidates.map(\.text).joined(separator: " ")
        return clean(text)
    }

    private static func clean(_ text: String?) -> String? {
        guard var value = text?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        value = value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "-—| "))
        let blocked = ["写邮件", "收件箱", "已加星标", "已延后", "重要邮件", "已发邮件", "草稿", "购物", "动态", "论坛", "推广", "标签", "显示更多标签", "搜索邮件"]
        guard !blocked.contains(where: { value == $0 || value.hasPrefix($0 + " ") }) else { return nil }
        return TextAnalyzer.truncated(value, limit: 600)
    }

    private static func emailHandle(in sender: String) -> String? {
        let pattern = #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: sender, range: NSRange(sender.startIndex..., in: sender)) else {
            return nil
        }
        guard let range = Range(match.range, in: sender) else { return nil }
        return String(sender[range]).lowercased()
    }

    private static func parseTime(_ raw: String, now: Date, calendar: Calendar) -> GmailTime? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = text.split(separator: ":")
        if parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
           (0...23).contains(hour), (0...59).contains(minute) {
            let start = calendar.startOfDay(for: now)
            var date = calendar.date(byAdding: .minute, value: hour * 60 + minute, to: start) ?? now
            if date > now.addingTimeInterval(300) {
                date = calendar.date(byAdding: .day, value: -1, to: date) ?? date
            }
            return GmailTime(date: date)
        }
        let monthDay = text.replacingOccurrences(of: " ", with: "")
        let pattern = #"^(\d{1,2})月(\d{1,2})日$"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: monthDay, range: NSRange(monthDay.startIndex..., in: monthDay)),
           let monthRange = Range(match.range(at: 1), in: monthDay),
           let dayRange = Range(match.range(at: 2), in: monthDay),
           let month = Int(monthDay[monthRange]), let day = Int(monthDay[dayRange]),
           (1...12).contains(month), (1...31).contains(day) {
            var components = calendar.dateComponents([.year], from: now)
            components.month = month
            components.day = day
            components.hour = 9
            var date = calendar.date(from: components) ?? now
            if date > now.addingTimeInterval(86_400) {
                components.year = (components.year ?? 0) - 1
                date = calendar.date(from: components) ?? date
            }
            return GmailTime(date: date)
        }
        if text == "昨天" {
            return GmailTime(date: calendar.date(byAdding: .day, value: -1, to: now) ?? now)
        }
        return nil
    }

    private static func dedupeKey(sender: String, subject: String, time: String) -> String {
        let value = "gmail-screen|\(sender.lowercased())|\(subject.lowercased())|\(time)"
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "gmail-screen-%016llx", hash)
    }
}
