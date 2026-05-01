import Foundation

private let codexLog = FileLog("Codex")

struct CodexAuthStatus: Codable {
    let loggedIn: Bool
    let email: String?
    let displayName: String?
    let accountId: String?
    let subscriptionType: String?
}

private struct CodexAuthFile: Codable {
    let authMode: String?
    let openAIAPIKey: String?
    let tokens: CodexTokens?

    enum CodingKeys: String, CodingKey {
        case authMode = "auth_mode"
        case openAIAPIKey = "OPENAI_API_KEY"
        case tokens
    }
}

private struct CodexTokens: Codable {
    let accessToken: String?
    let refreshToken: String?
    let idToken: String?
    let accountId: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case accountId = "account_id"
    }
}

private struct CodexIDTokenClaims: Codable {
    let email: String?
    let name: String?
    let sub: String?
    let exp: Int?
}

private struct CodexUsageResponse: Codable {
    let planType: String?
    let rateLimit: CodexRateLimit?
    let credits: CodexCredits?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case credits
    }
}

private struct CodexRateLimit: Codable {
    let allowed: Bool?
    let limitReached: Bool?
    let primaryWindow: CodexUsageWindow?
    let secondaryWindow: CodexUsageWindow?

    enum CodingKeys: String, CodingKey {
        case allowed
        case limitReached = "limit_reached"
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }
}

private struct CodexUsageWindow: Codable {
    let usedPercent: Double?
    let resetAt: Double?

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case resetAt = "reset_at"
    }
}

private struct CodexCredits: Codable {
    let hasCredits: Bool?
    let unlimited: Bool?
    let balance: String?

    enum CodingKeys: String, CodingKey {
        case hasCredits = "has_credits"
        case unlimited
        case balance
    }
}

final class CodexService: Sendable {
    static let shared = CodexService()

    private let codexPath: String
    private let authPath = NSHomeDirectory() + "/.codex/auth.json"

