import Foundation
import SQLite3

/// An OpenCode Console account discovered from OpenCode's local credential
/// store. OpenCode rotates these tokens itself; this app only reads them.
struct OpenCodeAccount: Equatable {
    let key: String
    let credentialId: String
    let name: String
    let email: String?
    let accessToken: String
    let expiresAt: Date?
    let isAPIKey: Bool

    var accountKey: String { "opencode:\(key)" }
    var displayName: String { name }
}

/// A single Go allowance meter (`rolling`, `weekly`, or `monthly`).
struct OpenCodeMeter: Equatable {
    let status: String?
    let percent: Double
    let resetsAt: Date?
}

struct OpenCodeUsageSnapshot: Equatable {
    let rolling: OpenCodeMeter?
    let weekly: OpenCodeMeter?
    let monthly: OpenCodeMeter?

    var hasAnyMeter: Bool { rolling != nil || weekly != nil || monthly != nil }
}

/// Reads OpenCode's local credential database and asks the OpenCode Go usage
/// endpoint for that account's allowance meters.
///
/// Storage is OpenCode v2's `opencode.db` (`credential` table) with a fallback
/// to the v1 `auth.json`. Nothing is ever written back.
final class OpenCodeAccountService {
    static let shared = OpenCodeAccountService()

    private let usageURL = URL(string: "https://opencode.ai/inference/go/v1/usage")!

    private init() {}

    // MARK: - Discovery

    func loadAccounts() -> [OpenCodeAccount] {
        var accounts = accountsFromDatabase() + accountsFromLegacyAuthFile()

        // The same account can be stored under more than one credential row.
        // Keep the one that stays valid longest.
        var byKey: [String: OpenCodeAccount] = [:]
        for account in accounts {
            if let existing = byKey[account.key] {
                let existingExpiry = existing.expiresAt ?? .distantPast
                let candidateExpiry = account.expiresAt ?? .distantPast
                if candidateExpiry <= existingExpiry { continue }
            }
            byKey[account.key] = account
        }
        accounts = Array(byKey.values)
        return accounts.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    func account(for profile: Profile) -> OpenCodeAccount? {
        guard let key = profile.externalAccountKey else { return nil }
        return loadAccounts().first { $0.accountKey == key }
    }

    // MARK: - Usage

    func fetchUsage(for account: OpenCodeAccount) async throws -> OpenCodeUsageSnapshot {
        var request = URLRequest(url: usageURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("claude-usage-tracker/1.0", forHTTPHeaderField: "User-Agent")

        let startTime = Date()
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw AppError(
                code: .apiGenericError,
                message: "Could not reach OpenCode",
                technicalDetails: error.localizedDescription,
                underlyingError: error,
                isRecoverable: true
            )
        }

        let statusCode = (response as? HTTPURLResponse)?.statusCode
        NetworkLoggerService.shared.logRequest(
            url: usageURL.absoluteString,
            method: "GET",
            requestBody: nil,
            responseData: data,
            statusCode: statusCode,
            duration: Date().timeIntervalSince(startTime),
            error: nil
        )

        switch statusCode {
        case .some(401), .some(403):
            throw AppError(
                code: .providerAuthExpired,
                message: "OpenCode login expired",
                technicalDetails: "The Go usage endpoint rejected this account (HTTP \(statusCode ?? 0)).",
                isRecoverable: true,
                recoverySuggestion: "Open OpenCode and run `/connect` (or `opencode auth login`) for this account, then refresh."
            )
        case .some(200...299):
            break
        default:
            throw AppError(
                code: .apiServerError,
                message: "OpenCode usage request failed",
                technicalDetails: "HTTP \(statusCode.map(String.init) ?? "nil") from the Go usage endpoint.",
                isRecoverable: true
            )
        }

        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let usage = json["usage"] as? [String: Any] else {
            throw AppError(
                code: .apiParsingFailed,
                message: "OpenCode returned an unexpected response",
                technicalDetails: "No `usage` object in the Go usage response.",
                isRecoverable: true
            )
        }

        let snapshot = OpenCodeUsageSnapshot(
            rolling: meter(usage["rolling"]),
            weekly: meter(usage["weekly"]),
            monthly: meter(usage["monthly"])
        )
        guard snapshot.hasAnyMeter else {
            throw AppError(
                code: .apiParsingFailed,
                message: "OpenCode returned no usage meters",
                technicalDetails: "The account may not have an active Go subscription.",
                isRecoverable: true,
                recoverySuggestion: "Check the OpenCode Console Go subscription for this account."
            )
        }
        return snapshot
    }

    // MARK: - Database

    private func accountsFromDatabase() -> [OpenCodeAccount] {
        let path = databaseURL().path
        guard FileManager.default.fileExists(atPath: path) else { return [] }

        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return []
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT id, label, integration_id, value, time_updated
        FROM credential
        WHERE integration_id IN ('opencode', 'opencode-go')
        ORDER BY time_updated DESC
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var accounts: [OpenCodeAccount] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(statement, 0),
                  let labelText = sqlite3_column_text(statement, 1),
                  let valueText = sqlite3_column_text(statement, 3) else { continue }

            let id = String(cString: idText)
            let label = String(cString: labelText)
            let value = String(cString: valueText)
            if let account = parseCredential(id: id, label: label, value: value) {
                accounts.append(account)
            }
        }
        return accounts
    }

