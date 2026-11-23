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

    private static let didApplySinglePrimaryKey = "didApplySinglePrimaryMenuBar"

    private struct DiscoveredAccount {
        let provider: Provider
        let key: String
        let name: String
        let accountIdentifier: String?
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
        var updatedExisting = false

        // The pre-existing Anthropic CLI profile already follows the account
        // cswap has active. Do not add a second profile for that same login.
        // Prefer cswap's live active record over a possibly stale oauthAccount
        // snapshot captured on an earlier launch.
        let activeCswap = CswapAccountService.shared.loadAccounts().first(where: { $0.isActive })
        var cliProfileEmails = Set(
            profiles
                .filter { $0.provider == .anthropic && $0.hasAnyCredentials }
                .compactMap { Self.oauthEmail(from: $0.oauthAccountJSON) }
                .map { $0.lowercased() }
        )
        if let activeEmail = activeCswap?.email {
            cliProfileEmails.insert(activeEmail.lowercased())
        }

        for account in discovered {
            if let index = profiles.firstIndex(where: { $0.externalAccountKey == account.key }) {
                // Keep auto-generated names in sync with the tool that owns
                // the account, but never overwrite a user-chosen name.
                if !profiles[index].nameIsCustomized, profiles[index].name != account.name {
                    profiles[index].name = account.name
                    updatedExisting = true
                }
                if let identifier = account.accountIdentifier,
                   profiles[index].detectedAccountIdentifier != identifier {
                    profiles[index].detectedAccountIdentifier = identifier
                    updatedExisting = true
                }
                // Codex snapshot profiles are read-only copies. Re-copy the
                // current access token so the profile keeps working without
                // ever refreshing another tool's token family.
                if let json = account.codexCredentialsJSON,
                   profiles[index].codexCredentialsJSON != json {
                    profiles[index].codexCredentialsJSON = json
                    updatedExisting = true
                }
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
            profile.detectedAccountIdentifier = account.accountIdentifier
            profile.nameIsCustomized = false
            profiles.append(profile)
            addedProfiles.append(profile)
        }

        // Replace generated names like "Funky Falcon" with the actual account
        // identity. This also follows cswap's active account when it changes.
        let anthropicCandidates = profiles.enumerated().filter { _, profile in
            profile.provider == .anthropic && profile.hasAnyCredentials && !profile.nameIsCustomized
        }
        let anthropicTarget = anthropicCandidates.first(where: { $0.element.id == manager.activeProfile?.id })
            ?? anthropicCandidates.first(where: { Self.oauthEmail(from: $0.element.oauthAccountJSON)?.lowercased() == activeCswap?.email.lowercased() })
            ?? (anthropicCandidates.count == 1 ? anthropicCandidates.first : nil)

        if let target = anthropicTarget {
            let email = activeCswap?.email ?? Self.oauthEmail(from: target.element.oauthAccountJSON)
            let preferredName = activeCswap?.preferredName ?? email
            if let email {
                if profiles[target.offset].detectedAccountIdentifier != email {
                    profiles[target.offset].detectedAccountIdentifier = email
                    updatedExisting = true
                }
                if let preferredName, target.element.name != preferredName {
                    profiles[target.offset].name = preferredName
                    updatedExisting = true
                }
            }
        }

        if !addedProfiles.isEmpty || updatedExisting {
            manager.profiles = profiles
            if let activeId = manager.activeProfile?.id,
               let refreshed = profiles.first(where: { $0.id == activeId }) {
                manager.activeProfile = refreshed
            }
            ProfileStore.shared.saveProfiles(profiles)
            NotificationCenter.default.post(name: .multiProfileConfigChanged, object: nil)
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

        // One menu bar tracker by default. The active profile is the primary
        // account, and the user can change it from the header switcher or
        // Manage Profiles. Multi-profile mode remains opt-in.
        if !UserDefaults.standard.bool(forKey: Self.didApplySinglePrimaryKey) {
            if manager.displayMode == .multi {
                manager.displayMode = .single
                ProfileStore.shared.saveDisplayMode(.single)
                NotificationCenter.default.post(name: .displayModeChanged, object: nil)
            }
            UserDefaults.standard.set(true, forKey: Self.didApplySinglePrimaryKey)
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
                    accountIdentifier: account.email,
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
                    accountIdentifier: account.email ?? account.name,
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

            let label = credentials.email
                ?? url.deletingPathExtension().lastPathComponent

            let credentialsJSON: String?
            if live {
                // The live file is owned by the Codex CLI; the existing
                // provider reads/refreshes it in place.
                credentialsJSON = nil
            } else {
                // A snapshot belongs to another account switcher. Copy it with
                // the refresh token removed so this app can never rotate that
                // token family out from under the other tool.
                guard let readOnly = Self.readOnlyCodexJSON(data) else { return }
                credentialsJSON = readOnly
            }

            accounts.append(
                DiscoveredAccount(
                    provider: .codex,
                    key: live ? "codex:default" : "codex:\(url.standardizedFileURL.path)",
                    name: label,
                    accountIdentifier: credentials.email,
                    codexCredentialsJSON: credentialsJSON,
                    refreshInterval: 60
                )
            )
        }

        // Another switcher (for example a cswap build with Codex support) may
        // manage auth.json as a symlink. Do not read or write through it: the
        // file and its token lineage belong to that tool.
        let liveIsSymlink = (try? FileManager.default.destinationOfSymbolicLink(atPath: liveURL.path)) != nil
        if !liveIsSymlink, let data = try? Data(contentsOf: liveURL) {
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

    /// Copy a snapshot's credentials with the refresh token removed, so the
    /// Codex provider can read usage but cannot rotate the token family that
    /// belongs to the account switcher that owns the snapshot.
    private static func readOnlyCodexJSON(_ data: Data) -> String? {
        guard var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        if var tokens = json["tokens"] as? [String: Any] {
            if tokens["refresh_token"] != nil { tokens["refresh_token"] = "" }
            if tokens["refreshToken"] != nil { tokens["refreshToken"] = "" }
            json["tokens"] = tokens
        }
        guard let output = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else {
            return nil
        }
        return String(data: output, encoding: .utf8)
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