    private init() {
        let home = NSHomeDirectory()
        let possiblePaths = [
            "/usr/local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/opt/local/bin/codex",
            "\(home)/.local/bin/codex",
            "\(home)/.npm-global/bin/codex",
            "\(home)/.volta/bin/codex",
            "\(home)/Library/pnpm/codex",
            "\(home)/.bun/bin/codex",
            "\(home)/.yarn/bin/codex"
        ] + Self.nvmPaths()

        if let found = possiblePaths.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            self.codexPath = found
            codexLog.info("Codex binary path: \(self.codexPath) (curated)")
        } else if let shellPath = Self.shellPathLookup() {
            self.codexPath = shellPath
            codexLog.info("Codex binary path: \(self.codexPath) (resolved via user shell PATH)")
        } else {
            self.codexPath = "codex"
            codexLog.warning("Codex binary not found; falling back to bare 'codex'")
        }
    }

    private static func nvmPaths() -> [String] {
        let nvmDir = "\(NSHomeDirectory())/.nvm/versions/node"
        guard FileManager.default.fileExists(atPath: nvmDir),
              let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmDir) else {
            return []
        }
        return versions
            .filter { !$0.hasPrefix(".") }
            .map { "\(nvmDir)/\($0)/bin/codex" }
    }

    private static func shellPathLookup() -> String? {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-ilc", "command -v codex"]
        process.standardOutput = stdout
        process.standardError = Pipe()
        process.environment = ProcessInfo.processInfo.environment

        do {
            try process.run()
        } catch {
            codexLog.warning("[shellPathLookup] Failed to launch /bin/zsh: \(error.localizedDescription)")
            return nil
        }

        let deadline = Date().addingTimeInterval(3.0)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            codexLog.warning("[shellPathLookup] zsh exceeded 3s timeout; aborting")
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let raw = String(data: data, encoding: .utf8) ?? ""
        let candidate = raw
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard candidate.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: candidate) else {
            return nil
        }
        return candidate
    }

    func isCodexAvailable() async -> Bool {
        do {
            let version = try await runCodex(args: ["--version"])
            codexLog.info("[isCodexAvailable] YES, version: \(version.trimmingCharacters(in: .whitespacesAndNewlines))")
            return true
        } catch {
            codexLog.error("[isCodexAvailable] NO, error: \(error.localizedDescription)")
            return false
        }
    }

    func getAuthStatus() throws -> CodexAuthStatus {
        guard let snapshot = readAuthSnapshot(),
              let data = snapshot.data(using: .utf8),
              let auth = try? JSONDecoder().decode(CodexAuthFile.self, from: data) else {
            return CodexAuthStatus(loggedIn: false, email: nil, displayName: nil, accountId: nil, subscriptionType: nil)
        }

        let claims = Self.decodeIDTokenClaims(auth.tokens?.idToken)
        let accountId = auth.tokens?.accountId ?? claims?.sub
        let loggedIn = auth.tokens?.accessToken?.isEmpty == false || auth.openAIAPIKey?.isEmpty == false
        return CodexAuthStatus(
            loggedIn: loggedIn,
            email: claims?.email ?? accountId,
            displayName: claims?.name ?? claims?.email ?? accountId,
            accountId: accountId,
            subscriptionType: nil
        )
    }

    func readAuthSnapshot() -> String? {
        guard let data = FileManager.default.contents(atPath: authPath),
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty else {
            codexLog.error("[readAuthSnapshot] Failed to read \(authPath)")
            return nil
        }
        return text
    }

    func writeAuthSnapshot(_ authJSON: String) -> Bool {
        do {
            let codexDir = URL(fileURLWithPath: authPath).deletingLastPathComponent()
            try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
            try authJSON.write(to: URL(fileURLWithPath: authPath), atomically: true, encoding: .utf8)
            codexLog.info("[writeAuthSnapshot] Wrote \(authPath), length=\(authJSON.count)")
            return true
        } catch {
            codexLog.error("[writeAuthSnapshot] Failed: \(error.localizedDescription)")
            return false
        }
    }

    func captureCurrentCredentials(forAccountId accountId: String, planType: String? = nil) -> Bool {
        guard let snapshot = readAuthSnapshot() else { return false }
        guard let status = try? getAuthStatus(),
              status.loggedIn,
              let codexAccountId = status.accountId,
              let email = status.email else {
            codexLog.error("[capture] Failed: could not derive Codex identity")
            return false
        }
        let backup = CodexAccountBackup(
            authJSON: snapshot,
            accountId: codexAccountId,
            email: email,
            displayName: status.displayName ?? email,
            planType: planType ?? status.subscriptionType
        )
        return KeychainService.shared.saveCodexAccountBackup(backup, forAccountId: accountId)
    }

    func switchAccount(from currentAccount: Account?, to targetAccount: Account) throws {
        if let currentAccount, currentAccount.provider == .codex, let currentSnapshot = readAuthSnapshot() {
            let status = try? getAuthStatus()
            let backup = CodexAccountBackup(
                authJSON: currentSnapshot,
                accountId: status?.accountId ?? currentAccount.email,
                email: status?.email ?? currentAccount.email,
                displayName: status?.displayName ?? currentAccount.displayName,
                planType: currentAccount.subscriptionType
            )
            _ = KeychainService.shared.saveCodexAccountBackup(backup, forAccountId: currentAccount.id.uuidString)
        }

        guard let targetBackup = KeychainService.shared.getCodexAccountBackup(forAccountId: targetAccount.id.uuidString) else {
            throw CodexServiceError.noAuthForAccount(targetAccount.id.uuidString)
        }
        guard writeAuthSnapshot(targetBackup.authJSON) else {
            throw CodexServiceError.authWriteFailed
        }

        let status = try getAuthStatus()
        guard status.loggedIn else { throw CodexServiceError.switchVerificationFailed }
        if let accountId = status.accountId, accountId != targetBackup.accountId {
            throw CodexServiceError.switchWrongAccount(expected: targetBackup.accountId, actual: accountId)
        }
    }

    func login() async throws {
        _ = try await runCodex(args: ["login"])
        try await Task.sleep(for: .seconds(1))
    }

    func logout() async throws {
        _ = try await runCodex(args: ["logout"])
    }

    enum UsageError: Error {
        case missingToken
        case expired
        case network(String)
        case decode(String)
    }

    func getUsageLimits(authJSON: String) async throws -> (UsageAPIResponse, String?) {
        guard let data = authJSON.data(using: .utf8),
              let auth = try? JSONDecoder().decode(CodexAuthFile.self, from: data),
              let accessToken = auth.tokens?.accessToken,
              !accessToken.isEmpty else {
            throw UsageError.missingToken
        }

        guard let url = URL(string: "https://chatgpt.com/backend-api/wham/usage") else {
            throw UsageError.network("invalid url")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let accountId = auth.tokens?.accountId {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (responseData, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as? HTTPURLResponse
        guard httpResponse?.statusCode == 200 else {
            if httpResponse?.statusCode == 401 || httpResponse?.statusCode == 403 {
                throw UsageError.expired
            }
            throw UsageError.network("HTTP \(httpResponse?.statusCode ?? 0)")
        }

        do {
            let usage = try JSONDecoder().decode(CodexUsageResponse.self, from: responseData)
            codexLog.info("[getUsageLimits] session=\(usage.rateLimit?.primaryWindow?.usedPercent ?? -1)%, weekly=\(usage.rateLimit?.secondaryWindow?.usedPercent ?? -1)%")
            return (UsageAPIResponse.codex(from: usage), usage.planType)
        } catch {
            codexLog.error("[getUsageLimits] Decode Error: \(error.localizedDescription)")
            throw UsageError.decode(error.localizedDescription)
        }
    }

    private func runCodex(args: [String]) async throws -> String {
        codexLog.debug("[runCodex] Running: codex \(args.joined(separator: " "))")
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [codexPath] in
                let process = Process()
                let pipe = Pipe()

                process.executableURL = URL(fileURLWithPath: codexPath)
                process.arguments = args
                process.standardOutput = pipe
                process.standardError = pipe

                var env = ProcessInfo.processInfo.environment
                let homeDir = NSHomeDirectory()
                var extraPaths = [
                    "/opt/homebrew/bin",
                    "/usr/local/bin",
                    "\(homeDir)/.local/bin",
                    "\(homeDir)/.npm-global/bin"
                ]
                if codexPath.contains("/") {
                    let resolved = URL(fileURLWithPath: codexPath).resolvingSymlinksInPath().path
                    let resolvedBinDir = URL(fileURLWithPath: resolved).deletingLastPathComponent().path
                    extraPaths.insert(resolvedBinDir, at: 0)
                }
                let existingPath = env["PATH"] ?? "/usr/bin:/bin"
                env["PATH"] = (extraPaths + [existingPath]).joined(separator: ":")
                env["HOME"] = homeDir
                process.environment = env

                do {
                    try process.run()
                    process.waitUntilExit()

                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""

                    if process.terminationStatus == 0 {
                        continuation.resume(returning: output)
                    } else {
                        continuation.resume(throwing: CodexServiceError.cliError(output))
                    }
                } catch {
                    continuation.resume(throwing: CodexServiceError.processLaunchFailed(error))
                }
            }
        }
    }

    private static func decodeIDTokenClaims(_ token: String?) -> CodexIDTokenClaims? {
        guard let token else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = payload.count % 4
        if padding > 0 {
            payload += String(repeating: "=", count: 4 - padding)
        }
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONDecoder().decode(CodexIDTokenClaims.self, from: data)
    }
}

