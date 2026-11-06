import Foundation
import SecretaryKit

enum DemoScenario {
    static func seedIfNeeded(service: MemoryService) throws -> (seeded: Bool, results: [IngestResult], digest: DailyDigest?) {
        let marker = try service.store.meta("demo_v3_seeded_at")
        if marker != nil {
            let digest = try service.digest(dayKey: DateCoding.dayKey(Date()))
            return (false, [], digest)
        }
        let counts = try service.store.counts()
        guard counts.episodes == 0 else {
            throw NSError(domain: "PrivateSecretary.Demo", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "This memory database already contains data. Run the demo with --home /tmp/private-secretary-demo to avoid mixing demo memories with real ones."
            ])
        }

        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        func at(_ dayOffset: Int, _ hour: Int, _ minute: Int) -> Date {
            let base = calendar.date(byAdding: .day, value: dayOffset, to: today) ?? today
            return calendar.date(byAdding: .minute, value: hour * 60 + minute, to: base) ?? base
        }

        let candidates: [CandidatePacket] = [
            CandidatePacket(
                id: "demo-001",
                capturedAt: at(-1, 15, 20),
                source: .audio,
                audioOrigin: .system,
                application: "Safari",
                windowTitle: "向量数据库入门 · 视频",
                transcript: "这个视频讲了向量数据库的 HNSW 参数。ef_construction 设置为 200，M 设置为 32，通常能在召回率和构建时间之间取得平衡。检索时把 ef_search 调大，召回率会提高，但延迟也会增加。",
                audioDurationSeconds: 38
            ),
            CandidatePacket(
                id: "demo-002",
                capturedAt: at(0, 9, 15),
                source: .combined,
                audioOrigin: .system,
                application: "Terminal",
                windowTitle: "npm run build",
                transcript: "",
                ocrText: "npm ERR! code ERESOLVE\nnpm ERR! ERESOLVE unable to resolve dependency tree\nnpm ERR! Could not resolve peer react@18.3.1 from @tanstack/react-query@5.62.0",
                ocrRegions: [
                    OCRRegion(text: "npm ERR! code ERESOLVE", confidence: 0.96, x: 0.02, y: 0.42, width: 0.34, height: 0.04),
                    OCRRegion(text: "npm ERR! ERESOLVE unable to resolve dependency tree", confidence: 0.93, x: 0.02, y: 0.47, width: 0.62, height: 0.04)
                ],
                screenFrameCount: 3
            ),
            CandidatePacket(
                id: "demo-003",
                capturedAt: at(0, 10, 5),
                source: .audio,
                audioOrigin: .system,
                application: "TencentMeeting",
                windowTitle: "架构周会",
                transcript: "我们决定采用 HNSW 加 BM25 的混合检索方案。语义召回走 HNSW，时间词和专有名词走 BM25，最后按显著性加权融合。下周三之前完成参数对比。",
                audioDurationSeconds: 26
            ),
            CandidatePacket(
                id: "demo-004",
                capturedAt: at(0, 11, 20),
                source: .manual,
                audioOrigin: .manual,
                application: "Notes",
                windowTitle: "每日记录",
                transcript: "帮我记一下周五前提交 HNSW 参数对比"
            ),
            CandidatePacket(
                id: "demo-005",
                capturedAt: at(0, 11, 22),
                source: .audio,
                audioOrigin: .microphone,
                application: "Notes",
                windowTitle: "每日记录",
                transcript: "提醒我下午三点和张三确认向量数据库选型",
                audioDurationSeconds: 6
            ),
            CandidatePacket(
                id: "demo-006",
                capturedAt: at(0, 12, 30),
                source: .manual,
                audioOrigin: .manual,
                application: "Mail",
                windowTitle: "Draft",
                transcript: "帮我发邮件告诉张三方案下周评审"
            ),
            CandidatePacket(
                id: "demo-007",
                capturedAt: at(0, 14, 40),
                source: .screen,
                audioOrigin: .manual,
                application: "Notes",
                windowTitle: "检索偏好",
                ocrText: "以后向量检索都用 hybrid 模式。我偏好先 BM25 再向量，这样时间词不会丢。成功验证后更新 README。",
                ocrRegions: [
                    OCRRegion(text: "以后向量检索都用 hybrid 模式", confidence: 0.92, x: 0.12, y: 0.22, width: 0.5, height: 0.05)
                ],
                screenFrameCount: 2
            )
        ]

        var results: [IngestResult] = []
        for candidate in candidates {
            let result = try service.ingest(candidate, now: candidate.capturedAt)
            results.append(result)
        }
        // Aggregate a few cross-channel contacts/messages to demonstrate the
        // read-only contact/message views. These are historical records; nothing
        // is sent by the application.
        do {
            let zhangsan = try service.upsertContact(
                displayName: "张三",
                organization: "Acme",
                channels: [
                    ContactChannel(channel: "email", handle: "zhangsan@example.com"),
                    ContactChannel(channel: "lark", handle: "zhangsan_lark")
                ]
            )
            _ = try service.recordMessage(
                channel: "email",
                contactName: zhangsan.displayName,
                handle: "zhangsan@example.com",
                direction: .inbound,
                text: "HNSW 参数对比请在周五前发我，重点看 ef_construction 和 M 的取舍。",
                timestamp: at(0, 9, 48),
                thread: "HNSW 参数对比",
                externalID: "demo-mail-001"
            )
            _ = try service.recordMessage(
                channel: "email",
                contactName: zhangsan.displayName,
                handle: "zhangsan@example.com",
                direction: .outbound,
                text: "收到，我整理好参数对比后发你。",
                timestamp: at(0, 9, 52),
                thread: "HNSW 参数对比",
                externalID: "demo-mail-002",
                isRead: true
            )
            _ = try service.recordMessage(
                channel: "lark",
                contactName: zhangsan.displayName,
                handle: "zhangsan_lark",
                direction: .inbound,
                text: "下周评审改到周一下午三点。",
                timestamp: at(0, 13, 10),
                thread: "架构评审"
            )
            let lisi = try service.upsertContact(
                displayName: "李四",
                organization: "Beta Labs",
                channels: [ContactChannel(channel: "wechat", handle: "lisi_wechat")]
            )
            _ = try service.recordMessage(
                channel: "wechat",
                contactName: lisi.displayName,
                handle: "lisi_wechat",
                direction: .inbound,
                text: "你上次说的向量数据库选型，我这边也倾向 HNSW，晚点把 benchmark 发你。",
                timestamp: at(-1, 16, 0),
                thread: "向量数据库选型"
            )
            _ = try service.recordMessage(
                channel: "telegram",
                contactName: "王五",
                handle: "wangwu_tg",
                direction: .inbound,
                text: "早上好，周报记得带上下载数据。",
                timestamp: at(0, 8, 30)
            )
        }

        try service.store.setMeta("demo_v3_seeded_at", DateCoding.iso(now))
        let todayKey = DateCoding.dayKey(now, calendar: calendar)
        let report = try service.generateDigest(dayKey: todayKey, now: now, calendar: calendar)
        return (true, results, report.digest)
    }
}
