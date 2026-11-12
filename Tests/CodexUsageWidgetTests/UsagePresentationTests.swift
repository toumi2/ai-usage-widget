import Foundation
import XCTest
@testable import CodexUsageWidget

final class UsagePresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    func testCountdownOmitsMinutesOnlyAboveSixHours() {
        let cases: [(TimeInterval, String)] = [
            (3 * 86_400 + 4 * 3_600 + 20 * 60, "3d 4h"),
            (86_400, "1d 0h"),
            (18 * 3_600 + 30 * 60, "18h"),
            (6 * 3_600 + 1, "6h"),
            (6 * 3_600, "6h 0m"),
            (5 * 3_600 + 25 * 60, "5h 25m"),
            (59 * 60, "59m"),
            (30, "<1m"),
            (0, "now"),
            (-60, "now")
        ]
        for (remaining, expected) in cases {
            XCTAssertEqual(
                UsageTimeFormatting.countdown(until: now.timeIntervalSince1970 + remaining, now: now),
                expected, "Remaining seconds: \(remaining)"
            )
        }
        XCTAssertEqual(UsageTimeFormatting.countdown(until: .infinity, now: now), "unavailable")
    }

    func testCountIsAuthoritativeWhenDetailRowsAreCapped() throws {
        let summary = try decode(#"{"availableCount":3,"credits":[{"status":"available","expiresAt":1793294524}]}"#)
        XCTAssertEqual(summary.label, "3 resets")
        XCTAssertTrue(summary.hoverDetails.contains("2 more resets: expiry not provided"))
    }

    func testMissingNullAndMalformedDetailsKeepTheCount() throws {
        for json in [
            #"{"availableCount":2}"#,
            #"{"availableCount":2,"credits":null}"#,
            #"{"availableCount":2,"credits":[]}"#,
            #"{"availableCount":2,"credits":[{"status":"available","expiresAt":"invalid"}]}"#
        ] {
            let summary = try decode(json)
            XCTAssertEqual(summary.availableCount, 2)
            XCTAssertTrue(summary.hoverDetails.contains("Expiry dates were not provided"))
        }
    }

    func testNoExpiryAndConsumedRowsAreHandledWithoutInventingDates() throws {
        let summary = try decode(#"{"availableCount":1,"credits":[{"status":"redeemed","expiresAt":1793294524},{"status":"available","expiresAt":null}]}"#)
        XCTAssertEqual(summary.label, "1 reset")
        XCTAssertEqual(summary.hoverDetails, "1 reset available.\nReset 1: expiry not provided")
    }

    func testZeroAndUnavailableAreDifferent() throws {
        let zero = try decode(#"{"availableCount":0,"credits":[]}"#)
        XCTAssertEqual(zero.label, "0 resets")
        XCTAssertEqual(zero.hoverDetails, "No reset credits available.")
        XCTAssertThrowsError(try decode(#"{"credits":[]}"#))
        XCTAssertThrowsError(try decode(#"{"availableCount":-1}"#))
        XCTAssertThrowsError(try decode("null"))
    }

    func testExpiryDetailsAreShownEarliestFirst() {
        let earlier = now.timeIntervalSince1970
        let later = earlier + 86_400
        let summary = ResetCredits(availableCount: 2, credits: [
            ResetCredit(status: "available", expiresAt: later),
            ResetCredit(status: "available", expiresAt: earlier)
        ])
        let earliestDate = now.formatted(date: .abbreviated, time: .shortened)
        XCTAssertTrue(summary.hoverDetails.contains("Reset 1: expires \(earliestDate)"))
    }

    private func decode(_ json: String) throws -> ResetCredits {
        try JSONDecoder().decode(ResetCredits.self, from: Data(json.utf8))
    }
}
