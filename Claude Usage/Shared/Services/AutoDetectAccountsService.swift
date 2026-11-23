import Foundation

/// Creates and maintains profiles for accounts that already exist in local
/// tools: cswap (Claude), OpenCode Go, and Codex CLI logins/snapshots.
///
/// Discovery is read-only and cheap (a few JSON/DB reads), so it runs at
/// launch before the setup wizard decides whether any credentials exist.
/// Profiles are only ever added; an account disappearing from a tool never
/// deletes the user's profile or its history.
@MainActor
final class AutoDetectAccountsService {
    static let shared = AutoDetectAccountsService()

    private static let didAutoConfigureMultiProfileKey = "didAutoConfigureLocalAccounts"

    private struct DiscoveredAccount {
        let provider: Provider
        let key: String
        let name: String
        let codexCredentialsJSON: String?
        let refreshInterval: TimeInterval
    }

    private var isSyncing = false

    private init() {}

    func syncNow() {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        let discovered = discoverAccounts()
        guard !discovered.isEmpty else { return }

        let manager = ProfileManager.shared
        var profiles = manager.profiles
        var addedProfiles: [Profile] = []

        // The pre-existing Anthropic CLI profile already follows the account
        // cswap has active. Do not add a second profile for that same login.
        let cliProfileEmails = Set(
            profiles
                .filter { $0.provider == .anthropic && $0.hasAnyCredentials }
                .compactMap { Self.oauthEmail(from: $0.oauthAccountJSON) }
                .map { $0.lowercased() }
        )

        for account in discovered {
            if profiles.contains(where: { $0.externalAccountKey == account.key }) {
                continue
            }
            if account.provider == .cswap,
               cliProfileEmails.contains(String(account.key.dropFirst("cswap:".count)).lowercased()) {
                continue
            }
            // A hand-made Codex profile already follows the live auth.json.
            // Do not add a duplicate auto profile for the same login.
            if account.provider == .codex,
               account.codexCredentialsJSON == nil,
               profiles.contains(where: { $0.provider == .codex && $0.externalAccountKey == nil }) {
                continue
            }

            var profile = Profile(
                name: account.name,
                provider: account.provider,
                codexCredentialsJSON: account.codexCredentialsJSON,
                hasCliAccount: false,
                iconConfig: Self.iconConfig(for: account.provider),
                refreshInterval: account.refreshInterval,
                autoStartSessionEnabled: false,
                checkOverageLimitEnabled: false,
                isSelectedForDisplay: true
            )
            profile.externalAccountKey = account.key
            profiles.append(profile)
            addedProfiles.append(profile)
        }

        if !addedProfiles.isEmpty {
            manager.profiles = profiles
            ProfileStore.shared.saveProfiles(profiles)
            LoggingService.shared.log("AutoDetectAccounts: created \(addedProfiles.count) profile(s) from local tools")
        }

        // If the app was sitting on an empty default profile, make the first
        // discovered account active so the menu bar has something to show.
        let autoProfiles = profiles.filter { $0.externalAccountKey != nil }
        if manager.activeProfile?.hasAnyCredentials != true,
           let first = autoProfiles.first {
            manager.activeProfile = first
            ProfileStore.shared.saveActiveProfileId(first.id)
        }

        // Enable multi-profile mode once, when there is more than one account
        // to show. After that the user's choice wins.
        if !UserDefaults.standard.bool(forKey: Self.didAutoConfigureMultiProfileKey),
           autoProfiles.count > 1 {
            manager.displayMode = .multi
            ProfileStore.shared.saveDisplayMode(.multi)
            UserDefaults.standard.set(true, forKey: Self.didAutoConfigureMultiProfileKey)
            NotificationCenter.default.post(name: .displayModeChanged, object: nil)
        }
    }

    // MARK: - Discovery

    private func discoverAccounts() -> [DiscoveredAccount] {
        var accounts: [DiscoveredAccount] = []

        for account in CswapAccountService.shared.loadAccounts() {
            accounts.append(
                DiscoveredAccount(
                    provider: .cswap,
                    key: account.accountKey,
                    name: account.displayName,
                    codexCredentialsJSON: nil,
                    refreshInterval: 60
                )
            )
        }

        for account in OpenCodeAccountService.shared.loadAccounts() {
            accounts.append(
                DiscoveredAccount(
                    provider: .opencode,
                    key: account.accountKey,
                    name: account.displayName,
                    codexCredentialsJSON: nil,
                    refreshInterval: 60
                )
            )
        }

        accounts.append(contentsOf: discoverCodexAccounts())
        return accounts
    }

    /// The live `~/.codex/auth.json` plus any snapshots kept under
    /// `~/.codex/accounts/` by Codex account switchers. Snapshot credentials
    /// are copied into the profile so this app never rewrites another tool's
    /// files; the live login is read in place like the Codex provider always did.
    private func discoverCodexAccounts() -> [DiscoveredAccount] {
        let authService = CodexAuthService.shared
        let liveURL = authService.authFileURL()
        let accountsURL = authService.codexHomeURL().appendingPathComponent("accounts")

        var accounts: [DiscoveredAccount] = []
        var seenIdentities = Set<String>()
        var seenPaths = Set<String>()

        func register(_ data: Data, at url: URL, live: Bool) {
            guard let credentials = CodexAuthService.parse(data) else { return }
            let identity = credentials.resolvedAccountId ?? credentials.email ?? url.path
            guard !seenIdentities.contains(identity) else { return }
            seenIdentities.insert(identity)
            seenPaths.insert(url.standardizedFileURL.path)

            let label = credentials.email.map { "Codex · \($0)" }
                ?? "Codex · \(url.deletingPathExtension().lastPathComponent)"

            accounts.append(
                DiscoveredAccount(
                    provider: .codex,
                    key: live ? "codex:default" : "codex:\(url.standardizedFileURL.path)",
                    name: label,
                    codexCredentialsJSON: live ? nil : String(data: data, encoding: .utf8),
                    refreshInterval: 60
                )
            )
        }

        if let data = try? Data(contentsOf: liveURL) {
            register(data, at: liveURL, live: true)
        }

        let fileManager = FileManager.default
        if let enumerator = fileManager.enumerator(
            at: accountsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator where url.pathExtension.lowercased() == "json" {
                guard !seenPaths.contains(url.standardizedFileURL.path),
                      let data = try? Data(contentsOf: url) else { continue }
                register(data, at: url, live: false)
            }
        }

        return accounts
    }

    /// Email from a captured Claude Code `oauthAccount` blob, if it has one.
    private static func oauthEmail(from json: String?) -> String? {
        guard let json,
              let data = json.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        return object["emailAddress"] as? String ?? object["email"] as? String
    }

    private static func iconConfig(for provider: Provider) -> MenuBarIconConfiguration {
        var config = MenuBarIconConfiguration.default
        if !provider.descriptor.capabilities.tokenCounts {
            for index in config.metrics.indices where config.metrics[index].weekDisplayMode == .tokens {
                config.metrics[index].weekDisplayMode = .percentage
            }
        }
        return config
    }
}
