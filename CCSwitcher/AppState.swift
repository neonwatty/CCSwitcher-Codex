import SwiftUI
import Combine
import WidgetKit

private let log = FileLog("AppState")

/// Central app state managing accounts, usage data, and active sessions.
@MainActor
final class AppState: ObservableObject {
    // MARK: - Published State

    @Published var accounts: [Account] = []
    @Published var activeAccount: Account?
    @Published var accountUsage: [UUID: UsageAPIResponse] = [:]
    @Published var usageSummary: UsageSummary = .empty
    @Published var recentActivity: [DailyActivity] = []
    @Published var activeSessions: [SessionInfo] = []
    @Published var isLoading = false
    @Published var isLoggingIn = false
    @Published var errorMessage: String?
    @Published var claudeAvailable = false
    @Published var codexAvailable = false
    @Published var lastUsageRefresh: Date?
    @Published var costSummary: CostSummary = .empty
    @Published var claudeCostSummary: CostSummary = .empty
    @Published var codexCostSummary: CostSummary = .empty
    @Published var activityStats: ActivityStats = .empty
    @Published var claudeActivityStats: ActivityStats = .empty
    @Published var codexActivityStats: ActivityStats = .empty

    // Store errors as special struct to surface in UI
    struct UsageErrorState {
        let isExpired: Bool
        let isRateLimited: Bool
        let message: String
    }
    
    @Published var accountUsageErrors: [UUID: UsageErrorState] = [:]

    // MARK: - Services

    private let claudeService = ClaudeService.shared
    private let codexService = CodexService.shared
    private let statsParser = StatsParser.shared
    private let costParser = CostParser.shared
    private let activityParser = ActivityParser.shared
    private let codexUsageParser = CodexUsageParser.shared
    private let keychain = KeychainService.shared

    private let accountsKey = "com.ccswitcher.accounts"
    private var refreshTimer: Timer?
    private var isRefreshing = false

    // MARK: - Initialization

    init() {
        log.info("[init] Loading accounts from UserDefaults...")
        loadAccounts()
        log.info("[init] Loaded \(self.accounts.count) accounts, active: \(self.activeAccount?.id.uuidString ?? "none")")
    }

    // MARK: - Refresh

    func refresh() async {
        guard !isLoggingIn else {
            log.info("[refresh] Skipping: login in progress")
            return
        }
        guard !isRefreshing else {
            log.info("[refresh] Skipping: refresh already in progress")
            return
        }
        isRefreshing = true
        defer {
            isRefreshing = false
            isLoading = false
        }
        isLoading = true
        errorMessage = nil

        claudeAvailable = await claudeService.isClaudeAvailable()
        codexAvailable = await codexService.isCodexAvailable()
        log.info("[refresh] Claude available: \(self.claudeAvailable), Codex available: \(self.codexAvailable)")

        if claudeAvailable {
            do {
                let status = try await claudeService.getAuthStatus()
                updateActiveClaudeAccount(from: status)
            } catch {
                log.error("[refresh] getAuthStatus failed: \(error.localizedDescription)")
                errorMessage = error.localizedDescription
            }
        }
        if codexAvailable {
            do {
                let status = try codexService.getAuthStatus()
                updateActiveCodexAccount(from: status)
            } catch {
                log.error("[refresh] Codex getAuthStatus failed: \(error.localizedDescription)")
            }
        }

        // Passive token health check (no CLI calls, keychain reads only)
        diagnoseTokenHealth()

        // Fetch usage limits for all accounts
        await fetchAllAccountUsage()
        lastUsageRefresh = Date()

        usageSummary = statsParser.getUsageSummary()
        recentActivity = statsParser.getRecentActivity(days: 7)
        activeSessions = statsParser.getActiveSessions()

        // Heavy local log parsing off main thread. Claude and Codex can both be
        // used at the same time, so these summaries are intentionally combined.
        let claudeCostParser = costParser
        let claudeActivityParser = activityParser
        let codexParser = codexUsageParser
        async let claudeCost = Task.detached { claudeCostParser.getCostSummary() }.value
        async let codexCost = Task.detached { codexParser.getCostSummary() }.value
        async let claudeActivity = Task.detached { claudeActivityParser.getTodayStats() }.value
        async let codexActivity = Task.detached { codexParser.getTodayStats() }.value
        let claudeCostSummary = await claudeCost
        let codexCostSummary = await codexCost
        let claudeActivityStats = await claudeActivity
        let codexActivityStats = await codexActivity
        self.claudeCostSummary = claudeCostSummary
        self.codexCostSummary = codexCostSummary
        self.claudeActivityStats = claudeActivityStats
        self.codexActivityStats = codexActivityStats
        costSummary = CostSummary.combined([claudeCostSummary, codexCostSummary])
        activityStats = ActivityStats.combined([claudeActivityStats, codexActivityStats])

        log.info("[refresh] Usage: weekly=\(self.usageSummary.weeklyMessages) msgs, \(self.activeSessions.count) active sessions, today=$\(String(format: "%.2f", costSummary.todayCost)) turns=\(activityStats.conversationTurns)")

        updateWidgetData()
    }

