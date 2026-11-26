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

        // cswap owns the Claude logins in this setup. Convert the legacy
        // auto-created Anthropic CLI profile into the cswap account it actually
        // represents, matched by its captured identity — never by cswap's
        // current active slot. Matching the active slot made a pinned profile
        // silently follow whatever account cswap had selected.
        let cswapAccounts = CswapAccountService.shared.loadAccounts()
        if !cswapAccounts.isEmpty {
            let convertible = profiles.enumerated().filter { _, profile in
                profile.provider == .anthropic
                    && profile.claudeSessionKey == nil
                    && profile.apiSessionKey == nil
                    && profile.externalAccountKey == nil
                    && (profile.id == manager.activeProfile?.id || profile.cliCredentialsJSON != nil)
            }
            let target = convertible.first(where: { $0.element.id == manager.activeProfile?.id })
                ?? (convertible.count == 1 ? convertible.first : nil)

            if let target {
                let legacyIdentity = profiles[target.offset].detectedAccountIdentifier?.lowercased()
                    ?? Self.oauthEmail(from: profiles[target.offset].oauthAccountJSON)?.lowercased()
                    ?? (profiles[target.offset].name.contains("@") ? profiles[target.offset].name.lowercased() : nil)

                let migrationAccount = legacyIdentity.flatMap { identity in
                    cswapAccounts.first {
                        $0.email.lowercased() == identity || $0.preferredName.lowercased() == identity
                    }
                }

                if let migrationAccount {
                    profiles[target.offset].provider = .cswap
                    profiles[target.offset].externalAccountKey = migrationAccount.accountKey
                    profiles[target.offset].detectedAccountIdentifier = migrationAccount.email
                    profiles[target.offset].hasCliAccount = false
                    profiles[target.offset].claudeSessionKey = nil
                    profiles[target.offset].organizationId = nil
                    profiles[target.offset].apiSessionKey = nil
                    profiles[target.offset].apiOrganizationId = nil
                    profiles[target.offset].apiSessionKeyExpiry = nil
                    profiles[target.offset].apiUsage = nil
                    profiles[target.offset].cliCredentialsJSON = nil
                    profiles[target.offset].customKeychainServiceName = nil
                    profiles[target.offset].oauthAccountJSON = nil
                    if !profiles[target.offset].nameIsCustomized {
                        profiles[target.offset].name = migrationAccount.preferredName
                    }
                    // cswap has no token-count metric; keep the profile's
                    // layout but drop a display mode it cannot render.
                    if !Provider.cswap.descriptor.capabilities.tokenCounts {
                        for index in profiles[target.offset].iconConfig.metrics.indices
                        where profiles[target.offset].iconConfig.metrics[index].weekDisplayMode == .tokens {
                            profiles[target.offset].iconConfig.metrics[index].weekDisplayMode = .percentage
                        }
                    }
                    updatedExisting = true
                    LoggingService.shared.log("AutoDetectAccounts: converted the Claude CLI profile to cswap account \(migrationAccount.email) (matched by \(legacyIdentity ?? "no identity"))")
                } else {
                    LoggingService.shared.log("AutoDetectAccounts: left the Claude CLI profile as Anthropic — no cswap account matched \(legacyIdentity ?? "no identity")")
                }
            }
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

        // Name any remaining Claude Code profile from its own captured login.
        // Never take the name from cswap's active slot: that was the source of
        // a pinned profile appearing to follow the current cswap selection.
        let anthropicCandidates = profiles.enumerated().filter { _, profile in
            profile.provider == .anthropic && profile.hasAnyCredentials && !profile.nameIsCustomized
        }
        let anthropicTarget = anthropicCandidates.first(where: { $0.element.id == manager.activeProfile?.id })
            ?? (anthropicCandidates.count == 1 ? anthropicCandidates.first : nil)

        if let target = anthropicTarget {
            let email = target.element.detectedAccountIdentifier.flatMap { $0.contains("@") ? $0 : nil }
                ?? Self.oauthEmail(from: target.element.oauthAccountJSON)
            if let email {
                if profiles[target.offset].detectedAccountIdentifier != email {
                    profiles[target.offset].detectedAccountIdentifier = email
                    updatedExisting = true
                }
                if profiles[target.offset].name != email {
                    profiles[target.offset].name = email
                    updatedExisting = true
                }
            }
        }

        // One account should exist once. The old conversion could create a
        // second profile for the same cswap login; collapse those by external
        // key, always keeping the currently pinned profile.
        var seenExternalKeys = Set<String>()
        var dedupedProfiles: [Profile] = []
        var removedDuplicates: [Profile] = []
        for profile in profiles {
            guard let key = profile.externalAccountKey, !key.isEmpty else {
                dedupedProfiles.append(profile)
                continue
            }
            if let index = dedupedProfiles.firstIndex(where: { $0.externalAccountKey == key }) {
                let existing = dedupedProfiles[index]
                let activeId = manager.activeProfile?.id
                let keepNew: Bool
                if profile.id == activeId {
                    keepNew = true
                } else if existing.id == activeId {
                    keepNew = false
                } else {
                    keepNew = profile.createdAt < existing.createdAt
                }

                if keepNew {
                    removedDuplicates.append(existing)
                    dedupedProfiles[index] = profile
                } else {
                    removedDuplicates.append(profile)
                }
            } else {
                dedupedProfiles.append(profile)
            }
        }
        if !removedDuplicates.isEmpty {
            profiles = dedupedProfiles
            updatedExisting = true
            for duplicate in removedDuplicates {
                LoggingService.shared.log("AutoDetectAccounts: removed duplicate profile '\(duplicate.name)' for \(duplicate.externalAccountKey ?? "unknown")")
            }
        }

        if !addedProfiles.isEmpty || updatedExisting {
            manager.profiles = profiles
            if let activeId = manager.activeProfile?.id,
               let refreshed = profiles.first(where: { $0.id == activeId }) {
                manager.activeProfile = refreshed
            }
            ProfileStore.shared.saveProfiles(profiles)
            for duplicate in removedDuplicates {
                ProfileStore.shared.deleteProfileSecrets(duplicate.id)
            }
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

        // One menu bar tracker by default. The active (pinned) profile is the
        // account shown in the menu bar, and the user can change it from the
        // account list or Manage Profiles. Multi-profile mode remains opt-in.
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
                    name: account.preferredName,
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
