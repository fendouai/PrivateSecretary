import Foundation
import SecretaryKit
import CoreGraphics

func daemonFail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

var home: URL?
var captureMode = "off"
var socketPath: String?
var arguments = Array(CommandLine.arguments.dropFirst())
var index = 0
while index < arguments.count {
    let argument = arguments[index]
    switch argument {
    case "--home":
        index += 1
        guard index < arguments.count else { daemonFail("--home requires a path") }
        home = URL(fileURLWithPath: (arguments[index] as NSString).expandingTildeInPath, isDirectory: true)
    case "--capture":
        index += 1
        guard index < arguments.count else { daemonFail("--capture requires off|system") }
        captureMode = arguments[index]
        guard captureMode == "off" || captureMode == "system" else {
            daemonFail("--capture must be off or system")
        }
    case "--socket":
        index += 1
        guard index < arguments.count else { daemonFail("--socket requires a path") }
        socketPath = arguments[index]
    case "--foreground", "--no-fork":
        break
    case "--version":
        print(PrivateSecretaryVersion.current)
        exit(0)
    case "--help", "-h":
        print("""
        secretaryd \(PrivateSecretaryVersion.current)
        Usage: secretaryd [--home <dir>] [--capture off|system] [--socket <path>] [--foreground]
                          [--request-permissions]

        The daemon owns the Unix-domain socket ingest endpoint and optional
        ScreenCaptureKit pipeline. It never stores raw audio or screen frames.
        """)
        exit(0)
    default:
        daemonFail("Unknown argument: \(argument)")
    }
    index += 1
}

signal(SIGPIPE, SIG_IGN)

if arguments.contains("--request-permissions") {
    let granted = CGRequestScreenCaptureAccess()
    print(granted
        ? "Screen Recording permission is granted for this app."
        : "Screen Recording permission was not granted. Open System Settings → Privacy & Security → Screen Recording.")
    exit(granted ? 0 : 2)
}

final class DaemonController: @unchecked Sendable {
    let paths: AppPaths
    let config: AppConfig
    let service: MemoryService
    private var capture: SystemCaptureEngine?
    private var interruptSources: [DispatchSourceSignal] = []
    private var lock: FileLock.Lock?
    private let ingestQueue = DispatchQueue(label: "com.privatesecretary.daemon.ingest", qos: .utility)
    private var stopping = false

    init(paths: AppPaths, config: AppConfig, socketPath: String) throws {
        self.paths = paths
        self.config = config
        self.service = try MemoryService(paths: paths, config: config)
    }

    func start(socketPath: String, captureMode: String) throws {
        try paths.ensureDirectories()
        lock = try FileLock.Lock(url: paths.home.appendingPathComponent("secretaryd.lock"))
        try "\(getpid())\n".write(to: paths.pidFile, atomically: true, encoding: .utf8)
        installSignals()

        // Rebind handler with the real serial ingest queue for consistent writes.
        let server = UnixSocketServer(
            path: socketPath,
            maximumRequestBytes: config.daemon.maximumRequestBytes
        ) { [weak self] line in
            guard let self else { return "{\"ok\":false,\"error\":\"daemon_stopping\"}" }
            return self.ingestQueue.sync {
                Self.handle(line: line, service: self.service)
            }
        }
        try server.start()
        socketMirror = server
        psLog("listening on \(socketPath)")

        if captureMode == "system" {
            startCapture()
        } else {
            service.publishCaptureHealth(CaptureHealth(
                state: "disabled",
                detail: "capture is off; ingest socket is active",
                permissionGranted: false
            ))
        }
        RunLoop.main.run()
    }

    private var socketMirror: UnixSocketServer?

