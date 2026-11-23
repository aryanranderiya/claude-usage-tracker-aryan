import Foundation

/// One usage window as cswap stores it in `cache/usage.json`.
struct CswapWindow: Equatable {
    let percent: Double
    let resetsAt: Date?
}

struct CswapScopedWindow: Equatable {
    let name: String
    let window: CswapWindow
}

/// A Claude account managed by the local `cswap` (claude-swap) tool.
///
/// This app is a pure reader of cswap's own state: it never copies, refreshes,
/// swaps, or writes credentials. cswap keeps polling and refreshing accounts,
/// and its cache is the single source of truth.
struct CswapAccount: Equatable {
    let number: Int
    let email: String
    let organizationUuid: String?
    let organizationName: String?
    let alias: String?
    let planLabel: String?
    let isActive: Bool
    let isDisabled: Bool
    let fetchedAt: Date?
    let fiveHour: CswapWindow?
    let sevenDay: CswapWindow?
    let scoped: [CswapScopedWindow]

    var accountKey: String { "cswap:\(email.lowercased())" }

    /// Human label without a rotation-state suffix.
    var preferredName: String {
        let trimmed = alias?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.flatMap { $0.isEmpty ? nil : $0 } ?? email
    }

    /// Label used by cswap profile rows. Disabled is a cswap rotation flag,
    /// not a property of the account itself, so it is appended only here.
    var displayName: String {
        isDisabled ? "\(preferredName) (disabled)" : preferredName
    }

    var hasAnyUsage: Bool {
        fiveHour != nil || sevenDay != nil || !scoped.isEmpty
    }
}

/// Reads cswap's per-account state without invoking the CLI. The paths mirror
/// cswap's own resolution: `~/.claude-swap-backup` on macOS/Windows and
/// `$XDG_DATA_HOME/claude-swap` (default `~/.local/share/claude-swap`) on Linux.
///
/// Safety contract: this service opens exactly three files — `sequence.json`,
/// `cache/usage.json`, and `cache/subscription_plans.json` — and only for
/// reading. It never touches `credentials/`, `configs/`, `settings.json`, the
/// keychain, `~/.claude`, or cswap's locks, and it never runs `cswap`. A token
/// can therefore never be copied, refreshed, rotated, or invalidated by this
/// app; cswap remains the sole owner of its accounts.
final class CswapAccountService {
    static let shared = CswapAccountService()

    private init() {}

    func loadAccounts() -> [CswapAccount] {
        guard let sequence = readJSON(at: backupRoot().appendingPathComponent("sequence.json")),
              let sequenceAccounts = sequence["accounts"] as? [String: Any] else {
            return []
        }

        let usageRows = (readJSON(at: backupRoot().appendingPathComponent("cache/usage.json"))?["accounts"] as? [String: Any]) ?? [:]
        let plans = readJSON(at: backupRoot().appendingPathComponent("cache/subscription_plans.json")) ?? [:]
        let activeNumber = intValue(sequence["activeAccountNumber"])

        return sequenceAccounts.compactMap { slot, raw -> CswapAccount? in
            guard let account = raw as? [String: Any],
                  let number = Int(slot),
                  let email = account["email"] as? String,
                  !email.isEmpty else { return nil }

            let organizationUuid = account["organizationUuid"] as? String
            let organizationName = account["organizationName"] as? String
            let alias = account["alias"] as? String
            let disabled = account["disabled"] as? Bool ?? false

            let row = usageRows[slot] as? [String: Any]
            let identityMatches: Bool = {
                guard let row else { return false }
                guard let rowEmail = row["email"] as? String else { return true }
                guard rowEmail.caseInsensitiveCompare(email) == .orderedSame else { return false }
                if let storedOrg = row["organizationUuid"] as? String,
                   let organizationUuid,
                   !storedOrg.isEmpty {
                    return storedOrg == organizationUuid
                }
                return true
            }()

            let lastGood = identityMatches
                ? ((row?["lastGood"] ?? row?["lastGoodUsage"]) as? [String: Any])
                : nil
            let fetchedRaw = row?["fetchedAt"] ?? row?["lastGoodFetchedAt"] ?? row?["usageFetchedAt"]
            let fetchedAt = identityMatches
                ? (UsageDateParser.date(fromUnixSeconds: fetchedRaw) ?? UsageDateParser.parse(fetchedRaw))
                : nil
            var planLabel: String?
            if let organizationUuid,
               let plan = plans["\(email)\n\(organizationUuid)"] as? [String: Any],
               let details = plan["plan"] as? [String: Any] {
                planLabel = details["planDisplayName"] as? String
            }

            let fiveHour = window(lastGood?["five_hour"] ?? lastGood?["fiveHour"] ?? lastGood?["session"])
            let sevenDay = window(lastGood?["seven_day"] ?? lastGood?["sevenDay"] ?? lastGood?["weekly"])
            let scoped = scopedWindows(lastGood?["scoped"])

            return CswapAccount(
                number: number,
                email: email,
                organizationUuid: organizationUuid,
                organizationName: organizationName,
                alias: alias,
                planLabel: planLabel,
                isActive: activeNumber == number,
                isDisabled: disabled,
                fetchedAt: fetchedAt,
                fiveHour: fiveHour,
                sevenDay: sevenDay,
                scoped: scoped
            )
        }
        .sorted { $0.number < $1.number }
    }

