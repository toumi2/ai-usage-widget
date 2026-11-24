import Foundation

enum ClaudeReaderError: LocalizedError, Equatable {
    case notSignedIn
    case expired
    case rateLimited
    case http(Int)
    case unreadable

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Claude Code isn’t signed in. Run `claude` in Terminal, sign in, then refresh."
        case .expired:
            return "Claude’s login needs renewing. Use Claude Code once, then refresh."
        case .rateLimited:
            return "Claude’s usage service is busy. The widget will try again in a few minutes."
        case .http(let status):
            return status == 0
                ? "Couldn’t reach Claude’s usage service. Check your connection, then refresh."
                : "Claude’s usage service answered with an error (\(status)). Try again later."
        case .unreadable:
            return "Claude’s usage answer couldn’t be read."
        }
    }
}

/// Reads Claude plan limits and reset credits from the usage endpoint that Claude Code's own
/// `/usage` screen uses. It is a plain HTTPS request: it never starts the Claude CLI, never sends
/// a prompt to a model, and uses no tokens.
///
/// It reads Claude Code's saved login from the Keychain (read-only), never refreshes, stores or
/// logs it. When the login has expired it keeps showing the last reading until Claude Code renews it.
/// The endpoint is not publicly documented, so any failure leaves the last reading in place.
struct ClaudeUsageReader {
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let cache = SnapshotCache(defaults: .standard)

    /// The reading for the widget: reuses a recent one, backs off after errors and rate limits.
    func readUsage() throws -> UsageSnapshot {
        try Self.cache.value(fetch: { try fetchUsage() })
    }

