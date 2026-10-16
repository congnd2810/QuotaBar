import Foundation
import SQLite3

/// Minimal read-only SQLite access for other apps' databases. Opened with `immutable=1` so nothing
/// (no lock, journal or WAL index file) is created next to the owner's database.
final class SQLiteReader {
    struct ReadError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private var db: OpaquePointer?

    init(_ url: URL) throws {
        let uri = "file:\(url.path)?mode=ro&immutable=1"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            throw ReadError(message: message)
        }
    }

    deinit { sqlite3_close(db) }

    func tableExists(_ name: String) -> Bool {
        (try? rows("SELECT name FROM sqlite_master WHERE type='table' AND name=?", [name]).isEmpty == false) ?? false
    }

    /// Runs a query; each row maps column name -> String / Int64 / Double / Data (or absent for NULL).
    func rows(_ sql: String, _ parameters: [String] = []) throws -> [[String: Any]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ReadError(message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, parameter) in parameters.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), parameter, -1, transient)
        }
        var result: [[String: Any]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [String: Any] = [:]
            for column in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, column))
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: row[name] = sqlite3_column_int64(statement, column)
                case SQLITE_FLOAT: row[name] = sqlite3_column_double(statement, column)
                case SQLITE_TEXT: row[name] = String(cString: sqlite3_column_text(statement, column))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, column))
                    row[name] = sqlite3_column_blob(statement, column).map { Data(bytes: $0, count: count) } ?? Data()
                default: break
                }
            }
            result.append(row)
        }
        return result
    }
}
