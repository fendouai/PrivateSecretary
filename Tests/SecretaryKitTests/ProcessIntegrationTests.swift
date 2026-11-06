import Testing
import Foundation
import CoreGraphics
@testable import SecretaryKit

private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func debugBinary(_ name: String) -> String {
    repositoryRoot().appendingPathComponent(".build/debug/\(name)").path
}

private func temporaryHome() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ps-process-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func makeProcess(_ executable: String, _ arguments: [String], environment: [String: String]) -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
    return process
}

private func readLine(from handle: FileHandle) -> String? {
    var data = Data()
    while true {
        guard let chunk = try? handle.read(upToCount: 1), let byte = chunk.first else {
            return data.isEmpty ? nil : String(decoding: data, as: UTF8.self)
        }
        if byte == 0x0A { return String(decoding: data, as: UTF8.self) }
        data.append(byte)
        if data.count > 4_194_304 { return nil }
    }
}

@Test func mcpProcessSpeaksStdioProtocol() throws {
    let executable = debugBinary("secretary-mcp")
    guard FileManager.default.isExecutableFile(atPath: executable) else {
        Issue.record("missing \(executable); run swift build")
        return
    }
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let process = makeProcess(executable, ["--home", home.path], environment: ["PRIVATE_SECRETARY_LOG_LEVEL": "error"])
    let input = Pipe()
    let output = Pipe()
    let error = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = error
    try process.run()
    defer {
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }
    let initialize = """
    {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"swift-test","version":"1"}}}
    """
    try input.fileHandleForWriting.write(contentsOf: Data((initialize + "\n").utf8))
    let responseLine = try #require(readLine(from: output.fileHandleForReading))
    let response = jsonObject(responseLine)
    let result = response["result"] as? [String: Any]
    #expect(result?["protocolVersion"] as? String == "2025-06-18")
    #expect((result?["serverInfo"] as? [String: Any])?["name"] as? String == "private-secretary")
    try input.fileHandleForWriting.write(contentsOf: Data("""
    {"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
    """.utf8 + Data("\n".utf8)))
    let toolsLine = try #require(readLine(from: output.fileHandleForReading))
    let tools = jsonObject(toolsLine)["result"] as? [String: Any]
    #expect((tools?["tools"] as? [[String: Any]])?.count == 16)
    try input.fileHandleForWriting.close()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    let stderr = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    #expect(!stderr.contains("\"jsonrpc\""))
}

@Test func cliDemoRecallDigestTodosAndMessages() throws {
    let executable = debugBinary("secretary")
    guard FileManager.default.isExecutableFile(atPath: executable) else {
        Issue.record("missing \(executable); run swift build")
        return
    }
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let demo = try runAndCapture(executable, ["--home", home.path, "demo"])
    #expect(demo.status == 0, "stderr: \(demo.stderr)")
    #expect(demo.stdout.contains("日报"))
    #expect(demo.stdout.contains("Seeded") || demo.stdout.contains("✓"))
    let recall = try runAndCapture(executable, ["--home", home.path, "recall", "HNSW 参数"])
    #expect(recall.status == 0, "stderr: \(recall.stderr)")
    #expect(recall.stdout.contains("[L2]"))
    let todos = try runAndCapture(executable, ["--home", home.path, "todos"])
    #expect(todos.status == 0)
    #expect(todos.stdout.contains("Todos: 3"))
    #expect(todos.stdout.contains("never executes"))
    let contacts = try runAndCapture(executable, ["--home", home.path, "contacts"])
    #expect(contacts.status == 0)
    #expect(contacts.stdout.contains("张三"))
    let messages = try runAndCapture(executable, ["--home", home.path, "messages"])
    #expect(messages.status == 0)
    #expect(messages.stdout.contains("Messages: 5"))
    let timeline = try runAndCapture(executable, ["--home", home.path, "timeline"])
    #expect(timeline.status == 0)
    #expect(timeline.stdout.contains("Timeline:"))
    let digest = try runAndCapture(executable, ["--home", home.path, "digest"])
    #expect(digest.status == 0)
    #expect(digest.stdout.contains("语义事实"))
}

