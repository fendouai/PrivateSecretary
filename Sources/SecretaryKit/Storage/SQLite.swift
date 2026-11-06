import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum SQLiteValue: Equatable, Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    public init(_ value: String?) {
        if let value { self = .text(value) } else { self = .null }
    }

    public init(_ value: Int) { self = .integer(Int64(value)) }
    public init(_ value: Int64) { self = .integer(value) }
    public init(_ value: Double) { self = .real(value) }
    public init(_ value: Bool) { self = .integer(value ? 1 : 0) }
    public init(_ value: Date) { self = .real(value.timeIntervalSince1970) }

    public static func optionalText(_ value: String?) -> SQLiteValue {
        value.map { .text($0) } ?? .null
    }

    public var string: String? {
        switch self {
        case .text(let value): return value
        case .integer(let value): return String(value)
        case .real(let value): return String(value)
        case .blob, .null: return nil
        }
    }

    public var int: Int? {
        switch self {
        case .integer(let value): return Int(value)
        case .real(let value): return Int(value)
        case .text(let value): return Int(value)
        case .blob, .null: return nil
        }
    }

    public var int64: Int64? {
        switch self {
        case .integer(let value): return value
        case .real(let value): return Int64(value)
        case .text(let value): return Int64(value)
        case .blob, .null: return nil
        }
    }

    public var double: Double? {
        switch self {
        case .real(let value): return value
        case .integer(let value): return Double(value)
        case .text(let value): return Double(value)
        case .blob, .null: return nil
        }
    }

    public var bool: Bool? {
        int.map { $0 != 0 }
    }

    public var date: Date? {
        double.map(Date.init(timeIntervalSince1970:))
    }

    public var data: Data? {
        switch self {
        case .blob(let value): return value
        case .text(let value): return value.data(using: .utf8)
        default: return nil
        }
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

public struct SQLiteRow: Sendable {
    public let values: [String: SQLiteValue]

    public subscript(_ column: String) -> SQLiteValue {
        values[column] ?? .null
    }

    public func string(_ column: String) -> String? { self[column].string }
    public func int(_ column: String) -> Int? { self[column].int }
    public func double(_ column: String) -> Double? { self[column].double }
    public func bool(_ column: String) -> Bool? { self[column].bool }
    public func date(_ column: String) -> Date? { self[column].date }
}

public enum SQLiteError: Error, LocalizedError {
    case openFailed(String)
    case prepareFailed(sql: String, message: String)
    case stepFailed(sql: String, message: String)
    case bindFailed(message: String)
    case notInTransaction

    public var errorDescription: String? {
        switch self {
        case .openFailed(let message): return "SQLite open failed: \(message)"
        case .prepareFailed(let sql, let message): return "SQLite prepare failed: \(message) — \(sql.prefix(240))"
        case .stepFailed(let sql, let message): return "SQLite step failed: \(message) — \(sql.prefix(240))"
        case .bindFailed(let message): return "SQLite bind failed: \(message)"
        case .notInTransaction: return "SQLite transaction was not active"
        }
    }
}

public final class SQLiteConnection {
    fileprivate let handle: OpaquePointer

    fileprivate init(handle: OpaquePointer) {
        self.handle = handle
    }

    @discardableResult
    public func execute(_ sql: String, _ bindings: [SQLiteValue] = []) throws -> Int {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw SQLiteError.stepFailed(sql: sql, message: errorMessage)
        }
        return Int(sqlite3_changes(handle))
    }

    public func executeScript(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &error)
        if result != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(error)
            throw SQLiteError.stepFailed(sql: sql, message: message)
        }
    }

    public func query(_ sql: String, _ bindings: [SQLiteValue] = []) throws -> [SQLiteRow] {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        var rows: [SQLiteRow] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW {
                rows.append(readRow(statement))
            } else if result == SQLITE_DONE {
                break
            } else {
                throw SQLiteError.stepFailed(sql: sql, message: errorMessage)
            }
        }
        return rows
    }

    public func scalarInt(_ sql: String, _ bindings: [SQLiteValue] = []) throws -> Int {
        guard let row = try query(sql, bindings).first else { return 0 }
        return row.values.values.first?.int ?? 0
    }

    public var lastInsertRowID: Int64 {
        sqlite3_last_insert_rowid(handle)
    }

    private func prepare(_ sql: String, _ bindings: [SQLiteValue]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw SQLiteError.prepareFailed(sql: sql, message: errorMessage)
        }
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let bindResult: Int32
            switch value {
            case .null:
                bindResult = sqlite3_bind_null(statement, index)
            case .integer(let number):
                bindResult = sqlite3_bind_int64(statement, index, number)
            case .real(let number):
                bindResult = sqlite3_bind_double(statement, index, number)
            case .text(let text):
                bindResult = sqlite3_bind_text(statement, index, text, -1, SQLITE_TRANSIENT)
            case .blob(let data):
                bindResult = data.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), SQLITE_TRANSIENT)
                }
            }
            if bindResult != SQLITE_OK {
                sqlite3_finalize(statement)
                throw SQLiteError.bindFailed(message: errorMessage)
            }
        }
        return statement
    }

    private func readRow(_ statement: OpaquePointer) -> SQLiteRow {
        var values: [String: SQLiteValue] = [:]
        for index in 0..<sqlite3_column_count(statement) {
            let name = String(cString: sqlite3_column_name(statement, index))
            switch sqlite3_column_type(statement, index) {
            case SQLITE_INTEGER:
                values[name] = .integer(sqlite3_column_int64(statement, index))
            case SQLITE_FLOAT:
                values[name] = .real(sqlite3_column_double(statement, index))
            case SQLITE_TEXT:
                if let text = sqlite3_column_text(statement, index) {
                    values[name] = .text(String(cString: text))
                } else {
                    values[name] = .null
                }
            case SQLITE_BLOB:
                let length = Int(sqlite3_column_bytes(statement, index))
                if let bytes = sqlite3_column_blob(statement, index), length > 0 {
                    values[name] = .blob(Data(bytes: bytes, count: length))
                } else {
                    values[name] = .blob(Data())
                }
            default:
                values[name] = .null
            }
        }
        return SQLiteRow(values: values)
    }

    private var errorMessage: String {
        String(cString: sqlite3_errmsg(handle))
    }
}

