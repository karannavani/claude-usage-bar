import Foundation
import SQLite3
import Testing
@testable import UsageCore

/// The shape of a real response (a plan merged with SuperGrok, on a weekly cycle), with the
/// model list shortened.
private let sample = """
{
  "billingCycleStart": "1795423342421",
  "billingCycleEnd": "1796028142421",
  "planUsage": {
    "remainingBonus": false,
    "bonusTooltip": "We work with model providers to give you free usage beyond what you've purchased.",
    "autoPercentUsed": 1.0272912927780184,
    "totalPercentUsed": 1.0272912927780184
  },
  "spendLimitUsage": {"limitType": "user"},
  "displayThreshold": 200,
  "enabled": true,
  "displayMessage": "You've used 1% of your included usage",
  "autoBucketModels": ["default", "composer-2"]
}
"""

private func rows(_ json: String) throws -> [LimitRow] {
    try CursorUsageResponse.decode(Data(json.utf8)).rows(now: now)
}

@Suite struct CursorUsageTests {
    @Test func weeklyCycleFromAMergedPlan() throws {
        let rows = try rows(sample)
        #expect(rows.map(\.title) == ["Weekly"])
        #expect(rows.first?.percent == 1.0272912927780184)
        #expect(rows.first?.resetsAt == Date(timeIntervalSince1970: 1_796_028_142.421))
        #expect(rows.first?.windowLength == 604_800)
        #expect(rows.first?.severity == .normal)
    }

    @Test func monthlyCycleWithOnDemandSpending() throws {
        // 2026-11-01 to 2026-12-01, as numbers this time.
        let rows = try rows("""
        {"billingCycleStart": 1793491200000, "billingCycleEnd": 1796083200000, "enabled": true,
         "planUsage": {"totalPercentUsed": 92, "autoPercentUsed": 40},
         "spendLimitUsage": {"individualLimit": 2000, "individualUsed": 500, "limitType": "user"}}
        """)
        #expect(rows.map(\.title) == ["Monthly", "Monthly · On-demand"])
        #expect(rows.map(\.percent) == [92, 25])
        #expect(rows.map(\.severity) == [.critical, .normal])
        #expect(rows.first?.windowLength == TimeInterval(30 * 86_400), "\(String(describing: rows.first))")
    }

    @Test func fallsBackToAutoUsageAndSkipsDisabledPlans() throws {
        #expect(try rows(#"{"planUsage": {"autoPercentUsed": 80}}"#).map(\.percent) == [80])
        #expect(try rows(#"{"planUsage": {"autoPercentUsed": 80}}"#).map(\.title) == ["Usage"])
        #expect(try rows(#"{"enabled": false, "planUsage": {"totalPercentUsed": 10}}"#).isEmpty)
        #expect(try rows(#"{"spendLimitUsage": {"individualLimit": 0, "individualUsed": 0}}"#).isEmpty)
    }

    @Test func rollsOverOnceTheCycleEnds() throws {
        let usage = try CursorUsageResponse.decode(Data(sample.utf8))
        let later = Date(timeIntervalSince1970: 1_796_028_200)
        #expect(usage.rows(now: later).map(\.percent) == [0])
    }

    @Test func survivesNonsense() throws {
        let rows = try rows("""
        {"billingCycleStart": "soon", "billingCycleEnd": 1e30, "enabled": "yes",
         "planUsage": {"totalPercentUsed": "1e19"},
         "spendLimitUsage": {"individualLimit": "nan", "individualUsed": -5}}
        """)
        #expect(rows.map(\.percent) == [1000])
        #expect(rows.first?.resetsAt == nil)
        #expect(rows.first?.windowLength == nil)
        #expect(throws: (any Error).self) { try CursorUsageResponse.decode(Data("[]".utf8)) }
    }

    @Test func planNames() {
        #expect(Format.cursorPlan("pro") == "Pro")
        #expect(Format.cursorPlan("pro_plus") == "Pro+")
        #expect(Format.cursorPlan("ULTRA") == "Ultra")
        #expect(Format.cursorPlan("free") == "Hobby")
        #expect(Format.cursorPlan("super") == "SuperGrok")
        #expect(Format.cursorPlan("something_new") == nil)
        #expect(Format.cursorPlan(nil) == nil)
    }
}

@Suite struct CursorCredentialTests {
    /// A token whose payload carries `exp`, like Cursor's.
    private static let token = "eyJhbGciOiJIUzI1NiJ9.\(Data(#"{"exp":1800209188}"#.utf8).base64EncodedString()).sig"