    func account(for profile: Profile) -> CswapAccount? {
        guard let key = profile.externalAccountKey else { return nil }
        return loadAccounts().first { $0.accountKey == key }
    }

    // MARK: - Mapping

    static func mapToUsage(_ account: CswapAccount) -> ClaudeUsage {
        let now = Date()
        var usage = ClaudeUsage.empty
        usage.weeklyLimit = 0

        if let session = account.fiveHour {
            usage.hasSessionLimit = true
            usage.sessionPercentage = livePercent(session, now: now)
            usage.sessionResetTime = session.resetsAt ?? now.addingTimeInterval(5 * 60 * 60)
        } else {
            usage.hasSessionLimit = false
        }

        if let week = account.sevenDay {
            usage.hasWeeklyLimit = true
            usage.weeklyPercentage = livePercent(week, now: now)
            usage.weeklyResetTime = week.resetsAt ?? now.addingTimeInterval(7 * 24 * 60 * 60)
        } else {
            usage.hasWeeklyLimit = false
        }

        for scoped in account.scoped {
            let percent = livePercent(scoped.window, now: now)
            let reset = scoped.window.resetsAt
            switch scoped.name.lowercased() {
            case "fable":
                usage.fableWeeklyPercentage = percent
                usage.fableWeeklyResetTime = reset
            case "opus":
                usage.opusWeeklyPercentage = percent
            case "sonnet":
                usage.sonnetWeeklyPercentage = percent
                usage.sonnetWeeklyResetTime = reset
            case "design":
                usage.designWeeklyPercentage = percent
                usage.designWeeklyResetTime = reset
            default:
                continue
            }
        }

        usage.planType = account.planLabel
        usage.lastUpdated = account.fetchedAt ?? now
        usage.userTimezone = .current
        return usage
    }

    private static func livePercent(_ window: CswapWindow, now: Date) -> Double {
        if let reset = window.resetsAt, reset <= now { return 0 }
        return min(100, max(0, window.percent))
    }

    // MARK: - Local file helpers

    private func backupRoot() -> URL {
        let env = ProcessInfo.processInfo.environment
        #if os(Linux) || os(Windows)
        if let xdg = env["XDG_DATA_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: (xdg as NSString).expandingTildeInPath)
                .appendingPathComponent("claude-swap")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/claude-swap")
        #else
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-swap-backup")
        #endif
    }

    private func readJSON(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private func window(_ raw: Any?) -> CswapWindow? {
        guard let dict = raw as? [String: Any] else { return nil }
        guard let percent = doubleValue(dict["pct"] ?? dict["percent"] ?? dict["utilization"]) else {
            return nil
        }
        return CswapWindow(
            percent: percent,
            resetsAt: UsageDateParser.parse(dict["resets_at"] ?? dict["resetsAt"] ?? dict["resets"])
        )
    }

    private func scopedWindows(_ raw: Any?) -> [CswapScopedWindow] {
        guard let rows = raw as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let name = row["name"] as? String, let window = window(row) else { return nil }
            return CswapScopedWindow(name: name, window: window)
        }
    }

    private func doubleValue(_ raw: Any?) -> Double? {
        if let number = raw as? NSNumber { return number.doubleValue }
        if let string = raw as? String { return Double(string) }
        return nil
    }

    private func intValue(_ raw: Any?) -> Int? {
        if let number = raw as? NSNumber { return number.intValue }
        if let string = raw as? String { return Int(string) }
        return nil
    }
}