    /// One request to the usage endpoint, without the cache.
    func fetchUsage(now: Date = Date()) throws -> UsageSnapshot {
        guard let token = Self.accessToken() else { throw ClaudeReaderError.notSignedIn }
        if let expiry = token.expiresAt, expiry < now { throw ClaudeReaderError.expired }

        let userAgent = "claude-cli/\(Self.cliVersion() ?? "2.1.0") (external, cli)"
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
                    throw ClaudeReaderError.unreadable
                }
#if DEBUG
                if ProcessInfo.processInfo.environment["CODEX_USAGE_DEBUG_CLAUDE"] != nil {
                    print("keys:", object.keys.sorted())
                    for key in ["five_hour", "seven_day"] {
                        print("\(key):", object[key].map { String(describing: $0) } ?? "missing")
                    }
                }
#endif
                return try Self.snapshot(fromUsageResponse: object, now: now)
            }
            if status == 401 { throw ClaudeReaderError.expired }
            if status == 429 { throw ClaudeReaderError.rateLimited }
            if status != 400 && status != 403 { break }
        }
        throw ClaudeReaderError.http(lastStatus)
    }

    // MARK: Parsing (covered by tests)

    /// Turns the endpoint's answer into a snapshot. `five_hour` and `seven_day` hold
    /// `utilization` (percent used, 0–100) and `resets_at` (ISO 8601).
    static func snapshot(fromUsageResponse object: [String: Any], now: Date = Date()) throws -> UsageSnapshot {
        let fiveHour = window(object["five_hour"], durationMins: 300)
        let weekly = window(object["seven_day"], durationMins: 10_080)
        guard fiveHour != nil || weekly != nil else { throw ClaudeReaderError.unreadable }
        return UsageSnapshot(weekly: weekly, fiveHour: fiveHour,
                             resetCredits: try? credits(fromUsageResponse: object, now: now),
                             updatedAt: now)
    }

    static func window(_ value: Any?, durationMins: Double) -> UsageWindow? {
        guard let block = value as? [String: Any],
              let used = (block["utilization"] as? NSNumber)?.doubleValue,
              used.isFinite else { return nil }
        let resetsAt = (block["resets_at"] as? String).flatMap(parseDate)?.timeIntervalSince1970
        return UsageWindow(usedPercent: min(100, max(0, used)), windowDurationMins: durationMins, resetsAt: resetsAt)
    }

    /// Turns the `cedar_ember` block into a count with expiry dates.
    /// A grant counts when it isn't paused, has resets left, has started and hasn't ended.
    /// Throws when the block is missing or unclear, which shows as unknown ("Resets —"), not zero.
    static func credits(fromUsageResponse object: [String: Any], now: Date = Date()) throws -> ResetCredits {
        guard let block = object["cedar_ember"] as? [String: Any] else { throw ClaudeReaderError.unreadable }
        if let eligible = block["eligible"] as? Bool, eligible == false {
            // "cli_version" means the request looked like an old CLI, not that there are no resets.
            if let reason = block["ineligible_reason"] as? String, reason == "cli_version" {
                throw ClaudeReaderError.unreadable
            }
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
        guard credits.count <= 50 else { throw ClaudeReaderError.unreadable }
        return ResetCredits(availableCount: credits.count, credits: credits)
    }

    static func parseDate(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }

    /// "2.1.322" from a path such as `~/.local/share/claude/versions/2.1.322`.
    static func version(inPath path: String) -> String? {
        guard let range = path.range(of: #"\d+\.\d+\.\d+"#, options: [.regularExpression, .backwards]) else { return nil }
        return String(path[range])
    }

    // MARK: Cache

    /// Keeps the last good reading, also across app restarts, so a rate limit, an expired login
    /// or a quick relaunch shows the last known numbers instead of an error. No login data is stored.
    final class SnapshotCache {
        /// The endpoint rate-limits, so ask at most about once a minute even with a 30-second refresh.
        static let minimumSpacing: TimeInterval = 55
        static let maximumAge: TimeInterval = 86_400

        private let lock = NSLock()
        private let defaults: UserDefaults?
        private static let key = "claude.usageSnapshot"
        private var last: UsageSnapshot?
        private var fetchedAt = Date.distantPast
        private var retryAfter = Date.distantPast

        init(defaults: UserDefaults? = nil) {
            self.defaults = defaults
            if let saved = defaults?.dictionary(forKey: Self.key), let snapshot = Self.decode(saved) {
                last = snapshot
                fetchedAt = snapshot.updatedAt
            }
        }

        func value(now: Date = Date(), fetch: () throws -> UsageSnapshot) throws -> UsageSnapshot {
            lock.lock()
            if let saved = last, now.timeIntervalSince(saved.updatedAt) > Self.maximumAge { last = nil }
            let cached = last
            let fresh = now.timeIntervalSince(fetchedAt) < Self.minimumSpacing
            let waiting = now < retryAfter
            lock.unlock()
            if let cached, fresh || waiting { return cached }
            do {
                let snapshot = try fetch()
                lock.lock(); last = snapshot; fetchedAt = now; retryAfter = .distantPast; lock.unlock()
                save(snapshot)
                return snapshot
            } catch {
                let pause: TimeInterval
                switch error as? ClaudeReaderError {
                case .rateLimited: pause = 600
                case .expired, .notSignedIn: pause = 300
                default: pause = 120
                }
                lock.lock(); retryAfter = now.addingTimeInterval(pause); lock.unlock()
                if let cached { return cached }
                throw error
            }
        }

        private func save(_ snapshot: UsageSnapshot) {
            guard let defaults else { return }
            var entry: [String: Any] = ["updatedAt": snapshot.updatedAt.timeIntervalSince1970]
            if let window = snapshot.fiveHour { entry["fiveHour"] = Self.encode(window) }
            if let window = snapshot.weekly { entry["weekly"] = Self.encode(window) }
            if let credits = snapshot.resetCredits {
                entry["credits"] = credits.availableCount
                entry["expiries"] = (credits.credits ?? []).map { $0.expiresAt ?? 0 }
            }
            defaults.set(entry, forKey: Self.key)
        }

        private static func encode(_ window: UsageWindow) -> [String: Double] {
            var value = ["used": window.usedPercent]
            if let mins = window.windowDurationMins { value["mins"] = mins }
            if let resetsAt = window.resetsAt { value["resetsAt"] = resetsAt }
            return value
        }

        private static func decode(_ saved: [String: Any]) -> UsageSnapshot? {
            guard let time = saved["updatedAt"] as? Double else { return nil }
            func window(_ key: String) -> UsageWindow? {
                guard let value = saved[key] as? [String: Double], let used = value["used"] else { return nil }
                return UsageWindow(usedPercent: used, windowDurationMins: value["mins"], resetsAt: value["resetsAt"])
            }
            var credits: ResetCredits?
            if let count = saved["credits"] as? Int {
                let expiries = saved["expiries"] as? [Double] ?? []
                credits = ResetCredits(availableCount: count, credits: expiries.map {
                    ResetCredit(status: "available", expiresAt: $0 > 0 ? $0 : nil)
                })
            }
            let fiveHour = window("fiveHour"), weekly = window("weekly")
            guard fiveHour != nil || weekly != nil else { return nil }
            return UsageSnapshot(weekly: weekly, fiveHour: fiveHour, resetCredits: credits,
                                 updatedAt: Date(timeIntervalSince1970: time))
        }
    }

    // MARK: Keychain, CLI version and network

    private struct Token {
        let value: String
        let expiresAt: Date?
    }

    /// Claude Code keeps its login in the "Claude Code-credentials" Keychain item as JSON.
    /// Claude Code writes that item with macOS's `security` tool and rewrites it on every token
    /// refresh, which clears any "Always Allow" given to other apps. The item always trusts
    /// `security`, so reading it the same way never shows a Keychain prompt.
    private static func accessToken() -> Token? {
        guard let data = readKeychainItem(service: "Claude Code-credentials"),
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

    private static func readKeychainItem(service: String) -> Data? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        // If macOS ever does show a prompt, give up rather than hang the refresh.
        let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timer)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()
        guard process.terminationStatus == 0 else { return nil }
        var trimmed = data
        while let last = trimmed.last, last == 0x0A || last == 0x0D { trimmed.removeLast() }
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The installed CLI's version, read from where its launcher points. It never runs the CLI.
    /// The usage service only reports reset credits to current CLI versions.
    static func cliVersion() -> String? {
        let fileManager = FileManager.default
        let home = NSHomeDirectory()
        let launchers = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude",
                         "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        for launcher in launchers where fileManager.fileExists(atPath: launcher) {
            let resolved = URL(fileURLWithPath: launcher).resolvingSymlinksInPath().path
            if let version = version(inPath: resolved) { return version }
        }
        // Native installs keep every version side by side; the newest is the one in use.
        let versionsFolder = "\(home)/.local/share/claude/versions"
        let versions = ((try? fileManager.contentsOfDirectory(atPath: versionsFolder)) ?? []).compactMap(version(inPath:))
        return versions.max { $0.compare($1, options: .numeric) == .orderedAscending }
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
        if failure != nil { throw ClaudeReaderError.http(0) }
        guard let result else { throw ClaudeReaderError.http(0) }
        return result
    }
}