private extension UsageAPIResponse {
    static func codex(from usage: CodexUsageResponse) -> UsageAPIResponse {
        UsageAPIResponse(
            fiveHour: UsageWindow.codex(from: usage.rateLimit?.primaryWindow),
            sevenDay: UsageWindow.codex(from: usage.rateLimit?.secondaryWindow),
            sevenDayOauthApps: nil,
            sevenDayOpus: nil,
            sevenDaySonnet: nil,
            sevenDayCowork: nil,
            iguanaNecktie: nil,
            extraUsage: ExtraUsage.codex(from: usage.credits)
        )
    }
}

private extension UsageWindow {
    static func codex(from window: CodexUsageWindow?) -> UsageWindow? {
        guard let window else { return nil }
        let resetString: String?
        if let resetAt = window.resetAt {
            resetString = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: resetAt))
        } else {
            resetString = nil
        }
        return UsageWindow(utilization: window.usedPercent, resetsAt: resetString)
    }
}

private extension ExtraUsage {
    static func codex(from credits: CodexCredits?) -> ExtraUsage? {
        guard let credits else { return nil }
        let balance = credits.balance.flatMap(Double.init)
        return ExtraUsage(
            isEnabled: credits.hasCredits,
            monthlyLimit: nil,
            usedCredits: balance,
            utilization: nil
        )
    }
}

enum CodexServiceError: LocalizedError {
    case cliError(String)
    case processLaunchFailed(Error)
    case noAuthForAccount(String)
    case authWriteFailed
    case switchVerificationFailed
    case switchWrongAccount(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .cliError(let msg):
            return "Codex CLI error: \(msg)"
        case .processLaunchFailed(let error):
            return "Failed to launch Codex: \(error.localizedDescription)"
        case .noAuthForAccount:
            return "No stored Codex auth for target account"
        case .authWriteFailed:
            return "Failed to write ~/.codex/auth.json"
        case .switchVerificationFailed:
            return "Codex switch verification failed"
        case .switchWrongAccount(let expected, let actual):
            return "Switched to wrong Codex account: expected \(expected), got \(actual)"
        }
    }
}
