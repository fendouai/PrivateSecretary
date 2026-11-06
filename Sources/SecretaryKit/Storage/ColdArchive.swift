import Foundation

/// Cold storage for forgotten L2 episodes. Forgetting is not deletion: the
/// summary and provenance stay in the hot database, while full observed text
/// moves to an append-only JSONL archive.
public final class ColdArchive: @unchecked Sendable {
    public let directory: URL
    private let lock = NSLock()
    private let monthFormatter: DateFormatter

    public init(directory: String) {
        self.directory = URL(fileURLWithPath: directory, isDirectory: true)
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM"
        self.monthFormatter = formatter
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    public func fileURL(for date: Date) -> URL {
        directory.appendingPathComponent("episodes-\(monthFormatter.string(from: date)).jsonl")
    }

    @discardableResult
    public func append(_ episode: Episode) throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = fileURL(for: episode.startedAt)
        let data = try JSONCoding.encoder().encode(episode)
        var line = data
        line.append(0x0A)
        if !FileManager.default.fileExists(atPath: url.path) {
            try line.write(to: url, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } else {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            try handle.synchronize()
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        return url
    }

    public func load(episodeID: String, startedAt: Date) -> Episode? {
        lock.lock()
        defer { lock.unlock() }
        let url = fileURL(for: startedAt)
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let decoder = JSONCoding.decoder()
        for line in text.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let episode = try? decoder.decode(Episode.self, from: lineData) else { continue }
            if episode.id == episodeID { return episode }
        }
        return nil
    }

    public func contains(episodeID: String, startedAt: Date) -> Bool {
        load(episodeID: episodeID, startedAt: startedAt) != nil
    }

    @discardableResult
    public func delete(episodeID: String, startedAt: Date) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let url = fileURL(for: startedAt)
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return false }
        var removed = false
        var kept: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if let lineData = line.data(using: .utf8),
               let episode = try? JSONCoding.decoder().decode(Episode.self, from: lineData),
               episode.id == episodeID {
                removed = true
                continue
            }
            kept.append(String(line))
        }
        if removed {
            let output = kept.joined(separator: "\n") + (kept.isEmpty ? "" : "\n")
            try output.write(to: url, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        return removed
    }

    public func purgeAll() {
        lock.lock()
        defer { lock.unlock() }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }
        for file in files where file.pathExtension == "jsonl" {
            try? FileManager.default.removeItem(at: file)
        }
    }

    public func files() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "jsonl" }) ?? []
    }
}
