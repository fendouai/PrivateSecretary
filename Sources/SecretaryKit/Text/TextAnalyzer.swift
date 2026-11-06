import Foundation

public enum TextAnalyzer {
    public static let englishStopwords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "if", "then", "than", "to", "of", "for",
        "in", "on", "at", "by", "with", "from", "as", "is", "are", "was", "were", "be",
        "been", "being", "it", "its", "this", "that", "these", "those", "i", "you", "we",
        "they", "he", "she", "my", "your", "our", "their", "me", "us", "them", "do", "did",
        "does", "have", "has", "had", "not", "no", "yes", "so", "just", "about", "into",
        "over", "after", "before", "can", "could", "would", "should", "will", "may", "might",
        "what", "when", "where", "which", "who", "how", "why", "there", "here"
    ]

    public static func normalize(_ text: String) -> String {
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        var scalars: [Unicode.Scalar] = []
        var lastWasSpace = false
        for scalar in folded.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar)
                || CharacterSet.controlCharacters.contains(scalar) {
                if !lastWasSpace {
                    scalars.append(" ")
                    lastWasSpace = true
                }
            } else {
                scalars.append(scalar)
                lastWasSpace = false
            }
        }
        return String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
             0x20000...0x2FA1F, 0x3040...0x30FF, 0xAC00...0xD7AF:
            return true
        default:
            return false
        }
    }

    public static func tokens(_ text: String, includeCJKUnigrams: Bool = false) -> [String] {
        let normalized = normalize(text)
        var result: [String] = []
        var latin = ""
        var cjkRun: [Unicode.Scalar] = []

        func flushLatin() {
            if !latin.isEmpty {
                let word = latin.lowercased()
                if !englishStopwords.contains(word) || word.count <= 1 {
                    result.append(word)
                }
                latin = ""
            }
        }

        func flushCJK() {
            guard !cjkRun.isEmpty else { return }
            if cjkRun.count == 1 {
                result.append(String(cjkRun[0]))
            } else {
                if includeCJKUnigrams {
                    result.append(contentsOf: cjkRun.map { String($0) })
                }
                for index in 0..<(cjkRun.count - 1) {
                    result.append(String(cjkRun[index]) + String(cjkRun[index + 1]))
                }
            }
            cjkRun.removeAll(keepingCapacity: true)
        }

        for scalar in normalized.unicodeScalars {
            if isCJK(scalar) {
                flushLatin()
                cjkRun.append(scalar)
            } else if CharacterSet.alphanumerics.contains(scalar) {
                flushCJK()
                latin.unicodeScalars.append(scalar)
            } else {
                flushLatin()
                flushCJK()
            }
        }
        flushLatin()
        flushCJK()
        return result.filter { !$0.isEmpty }
    }

    public static func keywordSet(_ text: String) -> Set<String> {
        Set(tokens(text))
    }

    public static func keywords(_ text: String, limit: Int = 8) -> [String] {
        var counts: [String: Int] = [:]
        for token in tokens(text) where token.count > 1 {
            counts[token, default: 0] += 1
        }
        return counts.sorted {
            if $0.value == $1.value { return $0.key < $1.key }
            return $0.value > $1.value
        }.prefix(limit).map(\.key)
    }

    public static func jaccard(_ lhs: String, _ rhs: String) -> Double {
        let left = keywordSet(lhs)
        let right = keywordSet(rhs)
        if left.isEmpty && right.isEmpty { return 1 }
        return Double(left.intersection(right).count) / Double(left.union(right).count)
    }

    public static func sentences(_ text: String) -> [String] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var sentences: [String] = []
        var current = ""
        let characters = Array(normalized)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\n" {
                appendSentence(&sentences, current)
                current = ""
            } else if "。！？!?；;".contains(character) {
                current.append(character)
                appendSentence(&sentences, current)
                current = ""
            } else if character == "." {
                let next = index + 1 < characters.count ? characters[index + 1] : " "
                if next == " " || next == "\n" || index + 1 == characters.count {
                    appendSentence(&sentences, current)
                    current = ""
                } else {
                    current.append(character)
                }
            } else {
                current.append(character)
            }
            index += 1
        }
        appendSentence(&sentences, current)
        return sentences
    }

    private static func appendSentence(_ result: inout [String], _ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { result.append(trimmed) }
    }

    public static func truncated(_ text: String, limit: Int) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\u{0000}", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        let end = collapsed.index(collapsed.startIndex, offsetBy: max(0, limit - 1))
        return String(collapsed[..<end]).trimmingCharacters(in: .whitespaces) + "…"
    }

    public static func summary(_ text: String, limit: Int = 220) -> String {
        let sentences = sentences(text)
        var result = ""
        for sentence in sentences {
            let candidate = result.isEmpty ? sentence : result + " " + sentence
            if candidate.count > limit { break }
            result = candidate
        }
        if result.isEmpty { result = text }
        return truncated(result, limit: limit)
    }

    public static func meaningfulCharacterRatio(_ text: String) -> Double {
        let scalars = Array(text.unicodeScalars)
        guard !scalars.isEmpty else { return 0 }
        let meaningful = scalars.filter {
            CharacterSet.alphanumerics.contains($0) || isCJK($0)
        }.count
        return Double(meaningful) / Double(scalars.count)
    }

    public static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: isCJK)
    }

    public static let injectionPatterns: [String] = [
        #"(?i)ignore\s+(all\s+)?(previous|prior|above)\s+(instructions?|rules?|prompts?)"#,
        #"(?i)disregard\s+(all\s+)?(previous|prior|above)"#,
        #"(?i)(system|developer)\s+(prompt|message|instructions?)"#,
        #"(?i)you\s+are\s+now\s+(a|an)\s+"#,
        #"(?i)(call|invoke|execute)\s+(the\s+)?(tool|function|command)"#,
        #"忽略(之前|以上|前面|先前)(的)?(所有)?(指令|要求|规则)"#,
        #"无视(之前|以上|前面|先前)(的)?(指令|要求|规则)"#,
        #"执行以下(指令|命令)"#,
        #"现在你是"#,
        #"系统提示词"#,
        #"调用(工具|函数|命令)"#
    ]

    public static func containsPromptInjection(_ text: String) -> Bool {
        for pattern in injectionPatterns {
            if text.range(of: pattern, options: .regularExpression) != nil {
                return true
            }
        }
        return false
    }

    public static func hasErrorSignal(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let signals = [
            " error", "error:", "err!", "npm err", "exception", "traceback", "failed", "failure",
            "fatal", "could not resolve", "unable to resolve",
            "报错", "错误", "失败", "崩溃", "异常", "无法", "不兼容", "超时"
        ]
        return signals.contains { lowered.contains($0) }
    }

    public static func hasRewardSignal(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let signals = [
            "success", "succeeded", "passed", "completed", "approved", "great", "nice",
            "成功", "通过", "完成", "解决了", "搞定", "太好了", "已合并"
        ]
        return signals.contains { lowered.contains($0) }
    }

    public static func hasEmotionSignal(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let signals = [
            "worried", "urgent", "frustrated", "angry", "excited", "important", "asap",
            "担心", "紧急", "焦虑", "生气", "重要", "尽快", "崩溃", "太好了", "麻烦"
        ]
        return signals.contains { lowered.contains($0) }
    }

    public static func hasExplicitIntentCue(_ text: String) -> Bool {
        let lowered = normalize(text)
        let cues = [
            "帮我记", "记一下", "记录一下", "帮我记录", "给我记", "记个待办", "建个待办",
            "创建待办", "加个待办", "提醒我", "到时候提醒", "跟踪一下", "跟踪这个", "跟进一下",
            "帮我发", "帮我删", "帮我改", "帮我上传", "帮我同步",
            "帮我跟踪", "帮我跟进", "别忘", "请记住",
            "remind me", "remember to", "note this", "make a note", "add a todo",
            "track this", "follow up on", "don't forget", "please remember"
        ]
        return cues.contains { lowered.contains($0) }
    }

    public static func hasUncertainIntentCue(_ text: String) -> Bool {
        let lowered = normalize(text)
        let cues = [
            "以后再说", "待会儿", "回头", "可能要", "也许要", "考虑一下", "想想",
            "should probably", "maybe later", "might need", "think about", "later on"
        ]
        return cues.contains { lowered.contains($0) }
    }
}

