import Foundation
import SQLite3

/// The subset of the Cursor app's login this app needs.
public struct CursorCredentials: Sendable, Equatable {
    public var accessToken: String
    public var expiresAt: Date?
    /// The plan Cursor last cached, e.g. `pro` or `pro_plus`.
    public var membershipType: String?

    /// Treats a token as expired a minute early so a request never races its expiry.
    public func isExpired(at now: Date = .now) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now.addingTimeInterval(60)
    }
}

/// Reads the login the Cursor app keeps in its settings database,
/// `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`.
///
/// Strictly read-only, like the other services: the database is opened read-only and Cursor
/// renews its own token whenever it runs.
public enum CursorCredentialStore {
    static let accessTokenKey = "cursorAuth/accessToken"
    static let membershipKey = "cursorAuth/stripeMembershipType"

    public static func load() throws -> CursorCredentials {
        try load(from: databaseFile())
    }

    static func databaseFile() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    static func load(from file: URL) throws -> CursorCredentials {
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw CredentialError.notFound
        }
        let values = try read(keys: [accessTokenKey, membershipKey], from: file)
        return try credentials(from: values)
    }

    /// Builds the login from the database's values. Signing out of Cursor clears the token, so a
    /// missing or empty one means signed out.
    static func credentials(from values: [String: String]) throws -> CursorCredentials {
        guard let token = values[accessTokenKey]?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            throw CredentialError.notFound
        }
        let membership = values[membershipKey]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return CursorCredentials(
            accessToken: token,
            expiresAt: JWT.expiry(of: token),
            membershipType: membership?.isEmpty == false ? membership : nil
        )
    }

    /// Reads values from the database's `ItemTable`, the key-value table VS Code-based editors
    /// keep their state in. Any failure to open or query it (Cursor mid-write, a locked file)
    /// is `unreadable`, never "signed out".
    static func read(keys: [String], from file: URL) throws -> [String: String] {
        var database: OpaquePointer?
        defer { sqlite3_close_v2(database) }
        guard sqlite3_open_v2(file.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else {
            throw CredentialError.unreadable
        }
        sqlite3_busy_timeout(database, 2000)

        let placeholders = Array(repeating: "?", count: keys.count).joined(separator: ", ")
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "SELECT key, value FROM ItemTable WHERE key IN (\(placeholders))", -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw CredentialError.unreadable
        }
        // SQLITE_TRANSIENT: SQLite copies each key before the Swift string goes away.
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, key) in keys.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), key, -1, transient)
        }

        var values: [String: String] = [:]
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let key = text(statement, 0) else { continue }
                values[key] = text(statement, 1)
            case SQLITE_DONE:
                return values
            default:
                throw CredentialError.unreadable
            }
        }
    }

    /// A column as text, whether it was stored as text or as a blob.
    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        let length = Int(sqlite3_column_bytes(statement, column))
        guard let bytes = sqlite3_column_blob(statement, column), length > 0 else { return nil }
        return String(data: Data(bytes: bytes, count: length), encoding: .utf8)
    }
}
