import Foundation

public enum UnixSocketError: Error, LocalizedError {
    case createFailed(String)
    case bindFailed(String)
    case listenFailed(String)
    case connectFailed(String)
    case pathTooLong
    case notRunning
    case payloadTooLarge

    public var errorDescription: String? {
        switch self {
        case .createFailed(let message): return "socket() failed: \(message)"
        case .bindFailed(let message): return "bind() failed: \(message)"
        case .listenFailed(let message): return "listen() failed: \(message)"
        case .connectFailed(let message): return "connect() failed: \(message)"
        case .pathTooLong: return "Unix socket path is too long"
        case .notRunning: return "Unix socket server is not running"
        case .payloadTooLarge: return "Unix socket request exceeded the size limit"
        }
    }
}

public final class UnixSocketServer: @unchecked Sendable {
    public typealias Handler = (String) -> String?

    private let path: String
    private let handler: Handler
    private let maximumRequestBytes: Int
    private var listener: Int32 = -1
    private let lock = NSLock()
    private var running = false
    private let acceptQueue = DispatchQueue(label: "com.privatesecretary.socket.accept", qos: .utility)
    private let clientQueue = DispatchQueue(label: "com.privatesecretary.socket.client", qos: .utility, attributes: .concurrent)

    public init(path: String, maximumRequestBytes: Int = 2_097_152, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
        self.maximumRequestBytes = maximumRequestBytes
    }

    public func start() throws {
        guard path.utf8.count < 104 else { throw UnixSocketError.pathTooLong }
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        unlink(path)

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw UnixSocketError.createFailed(String(cString: strerror(errno)))
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            for (index, byte) in bytes.prefix(max(0, destination.count - 1)).enumerated() {
                destination[index] = byte
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, size)
            }
        }
        guard bindResult == 0 else {
            let message = String(cString: strerror(errno))
            close(descriptor)
            throw UnixSocketError.bindFailed(message)
        }
        chmod(path, S_IRUSR | S_IWUSR)
        guard listen(descriptor, 16) == 0 else {
            let message = String(cString: strerror(errno))
            close(descriptor)
            unlink(path)
            throw UnixSocketError.listenFailed(message)
        }
        lock.lock()
        listener = descriptor
        running = true
        lock.unlock()
        acceptQueue.async { [weak self] in self?.acceptLoop(descriptor) }
    }

    public func stop() {
        lock.lock()
        guard running else { lock.unlock(); return }
        running = false
        let descriptor = listener
        listener = -1
        lock.unlock()
        if descriptor >= 0 {
            shutdown(descriptor, SHUT_RDWR)
            close(descriptor)
        }
        unlink(path)
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func acceptLoop(_ descriptor: Int32) {
        while true {
            lock.lock()
            let active = running
            lock.unlock()
            guard active else { return }
            let client = accept(descriptor, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            clientQueue.async { [weak self] in
                self?.handle(client: client)
            }
        }
    }

    private func handle(client: Int32) {
        defer { close(client) }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 8_192)
        while true {
            let count = read(client, &chunk, chunk.count)
            if count <= 0 { return }
            buffer.append(contentsOf: chunk.prefix(count))
            guard buffer.count <= maximumRequestBytes else {
                writeLine("{\"ok\":false,\"error\":\"request_too_large\"}", to: client)
                return
            }
            while let newline = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.prefix(upTo: newline)
                buffer.removeSubrange(...newline)
                guard !lineData.isEmpty,
                      let line = String(data: lineData, encoding: .utf8) else { continue }
                if let response = handler(line) {
                    writeLine(response, to: client)
                }
            }
        }
    }

    private func writeLine(_ string: String, to client: Int32) {
        var data = Data(string.utf8)
        data.append(0x0A)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let result = Darwin.send(client, base.advanced(by: sent), raw.count - sent, 0)
                if result <= 0 { return }
                sent += result
            }
        }
    }

    deinit { stop() }
}

public enum UnixSocketClient {
    public static func send(
        _ object: [String: Any],
        to path: String,
        timeoutSeconds: Double = 5,
        maximumResponseBytes: Int = 4_194_304
    ) throws -> [String: Any] {
        guard try UnixSocketProbe.isSocket(at: path) else {
            throw UnixSocketError.connectFailed("socket file not found: \(path)")
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw UnixSocketError.createFailed(String(cString: strerror(errno)))
        }
        defer { close(descriptor) }
        var timeout = timeval(
            tv_sec: Int(timeoutSeconds),
            tv_usec: Int32((timeoutSeconds - Double(Int(timeoutSeconds))) * 1_000_000)
        )
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < 104 else { throw UnixSocketError.pathTooLong }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            for (index, byte) in bytes.prefix(max(0, destination.count - 1)).enumerated() {
                destination[index] = byte
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, size)
            }
        }
        guard connectResult == 0 else {
            throw UnixSocketError.connectFailed(String(cString: strerror(errno)))
        }
        let payload = try JSONSerialization.data(withJSONObject: object)
        var request = payload
        request.append(0x0A)
        request.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let result = Darwin.send(descriptor, base.advanced(by: sent), raw.count - sent, 0)
                if result <= 0 { return }
                sent += result
            }
        }
        var response = Data()
        var chunk = [UInt8](repeating: 0, count: 4_096)
        while response.count <= maximumResponseBytes {
            let count = read(descriptor, &chunk, chunk.count)
            if count <= 0 { break }
            response.append(contentsOf: chunk.prefix(count))
            if response.contains(0x0A) { break }
        }
        guard let newline = response.firstIndex(of: 0x0A),
              let object = try JSONSerialization.jsonObject(
                with: response.prefix(upTo: newline)
              ) as? [String: Any] else {
            throw UnixSocketError.connectFailed("invalid or empty response")
        }
        return object
    }
}

private enum UnixSocketProbe {
    static func isSocket(at path: String) throws -> Bool {
        var info = stat()
        guard stat(path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFSOCK
    }
}