    func shutdown(exitCode: Int32 = 0) {
        guard !stopping else { return }
        stopping = true
        psLog("shutting down")
        socketMirror?.stop()
        service.publishCaptureHealth(CaptureHealth(
            state: "stopped",
            detail: "daemon stopped",
            permissionGranted: false
        ))
        try? FileManager.default.removeItem(at: paths.pidFile)
        lock?.unlock()
        lock = nil
        if let capture {
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                await capture.stop()
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 3)
        }
        exit(exitCode)
    }

    private func startCapture() {
        service.publishCaptureHealth(CaptureHealth(
            state: "starting",
            detail: "requesting ScreenCaptureKit stream",
            permissionGranted: CGPreflightScreenCaptureAccess()
        ))
        let engine = SystemCaptureEngine(
            config: config,
            paths: paths,
            onCandidate: { [weak self] candidate in
                guard let self else { return }
                self.ingestQueue.async {
                    do {
                        let result = try self.service.ingest(candidate)
                        if result.accepted {
                            PSLog.info("ingested \(result.episode?.id ?? "?") facts=\(result.facts.count) todo=\(result.todo?.id ?? "-")")
                        } else {
                            PSLog.debug("candidate dropped: \(result.reason ?? "unknown")")
                        }
                    } catch {
                        PSLog.error("ingest failed: \(error.localizedDescription)")
                    }
                }
            },
            onHealth: { [weak self] health in
                self?.service.publishCaptureHealth(health)
            }
        )
        self.capture = engine
        Task {
            do {
                try await engine.start()
            } catch {
                PSLog.error("capture unavailable: \(error.localizedDescription)")
                self.service.publishCaptureHealth(CaptureHealth(
                    state: "capture_unavailable",
                    detail: error.localizedDescription,
                    permissionGranted: false
                ))
            }
        }
    }

    private func installSignals() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in self?.shutdown() }
            source.resume()
            interruptSources.append(source)
        }
    }

    private static func handle(line: String, service: MemoryService) -> String {
        guard let data = line.data(using: .utf8),
              let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return jsonText(["ok": false, "error": "invalid_json"])
        }
        let op = request["op"] as? String ?? "ping"
        do {
            switch op {
            case "ping":
                return jsonText(["ok": true, "result": "pong"])
            case "status", "health":
                return jsonText(["ok": true, "result": try object(service.status())])
            case "ingest":
                guard let candidateObject = request["candidate"] as? [String: Any] else {
                    return jsonText(["ok": false, "error": "candidate_required"])
                }
                let candidateData = try JSONSerialization.data(withJSONObject: candidateObject)
                let candidate = try JSONCoding.decoder().decode(CandidatePacket.self, from: candidateData)
                let result = try service.ingest(candidate)
                return jsonText(["ok": true, "result": try object(result)])
            case "message":
                guard let channel = request["channel"] as? String,
                      let contactName = request["contact_name"] as? String,
                      let text = request["text"] as? String else {
                    return jsonText(["ok": false, "error": "channel, contact_name and text are required"])
                }
                let direction = MessageDirection(rawValue: (request["direction"] as? String ?? "inbound").lowercased()) ?? .inbound
                let timestamp: Date
                if let raw = request["timestamp"] as? String,
                   let parsed = DateCoding.parseISO(raw) ?? DateCoding.parseDay(raw) {
                    timestamp = parsed
                } else {
                    timestamp = Date()
                }
                let message = try service.recordMessage(
                    channel: channel,
                    contactName: contactName,
                    handle: request["handle"] as? String,
                    direction: direction,
                    text: text,
                    timestamp: timestamp,
                    thread: request["thread"] as? String,
                    externalID: request["external_id"] as? String,
                    isRead: request["is_read"] as? Bool
                )
                return jsonText(["ok": true, "result": try object(message)])
            case "contact":
                guard let displayName = request["display_name"] as? String else {
                    return jsonText(["ok": false, "error": "display_name_required"])
                }
                var channels: [ContactChannel] = []
                if let raw = request["channels"] as? [[String: Any]] {
                    channels = raw.compactMap { item in
                        guard let channel = item["channel"] as? String,
                              let handle = item["handle"] as? String else { return nil }
                        return ContactChannel(channel: channel, handle: handle)
                    }
                }
                let contact = try service.upsertContact(
                    displayName: displayName,
                    organization: request["organization"] as? String,
                    notes: request["notes"] as? String,
                    channels: channels
                )
                return jsonText(["ok": true, "result": try object(contact)])
            case "shutdown":
                return jsonText(["ok": false, "error": "use_signal_to_stop_daemon"])
            default:
                return jsonText(["ok": false, "error": "unknown_op", "op": op])
            }
        } catch {
            return jsonText(["ok": false, "error": error.localizedDescription])
        }
    }

    private static func object<T: Encodable>(_ value: T) throws -> Any {
        let data = try JSONCoding.encoder().encode(value)
        return try JSONSerialization.jsonObject(with: data)
    }

    private static func jsonText(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{\"ok\":false,\"error\":\"encoding_failure\"}"
        }
        return string
    }
}

func psLog(_ message: String) {
    PSLog.info(message)
}

let paths = AppPaths(home: home)
do {
    let config = try AppConfigLoader.loadOrCreate(paths: paths)
    try paths.ensureDirectories()
    let finalSocket = socketPath ?? paths.socketFile.path
    let controller = try DaemonController(paths: paths, config: config, socketPath: finalSocket)
    // Retain the controller for the process lifetime.
    try controller.start(socketPath: finalSocket, captureMode: captureMode)
    withExtendedLifetime(controller) {}
} catch {
    daemonFail("secretaryd failed: \(error.localizedDescription)")
}
