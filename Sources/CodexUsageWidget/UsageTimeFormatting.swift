import Foundation

enum UsageTimeFormatting {
    static func countdown(until timestamp: TimeInterval, now: Date = Date()) -> String {
        let remaining = timestamp - now.timeIntervalSince1970
        guard remaining.isFinite, remaining < Double(Int.max) else { return "unavailable" }
        guard remaining > 0 else { return "now" }
        guard remaining >= 60 else { return "<1m" }

        let seconds = Int(remaining)
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if remaining > 6 * 3_600 {
            return days > 0 ? "\(days)d \(hours)h" : "\(hours)h"
        }
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }
}
