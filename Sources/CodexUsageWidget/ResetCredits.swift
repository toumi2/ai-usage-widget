import Foundation

struct ResetCredit: Decodable {
    let status: String
    let expiresAt: TimeInterval?
}

struct ResetCredits: Decodable {
    let availableCount: Int
    let credits: [ResetCredit]?

    var label: String {
        "\(availableCount) \(availableCount == 1 ? "reset" : "resets")"
    }

    var hoverDetails: String {
        guard availableCount > 0 else { return "No reset credits available." }
        var lines = ["\(label) available."]
        let available = (credits ?? [])
            .filter { $0.status == "available" }
            .sorted { ($0.expiresAt ?? .infinity) < ($1.expiresAt ?? .infinity) }
            .prefix(availableCount)

        guard !available.isEmpty else {
            return (lines + ["Expiry dates were not provided."]).joined(separator: "\n")
        }
        for (index, credit) in available.enumerated() {
            if let expiry = credit.expiresAt, expiry.isFinite {
                let date = Date(timeIntervalSince1970: expiry)
                    .formatted(date: .abbreviated, time: .shortened)
                lines.append("Reset \(index + 1): expires \(date)")
            } else {
                lines.append("Reset \(index + 1): expiry not provided")
            }
        }
        if available.count < availableCount {
            let missing = availableCount - available.count
            lines.append("\(missing) more \(missing == 1 ? "reset" : "resets"): expiry not provided")
        }
        return lines.joined(separator: "\n")
    }
}

extension ResetCredits {
    private enum CodingKeys: String, CodingKey {
        case availableCount, credits
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        availableCount = try container.decode(Int.self, forKey: .availableCount)
        guard availableCount >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .availableCount, in: container,
                debugDescription: "Available reset count cannot be negative."
            )
        }
        // Optional detail rows must not hide a valid authoritative count.
        credits = try? container.decodeIfPresent([ResetCredit].self, forKey: .credits)
    }
}
