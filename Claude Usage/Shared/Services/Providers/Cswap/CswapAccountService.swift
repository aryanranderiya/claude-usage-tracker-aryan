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

    private var liveAccounts: [CswapAccount] = []
    private var liveFetchedAt: Date = .distantPast
    private var refreshTask: Task<[CswapAccount], Never>?
    private let stateLock = NSLock()

    private init() {}

    /// Synchronous snapshot for discovery/UI. Uses the most recent CLI result
    /// when one exists, otherwise the read-only cache on disk.
    func loadAccounts() -> [CswapAccount] {
        stateLock.lock()
        let live = liveAccounts
        stateLock.unlock()
        return live.isEmpty ? loadCachedAccounts() : live
    }

    /// Refreshes from `cswap list --json`. cswap owns login refresh and usage
    /// polling; this app only reads its output and never touches credentials.
    func refreshAccounts(force: Bool = false) async -> [CswapAccount] {
        stateLock.lock()
        if let refreshTask {
            stateLock.unlock()
            return await refreshTask.value
        }
        if !force, !liveAccounts.isEmpty, Date().timeIntervalSince(liveFetchedAt) < 10 {
            let accounts = liveAccounts
            stateLock.unlock()
            return accounts
        }

        let task = Task.detached(priority: .utility) { Self.fetchLiveAccounts() }
        refreshTask = task
        stateLock.unlock()

        let accounts = await task.value

        stateLock.lock()
        refreshTask = nil
        if !accounts.isEmpty {
            liveAccounts = accounts
            liveFetchedAt = Date()
        }
        let resolved = accounts.isEmpty ? liveAccounts : accounts
        stateLock.unlock()

        return resolved.isEmpty ? loadCachedAccounts() : resolved
    }

    private func loadCachedAccounts() -> [CswapAccount] {
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

    // MARK: - Fresh cswap CLI snapshot

    private static func fetchLiveAccounts() -> [CswapAccount] {
        guard let executable = cswapExecutable() else { return [] }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["list", "--json"]

        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extraPath = [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"].joined(separator: ":")
        environment["PATH"] = extraPath + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let timeout = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20, execute: timeout)

        do {
            try process.run()
        } catch {
            timeout.cancel()
            return []
        }
        process.waitUntilExit()
        timeout.cancel()

        guard process.terminationStatus == 0 else { return [] }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return parseCLIAccounts(data)
    }

    private static func cswapExecutable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".local/bin/cswap"),
            URL(fileURLWithPath: "/opt/homebrew/bin/cswap"),
            URL(fileURLWithPath: "/usr/local/bin/cswap"),
            home.appendingPathComponent(".local/share/uv/tools/claude-swap/bin/cswap"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func parseCLIAccounts(_ data: Data) -> [CswapAccount] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = root["accounts"] as? [[String: Any]] else { return [] }

        return rows.compactMap { row -> CswapAccount? in
            guard let number = row["number"] as? Int,
                  let email = row["email"] as? String,
                  !email.isEmpty else { return nil }

            let usage = row["usage"] as? [String: Any]
                ?? row["lastGoodUsage"] as? [String: Any]
            let fetchedRaw = row["usageFetchedAt"]
                ?? row["lastGoodFetchedAt"]
                ?? row["fetchedAt"]
            let fetchedAt = UsageDateParser.parse(fetchedRaw)

            let plan = row["plan"] as? [String: Any]
            let planLabel = plan?["label"] as? String ?? plan?["planDisplayName"] as? String
            let scoped = (usage?["scoped"] as? [[String: Any]] ?? []).compactMap { item -> CswapScopedWindow? in
                guard let name = item["name"] as? String,
                      let window = Self.window(from: item) else { return nil }
                return CswapScopedWindow(name: name, window: window)
            }

            return CswapAccount(
                number: number,
                email: email,
                organizationUuid: row["organizationUuid"] as? String,
                organizationName: row["organizationName"] as? String,
                alias: row["alias"] as? String,
                planLabel: planLabel,
                isActive: row["active"] as? Bool ?? false,
                isDisabled: row["disabled"] as? Bool ?? false,
                fetchedAt: fetchedAt,
                fiveHour: Self.window(from: usage?["fiveHour"] ?? usage?["five_hour"]),
                sevenDay: Self.window(from: usage?["sevenDay"] ?? usage?["seven_day"]),
                scoped: scoped
            )
        }
        .sorted { $0.number < $1.number }
    }

    private static func window(from raw: Any?) -> CswapWindow? {
        guard let dict = raw as? [String: Any] else { return nil }
        let percent: Double?
        if let value = dict["pct"] as? NSNumber { percent = value.doubleValue }
        else if let value = dict["percent"] as? NSNumber { percent = value.doubleValue }
        else if let value = dict["utilization"] as? NSNumber { percent = value.doubleValue }
        else if let value = dict["pct"] as? String { percent = Double(value) }
        else { percent = nil }
        guard let percent else { return nil }
        return CswapWindow(
            percent: percent,
            resetsAt: UsageDateParser.parse(dict["resetsAt"] ?? dict["resets_at"] ?? dict["resets"])
        )
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
