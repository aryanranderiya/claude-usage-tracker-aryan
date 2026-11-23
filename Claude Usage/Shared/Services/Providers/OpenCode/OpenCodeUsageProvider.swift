import Foundation

/// Usage provider for OpenCode Go accounts.
///
/// OpenCode's own `opencode.allowance` accounting exposes three meters:
/// a 5-hour `rolling` window, a Monday-reset `weekly` window, and the
/// `monthly` allowance. The app's two-window model maps the first two; the
/// monthly percentage is carried in the plan badge.
final class OpenCodeUsageProvider: UsageProviderService {
    static let shared = OpenCodeUsageProvider()

    let provider: Provider = .opencode

    private let accountService = OpenCodeAccountService.shared

    private init() {}

    func hasCredentials(for profile: Profile) -> Bool {
        accountService.account(for: profile) != nil
    }

    func fetchUsage(for profile: Profile) async throws -> ClaudeUsage {
        guard let account = accountService.account(for: profile) else {
            throw AppError(
                code: .providerCredentialsNotFound,
                message: "OpenCode account not found",
                technicalDetails: "No OpenCode credential matches \(profile.externalAccountKey ?? "nil").",
                isRecoverable: true,
                recoverySuggestion: "Open OpenCode, sign in with `/connect`, then reopen this app."
            )
        }

        let snapshot = try await accountService.fetchUsage(for: account)
        return Self.mapToUsage(snapshot, previous: profile.claudeUsage)
    }

    static func mapToUsage(_ snapshot: OpenCodeUsageSnapshot, previous: ClaudeUsage?) -> ClaudeUsage {
        let now = Date()
        var usage = ClaudeUsage.empty
        usage.weeklyLimit = 0

        if let rolling = snapshot.rolling {
            usage.hasSessionLimit = true
            usage.sessionPercentage = rolling.percent
            usage.sessionResetTime = rolling.resetsAt
                ?? previous?.sessionResetTime
                ?? now.addingTimeInterval(5 * 60 * 60)
        } else {
            usage.hasSessionLimit = false
        }

        if let weekly = snapshot.weekly {
            usage.hasWeeklyLimit = true
            usage.weeklyPercentage = weekly.percent
            usage.weeklyResetTime = weekly.resetsAt
                ?? previous?.weeklyResetTime
                ?? now.addingTimeInterval(7 * 24 * 60 * 60)
        } else {
            usage.hasWeeklyLimit = false
        }

        if let monthly = snapshot.monthly {
            usage.planType = "Go · \(Int(monthly.percent.rounded()))% month"
        } else {
            usage.planType = "Go"
        }

        usage.lastUpdated = now
        usage.userTimezone = .current
        return usage
    }
}
