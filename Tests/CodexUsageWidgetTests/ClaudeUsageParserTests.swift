import Foundation
import XCTest
@testable import CodexUsageWidget

final class ClaudeUsageParserTests: XCTestCase {
    private let now = ClaudeUsageReader.parseDate("2026-10-23T18:00:00Z")!

    private func object(_ json: String) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    }

    func testFrontmostAppMapping() {
        XCTAssertEqual(UsageProvider.matching(bundleIdentifier: "com.anthropic.claudefordesktop"), .claude)
        XCTAssertEqual(UsageProvider.matching(bundleIdentifier: "com.openai.codex"), .codex)
        XCTAssertEqual(UsageProvider.matching(bundleIdentifier: "com.openai.chat"), .codex)
        XCTAssertNil(UsageProvider.matching(bundleIdentifier: "com.apple.Terminal"))
        XCTAssertNil(UsageProvider.matching(bundleIdentifier: nil))
    }

    // MARK: Limits from the usage endpoint

    func testParsesFiveHourAndWeeklyWindows() throws {
        let snapshot = try ClaudeUsageReader.snapshot(fromUsageResponse: object(#"""
        {"five_hour":{"utilization":13.0,"resets_at":"2026-10-23T21:00:00.530Z"},
         "seven_day":{"utilization":69,"resets_at":"2026-10-28T08:00:00+00:00"},
         "seven_day_opus":null,"extra_usage":{"is_enabled":false}}
        """#), now: now)
        XCTAssertEqual(snapshot.fiveHour?.usedPercent, 13)
        XCTAssertEqual(snapshot.fiveHour?.remainingPercent, 87)
        XCTAssertEqual(snapshot.fiveHour?.windowDurationMins, 300)
        XCTAssertEqual(snapshot.fiveHour?.resetsAt ?? 0, ClaudeUsageReader.parseDate("2026-10-23T21:00:00.530Z")!.timeIntervalSince1970, accuracy: 0.01)
        XCTAssertEqual(snapshot.weekly?.usedPercent, 69)
        XCTAssertEqual(snapshot.weekly?.windowDurationMins, 10_080)
        XCTAssertNotNil(snapshot.weekly?.resetsAt)
        XCTAssertNil(snapshot.resetCredits, "No inventory block means unknown, not zero")
        XCTAssertEqual(snapshot.updatedAt, now)
    }

    func testMissingOrNullWindowsAndClamping() throws {
        let snapshot = try ClaudeUsageReader.snapshot(fromUsageResponse: object(#"""
        {"five_hour":null,"seven_day":{"utilization":104.2,"resets_at":null}}
        """#), now: now)
        XCTAssertNil(snapshot.fiveHour)
        XCTAssertEqual(snapshot.weekly?.usedPercent, 100)
        XCTAssertNil(snapshot.weekly?.resetsAt)
        XCTAssertThrowsError(try ClaudeUsageReader.snapshot(fromUsageResponse: object(#"{"error":"nope"}"#), now: now))
    }

    func testVersionFromInstallPath() {
        XCTAssertEqual(ClaudeUsageReader.version(inPath: "/Users/me/.local/share/claude/versions/2.1.322"), "2.1.322")
        XCTAssertNil(ClaudeUsageReader.version(inPath: "/opt/homebrew/bin/claude"))
    }

    // MARK: Reset credits from the usage endpoint

    private func endpointCredits(_ json: String) throws -> ResetCredits {
        try ClaudeUsageReader.credits(fromUsageResponse: object(json), now: now)
    }

    func testEndpointCountsAvailableGrantsWithExpiry() throws {
        let credits = try endpointCredits(#"""
        {"five_hour":{"utilization":10},"cedar_ember":{"eligible":true,"grants":[
          {"resets_left":2,"resets_total":2,"starts_at":"2026-10-01T00:00:00Z","ends_at":"2026-12-01T00:00:00.000Z","paused":false},
          {"resets_left":1,"resets_total":1,"starts_at":null,"ends_at":"2026-10-01T00:00:00Z","paused":false},
          {"resets_left":3,"resets_total":3,"paused":true},
          {"resets_left":1,"starts_at":"2027-01-01T00:00:00Z","paused":false},
          {"resets_left":1}
        ]}}
        """#)
        XCTAssertEqual(credits.availableCount, 2, "Only the active, unpaused grant counts")
        XCTAssertEqual(credits.label, "2 resets")
        XCTAssertEqual(credits.credits?.first?.expiresAt, ClaudeUsageReader.parseDate("2026-12-01T00:00:00Z")?.timeIntervalSince1970)
        XCTAssertTrue(credits.hoverDetails.contains("Reset 2: expires"))
    }

    func testEndpointIneligibleOrEmptyMeansZero() throws {
        XCTAssertEqual(try endpointCredits(#"{"cedar_ember":{"eligible":false}}"#).availableCount, 0)
        XCTAssertThrowsError(try endpointCredits(#"{"cedar_ember":{"eligible":false,"ineligible_reason":"cli_version","grants":[]}}"#),
                             "An outdated-CLI answer is unknown, not zero")
        XCTAssertEqual(try endpointCredits(#"{"cedar_ember":{"eligible":true,"grants":[]}}"#).availableCount, 0)
    }

    func testEndpointWithoutInventoryIsUnknown() {
        XCTAssertThrowsError(try endpointCredits(#"{"five_hour":{"utilization":10}}"#))
    }

    // MARK: Cache

    private func reading(_ used: Double, at date: Date) -> UsageSnapshot {
        UsageSnapshot(weekly: UsageWindow(usedPercent: used, windowDurationMins: 10_080, resetsAt: nil),
                      fiveHour: UsageWindow(usedPercent: used / 2, windowDurationMins: 300, resetsAt: date.addingTimeInterval(3_600).timeIntervalSince1970),
                      resetCredits: ResetCredits(availableCount: 1, credits: [ResetCredit(status: "available", expiresAt: nil)]),
                      updatedAt: date)
    }

    func testCacheSpacesRequestsAndBacksOffAfterRateLimit() throws {
        let cache = ClaudeUsageReader.SnapshotCache()
        var calls = 0
        XCTAssertEqual(try cache.value(now: now) { calls += 1; return reading(40, at: now) }.weekly?.usedPercent, 40)
        XCTAssertEqual(try cache.value(now: now.addingTimeInterval(30)) { calls += 1; return reading(41, at: now) }.weekly?.usedPercent, 40)
        XCTAssertEqual(calls, 1, "A 30-second refresh reuses the last reading")
        let later = now.addingTimeInterval(60)
        XCTAssertEqual(try cache.value(now: later) { calls += 1; throw ClaudeReaderError.rateLimited }.weekly?.usedPercent, 40,
                       "A rate limit keeps the last reading")
        XCTAssertEqual(try cache.value(now: later.addingTimeInterval(120)) { calls += 1; return reading(42, at: later) }.weekly?.usedPercent, 40)
        XCTAssertEqual(calls, 2, "Waits after a 429")
        XCTAssertEqual(try cache.value(now: later.addingTimeInterval(601)) { calls += 1; return reading(43, at: later) }.weekly?.usedPercent, 43)
    }

    func testCacheWithoutReadingReportsTheError() {
        let cache = ClaudeUsageReader.SnapshotCache()
        XCTAssertThrowsError(try cache.value(now: now) { throw ClaudeReaderError.expired }) {
            XCTAssertEqual($0 as? ClaudeReaderError, .expired)
        }
    }

    func testCacheSurvivesRestartAndExpiresAfterADay() throws {
        let suite = "ClaudeSnapshotCacheTest"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        _ = try ClaudeUsageReader.SnapshotCache(defaults: defaults).value(now: now) { reading(40, at: now) }

        let restarted = ClaudeUsageReader.SnapshotCache(defaults: defaults)
        let expiredLogin = try restarted.value(now: now.addingTimeInterval(3_600)) { throw ClaudeReaderError.expired }
        XCTAssertEqual(expiredLogin.weekly?.usedPercent, 40)
        XCTAssertEqual(expiredLogin.fiveHour?.usedPercent, 20)
        XCTAssertEqual(expiredLogin.resetCredits?.availableCount, 1)
        XCTAssertNil(expiredLogin.resetCredits?.credits?.first?.expiresAt)

        let stale = ClaudeUsageReader.SnapshotCache(defaults: defaults)
        XCTAssertThrowsError(try stale.value(now: now.addingTimeInterval(2 * 86_400)) { throw ClaudeReaderError.expired })
        defaults.removePersistentDomain(forName: suite)
    }
}