public struct ParsedTemporalQuery: Equatable, Sendable {
    public var query: String
    public var range: DateInterval?
    public var matchedExpression: String?

    public init(query: String, range: DateInterval?, matchedExpression: String? = nil) {
        self.query = query
        self.range = range
        self.matchedExpression = matchedExpression
    }
}

public enum QueryTimeParser {
    private static let weekdayMap: [Character: Int] = [
        "一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "日": 7, "天": 7
    ]

    public static func parse(
        _ rawQuery: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> ParsedTemporalQuery {
        var query = rawQuery
        var range: DateInterval?
        var matched: String?

        // Relative instants first: "刚才" is more specific than any day phrase.
        if let phrase = firstMatch(in: query, patterns: ["刚才", "刚刚", "just now"]) {
            range = DateInterval(start: now.addingTimeInterval(-2 * 3600), end: now.addingTimeInterval(1))
            matched = phrase
            query = remove(phrase, from: query)
            return finish(query: query, range: range, matched: matched)
        }

        var dayAnchor: Date?
        let dayPatterns: [(String, Int)] = [
            (#"今天|今日|today"#, 0),
            (#"昨天|昨日|yesterday"#, -1),
            (#"前天"#, -2),
            (#"明天|tomorrow"#, 1)
        ]
        for (pattern, offset) in dayPatterns {
            if let found = firstRegexMatch(in: query, pattern: pattern) {
                dayAnchor = calendar.date(byAdding: .day, value: offset, to: now)
                matched = found
                query = remove(found, from: query)
                break
            }
        }

        if dayAnchor == nil, let found = firstRegexMatch(in: query, pattern: #"上周[一二三四五六日天]|上个?星期[一二三四五六日天]"#) {
            let weekdayChar = found.last ?? "一"
            dayAnchor = weekdayDate(
                weekday: weekdayMap[weekdayChar] ?? 1,
                weekOffset: -1,
                now: now,
                calendar: calendar
            )
            matched = matched ?? found
            query = remove(found, from: query)
        }

        if dayAnchor == nil, let found = firstRegexMatch(in: query, pattern: #"(?i)last\s+(monday|tuesday|wednesday|thursday|friday|saturday|sunday)"#) {
            let weekday = englishWeekday(found)
            dayAnchor = weekdayDate(weekday: weekday, weekOffset: -1, now: now, calendar: calendar)
            matched = matched ?? found
            query = remove(found, from: query)
        }

        if dayAnchor == nil, let found = firstRegexMatch(in: query, pattern: #"上周|上个星期|last\s+week"#) {
            let thisWeek = mondayStart(for: now, calendar: calendar)
            let previousWeek = calendar.date(byAdding: .day, value: -7, to: thisWeek) ?? thisWeek
            let end = calendar.date(byAdding: .day, value: 7, to: previousWeek) ?? previousWeek
            range = DateInterval(start: previousWeek, end: end)
            matched = found
            query = remove(found, from: query)
        }

        if range == nil, dayAnchor == nil, let found = firstRegexMatch(in: query, pattern: #"这周|本周|这个星期|this\s+week"#) {
            let thisWeek = mondayStart(for: now, calendar: calendar)
            let end = calendar.date(byAdding: .day, value: 7, to: thisWeek) ?? thisWeek
            range = DateInterval(start: thisWeek, end: end)
            matched = found
            query = remove(found, from: query)
        }

        if range == nil, dayAnchor == nil, let found = firstRegexMatch(in: query, pattern: #"(?<!上)(?:周|星期)[一二三四五六日天]"#) {
            let weekdayChar = found.last ?? "一"
            var target = weekdayDate(
                weekday: weekdayMap[weekdayChar] ?? 1,
                weekOffset: 0,
                now: now,
                calendar: calendar
            )
            if target > now {
                target = calendar.date(byAdding: .day, value: -7, to: target) ?? target
            }
            dayAnchor = target
            matched = matched ?? found
            query = remove(found, from: query)
        }

        if dayAnchor == nil, range == nil,
           let found = firstRegexMatch(in: query, pattern: #"\b\d{4}-\d{2}-\d{2}\b"#),
           let date = DateCoding.parseDay(found, calendar: calendar) {
            dayAnchor = date
            matched = matched ?? found
            query = remove(found, from: query)
        }

        if dayAnchor == nil, range == nil,
           let found = firstRegexMatch(in: query, pattern: #"(\d{1,2})月(\d{1,2})日"#) {
            if let parsed = parseChineseMonthDay(found, now: now, calendar: calendar) {
                dayAnchor = parsed
                matched = matched ?? found
                query = remove(found, from: query)
            }
        }

        // Time of day narrows the selected day. "下午" alone means today afternoon.
        let periods: [(String, Int, Int)] = [
            (#"凌晨"#, 0, 6),
            (#"早上|早晨|上午"#, 6, 12),
            (#"中午|中午时分"#, 11, 14),
            (#"下午|afternoon"#, 12, 18),
            (#"傍晚"#, 17, 20),
            (#"晚上|夜里|tonight"#, 18, 24),
            (#"(?i)this\s+morning|morning"#, 6, 12)
        ]

        var period: (start: Int, end: Int)?
        for (pattern, start, end) in periods {
            if let found = firstRegexMatch(in: query, pattern: pattern) {
                period = (start, end)
                matched = matched ?? found
                query = remove(found, from: query)
                break
            }
        }

        if let base = dayAnchor ?? (range == nil && period != nil ? now : nil) {
            var day = DateCoding.dayInterval(for: base, calendar: calendar)
            if let period {
                let start = calendar.date(byAdding: .hour, value: period.start, to: day.start) ?? day.start
                let end: Date
                if period.end >= 24 {
                    end = day.end
                } else {
                    end = calendar.date(byAdding: .hour, value: period.end, to: day.start) ?? day.end
                }
                day = DateInterval(start: start, end: minDate(end, day.end))
            }
            range = day
        }

        return finish(query: query, range: range, matched: matched)
    }

    private static func finish(query: String, range: DateInterval?, matched: String?) -> ParsedTemporalQuery {
        var cleaned = query
        cleaned = cleaned.replacingOccurrences(
            of: #"^[\s,，。.!！?？:：;；-]+|[\s,，。.!！?？:：;；-]+$"#,
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        if cleaned.isEmpty { cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines) }
        return ParsedTemporalQuery(query: cleaned, range: range, matchedExpression: matched)
    }

    private static func firstMatch(in text: String, patterns: [String]) -> String? {
        for pattern in patterns {
            if let found = firstRegexMatch(in: text, pattern: pattern) { return found }
        }
        return nil
    }

    private static func firstRegexMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let swiftRange = Range(match.range, in: text) else { return nil }
        return String(text[swiftRange])
    }

    private static func remove(_ fragment: String, from text: String) -> String {
        guard !fragment.isEmpty else { return text }
        return text.replacingOccurrences(of: fragment, with: " ", options: [.caseInsensitive])
    }

    private static func englishWeekday(_ phrase: String) -> Int {
        let lowered = phrase.lowercased()
        let names = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
        if let index = names.firstIndex(where: { lowered.contains($0) }) {
            return index + 1
        }
        return 1
    }

    private static func mondayStart(for date: Date, calendar: Calendar) -> Date {
        var localCalendar = calendar
        localCalendar.firstWeekday = 2
        let interval = localCalendar.dateInterval(of: .weekOfYear, for: date)
        return interval?.start ?? localCalendar.startOfDay(for: date)
    }

    private static func weekdayDate(weekday: Int, weekOffset: Int, now: Date, calendar: Calendar) -> Date {
        // Foundation weekday: Sunday = 1, Monday = 2. Map our Monday=1...Sunday=7.
        let foundationWeekday = weekday == 7 ? 1 : weekday + 1
        let monday = calendar.date(
            byAdding: .day,
            value: weekOffset * 7,
            to: mondayStart(for: now, calendar: calendar)
        ) ?? now
        let delta = foundationWeekday - 2
        return calendar.date(byAdding: .day, value: delta, to: monday) ?? monday
    }

    private static func parseChineseMonthDay(_ text: String, now: Date, calendar: Calendar) -> Date? {
        guard let regex = try? NSRegularExpression(pattern: #"(\d{1,2})月(\d{1,2})日"#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
              let monthRange = Range(match.range(at: 1), in: text),
              let dayRange = Range(match.range(at: 2), in: text),
              let month = Int(text[monthRange]),
              let day = Int(text[dayRange]) else { return nil }
        var components = calendar.dateComponents([.year], from: now)
        components.month = month
        components.day = day
        components.hour = 0
        components.minute = 0
        components.second = 0
        guard var date = calendar.date(from: components) else { return nil }
        if date > now {
            components.year = (components.year ?? 1970) - 1
            if let previous = calendar.date(from: components) { date = previous }
        }
        return date
    }

    private static func minDate(_ lhs: Date, _ rhs: Date) -> Date {
        lhs < rhs ? lhs : rhs
    }
}
