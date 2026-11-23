import Foundation

enum HTTP {
    struct Reply: Sendable {
        var status: Int
        var data: Data
        var retryAfter: TimeInterval?
    }

    /// One shared session with no cache, cookies or credential storage: each poll is a single
    /// small request, so there's nothing worth keeping in memory or on disk between them.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        return URLSession(configuration: configuration)
    }()

    static func get(_ url: URL, headers: [String: String]) async throws -> Reply {
        try await send(URLRequest(url: url), headers: headers)
    }

    static func post(_ url: URL, headers: [String: String], body: Data) async throws -> Reply {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        return try await send(request, headers: headers)
    }

    private static func send(_ request: URLRequest, headers: [String: String]) async throws -> Reply {
        var request = request
        request.setValue("LLMits", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        return Reply(
            status: http?.statusCode ?? 0,
            data: data,
            retryAfter: retryAfter(http?.value(forHTTPHeaderField: "Retry-After"))
        )
    }

    /// A Retry-After header as seconds from now: either whole seconds or an HTTP date, clamped to
    /// a day. Anything else (`inf`, `nan`, garbage) is ignored rather than trusted.
    static func retryAfter(_ value: String?, now: Date = .now) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = Int(value) {
            return TimeInterval(min(max(seconds, 0), 86_400))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return min(max(date.timeIntervalSince(now), 0), 86_400)
    }
}