public final class SQLiteDatabase {
    private var handle: OpaquePointer?
    private let lock = NSLock()
    private let path: String

    public init(path: String, busyTimeoutMilliseconds: Int = 4_000) throws {
        self.path = path
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(path, &database, flags, nil)
        guard result == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let database { sqlite3_close(database) }
            throw SQLiteError.openFailed(message)
        }
        self.handle = database
        sqlite3_busy_timeout(database, Int32(max(100, busyTimeoutMilliseconds)))
        try configure(database)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    deinit {
        if let handle { sqlite3_close(handle) }
    }

    private func configure(_ database: OpaquePointer) throws {
        let pragmas = [
            "PRAGMA journal_mode=WAL;",
            "PRAGMA synchronous=NORMAL;",
            "PRAGMA foreign_keys=ON;",
            "PRAGMA wal_autocheckpoint=1000;",
            "PRAGMA temp_store=MEMORY;",
            "PRAGMA secure_delete=ON;"
        ]
        for pragma in pragmas {
            var error: UnsafeMutablePointer<CChar>?
            let result = sqlite3_exec(database, pragma, nil, nil, &error)
            if result != SQLITE_OK {
                let message = error.map { String(cString: $0) } ?? "unknown error"
                sqlite3_free(error)
                throw SQLiteError.openFailed("\(pragma) — \(message)")
            }
        }
    }

    public func read<T>(_ body: (SQLiteConnection) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { throw SQLiteError.openFailed("database is closed") }
        return try body(SQLiteConnection(handle: handle))
    }

    @discardableResult
    public func transaction<T>(_ body: (SQLiteConnection) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { throw SQLiteError.openFailed("database is closed") }
        let connection = SQLiteConnection(handle: handle)
        try connection.execute("BEGIN IMMEDIATE;")
        do {
            let value = try body(connection)
            try connection.execute("COMMIT;")
            return value
        } catch {
            _ = try? connection.execute("ROLLBACK;")
            throw error
        }
    }

    public func checkpoint() throws {
        try read { connection in
            _ = try connection.query("PRAGMA wal_checkpoint(TRUNCATE);")
        }
    }

    public func vacuum() throws {
        _ = try read { connection in
            try connection.execute("VACUUM;")
        }
    }

    public var databasePath: String { path }
}