    func startAutoRefresh(interval: TimeInterval = 300) {
        stopAutoRefresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.refresh()
            }
        }
    }

    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    var activeClaudeAccount: Account? {
        accounts.first { $0.provider == .claudeCode && $0.isActive }
    }

    var activeCodexAccount: Account? {
        accounts.first { $0.provider == .codex && $0.isActive }
    }

    func menuBarUsageLabel() -> String? {
        let items: [String?] = [
            activeClaudeAccount.map { "Claude \(usagePressure(for: $0))" },
            activeCodexAccount.map { "Codex \(usagePressure(for: $0))" },
        ]
        let label = items.compactMap { $0 }.joined(separator: " · ")
        return label.isEmpty ? activeAccount?.effectiveDisplayName(obfuscated: true) : label
    }

    private func usagePressure(for account: Account) -> String {
        guard let usage = accountUsage[account.id] else { return "--" }
        let values = [
            usage.fiveHour?.utilization,
            usage.sevenDay?.utilization,
        ].compactMap { $0 }
        guard let pressure = values.max() else { return "--" }
        return "\(Int(pressure.rounded()))%"
    }

    // MARK: - Account Management

    func addAccount(provider: AIProviderType = .claudeCode) async {
        switch provider {
        case .claudeCode:
            await addClaudeAccount()
        case .codex:
            await addCodexAccount()
        case .gemini:
            errorMessage = "Gemini is not implemented"
        }
    }

    private func addClaudeAccount() async {
        log.info("[addClaudeAccount] Starting add current account flow...")
        guard claudeAvailable else {
            errorMessage = String(localized: "Claude CLI not found", bundle: L10n.bundle)
            log.error("[addClaudeAccount] Aborted: Claude CLI not found")
            return
        }

        do {
            let status = try await claudeService.getAuthStatus()
            guard status.loggedIn, let email = status.email else {
                errorMessage = String(localized: "Not logged in to Claude. Run 'claude auth login' first.", bundle: L10n.bundle)
                log.error("[addClaudeAccount] Aborted: not logged in")
                return
            }
            log.info("[addClaudeAccount] Current auth: logged in, sub=\(status.subscriptionType ?? "nil")")

            if accounts.contains(where: { $0.provider == .claudeCode && $0.email == email }) {
                errorMessage = String(localized: "Account already exists", bundle: L10n.bundle)
                log.warning("[addClaudeAccount] Aborted: duplicate account")
                return
            }

            var account = Account(
                email: email,
                displayName: status.orgName ?? email,
                provider: .claudeCode,
                orgName: status.orgName,
                subscriptionType: status.subscriptionType,
                isActive: !accounts.contains(where: { $0.provider == .claudeCode && $0.isActive })
            )
            log.info("[addClaudeAccount] Created account model, id=\(account.id)")

            log.info("[addClaudeAccount] Capturing token from keychain...")
            let captured = claudeService.captureCurrentCredentials(forAccountId: account.id.uuidString)
            if !captured {
                errorMessage = String(localized: "Could not capture auth token from keychain", bundle: L10n.bundle)
                log.error("[addClaudeAccount] Token capture failed!")
                return
            }
            log.info("[addClaudeAccount] Token captured successfully")

            if activeAccount == nil || account.isActive {
                account.isActive = true
                activeAccount = account
                log.info("[addClaudeAccount] Setting as active")
            }

            accounts.append(account)
            saveAccounts()
            log.info("[addClaudeAccount] Account saved. Total accounts: \(self.accounts.count)")
        } catch {
            errorMessage = error.localizedDescription
            log.error("[addClaudeAccount] Error: \(error.localizedDescription)")
        }
    }

    private func addCodexAccount() async {
        log.info("[addCodexAccount] Starting add current account flow...")
        guard codexAvailable else {
            errorMessage = "Codex CLI not found"
            return
        }

        do {
            let status = try codexService.getAuthStatus()
            guard status.loggedIn, let email = status.email else {
                errorMessage = "Not logged in to Codex. Run 'codex login' first."
                return
            }

            if accounts.contains(where: { $0.provider == .codex && $0.email == email }) {
                errorMessage = String(localized: "Account already exists", bundle: L10n.bundle)
                return
            }

            var account = Account(
                email: email,
                displayName: status.displayName ?? email,
                provider: .codex,
                orgName: nil,
                subscriptionType: status.subscriptionType,
                isActive: !accounts.contains(where: { $0.provider == .codex && $0.isActive })
            )

            let captured = codexService.captureCurrentCredentials(forAccountId: account.id.uuidString)
            if !captured {
                errorMessage = "Could not capture Codex auth from ~/.codex/auth.json"
                return
            }

            if activeAccount == nil || account.isActive {
                account.isActive = true
                activeAccount = account
            }

            accounts.append(account)
            saveAccounts()
            await fetchAllAccountUsage()
            updateWidgetData()
            log.info("[addCodexAccount] Account saved. Total accounts: \(self.accounts.count)")
        } catch {
            errorMessage = error.localizedDescription
            log.error("[addCodexAccount] Error: \(error.localizedDescription)")
        }
    }

    func loginNewAccount(provider: AIProviderType = .claudeCode) async {
        switch provider {
        case .claudeCode:
            await loginNewClaudeAccount()
        case .codex:
            await loginNewCodexAccount()
        case .gemini:
            errorMessage = "Gemini is not implemented"
        }
    }

    private func loginNewClaudeAccount() async {
        log.info("[loginNewAccount] ===== Starting login new account flow =====")
        guard claudeAvailable else {
            errorMessage = String(localized: "Claude CLI not found", bundle: L10n.bundle)
            log.error("[loginNewAccount] Aborted: Claude CLI not found")
            return
        }

        isLoggingIn = true
        errorMessage = nil

        do {
            // 1. Back up current account (token + oauthAccount) before login overwrites them
            if let current = activeClaudeAccount {
                log.info("[loginNewAccount] Step 1: Backing up current account (\(current.email))...")
                let backed = claudeService.captureCurrentCredentials(forAccountId: current.id.uuidString)
                log.info("[loginNewAccount] Step 1: Backup result: \(backed)")
            } else {
                log.info("[loginNewAccount] Step 1: No active account, skipping backup")
            }

            // 2. Run `claude auth login` — this overwrites both keychain and ~/.claude.json
            log.info("[loginNewAccount] Step 2: Running `claude auth login`...")
            try await claudeService.login()
            log.info("[loginNewAccount] Step 2: Login process completed")

            // 3. Read the new identity from ~/.claude.json
            log.info("[loginNewAccount] Step 3: Reading post-login state...")
            let status = try await claudeService.getAuthStatus()
            guard status.loggedIn, let email = status.email else {
                errorMessage = String(localized: "Login did not complete", bundle: L10n.bundle)
                log.error("[loginNewAccount] Step 3: Not logged in after login!")
                isLoggingIn = false
                return
            }
            log.info("[loginNewAccount] Step 3: Logged in as \(email)")

            // 4. Check for duplicate — if exists, just refresh its backup
            if let existing = accounts.firstIndex(where: { $0.provider == .claudeCode && $0.email == email }) {
                log.info("[loginNewAccount] Step 4: Account already exists, refreshing backup")
                _ = claudeService.captureCurrentCredentials(forAccountId: accounts[existing].id.uuidString)
                errorMessage = String(localized: "Account already exists - credentials refreshed", bundle: L10n.bundle)
                isLoggingIn = false
                return
            }

            // 5. Create new account and capture credentials (token + oauthAccount)
            let account = Account(
                email: email,
                displayName: status.orgName ?? email,
                provider: .claudeCode,
                orgName: status.orgName,
                subscriptionType: status.subscriptionType,
                isActive: true
            )
            log.info("[loginNewAccount] Step 5: Created account, id=\(account.id)")

            let captured = claudeService.captureCurrentCredentials(forAccountId: account.id.uuidString)
            if !captured {
                errorMessage = String(localized: "Could not capture credentials", bundle: L10n.bundle)
                log.error("[loginNewAccount] Step 5: Capture failed!")
                isLoggingIn = false
                return
            }

            // 6. Mark new account as active
            for i in accounts.indices where accounts[i].provider == .claudeCode {
                accounts[i].isActive = false
            }
            accounts.append(account)
            activeAccount = account
            saveAccounts()
            log.info("[loginNewAccount] Step 6: New account active. Total: \(self.accounts.count)")

            isLoggingIn = false
            await refresh()
            log.info("[loginNewAccount] ===== Login completed =====")
        } catch {
            errorMessage = error.localizedDescription
            isLoggingIn = false
            log.error("[loginNewAccount] Error: \(error.localizedDescription)")
        }
    }

    private func loginNewCodexAccount() async {
        log.info("[loginNewCodexAccount] ===== Starting login new Codex account flow =====")
        guard codexAvailable else {
            errorMessage = "Codex CLI not found"
            return
        }

        isLoggingIn = true
        errorMessage = nil

        do {
            if let current = accounts.first(where: { $0.provider == .codex && $0.isActive }) {
                _ = codexService.captureCurrentCredentials(forAccountId: current.id.uuidString)
            }

            try await codexService.login()
            let status = try codexService.getAuthStatus()
            guard status.loggedIn, let email = status.email else {
                errorMessage = "Codex login did not complete"
                isLoggingIn = false
                return
            }

            if let existing = accounts.firstIndex(where: { $0.provider == .codex && $0.email == email }) {
                _ = codexService.captureCurrentCredentials(forAccountId: accounts[existing].id.uuidString)
                errorMessage = String(localized: "Account already exists - credentials refreshed", bundle: L10n.bundle)
                isLoggingIn = false
                return
            }

            let account = Account(
                email: email,
                displayName: status.displayName ?? email,
                provider: .codex,
                orgName: nil,
                subscriptionType: status.subscriptionType,
                isActive: true
            )

            let captured = codexService.captureCurrentCredentials(forAccountId: account.id.uuidString)
            if !captured {
                errorMessage = "Could not capture Codex auth"
                isLoggingIn = false
                return
            }

            for i in accounts.indices where accounts[i].provider == .codex {
                accounts[i].isActive = false
            }
            accounts.append(account)
            activeAccount = account
            saveAccounts()

            isLoggingIn = false
            await refresh()
            log.info("[loginNewCodexAccount] ===== Login completed =====")
        } catch {
            errorMessage = error.localizedDescription
            isLoggingIn = false
            log.error("[loginNewCodexAccount] Error: \(error.localizedDescription)")
        }
    }

    func updateAccountLabel(_ account: Account, label: String?) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        let trimmed = label?.trimmingCharacters(in: .whitespaces)
        accounts[index].customLabel = (trimmed?.isEmpty == true) ? nil : trimmed
        if accounts[index].isActive {
            activeAccount = accounts[index]
        }
        saveAccounts()
        updateWidgetData()
        log.info("[updateAccountLabel] Set label for \(account.email): \(trimmed ?? "nil")")
    }

    func removeAccount(_ account: Account) {
        log.info("[removeAccount] Removing account \(account.id)")
        switch account.provider {
        case .claudeCode:
            keychain.removeAccountBackup(forAccountId: account.id.uuidString)
        case .codex:
            keychain.removeCodexAccountBackup(forAccountId: account.id.uuidString)
        case .gemini:
            break
        }
        accounts.removeAll { $0.id == account.id }
        if account.isActive, let first = accounts.first(where: { $0.provider == account.provider }) {
            if let firstIndex = accounts.firstIndex(where: { $0.id == first.id }) {
                accounts[firstIndex].isActive = true
            }
            activeAccount = first
            log.info("[removeAccount] Removed active account, switching to first remaining")
            Task { await switchTo(first) }
        } else if activeAccount?.id == account.id {
            activeAccount = accounts.first(where: \.isActive)
        }
        saveAccounts()
        log.info("[removeAccount] Done. Remaining accounts: \(self.accounts.count)")
    }

    func switchTo(_ account: Account) async {
        let currentActive = accounts.first(where: { $0.provider == account.provider && $0.isActive })
        guard currentActive?.id != account.id else {
            log.info("[switchTo] No switch needed (same account or no active account)")
            return
        }

        log.info("[switchTo] ===== Switching to \(account.provider.rawValue) account \(account.email) =====")

        // Pre-switch: verify target has a backup
        let hasBackup: Bool
        switch account.provider {
        case .claudeCode:
            hasBackup = keychain.getAccountBackup(forAccountId: account.id.uuidString) != nil
        case .codex:
            hasBackup = keychain.getCodexAccountBackup(forAccountId: account.id.uuidString) != nil
        case .gemini:
            hasBackup = false
        }
        guard hasBackup else {
            log.error("[switchTo] ABORT: no backup for target account")
            errorMessage = String(localized: "No stored credentials for \(account.email). Use re-authenticate to fix.", bundle: L10n.bundle)
            return
        }

        isLoading = true
        do {
            switch account.provider {
            case .claudeCode:
                guard let currentActive else { throw ClaudeServiceError.switchVerificationFailed }
                try await claudeService.switchAccount(from: currentActive, to: account)
            case .codex:
                try codexService.switchAccount(from: currentActive, to: account)
            case .gemini:
                throw CodexServiceError.noAuthForAccount(account.id.uuidString)
            }

            for i in accounts.indices where accounts[i].provider == account.provider {
                accounts[i].isActive = (accounts[i].id == account.id)
                if accounts[i].id == account.id {
                    accounts[i].lastUsed = Date()
                }
            }
            activeAccount = account
            saveAccounts()

            await refresh()
            log.info("[switchTo] ===== Switch completed =====")
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
            log.error("[switchTo] Switch failed: \(error.localizedDescription)")
        }
    }

    /// Re-authenticate an account by running `claude auth login` and capturing fresh credentials.
    func reauthenticateAccount(_ account: Account) async {
        if account.provider == .codex {
            await reauthenticateCodexAccount(account)
            return
        }
        log.info("[reauth] ===== Re-authenticating account \(account.id) (\(account.email)) =====")
        guard claudeAvailable else {
            errorMessage = String(localized: "Claude CLI not found", bundle: L10n.bundle)
            return
        }

        isLoggingIn = true
        errorMessage = nil

        do {
            // 1. Back up current active account before login overwrites it
            if let current = activeClaudeAccount, current.id != account.id {
                log.info("[reauth] Backing up current account before login...")
                _ = claudeService.captureCurrentCredentials(forAccountId: current.id.uuidString)
            }

            // 2. Run login
            log.info("[reauth] Running `claude auth login`...")
            try await claudeService.login()

            // 3. Verify the login result matches the target account
            let status = try await claudeService.getAuthStatus()
            guard status.loggedIn, let email = status.email else {
                errorMessage = String(localized: "Login did not complete", bundle: L10n.bundle)
                isLoggingIn = false
                return
            }

            guard email == account.email else {
                errorMessage = String(localized: "Logged in as \(email), but expected \(account.email). Credentials not updated.", bundle: L10n.bundle)
                log.error("[reauth] Email mismatch: got \(email), expected \(account.email)")
                isLoggingIn = false
                return
            }

            // 4. Capture the fresh token
            let captured = claudeService.captureCurrentCredentials(forAccountId: account.id.uuidString)
            log.info("[reauth] Token capture result: \(captured)")

            // 5. Update account metadata
            if let index = accounts.firstIndex(where: { $0.id == account.id }) {
                accounts[index].orgName = status.orgName
                accounts[index].subscriptionType = status.subscriptionType

                // Mark this account as active (it's what the CLI is now using)
                for i in accounts.indices where accounts[i].provider == .claudeCode {
                    accounts[i].isActive = (i == index)
                }
                activeAccount = accounts[index]
                saveAccounts()
            }

            isLoggingIn = false
            await refresh()
            log.info("[reauth] ===== Re-authentication completed =====")
        } catch {
            errorMessage = error.localizedDescription
            isLoggingIn = false
            log.error("[reauth] Error: \(error.localizedDescription)")
        }
    }

    private func reauthenticateCodexAccount(_ account: Account) async {
        log.info("[reauthCodex] ===== Re-authenticating account \(account.id) (\(account.email)) =====")
        guard codexAvailable else {
            errorMessage = "Codex CLI not found"
            return
        }

        isLoggingIn = true
        errorMessage = nil

        do {
            if let current = accounts.first(where: { $0.provider == .codex && $0.isActive && $0.id != account.id }) {
                _ = codexService.captureCurrentCredentials(forAccountId: current.id.uuidString)
            }

            try await codexService.login()
            let status = try codexService.getAuthStatus()
            guard status.loggedIn, let email = status.email else {
                errorMessage = "Codex login did not complete"
                isLoggingIn = false
                return
            }

            guard email == account.email else {
                errorMessage = "Logged in as \(email), but expected \(account.email). Credentials not updated."
                isLoggingIn = false
                return
            }

            let captured = codexService.captureCurrentCredentials(forAccountId: account.id.uuidString)
            log.info("[reauthCodex] Auth capture result: \(captured)")

            if let index = accounts.firstIndex(where: { $0.id == account.id }) {
                accounts[index].displayName = status.displayName ?? accounts[index].displayName
                accounts[index].subscriptionType = status.subscriptionType
                for i in accounts.indices where accounts[i].provider == .codex {
                    accounts[i].isActive = (i == index)
                }
                activeAccount = accounts[index]
                saveAccounts()
            }

            isLoggingIn = false
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
            isLoggingIn = false
            log.error("[reauthCodex] Error: \(error.localizedDescription)")
        }
    }

    // MARK: - Usage

    private func fetchAllAccountUsage() async {
        accountUsageErrors.removeAll()
        // For active account: use live keychain token (with delegated refresh on expiry)
        // For other accounts: use backup token (no silent swap — just mark expired)
        for account in accounts {
            switch account.provider {
            case .claudeCode:
                await fetchClaudeUsage(for: account)
            case .codex:
                await fetchCodexUsage(for: account)
            case .gemini:
                continue
            }
        }
    }

    private func fetchClaudeUsage(for account: Account) async {
        let tokenJSON: String?
        if account.isActive {
            tokenJSON = keychain.readClaudeToken()
        } else {
            tokenJSON = keychain.getAccountBackup(forAccountId: account.id.uuidString)?.token
        }
        guard let tokenJSON, let accessToken = ClaudeService.extractAccessToken(from: tokenJSON) else {
            log.warning("[fetchClaudeUsage] No token for \(account.email), skipping")
            return
        }
        do {
            let usage = try await claudeService.getUsageLimits(accessToken: accessToken)
            accountUsage[account.id] = usage
            accountUsageErrors[account.id] = nil
            log.info("[fetchClaudeUsage] \(account.email): session=\(usage.fiveHour?.utilization ?? -1)%, weekly=\(usage.sevenDay?.utilization ?? -1)%")
        } catch ClaudeService.UsageError.expired {
            log.warning("[fetchClaudeUsage] Token expired for \(account.email)")
            if account.isActive {
                do {
                    _ = try await claudeService.getAuthStatus()
                    if let refreshedJSON = keychain.readClaudeToken(),
                       let refreshedToken = ClaudeService.extractAccessToken(from: refreshedJSON),
                       let usage = try? await claudeService.getUsageLimits(accessToken: refreshedToken) {
                        accountUsage[account.id] = usage
                        accountUsageErrors[account.id] = nil
                    }
                } catch {
                    accountUsage[account.id] = nil
                    accountUsageErrors[account.id] = UsageErrorState(isExpired: true, isRateLimited: false, message: String(localized: "Token expired. Switch to refresh.", bundle: L10n.bundle))
                }
            } else {
                accountUsage[account.id] = nil
                accountUsageErrors[account.id] = UsageErrorState(isExpired: true, isRateLimited: false, message: String(localized: "Token expired. Switch to this account to refresh.", bundle: L10n.bundle))
            }
        } catch {
            log.error("[fetchClaudeUsage] Failed to get usage for \(account.email): \(error.localizedDescription)")
            accountUsage[account.id] = nil
            if let usageError = error as? ClaudeService.UsageError, case .network(let msg) = usageError, msg.contains("429") {
                accountUsageErrors[account.id] = UsageErrorState(isExpired: false, isRateLimited: true, message: String(localized: "API Rate Limited. Try again later.", bundle: L10n.bundle))
            } else {
                accountUsageErrors[account.id] = UsageErrorState(isExpired: false, isRateLimited: false, message: String(localized: "Could not fetch usage: \(error.localizedDescription)", bundle: L10n.bundle))
            }
        }
    }

    private func fetchCodexUsage(for account: Account) async {
        let authJSON: String?
        if account.isActive {
            authJSON = codexService.readAuthSnapshot()
        } else {
            authJSON = keychain.getCodexAccountBackup(forAccountId: account.id.uuidString)?.authJSON
        }
        guard let authJSON else {
            log.warning("[fetchCodexUsage] No auth for \(account.email), skipping")
            return
        }
        do {
            let (usage, planType) = try await codexService.getUsageLimits(authJSON: authJSON)
            accountUsage[account.id] = usage
            accountUsageErrors[account.id] = nil
            if let planType, let index = accounts.firstIndex(where: { $0.id == account.id }) {
                accounts[index].subscriptionType = planType
                if activeAccount?.id == account.id {
                    activeAccount = accounts[index]
                }
                saveAccounts()
            }
            log.info("[fetchCodexUsage] \(account.email): session=\(usage.fiveHour?.utilization ?? -1)%, weekly=\(usage.sevenDay?.utilization ?? -1)%")
        } catch CodexService.UsageError.expired {
            accountUsage[account.id] = nil
            accountUsageErrors[account.id] = UsageErrorState(isExpired: true, isRateLimited: false, message: "Codex token expired. Switch to this account or re-authenticate.")
        } catch {
            log.error("[fetchCodexUsage] Failed to get usage for \(account.email): \(error.localizedDescription)")
            accountUsage[account.id] = nil
            accountUsageErrors[account.id] = UsageErrorState(isExpired: false, isRateLimited: false, message: "Could not fetch Codex usage: \(error.localizedDescription)")
        }
    }

    // MARK: - Diagnostics

    /// Passive health check — verifies backup existence and identity consistency.
    private func diagnoseTokenHealth() {
        guard !accounts.isEmpty else { return }

        log.info("[diagnose] === Health Check ===")
        log.info("[diagnose] Accounts: \(self.accounts.count), active: \(self.activeAccount?.email ?? "none")")

        // Check live oauthAccount identity
        if let liveOAuth = keychain.readOAuthAccount() {
            let liveEmail = (liveOAuth["emailAddress"]?.value as? String) ?? "?"
            log.info("[diagnose] Live oauthAccount: \(liveEmail)")
        } else {
            log.warning("[diagnose] Live oauthAccount: MISSING")
        }

        // Check each account has a backup
        for account in accounts {
            if account.provider == .claudeCode, let backup = keychain.getAccountBackup(forAccountId: account.id.uuidString) {
                let backupEmail = (backup.oauthAccount["emailAddress"]?.value as? String) ?? "?"
                log.info("[diagnose] Backup [\(account.email)]: OK (email=\(backupEmail))")
            } else if account.provider == .codex, let backup = keychain.getCodexAccountBackup(forAccountId: account.id.uuidString) {
                log.info("[diagnose] Codex backup [\(account.email)]: OK (email=\(backup.email))")
            } else {
                log.warning("[diagnose] Backup [\(account.email)]: MISSING — switch will fail")
            }
        }

        log.info("[diagnose] === End Health Check ===")
    }

    // MARK: - Widget

    private func updateWidgetData() {
        let widgetAccounts = accounts.map { account in
            let usage = accountUsage[account.id]
            let error = accountUsageErrors[account.id]
            return WidgetAccountData(
                email: account.displayEmail(obfuscated: !UserDefaults.standard.bool(forKey: "showFullEmail")),
                displayName: account.effectiveDisplayName(obfuscated: !UserDefaults.standard.bool(forKey: "showFullEmail")),
                subscriptionType: account.displaySubscriptionType,
                isActive: account.isActive,
                sessionUtilization: usage?.fiveHour?.utilization,
                sessionResetTime: usage?.fiveHour?.resetTimeString,
                weeklyUtilization: usage?.sevenDay?.utilization,
                weeklyResetTime: usage?.sevenDay?.resetTimeString,
                extraUsageEnabled: usage?.extraUsage?.isEnabled,
                hasError: error != nil,
                errorMessage: error?.message
            )
        }

        let data = WidgetData(
            accounts: widgetAccounts,
            todayCost: costSummary.todayCost,
            conversationTurns: activityStats.conversationTurns,
            activeCodingTime: activityStats.activeCodingTimeString,
            linesWritten: activityStats.linesWritten,
            modelUsage: activityStats.modelUsage,
            lastUpdated: Date()
        )
        data.save()
        WidgetCenter.shared.reloadAllTimelines()
        log.debug("[updateWidgetData] Widget data saved and timelines reloaded")
    }

    // MARK: - Persistence

    private func loadAccounts() {
        guard let data = UserDefaults.standard.data(forKey: accountsKey),
              let decoded = try? JSONDecoder().decode([Account].self, from: data) else {
            log.info("[loadAccounts] No saved accounts found")
            return
        }
        accounts = decoded
        activeAccount = accounts.first(where: \.isActive)
        log.info("[loadAccounts] Loaded \(decoded.count) accounts")
    }

    private func saveAccounts(refreshWidget: Bool = false) {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: accountsKey)
            log.debug("[saveAccounts] Saved \(self.accounts.count) accounts to UserDefaults")
        }
        if refreshWidget {
            updateWidgetData()
        }
    }

    private func updateActiveClaudeAccount(from status: AuthStatus) {
        guard status.loggedIn, let email = status.email else { return }

        if let index = accounts.firstIndex(where: { $0.provider == .claudeCode && $0.email == email }) {
            for i in accounts.indices where accounts[i].provider == .claudeCode {
                accounts[i].isActive = (i == index)
            }
            accounts[index].orgName = status.orgName
            accounts[index].subscriptionType = status.subscriptionType
            if activeAccount == nil || activeAccount?.provider == .claudeCode {
                activeAccount = accounts[index]
            }
            if keychain.getAccountBackup(forAccountId: accounts[index].id.uuidString) == nil {
                _ = claudeService.captureCurrentCredentials(forAccountId: accounts[index].id.uuidString)
            }
            saveAccounts()
            log.info("[updateActiveClaudeAccount] Matched existing account at index \(index)")
        } else if !accounts.contains(where: { $0.provider == .claudeCode }) {
            let account = Account(
                email: email,
                displayName: status.orgName ?? email,
                provider: .claudeCode,
                orgName: status.orgName,
                subscriptionType: status.subscriptionType,
                isActive: true
            )
            accounts.append(account)
            if activeAccount == nil {
                activeAccount = account
            }
            _ = claudeService.captureCurrentCredentials(forAccountId: account.id.uuidString)
            saveAccounts()
            log.info("[updateActiveClaudeAccount] Auto-created first Claude account, id=\(account.id)")
        } else {
            log.info("[updateActiveClaudeAccount] Logged-in account not in our list (might be new)")
        }
    }

    private func updateActiveCodexAccount(from status: CodexAuthStatus) {
        guard status.loggedIn, let email = status.email else { return }

        if let index = accounts.firstIndex(where: { $0.provider == .codex && $0.email == email }) {
            for i in accounts.indices where accounts[i].provider == .codex {
                accounts[i].isActive = (i == index)
            }
            accounts[index].displayName = status.displayName ?? accounts[index].displayName
            accounts[index].subscriptionType = status.subscriptionType ?? accounts[index].subscriptionType
            if activeAccount == nil || activeAccount?.provider == .codex {
                activeAccount = accounts[index]
            }
            if keychain.getCodexAccountBackup(forAccountId: accounts[index].id.uuidString) == nil {
                _ = codexService.captureCurrentCredentials(forAccountId: accounts[index].id.uuidString)
            }
            saveAccounts()
            log.info("[updateActiveCodexAccount] Matched existing account at index \(index)")
        } else if !accounts.contains(where: { $0.provider == .codex }) {
            let account = Account(
                email: email,
                displayName: status.displayName ?? email,
                provider: .codex,
                orgName: nil,
                subscriptionType: status.subscriptionType,
                isActive: true
            )
            accounts.append(account)
            if activeAccount == nil {
                activeAccount = account
            }
            _ = codexService.captureCurrentCredentials(forAccountId: account.id.uuidString)
            saveAccounts()
            log.info("[updateActiveCodexAccount] Auto-created first Codex account, id=\(account.id)")
        } else {
            log.info("[updateActiveCodexAccount] Logged-in account not in our list (might be new)")
        }
    }
}
