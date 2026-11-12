import Foundation
import Security

/// Reads Claude's limit-reset credits from the usage endpoint that Claude Code itself uses.
/// The Claude CLI's screens don't show this count, so this is the only source.
/// It reads Claude Code's saved login from the Keychain (read-only) and never stores or logs it.
/// The endpoint is not publicly documented, so any failure simply leaves the count unknown.
struct ClaudeResetCreditsReader {
    enum ReadError: Error {
        case noLogin
        case expired
        case http(Int)
        case unreadable
    }

    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// Reset credits change rarely and the endpoint rate-limits, so reuse a reading for 10 minutes
    /// and back off for 5 minutes after a 429.
    private static let cache = CreditCache()

    func cachedCredits(cliVersion: String?) -> ResetCredits? {
        Self.cache.value(fetch: { try readCredits(cliVersion: cliVersion) })
    }

    func readCredits(cliVersion: String?) throws -> ResetCredits {
        guard let token = Self.accessToken() else { throw ReadError.noLogin }
        if let expiry = token.expiresAt, expiry < Date() { throw ReadError.expired }

        let userAgent = "claude-cli/\(cliVersion ?? "2.1.0") (external, cli)"
        var lastStatus = 0
        // The reset inventory is opt-in with cedar_ember=1; retry once without it if rejected.
        for includeInventory in [true, false] {
            var components = URLComponents(url: Self.usageURL, resolvingAgainstBaseURL: false)!
            if includeInventory { components.queryItems = [URLQueryItem(name: "cedar_ember", value: "1")] }
            var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            request.setValue("Bearer \(token.value)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

            let (data, status) = try Self.send(request)
            lastStatus = status
            if status == 200 {
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw ReadError.unreadable
                }
                return try Self.credits(fromUsageResponse: object)
            }
            if status != 400 && status != 403 { break }
        }
        throw ReadError.http(lastStatus)
    }

    final class CreditCache {
        private let lock = NSLock()
        private var last: ResetCredits?
        private var fetchedAt = Date.distantPast
        private var retryAfter = Date.distantPast

        func value(now: Date = Date(), fetch: () throws -> ResetCredits) -> ResetCredits? {
            lock.lock()
            let cached = last
            let fresh = now.timeIntervalSince(fetchedAt) < 600
            let waiting = now < retryAfter
            lock.unlock()
            if fresh || waiting { return cached }
            do {
                let credits = try fetch()
                lock.lock(); last = credits; fetchedAt = now; lock.unlock()
                return credits
            } catch ReadError.http(429) {
                lock.lock(); retryAfter = now.addingTimeInterval(300); lock.unlock()
                return cached
            } catch {
                // Try again on the next refresh; keep showing the last good count meanwhile.
                lock.lock(); retryAfter = now.addingTimeInterval(60); lock.unlock()
                return cached
            }
        }
    }

    // MARK: Parsing (covered by tests)

    /// Turns the `cedar_ember` block into a count with expiry dates.
    /// A grant counts when it isn't paused, has resets left, has started and hasn't ended.
    static func credits(fromUsageResponse object: [String: Any], now: Date = Date()) throws -> ResetCredits {
        guard let block = object["cedar_ember"] as? [String: Any] else { throw ReadError.unreadable }
        if let eligible = block["eligible"] as? Bool, eligible == false {
            return ResetCredits(availableCount: 0, credits: [])
        }
        let grants = block["grants"] as? [[String: Any]] ?? []
        var credits: [ResetCredit] = []
        for grant in grants.prefix(200) {
            guard let left = grant["resets_left"] as? Int, left > 0, left <= 50,
                  let paused = grant["paused"] as? Bool, !paused else { continue }
            if let total = grant["resets_total"] as? Int, left > total { continue }
            let start = (grant["starts_at"] as? String).flatMap(parseDate)
            let end = (grant["ends_at"] as? String).flatMap(parseDate)
            if let start, start > now { continue }
            if let end, end <= now { continue }
            for _ in 0..<left {
                credits.append(ResetCredit(status: "available", expiresAt: end?.timeIntervalSince1970))
            }
        }
        guard credits.count <= 50 else { throw ReadError.unreadable }
        return ResetCredits(availableCount: credits.count, credits: credits)
    }

    static func parseDate(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }

    // MARK: Keychain and network

    private struct Token {
        let value: String
        let expiresAt: Date?
    }

    /// Claude Code keeps its login in the "Claude Code-credentials" Keychain item as JSON.
    private static func accessToken() -> Token? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = object["claudeAiOauth"] as? [String: Any],
              let value = oauth["accessToken"] as? String, !value.isEmpty else { return nil }
        var expiresAt: Date?
        if let raw = oauth["expiresAt"] as? Double {
            // Stored in milliseconds; tolerate seconds too.
            expiresAt = Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1000 : raw)
        }
        return Token(value: value, expiresAt: expiresAt)
    }

    private static func send(_ request: URLRequest) throws -> (Data, Int) {
        let semaphore = DispatchSemaphore(value: 0)
        var result: (Data, Int)?
        var failure: Error?
        let session = URLSession(configuration: .ephemeral)
        session.dataTask(with: request) { data, response, error in
            if let error { failure = error }
            result = (data ?? Data(), (response as? HTTPURLResponse)?.statusCode ?? 0)
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 20)
        session.invalidateAndCancel()
        if let failure { throw failure }
        guard let result else { throw ReadError.http(0) }
        return result
    }
}
