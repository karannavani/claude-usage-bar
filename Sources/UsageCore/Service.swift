import Foundation

/// A service whose plan limits the app can show.
public enum Service: String, CaseIterable, Codable, Sendable, Identifiable {
    case claude
    case chatGPT
    case cursor

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .claude: "Claude"
        case .chatGPT: "ChatGPT"
        case .cursor: "Cursor"
        }
    }

    /// The tool whose login the app reads.
    public var loginTool: String {
        switch self {
        case .claude: "Claude Code"
        case .chatGPT: "Codex"
        case .cursor: "Cursor"
        }
    }
}

/// One service's limits as they were when fetched.
public struct ServiceUsage: Codable, Sendable, Equatable {
    public var service: Service
    /// The plan's display name, e.g. "Max 20x" or "Pro 100".
    public var plan: String?
    public var rows: [LimitRow]

    public init(service: Service, plan: String?, rows: [LimitRow]) {
        self.service = service
        self.plan = plan
        self.rows = rows
    }

    /// The rows as they stand at `now`, with any window whose reset has passed shown as reset.
    public func rows(at now: Date) -> [LimitRow] {
        rows.map { $0.rolledOver(at: now) }
    }
}

public enum FetchOutcome: Sendable, Equatable {
    case success(ServiceUsage)
    /// No login for this service was found on this Mac.
    case notSignedIn
    /// The stored token has expired or was rejected; its tool renews it the next time it runs.
    case tokenExpired(plan: String?)
    case rateLimited(retryAfter: TimeInterval?)
    case failed(Failure)
}

/// Why a fetch failed, kept structured so the copy can say what happens next.
public enum Failure: Sendable, Equatable {
    case offline
    /// The service answered with an unexpected HTTP status.
    case server(status: Int)
    /// The service answered, but not in a shape the app understands.
    case unreadable
    /// The tool's stored login exists but couldn't be read just now (e.g. the keychain was
    /// briefly unavailable, or the login file was mid-write).
    case loginUnreadable
    case other(String)

    init(_ error: any Error) {
        let offline: Set<URLError.Code> = [
            .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
            .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff,
        ]
        if let error = error as? URLError, offline.contains(error.code) {
            self = .offline
        } else {
            self = .other(error.localizedDescription)
        }
    }
}

/// Why a service's numbers may be out of date.
public enum Problem: Sendable, Equatable {
    case tokenExpired
    case rateLimited(until: Date)
    case failed(Failure)
}

/// Fetches one service's usage. Implementations only ever read the stored login.
public protocol UsageSource: Sendable {
    var service: Service { get }
    func fetch(now: Date) async -> FetchOutcome
}

public enum CredentialError: Error, Equatable {
    /// There's no login: the person isn't signed in. The only error that means "signed out".
    case notFound
    /// A login exists but its contents aren't in a shape the app understands.
    case malformed
    /// A login may exist but couldn't be read just now.
    case unreadable
}
