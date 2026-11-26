import Foundation

/// Read-only usage provider for Claude accounts managed by `cswap`.
///
/// cswap already owns login, token refresh, and polling. This provider only
/// maps its cached measurements onto `ClaudeUsage`, so it can never race a
/// swap or rotate a refresh token out from under the CLI.
final class CswapUsageProvider: UsageProviderService {
    static let shared = CswapUsageProvider()

    let provider: Provider = .cswap

    private let accountService = CswapAccountService.shared

    private init() {}

    func hasCredentials(for profile: Profile) -> Bool {
        profile.externalAccountKey != nil
    }

    func fetchUsage(for profile: Profile) async throws -> ClaudeUsage {
        let accounts = await accountService.refreshAccounts()
        guard let account = accounts.first(where: { $0.accountKey == profile.externalAccountKey }) else {
            throw AppError(
                code: .providerCredentialsNotFound,
                message: "cswap account not found",
                technicalDetails: "No cswap account matches \(profile.externalAccountKey ?? "nil"). Run `cswap list` and reopen the app.",
                isRecoverable: true,
                recoverySuggestion: "Make sure cswap is installed and manages this account."
            )
        }

        guard account.hasAnyUsage else {
            throw AppError(
                code: .apiParsingFailed,
                message: "cswap has no usage for this account yet",
                technicalDetails: "cswap cache has no usable windows for \(account.email) (disabled: \(account.isDisabled))",
                isRecoverable: true,
                recoverySuggestion: "Run `cswap list` to refresh usage, then try again."
            )
        }

        return CswapAccountService.mapToUsage(account)
    }
}