    /// A database laid out like Cursor's `state.vscdb`.
    private func database(_ rows: [String: String]) throws -> URL {
        let file = FileManager.default.temporaryDirectory.appending(path: "cursor-\(UUID().uuidString).vscdb")
        var database: OpaquePointer?
        #expect(sqlite3_open(file.path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        #expect(sqlite3_exec(database, "CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)", nil, nil, nil) == SQLITE_OK)
        for (key, value) in rows {
            let escaped = value.replacingOccurrences(of: "'", with: "''")
            #expect(sqlite3_exec(database, "INSERT INTO ItemTable VALUES ('\(key)', '\(escaped)')", nil, nil, nil) == SQLITE_OK)
        }
        return file
    }

    @Test func readsTheTokenAndPlan() throws {
        let file = try database([
            "cursorAuth/accessToken": Self.token,
            "cursorAuth/stripeMembershipType": "pro_plus",
            "cursorAuth/refreshToken": "never-read",
        ])
        defer { try? FileManager.default.removeItem(at: file) }
        let credentials = try CursorCredentialStore.load(from: file)
        #expect(credentials.accessToken == Self.token)
        #expect(credentials.membershipType == "pro_plus")
        #expect(credentials.expiresAt == Date(timeIntervalSince1970: 1_800_209_188))
    }

    @Test func signedOutAndMissingAreNotFound() throws {
        let empty = try database(["cursorAuth/accessToken": ""])
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(throws: CredentialError.notFound) { try CursorCredentialStore.load(from: empty) }
        let missing = FileManager.default.temporaryDirectory.appending(path: "no-such-\(UUID().uuidString).vscdb")
        #expect(throws: CredentialError.notFound) { try CursorCredentialStore.load(from: missing) }
    }

    @Test func anotherFileIsUnreadable() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "garbage-\(UUID().uuidString).vscdb")
        try Data("not a database".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(throws: CredentialError.unreadable) { try CursorCredentialStore.load(from: file) }
    }
}

@Suite struct CursorSourceTests {
    private let valid = CursorCredentials(accessToken: "token", expiresAt: now.addingTimeInterval(86_400), membershipType: "pro")

    @Test func postsWithTheTokenAndReadsThePlan() async {
        let requests = Recorder<(URL, [String: String], Data)>()
        let source = CursorSource(
            loadCredentials: { [valid] in valid },
            post: { url, headers, body in requests.record((url, headers, body)); return reply(200, sample) }
        )
        let outcome = await source.fetch(now: now)
        #expect(requests.all.first?.0.absoluteString == "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")
        #expect(requests.all.first?.1["Authorization"] == "Bearer token")
        #expect(requests.all.first?.1["Content-Type"] == "application/json")
        #expect(requests.all.first?.2 == Data("{}".utf8))
        guard case let .success(usage) = outcome else {
            Issue.record("expected success, got \(outcome)")
            return
        }
        #expect(usage.service == .cursor)
        #expect(usage.plan == "Pro")
        #expect(usage.rows.map(\.title) == ["Weekly"])
    }

    @Test func statusCodes() async {
        func outcome(_ reply: HTTP.Reply) async -> FetchOutcome {
            await CursorSource(loadCredentials: { [valid] in valid }, post: { _, _, _ in reply }).fetch(now: now)
        }
        #expect(await outcome(reply(401)) == .tokenExpired(plan: "Pro"))
        #expect(await outcome(reply(429, retryAfter: 60)) == .rateLimited(retryAfter: 60))
        #expect(await outcome(reply(500)) == .failed(.server(status: 500)))
        #expect(await outcome(reply(200, "[]")) == .failed(.unreadable))
    }

    @Test func aRejectedTokenIsNotSentAgain() async {
        let sent = Recorder<String>()
        let stored = Sequence([valid, valid, CursorCredentials(accessToken: "new", expiresAt: nil, membershipType: nil)])
        let source = CursorSource(loadCredentials: { stored.next() }, post: { _, headers, _ in
            sent.record(headers["Authorization"] ?? "")
            return headers["Authorization"] == "Bearer new" ? reply(200, sample) : reply(401)
        })
        #expect(await source.fetch(now: now) == .tokenExpired(plan: "Pro"))
        #expect(await source.fetch(now: now) == .tokenExpired(plan: "Pro"))
        guard case .success = await source.fetch(now: now) else {
            Issue.record("expected the new token to work")
            return
        }
        #expect(sent.all == ["Bearer token", "Bearer new"])
    }

    @Test func loginStates() async {
        let expired = CursorCredentials(accessToken: "old", expiresAt: now, membershipType: nil)
        #expect(await CursorSource(loadCredentials: { expired }, post: { _, _, _ in reply(200, sample) }).fetch(now: now) == .tokenExpired(plan: nil))
        #expect(await CursorSource(loadCredentials: { throw CredentialError.notFound }, post: { _, _, _ in reply(200, sample) }).fetch(now: now) == .notSignedIn)
        #expect(await CursorSource(loadCredentials: { throw CredentialError.unreadable }, post: { _, _, _ in reply(200, sample) }).fetch(now: now) == .failed(.loginUnreadable))
    }
}