    private func parseCredential(id: String, label: String, value: String) -> OpenCodeAccount? {
        guard let data = value.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = json["type"] as? String else {
            return nil
        }

        let expiresAt = UsageDateParser.date(fromUnixMilliseconds: json["expires"])

        switch type {
        case "oauth":
            guard let access = json["access"] as? String, !access.isEmpty else { return nil }
            // An already-expired token would only produce an auth error. It
            // reappears here after OpenCode refreshes it on next use.
            if let expiresAt, expiresAt < Date().addingTimeInterval(-60) { return nil }

            let metadata = json["metadata"] as? [String: Any] ?? [:]
            let accountId = metadata["accountID"] as? String
            let orgId = metadata["orgID"] as? String
            let email = metadata["email"] as? String
            let orgName = metadata["orgName"] as? String

            let dedupeKey = [accountId ?? email ?? id, orgId ?? ""].joined(separator: ":")
            let displayName: String
            if let orgName, !orgName.isEmpty, orgName != "Default" {
                displayName = email.map { "\(orgName) · \($0)" } ?? orgName
            } else {
                displayName = email ?? label
            }

            return OpenCodeAccount(
                key: dedupeKey,
                credentialId: id,
                name: displayName,
                email: email,
                accessToken: access,
                expiresAt: expiresAt,
                isAPIKey: false
            )

        case "key":
            // Only Console API keys (`oc_sk_...`) are Go-eligible. OpenCode's
            // own provider keys (`sk-...`) are inference credentials and are
            // rejected by the Go usage endpoint.
            guard let apiKey = json["key"] as? String, apiKey.hasPrefix("oc_sk_") else {
                return nil
            }
            return OpenCodeAccount(
                key: "key:\(id)",
                credentialId: id,
                name: label,
                email: nil,
                accessToken: apiKey,
                expiresAt: nil,
                isAPIKey: true
            )

        default:
            return nil
        }
    }

    private func databaseURL() -> URL {
        let env = ProcessInfo.processInfo.environment
        if let xdg = env["XDG_DATA_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: (xdg as NSString).expandingTildeInPath)
                .appendingPathComponent("opencode/opencode.db")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/opencode.db")
    }

    // MARK: - Legacy v1 auth.json

    private func accountsFromLegacyAuthFile() -> [OpenCodeAccount] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".local/share/opencode/auth.json"),
            home.appendingPathComponent(".config/opencode/auth.json"),
        ]
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let data = try? Data(contentsOf: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return []
        }

        return json.compactMap { provider, raw in
            guard provider == "opencode" || provider == "opencode-go",
                  let dict = raw as? [String: Any],
                  let type = dict["type"] as? String else { return nil }

            if type == "oauth", let access = dict["access"] as? String, !access.isEmpty {
                let expiresAt = UsageDateParser.date(fromUnixMilliseconds: dict["expires"])
                if let expiresAt, expiresAt < Date().addingTimeInterval(-60) { return nil }
                let metadata = dict["metadata"] as? [String: Any] ?? [:]
                let accountId = metadata["accountID"] as? String
                let orgId = metadata["orgID"] as? String
                let email = metadata["email"] as? String
                let orgName = metadata["orgName"] as? String
                let dedupeKey = [accountId ?? email ?? "legacy", orgId ?? provider].joined(separator: ":")
                let displayName = orgName.flatMap { $0.isEmpty ? nil : $0 }
                    ?? email
                    ?? "OpenCode (\(provider))"
                return OpenCodeAccount(
                    key: dedupeKey,
                    credentialId: "legacy-\(provider)",
                    name: displayName,
                    email: email,
                    accessToken: access,
                    expiresAt: expiresAt,
                    isAPIKey: false
                )
            }

            if type == "key", let apiKey = dict["key"] as? String, apiKey.hasPrefix("oc_sk_") {
                return OpenCodeAccount(
                    key: "legacy-key:\(provider)",
                    credentialId: "legacy-\(provider)",
                    name: "OpenCode (\(provider))",
                    email: nil,
                    accessToken: apiKey,
                    expiresAt: nil,
                    isAPIKey: true
                )
            }
            return nil
        }
    }

    // MARK: - Parsing

    private func meter(_ raw: Any?) -> OpenCodeMeter? {
        guard let dict = raw as? [String: Any] else { return nil }
        guard let percent = doubleValue(dict["percent"]) else { return nil }
        return OpenCodeMeter(
            status: dict["status"] as? String,
            percent: min(100, max(0, percent)),
            resetsAt: UsageDateParser.parse(dict["resetsAt"])
        )
    }

    private func doubleValue(_ raw: Any?) -> Double? {
        if let number = raw as? NSNumber { return number.doubleValue }
        if let string = raw as? String { return Double(string) }
        return nil
    }
}
