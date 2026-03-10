import Foundation
import SQLite3

struct Message {
    let rowid: Int64
    let text: String
    let isFromMe: Bool
    let handle: String
    let date: Int64
}

class MessageReader {
    let dbPath: String
    let targetHandle: String

    init() {
        self.dbPath = NSHomeDirectory() + "/Library/Messages/chat.db"

        // Load authorized sender from config file next to the binary
        let configPath = CommandLine.arguments[0]
            .split(separator: "/").dropLast().joined(separator: "/")
        let configFile = "/" + configPath + "/config.env"

        if let contents = try? String(contentsOfFile: configFile, encoding: .utf8) {
            var handle = ""
            for line in contents.split(separator: "\n") {
                if line.hasPrefix("AUTHORIZED_HANDLE=") {
                    handle = String(line.dropFirst("AUTHORIZED_HANDLE=".count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(of: "\"", with: "")
                }
            }
            self.targetHandle = handle
        } else {
            fputs("Error: config.env not found at \(configFile)\n", stderr)
            self.targetHandle = ""
        }
    }

    func getNewMessages(afterRowid: Int64) -> [Message] {
        var messages: [Message] = []
        var db: OpaquePointer?

        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            fputs("Error: Cannot open Messages database. Grant Full Disk Access to the message-reader binary.\n", stderr)
            return messages
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        let query = """
            SELECT m.ROWID, m.text, m.is_from_me, h.id, m.date
            FROM message m
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            WHERE h.id = ? AND m.ROWID > ? AND m.is_from_me = 0 AND m.text IS NOT NULL
                AND m.service = 'iMessage'
            ORDER BY m.date ASC
        """

        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return messages }
        defer { sqlite3_finalize(stmt) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, (targetHandle as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 2, afterRowid)

        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowid = sqlite3_column_int64(stmt, 0)
            let text = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let isFromMe = sqlite3_column_int(stmt, 2) != 0
            let handle = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
            let date = sqlite3_column_int64(stmt, 4)
            messages.append(Message(rowid: rowid, text: text, isFromMe: isFromMe, handle: handle, date: date))
        }

        return messages
    }

    func getLatestRowid() -> Int64 {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        let query = "SELECT MAX(ROWID) FROM message"
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }

        if sqlite3_step(stmt) == SQLITE_ROW {
            return sqlite3_column_int64(stmt, 0)
        }
        return 0
    }
}

// Main
let args = CommandLine.arguments
let reader = MessageReader()

if args.count > 1 && args[1] == "latest" {
    print(reader.getLatestRowid())
} else {
    let afterRowid = args.count > 1 ? Int64(args[1]) ?? 0 : 0
    let messages = reader.getNewMessages(afterRowid: afterRowid)
    for msg in messages {
        print("\(msg.rowid)|\(msg.text)")
    }
}
