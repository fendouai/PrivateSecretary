import Testing
import CoreGraphics
import ImageIO
@testable import SecretaryKit

@Test func unixSocketRoundTrip() throws {
    let path = "/tmp/ps-\(UUID().uuidString.prefix(8)).sock"
    defer { try? FileManager.default.removeItem(atPath: path) }
    let server = UnixSocketServer(path: path) { line in
        "{\"ok\":true,\"echo\":\(line.debugDescription)}"
    }
    try server.start()
    defer { server.stop() }
    #expect(server.isRunning)
    let response = try UnixSocketClient.send(["op": "ping"], to: path)
    #expect(response["ok"] as? Bool == true)
    #expect((response["echo"] as? String)?.contains("ping") == true)
    let second = try UnixSocketClient.send(["op": "status"], to: path)
    #expect(second["ok"] as? Bool == true)
    server.stop()
    #expect(!FileManager.default.fileExists(atPath: path))
}

@Test func unixSocketRejectsLongPath() throws {
    let longPath = "/tmp/" + String(repeating: "a", count: 120) + ".sock"
    let server = UnixSocketServer(path: longPath) { _ in nil }
    #expect(throws: UnixSocketError.self) { try server.start() }
}

@Test func captureStatusStoreRoundTrip() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ps-status-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = AppPaths(home: root)
    try paths.ensureDirectories()
    let store = CaptureStatusStore(paths: paths)
    #expect(store.read() == nil)
    let health = CaptureHealth(
        state: "capture_unavailable",
        detail: "permission denied",
        permissionGranted: false,
        lastFrameAt: Date(timeIntervalSince1970: 100),
        lastAudioSegmentAt: Date(timeIntervalSince1970: 200)
    )
    store.write(health)
    #expect(store.read() == health)
}

@Test func fileLockPreventsSecondInstance() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ps-lock-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("daemon.lock")
    let first = try FileLock.Lock(url: path)
    #expect(throws: (any Error).self) { _ = try FileLock.Lock(url: path) }
    first.unlock()
    let second = try FileLock.Lock(url: path)
    second.unlock()
}

@Test func configPartialMergeUsesDefaults() throws {
    let json = """
    {"salience":{"threshold":0.42},"capture":{"vadThreshold":0.02}}
    """
    let config = try AppConfigLoader.decodeMerged(Data(json.utf8))
    #expect(abs(config.salience.threshold - 0.42) < 0.0001)
    #expect(abs(config.capture.vadThreshold - 0.02) < 0.0001)
    #expect(config.capture.audioRingSeconds == AppConfig().capture.audioRingSeconds)
    #expect(config.intentGate.explicitThreshold == AppConfig().intentGate.explicitThreshold)
}

@Test func configRejectsInvalidThresholds() throws {
    var config = AppConfig()
    config.salience.threshold = 2
    #expect(!config.validationErrors.isEmpty)
    config = AppConfig()
    config.intentGate.uncertainThreshold = 0.9
    config.intentGate.explicitThreshold = 0.5
    #expect(config.validationErrors.contains { $0.contains("uncertainThreshold") })
}

@Test func configRoundTripOnDisk() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ps-config-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = AppPaths(home: root)
    try paths.ensureDirectories()
    var config = AppConfig()
    config.salience.threshold = 0.37
    try AppConfigLoader.save(config, to: paths.configFile)
    let loaded = try AppConfigLoader.load(from: paths.configFile)
    #expect(abs(loaded.salience.threshold - 0.37) < 0.0001)
}

@Test func candidatePacketDecodesMinimalJSONWithDefaults() throws {
    let data = Data("""
    {"transcript":"帮我记一下 HNSW 参数","source":"manual"}
    """.utf8)
    let candidate = try JSONCoding.decoder().decode(CandidatePacket.self, from: data)
    #expect(candidate.transcript.contains("HNSW"))
    #expect(candidate.source == .manual)
    #expect(candidate.audioOrigin == .manual)
    #expect(candidate.ocrRegions.isEmpty)
    #expect(!candidate.id.isEmpty)
}

@Test func commandRunnerCapturesOutput() throws {
    let result = try CommandRunner.run(
        executable: "/bin/echo",
        arguments: ["private-secretary"],
        timeoutSeconds: 2
    )
    #expect(result.exitCode == 0)
    #expect(result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == "private-secretary")
}

@Test func commandRunnerRejectsMissingExecutable() {
    #expect(throws: (any Error).self) {
        _ = try CommandRunner.run(executable: "/definitely/missing/binary", arguments: [], timeoutSeconds: 1)
    }
}

@Test func commandModelClientClassifiesIntent() throws {
    let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/fake-model.py").path
    guard let python = SystemDiagnostics.locateExecutable("python3") else { return }
    var config = CommandModelConfig()
    config.enabled = true
    config.executable = python
    config.arguments = [script]
    config.timeoutSeconds = 5
    let client = ModelCommandClient(config: config)
    let result = try #require(try client.classify(text: "send the report to Alice", context: [:]))
    #expect(result.classification == .explicit)
    #expect(result.intentType == .send)
    #expect(result.confidence > 0.9)
}

@Test func commandModelClientExtractsFacts() throws {
    let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/fake-model.py").path
    guard let python = SystemDiagnostics.locateExecutable("python3") else { return }
    var config = CommandModelConfig()
    config.enabled = true
    config.executable = python
    config.arguments = [script]
    let client = ModelCommandClient(config: config)
    let episode = Episode(
        id: "ep_model",
        startedAt: Date(),
        endedAt: Date(),
        application: "Terminal",
        windowTitle: "npm",
        source: .screen,
        audioOrigin: .manual,
        transcript: "",
        ocrText: "npm ERR! code ERESOLVE",
        ocrRegions: [],
        summary: "dependency error",
        keywords: ["npm", "error"],
        salience: 0.7,
        signals: SalienceSignals(error: 0.9),
        provenance: [],
        trust: .untrustedObservedContent
    )
    let facts = try client.extractFacts(from: episode)
    #expect(facts.count == 1)
    #expect(facts.first?.kind == .error)
    #expect(facts.first?.statement.contains("ERESOLVE") == true)
}

@Test func dateCodingRoundTrip() throws {
    let date = Date(timeIntervalSince1970: 1_760_000_000.123)
    let encoded = DateCoding.iso(date)
    let decoded = try #require(DateCoding.parseISO(encoded))
    #expect(abs(decoded.timeIntervalSince1970 - date.timeIntervalSince1970) < 0.01)
}

@Test func dataFilesUsePrivatePermissions() throws {
    let env = try TestEnvironment()
    let attributes = try FileManager.default.attributesOfItem(atPath: env.paths.home.path)
    let homePermissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
    #expect(homePermissions & 0o077 == 0)
    let dbAttributes = try FileManager.default.attributesOfItem(atPath: env.paths.databaseFile.path)
    let dbPermissions = (dbAttributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
    #expect(dbPermissions & 0o077 == 0)
}
