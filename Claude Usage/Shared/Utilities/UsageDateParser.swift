import Foundation

/// Date parsing shared by the locally-detected providers (cswap, OpenCode).
/// Their stores mix ISO-8601 strings with and without fractional seconds.
enum UsageDateParser {
    static func parse(_ value: Any?) -> Date? {
        if let date = value as? Date { return date }
        guard let raw = value as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: trimmed) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: trimmed)
    }

    static func date(fromUnixSeconds value: Any?) -> Date? {
        guard let number = value as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: number.doubleValue)
    }

    /// Accepts either seconds or milliseconds; OpenCode has used both in
    /// different storage versions.
    static func date(fromUnixEpoch value: Any?) -> Date? {
        guard let number = value as? NSNumber else { return nil }
        let raw = number.doubleValue
        guard raw > 0 else { return nil }
        return Date(timeIntervalSince1970: raw > 1_000_000_000_000 ? raw / 1000.0 : raw)
    }
}
