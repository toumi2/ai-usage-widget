import Foundation
import XCTest
@testable import CodexUsageWidget

final class ClaudeUsageParserTests: XCTestCase {
    private let paris = TimeZone(identifier: "Europe/Paris")!
    // 2026-10-23 20:00 in Paris.
    private var now: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = paris
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 20, minute: 0))!
    }

    private func parisDate(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0, year: Int = 2026) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = paris
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private let sampleScreen = """
     Settings:  Status   Config   Usage

     Current session
     ██████████████████▌                                42% used
     Resets 11pm (Europe/Paris)

     Current week (all models)
     ███████▌                                           15% used
     Resets Oct 28, 10:30am (Europe/Paris)

     Current week (Sonnet only)
     █▌                                                 3% used
     Resets Oct 28, 10:30am (Europe/Paris)

     Esc to cancel
    """

    func testParsesSessionAndWeeklyWindows() throws {
        let snapshot = try ClaudeUsageParser.parse(screen: sampleScreen, now: now, timeZone: paris)
        XCTAssertEqual(snapshot.fiveHour?.usedPercent, 42)
        XCTAssertEqual(snapshot.fiveHour?.remainingPercent, 58)
        XCTAssertEqual(snapshot.fiveHour?.resetsAt, parisDate(10, 23, 23).timeIntervalSince1970)
        XCTAssertEqual(snapshot.weekly?.usedPercent, 15, "Uses all models, not the Sonnet-only row")
        XCTAssertEqual(snapshot.weekly?.resetsAt, parisDate(10, 28, 10, 30).timeIntervalSince1970)
        XCTAssertNil(snapshot.resetCredits, "The screen has no reset count, so it stays unknown")
    }

    func testParsesScreenWithoutSpacesAndWithControlCodes() throws {
        let raw = "\u{1B}[2K\u{1B}[1GCurrent\u{1B}[1Csession\r\n\u{1B}[38;5;246m███\u{1B}[39m\u{1B}[3C42%\u{1B}[1Cused\r\n"
            + "Resets\u{1B}[1C11pm\u{1B}[1C(Europe/Paris)\r\n"
            + "Currentweek(allmodels)\r\n15%used\r\nResetsOct28,10:30am(Europe/Paris)\r\n"
        let snapshot = try ClaudeUsageParser.parse(screen: ClaudeUsageParser.clean(raw), now: now, timeZone: paris)
        XCTAssertEqual(snapshot.fiveHour?.usedPercent, 42)
        XCTAssertEqual(snapshot.fiveHour?.resetsAt, parisDate(10, 23, 23).timeIntervalSince1970)
        XCTAssertEqual(snapshot.weekly?.resetsAt, parisDate(10, 28, 10, 30).timeIntervalSince1970)
    }

    func testUsesTheLastDrawnPanel() throws {
        let older = sampleScreen.replacingOccurrences(of: "42% used", with: "10% used")
        let snapshot = try ClaudeUsageParser.parse(screen: older + "\n" + sampleScreen, now: now, timeZone: paris)
        XCTAssertEqual(snapshot.fiveHour?.usedPercent, 42)
    }

    /// Text captured from Claude Code 2.1.274's /usage screen.
    func testParsesRealCliScreen() throws {
        let screen = """
           Settings  Status   Config   Usage   Stats
           Current session
           ██████▌                                           13%used
           Resets 11:40am (Africa/Algiers)
           Current week (all models)
           █████                                             10%used
           Resets Oct 25 at 9am (Africa/Algiers)
           What's contributing to your limits usage?
           Esc to cancel
        """
        let snapshot = try ClaudeUsageParser.parse(screen: screen, now: now, timeZone: paris)
        XCTAssertEqual(snapshot.fiveHour?.usedPercent, 13)
        XCTAssertEqual(snapshot.weekly?.usedPercent, 10)
        // Africa/Algiers is UTC+1. Paris is UTC+2 on Oct 24 and UTC+1 from Oct 25 (DST ends).
        XCTAssertEqual(snapshot.weekly?.resetsAt, parisDate(10, 25, 9).timeIntervalSince1970)
        XCTAssertEqual(snapshot.fiveHour?.resetsAt, parisDate(10, 24, 12, 40).timeIntervalSince1970)
    }

    func testResetCreditCountWhenTheScreenShowsOne() {
        XCTAssertEqual(ClaudeUsageParser.resetCredits(in: "Limit resets\n 2 resets available")?.availableCount, 2)
        XCTAssertEqual(ClaudeUsageParser.resetCredits(in: "1 limit reset left")?.availableCount, 1)
        XCTAssertNil(ClaudeUsageParser.resetCredits(in: "Resets 11:40am (Africa/Algiers)"))
        XCTAssertEqual(ClaudeUsageParser.cliVersion(in: "Welcome to Claude Code v2.1.322"), "2.1.322")
    }

    func testPercentLeftWording() {
        XCTAssertEqual(ClaudeUsageParser.percentUsed(in: "58%left"), 42)
        XCTAssertEqual(ClaudeUsageParser.percentUsed(in: "█████42%used"), 42)
        XCTAssertNil(ClaudeUsageParser.percentUsed(in: "nopercenthere"))
    }

    func testResetFormats() {
        func reset(_ text: String) -> Date? { ClaudeUsageParser.resetDate(from: text, now: now, timeZone: paris) }
        XCTAssertEqual(reset("Resets 11pm (Europe/Paris)"), parisDate(10, 23, 23))
        XCTAssertEqual(reset("Resets 9am (Europe/Paris)"), parisDate(10, 24, 9), "Past time today rolls to tomorrow")
        XCTAssertEqual(reset("Resets 12am"), parisDate(10, 24, 0))
        XCTAssertEqual(reset("Resets Nov 2 at 5pm"), parisDate(11, 2, 17))
        XCTAssertEqual(reset("Resets Jan 3, 2027, 8:15am"), parisDate(1, 3, 8, 15, year: 2027))
        XCTAssertEqual(reset("Resets Jan 3, 8am"), parisDate(1, 3, 8, year: 2027), "Past month rolls to next year")
        XCTAssertEqual(reset("Resets in 2h 15m"), now.addingTimeInterval(2 * 3_600 + 15 * 60))
        XCTAssertNil(reset("Resets soon"))
        // A timezone in the text wins over the local one.
        XCTAssertEqual(
            ClaudeUsageParser.resetDate(from: "Resets 5pm (America/New_York)", now: now, timeZone: paris),
            parisDate(10, 23, 23)
        )
    }

    func testSignedOutAndUnreadableScreens() {
        XCTAssertThrowsError(try ClaudeUsageParser.parse(screen: "Select login method:\n❯ Claude account", now: now)) {
            XCTAssertEqual($0 as? ClaudeReaderError, .notSignedIn)
        }
        XCTAssertThrowsError(try ClaudeUsageParser.parse(screen: "Welcome back!", now: now)) {
            XCTAssertEqual($0 as? ClaudeReaderError, .unreadable)
        }
    }

    func testPanelCompletion() {
        XCTAssertTrue(ClaudeUsageParser.panelLooksComplete(ClaudeUsageParser.lastPanel(sampleScreen)))
        XCTAssertFalse(ClaudeUsageParser.panelLooksComplete("Current session\n42% used\nResets 11pm"))
    }

    func testFrontmostAppMapping() {
        XCTAssertEqual(UsageProvider.matching(bundleIdentifier: "com.anthropic.claudefordesktop"), .claude)
        XCTAssertEqual(UsageProvider.matching(bundleIdentifier: "com.openai.codex"), .codex)
        XCTAssertEqual(UsageProvider.matching(bundleIdentifier: "com.openai.chat"), .codex)
        XCTAssertNil(UsageProvider.matching(bundleIdentifier: "com.apple.Terminal"))
        XCTAssertNil(UsageProvider.matching(bundleIdentifier: nil))
    }

    // MARK: Reset credits from the usage endpoint

    private func endpointCredits(_ json: String) throws -> ResetCredits {
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        return try ClaudeResetCreditsReader.credits(fromUsageResponse: object, now: now)
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
        XCTAssertEqual(credits.credits?.first?.expiresAt, ClaudeResetCreditsReader.parseDate("2026-12-01T00:00:00Z")?.timeIntervalSince1970)
        XCTAssertTrue(credits.hoverDetails.contains("Reset 2: expires"))
    }

    func testEndpointIneligibleOrEmptyMeansZero() throws {
        XCTAssertEqual(try endpointCredits(#"{"cedar_ember":{"eligible":false}}"#).availableCount, 0)
        XCTAssertEqual(try endpointCredits(#"{"cedar_ember":{"eligible":true,"grants":[]}}"#).availableCount, 0)
    }

    func testEndpointWithoutInventoryIsUnknown() {
        XCTAssertThrowsError(try endpointCredits(#"{"five_hour":{"utilization":10}}"#))
    }

    func testCreditCacheReusesReadingsAndBacksOffAfterRateLimit() {
        let cache = ClaudeResetCreditsReader.CreditCache()
        let two = ResetCredits(availableCount: 2, credits: nil)
        var calls = 0
        XCTAssertEqual(cache.value(now: now) { calls += 1; return two }?.availableCount, 2)
        XCTAssertEqual(cache.value(now: now.addingTimeInterval(60)) { calls += 1; return two }?.availableCount, 2)
        XCTAssertEqual(calls, 1, "Reused within 10 minutes")
        let later = now.addingTimeInterval(700)
        XCTAssertEqual(cache.value(now: later) { calls += 1; throw ClaudeResetCreditsReader.ReadError.http(429) }?.availableCount, 2)
        XCTAssertEqual(cache.value(now: later.addingTimeInterval(60)) { calls += 1; return two }?.availableCount, 2)
        XCTAssertEqual(calls, 2, "Waits 5 minutes after a 429")
    }
}
