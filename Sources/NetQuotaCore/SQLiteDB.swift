import Foundation
import SQLite3

public enum SQLValue {
    case int(Int64)
    case double(Double)
    case text(String)
    case null
}

public struct SQLiteError: Error, CustomStringConvertible {
    public let description: String
}

/// 系統內建 SQLite3 的極簡包裝。
public final class SQLiteDB {
    private var handle: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: String) throws {
        guard sqlite3_open(path, &handle) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(handle)
            throw SQLiteError(description: "無法開啟資料庫 \(path)：\(message)")
        }
        try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
    }

    deinit {
        sqlite3_close(handle)
    }

    public func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw SQLiteError(description: message)
        }
    }

    public func run(_ sql: String, _ args: [SQLValue] = []) throws {
        let statement = try prepare(sql, args)
        defer { sqlite3_finalize(statement) }
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE || code == SQLITE_ROW else { throw lastError() }
    }

    public func query(_ sql: String, _ args: [SQLValue] = [], _ row: (Row) -> Void) throws {
        let statement = try prepare(sql, args)
        defer { sqlite3_finalize(statement) }
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_ROW {
                row(Row(statement: statement))
            } else if code == SQLITE_DONE {
                return
            } else {
                throw lastError()
            }
        }
    }

    public func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN")
        do {
            try body()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String, _ args: [SQLValue]) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw lastError() }
        for (offset, value) in args.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .int(let v): sqlite3_bind_int64(statement, index, v)
            case .double(let v): sqlite3_bind_double(statement, index, v)
            case .text(let v): sqlite3_bind_text(statement, index, v, -1, Self.transient)
            case .null: sqlite3_bind_null(statement, index)
            }
        }
        return statement
    }

    private func lastError() -> SQLiteError {
        SQLiteError(description: String(cString: sqlite3_errmsg(handle)))
    }

    public struct Row {
        let statement: OpaquePointer?

        public func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
        public func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
        public func text(_ column: Int32) -> String? {
            guard let pointer = sqlite3_column_text(statement, column) else { return nil }
            return String(cString: pointer)
        }
        public func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }
    }
}