private struct CaptureResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

private func runAndCapture(_ executable: String, _ arguments: [String]) throws -> CaptureResult {
    let process = makeProcess(executable, arguments, environment: ["PRIVATE_SECRETARY_LOG_LEVEL": "error"])
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    let outData = stdout.fileHandleForReading.readDataToEndOfFile()
    let errData = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return CaptureResult(
        status: process.terminationStatus,
        stdout: String(decoding: outData, as: UTF8.self),
        stderr: String(decoding: errData, as: UTF8.self)
    )
}

@Test func daemonProcessSocketIngestAndShutdown() throws {
    let executable = debugBinary("secretaryd")
    guard FileManager.default.isExecutableFile(atPath: executable) else {
        Issue.record("missing \(executable); run swift build")
        return
    }
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let socket = "/tmp/ps-daemon-\(UUID().uuidString.prefix(8)).sock"
    defer { try? FileManager.default.removeItem(atPath: socket) }
    let process = makeProcess(
        executable,
        ["--home", home.path, "--socket", socket, "--capture", "off"],
        environment: ["PRIVATE_SECRETARY_LOG_LEVEL": "error"]
    )
    let stderrPipe = Pipe()
    process.standardError = stderrPipe
    process.standardOutput = Pipe()
    try process.run()
    defer {
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }
    var ready = false
    for _ in 0..<100 {
        if FileManager.default.fileExists(atPath: socket) {
            ready = true
            break
        }
        usleep(50_000)
    }
    try #require(ready, "daemon socket did not appear")
    let status = try UnixSocketClient.send(["op": "status"], to: socket)
    #expect(status["ok"] as? Bool == true)
    let result = status["result"] as? [String: Any]
    #expect((result?["capture"] as? [String: Any])?["state"] as? String == "disabled")
    let ingest = try UnixSocketClient.send([
        "op": "ingest",
        "candidate": [
            "capturedAt": DateCoding.iso(Date()),
            "source": "manual",
            "application": "Notes",
            "transcript": "帮我记一下 daemon 进程集成测试"
        ]
    ], to: socket)
    #expect(ingest["ok"] as? Bool == true)
    let ingested = ingest["result"] as? [String: Any]
    #expect(ingested?["accepted"] as? Bool == true)
    #expect((ingested?["todo"] as? [String: Any])?["status"] as? String == "open")
    process.terminate()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
}


@Test func daemonReportsCaptureUnavailableWhenTCCDenied() throws {
    guard !CGPreflightScreenCaptureAccess() else { return }
    let executable = debugBinary("secretaryd")
    guard FileManager.default.isExecutableFile(atPath: executable) else {
        Issue.record("missing \(executable); run swift build")
        return
    }
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let socket = "/tmp/ps-tcc-\(UUID().uuidString.prefix(8)).sock"
    defer { try? FileManager.default.removeItem(atPath: socket) }
    let process = makeProcess(
        executable,
        ["--home", home.path, "--socket", socket, "--capture", "system"],
        environment: ["PRIVATE_SECRETARY_LOG_LEVEL": "error"]
    )
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    defer {
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }
    var ready = false
    for _ in 0..<100 {
        if FileManager.default.fileExists(atPath: socket) {
            ready = true
            break
        }
        usleep(50_000)
    }
    try #require(ready)
    var state: String?
    for _ in 0..<50 {
        let status = try UnixSocketClient.send(["op": "status"], to: socket)
        let result = status["result"] as? [String: Any]
        state = (result?["capture"] as? [String: Any])?["state"] as? String
        if state == "capture_unavailable" { break }
        usleep(100_000)
    }
    #expect(state == "capture_unavailable")
    process.terminate()
    process.waitUntilExit()
}
