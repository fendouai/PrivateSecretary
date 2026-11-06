import Foundation

/// The gate now only decides whether a spoken/typed line should become a
/// read-only todo. It never authorizes or performs an action.
public final class IntentGate: @unchecked Sendable {
    public let config: AppConfig
    private let model: (any IntentClassifying)?
    private let lock = NSLock()
    private var recent: [(text: String, at: Date)] = []
    private var appTriggerAt: [String: Date] = [:]

    public init(config: AppConfig, model: (any IntentClassifying)? = nil) {
        self.config = config
        if let model {
            self.model = model
        } else if config.intentGate.model.enabled {
            self.model = ModelCommandClient(config: config.intentGate.model)
        } else {
            self.model = nil
        }
    }

    public var modelName: String {
        model?.name ?? "rules"
    }

    public func evaluate(candidate: CandidatePacket, now: Date = Date()) -> IntentDecision {
        guard config.intentGate.enabled else { return .none(reason: "intent_gate_disabled") }
        let text = candidate.intentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= config.intentGate.minimumTextLength else {
            return .none(reason: "text_too_short")
        }
        guard TextAnalyzer.meaningfulCharacterRatio(text) >= 0.3 else {
            return .none(reason: "not_meaningful_text")
        }
        if TextAnalyzer.containsPromptInjection(text) {
            record(text: text, at: now)
            return .none(reason: "prompt_injection_suspected")
        }

        lock.lock()
        let duplicate = recent.contains {
            now.timeIntervalSince($0.at) <= config.intentGate.duplicateWindowSeconds
                && TextAnalyzer.jaccard($0.text, text) >= config.intentGate.duplicateSimilarity
        }
        let appKey = (candidate.application ?? "") + "|" + (candidate.windowTitle ?? "")
        let throttled = appTriggerAt[appKey].map {
            now.timeIntervalSince($0) < config.intentGate.appThrottleSeconds
        } ?? false
        lock.unlock()

        if duplicate { return .none(reason: "duplicate_intent_window") }
        if throttled { return .none(reason: "app_window_throttled") }

        var decision = ruleDecision(text: text, candidate: candidate)
        if decision.classification == .none, let model {
            do {
                if let output = try model.classify(text: text, context: [
                    "application": candidate.application ?? "",
                    "window_title": candidate.windowTitle ?? "",
                    "audio_origin": candidate.audioOrigin.rawValue
                ]) {
                    decision = decisionFromModel(output, text: text)
                }
            } catch {
                PSLog.warn("intent model failed: \(error.localizedDescription)")
            }
        }

        if decision.classification == .explicit, !candidate.audioOrigin.allowsTodoCapture {
            decision = IntentDecision(
                classification: .uncertain,
                confidence: min(decision.confidence, 0.65),
                intentType: decision.intentType,
                routedText: decision.routedText,
                reason: "system_audio_not_captured_as_todo"
            )
        }

        if decision.classification == .explicit,
           decision.confidence < config.intentGate.explicitThreshold {
            if decision.confidence >= config.intentGate.uncertainThreshold {
                decision.classification = .uncertain
                decision.reason = "confidence_below_explicit_threshold"
            } else {
                decision = .none(reason: "confidence_below_uncertain_threshold")
            }
        }

        if decision.classification != .none {
            record(text: text, at: now)
            lock.lock()
            appTriggerAt[appKey] = now
            lock.unlock()
        }
        return decision
    }

    private func record(text: String, at date: Date) {
        lock.lock()
        defer { lock.unlock() }
        recent.append((text, date))
        let cutoff = date.addingTimeInterval(-max(600, config.intentGate.duplicateWindowSeconds * 3))
        recent = recent.filter { $0.at >= cutoff }.suffix(40).map { $0 }
        appTriggerAt = appTriggerAt.filter { date.timeIntervalSince($0.value) < 3_600 }
    }

    private func ruleDecision(text: String, candidate: CandidatePacket) -> IntentDecision {
        let lowered = TextAnalyzer.normalize(text)
        let hasExplicit = TextAnalyzer.hasExplicitIntentCue(lowered)
            || ((lowered.contains("帮我") || lowered.contains("麻烦") || lowered.contains("请"))
                && Self.containsAny(lowered, ["发送", "发给", "删掉", "删除", "改成", "修改", "上传", "同步", "调用", "发布"]))
        let hasUncertain = TextAnalyzer.hasUncertainIntentCue(lowered)
            || (lowered.contains("要记") && lowered.contains("吗"))
            || (lowered.contains("should") && lowered.contains("remember"))

        guard hasExplicit || hasUncertain else { return .none(reason: "no_explicit_cue") }
        let intentType = Self.intentType(for: lowered)
        guard let intentType else {
            return IntentDecision(
                classification: .uncertain,
                confidence: 0.46,
                intentType: nil,
                routedText: TextAnalyzer.truncated(text, limit: config.intentGate.maximumRoutedTextLength),
                reason: "cue_without_action_type"
            )
        }
        let confidence = hasExplicit ? config.intentGate.minimumRuleConfidence : 0.5
        return IntentDecision(
            classification: hasExplicit ? .explicit : .uncertain,
            confidence: confidence,
            intentType: intentType,
            routedText: Self.routedText(text, limit: config.intentGate.maximumRoutedTextLength),
            reason: hasExplicit ? "explicit_rule_match" : "uncertain_rule_match"
        )
    }

    private func decisionFromModel(_ output: ModelIntentOutput, text: String) -> IntentDecision {
        guard output.classification != .none else { return .none(reason: "model_none") }
        return IntentDecision(
            classification: output.classification,
            confidence: output.confidence,
            intentType: output.intentType,
            routedText: TextAnalyzer.truncated(
                output.routedText.isEmpty ? text : output.routedText,
                limit: config.intentGate.maximumRoutedTextLength
            ),
            reason: "local_model"
        )
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    static func intentType(for lowered: String) -> IntentType? {
        if containsAny(lowered, ["发送", "发给", "邮件", "send", "email", "reply to"]) {
            return .send
        }
        if containsAny(lowered, ["删除", "删掉", "移除", "delete", "remove", "trash"]) {
            return .delete
        }
        if containsAny(lowered, ["修改", "改成", "改一下", "更新为", "重命名", "modify", "change to", "rename"]) {
            return .modify
        }
        if containsAny(lowered, ["上传", "同步到", "发布到", "调用", "webhook", "external api", "post to api", "publish to"]) {
            return .externalAPI
        }
        if containsAny(lowered, ["提醒", "remind", "reminder"]) {
            return .remind
        }
        if containsAny(lowered, ["待办", "todo", "to-do", "task list"]) {
            return .todo
        }
        if containsAny(lowered, ["跟踪", "跟进", "follow up", "follow-up", "track"]) {
            return .track
        }
        if containsAny(lowered, ["记一下", "记录", "帮我记", "记住", "note", "remember", "log this"]) {
            return .record
        }
        return nil
    }

    private static func routedText(_ text: String, limit: Int) -> String {
        var result = text
            .replacingOccurrences(of: #"^(请|麻烦你?|帮我|帮忙)[\s，,]*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if result.isEmpty { result = text }
        return TextAnalyzer.truncated(result, limit: limit)
    }
}
