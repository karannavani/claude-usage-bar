import Foundation

/// Cursor plan limits, read with the login the Cursor app keeps in its settings database.
public actor CursorSource: UsageSource {
    public nonisolated let service = Service.cursor

    static let endpoint = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!

    private let loadCredentials: @Sendable () throws -> CursorCredentials
    private let post: @Sendable (URL, [String: String], Data) async throws -> HTTP.Reply
    /// A token the server has turned down. It's never sent again; until Cursor stores a new one,
    /// checks only re-read the database.
    private var rejectedToken: String?

    public init() {
        self.init(loadCredentials: CursorCredentialStore.load, post: HTTP.post)
    }

    init(
        loadCredentials: @escaping @Sendable () throws -> CursorCredentials,
        post: @escaping @Sendable (URL, [String: String], Data) async throws -> HTTP.Reply
    ) {
        self.loadCredentials = loadCredentials
        self.post = post
    }

    public func fetch(now: Date) async -> FetchOutcome {
        let credentials: CursorCredentials
        do {
            credentials = try loadCredentials()
        } catch CredentialError.notFound {
            return .notSignedIn
        } catch {
            return .failed(.loginUnreadable)
        }
        let plan = Format.cursorPlan(credentials.membershipType)
        if credentials.accessToken != rejectedToken {
            rejectedToken = nil
        }
        if credentials.isExpired(at: now) || credentials.accessToken == rejectedToken {
            return .tokenExpired(plan: plan)
        }

        let headers = [
            "Authorization": "Bearer \(credentials.accessToken)",
            "Content-Type": "application/json",
            // A Connect RPC called with JSON: the version header asks for a plain JSON reply.
            "Connect-Protocol-Version": "1",
        ]

        let reply: HTTP.Reply
        do {
            reply = try await post(Self.endpoint, headers, Data("{}".utf8))
        } catch {
            return .failed(Failure(error))
        }

        switch reply.status {
        case 200:
            rejectedToken = nil
            guard let usage = try? CursorUsageResponse.decode(reply.data) else {
                return .failed(.unreadable)
            }
            return .success(ServiceUsage(service: .cursor, plan: plan, rows: usage.rows(now: now)))
        case 401:
            rejectedToken = credentials.accessToken
            return .tokenExpired(plan: plan)
        case 429:
            return .rateLimited(retryAfter: reply.retryAfter)
        case let status:
            return .failed(.server(status: status))
        }
    }
}
