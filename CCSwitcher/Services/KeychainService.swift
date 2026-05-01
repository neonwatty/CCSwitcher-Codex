import Foundation
import Security

private let log = FileLog("Keychain")

/// Per-account backup: keychain token + oauthAccount from ~/.claude.json
struct AccountBackup: Codable {
    let token: String
    let oauthAccount: [String: AnyCodable]
}

/// Per-account Codex backup. Codex stores ChatGPT auth in ~/.codex/auth.json,
/// so the safest switch primitive is a complete auth-file snapshot.
struct CodexAccountBackup: Codable {
    let authJSON: String
    let accountId: String
    let email: String
    let displayName: String
    let planType: String?
}

/// Type-erased Codable wrapper for heterogeneous JSON values.
struct AnyCodable: Codable, Equatable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { value = NSNull() }
        else if let b = try? container.decode(Bool.self) { value = b }
        else if let i = try? container.decode(Int.self) { value = i }
        else if let d = try? container.decode(Double.self) { value = d }
        else if let s = try? container.decode(String.self) { value = s }
        else if let a = try? container.decode([AnyCodable].self) { value = a }
        else if let o = try? container.decode([String: AnyCodable].self) { value = o }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported type") }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull: try container.encodeNil()
        case let b as Bool: try container.encode(b)
        case let i as Int: try container.encode(i)
        case let d as Double: try container.encode(d)
        case let s as String: try container.encode(s)
        case let a as [AnyCodable]: try container.encode(a)
        case let o as [String: AnyCodable]: try container.encode(o)
        default: throw EncodingError.invalidValue(value, .init(codingPath: [], debugDescription: "Unsupported type"))
        }
    }

    static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        String(describing: lhs.value) == String(describing: rhs.value)
    }
}

/// Manages token + identity storage:
/// - Claude CLI's token: read/write via `security` CLI (keychain).
/// - Claude CLI's identity: read/write oauthAccount in ~/.claude.json.
/// - Our backups: per-account {token, oauthAccount} in ~/.ccswitcher/backups.json.
final class KeychainService: Sendable {
    static let shared = KeychainService()

    private let claudeService = "Claude Code-credentials"
    private let claudeAccount: String
    private let backupsFilePath: String
    private let claudeJsonPath: String

    private init() {
        self.claudeAccount = NSUserName()

        let home = NSHomeDirectory()
        let dir = home + "/.ccswitcher"
        self.backupsFilePath = dir + "/backups.json"
        self.claudeJsonPath = home + "/.claude.json"

        // Ensure directory exists
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // Migrate old tokens.json → backups.json if needed
        let oldPath = dir + "/tokens.json"
        if FileManager.default.fileExists(atPath: oldPath) && !FileManager.default.fileExists(atPath: backupsFilePath) {
            log.info("init: Migrating tokens.json → backups.json (old format, token-only entries)")
            // Old format was {accountId: tokenString}. We can't migrate without oauthAccount,
            // so just delete the stale file — user will need to re-capture.
            try? FileManager.default.removeItem(atPath: oldPath)
        }

        log.info("init: claudeAccount=\(claudeAccount), backupsFile=\(backupsFilePath)")
    }

    // MARK: - Claude Code Token Operations (keychain via `security` CLI)

    func readClaudeToken() -> String? {
        let token = runSecurity(args: [
            "find-generic-password",
            "-s", claudeService,
            "-a", claudeAccount,
            "-w"
        ])
        
        if let token {
            // Clean up possible trailing newlines from security CLI output
            let sanitized = token.trimmingCharacters(in: .whitespacesAndNewlines)
            log.info("[readClaudeToken] Found via security CLI, length=\(sanitized.count)")
            return sanitized
        } else {
            log.error("[readClaudeToken] No token found!")
            return nil
        }
    }

    func writeClaudeToken(_ token: String) -> Bool {
        // Delete then add (security CLI doesn't have a pure "update" for generic passwords)
        _ = runSecurityStatus(args: ["delete-generic-password", "-s", claudeService, "-a", claudeAccount])

        let added = runSecurityStatus(args: [
            "add-generic-password",
            "-s", claudeService,
            "-a", claudeAccount,
            "-w", token,
            "-U"
        ])
        log.info("[writeClaudeToken] Result: \(added)")
        return added
    }

    // MARK: - ~/.claude.json oauthAccount Operations

    func readOAuthAccount() -> [String: AnyCodable]? {
        guard let data = FileManager.default.contents(atPath: claudeJsonPath),
              let json = try? JSONDecoder().decode([String: AnyCodable].self, from: data),
              let oauthEntry = json["oauthAccount"],
              let dict = oauthEntry.value as? [String: AnyCodable] else {
            log.error("[readOAuthAccount] Failed to read oauthAccount from \(claudeJsonPath)")
            return nil
        }
        let email = (dict["emailAddress"]?.value as? String) ?? "?"
        log.info("[readOAuthAccount] Found: email=\(email)")
        return dict
    }

    func writeOAuthAccount(_ oauthAccount: [String: AnyCodable]) -> Bool {
        guard let data = FileManager.default.contents(atPath: claudeJsonPath),
              var json = try? JSONDecoder().decode([String: AnyCodable].self, from: data) else {
            log.error("[writeOAuthAccount] Failed to read \(claudeJsonPath)")
            return false
        }

        json["oauthAccount"] = AnyCodable(oauthAccount)

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let newData = try encoder.encode(json)
            try newData.write(to: URL(fileURLWithPath: claudeJsonPath), options: .atomic)
            let email = (oauthAccount["emailAddress"]?.value as? String) ?? "?"
            log.info("[writeOAuthAccount] Written: email=\(email)")
            return true
        } catch {
            log.error("[writeOAuthAccount] Failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Account Backup Operations (token + oauthAccount)

    func saveAccountBackup(token: String, oauthAccount: [String: AnyCodable], forAccountId accountId: String) -> Bool {
        let email = (oauthAccount["emailAddress"]?.value as? String) ?? "?"
        log.info("[saveBackup] Saving for \(accountId) (\(email)), token length=\(token.count)")
        var store = loadBackupStore()
        store[accountId] = AccountBackup(token: token, oauthAccount: oauthAccount)
        let result = saveBackupStore(store)
        log.info("[saveBackup] Result: \(result)")
        return result
    }

    func getAccountBackup(forAccountId accountId: String) -> AccountBackup? {
        let store = loadBackupStore()
        let backup = store[accountId]
        if let backup {
            let email = (backup.oauthAccount["emailAddress"]?.value as? String) ?? "?"
            log.info("[getBackup] Found for \(accountId) (\(email)), token length=\(backup.token.count)")
        } else {
            log.error("[getBackup] No backup for accountId=\(accountId)")
        }
        return backup
    }

    @discardableResult
    func removeAccountBackup(forAccountId accountId: String) -> Bool {
        log.info("[removeBackup] Removing for accountId=\(accountId)")
        var store = loadBackupStore()
        store.removeValue(forKey: accountId)
        return saveBackupStore(store)
    }

    // Legacy compatibility — read token string only (for diagnostics)
    func getAccountToken(forAccountId accountId: String) -> String? {
        return getAccountBackup(forAccountId: accountId)?.token
    }

    // MARK: - App Keychain operations (Backups)

    private let appBackupService = "me.local.ccswitcher.codex.backups"
    private let appBackupAccount = "all-accounts"
    private let codexBackupService = "me.local.ccswitcher.codex.codex.backups"
    private let codexBackupAccount = "all-accounts"

    private func loadBackupStore() -> [String: AccountBackup] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: appBackupService,
            kSecAttrAccount as String: appBackupAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        
        if status == errSecSuccess, let data = item as? Data,
           let dict = try? JSONDecoder().decode([String: AccountBackup].self, from: data) {
            log.debug("[loadBackupStore] Loaded \(dict.count) entries from Keychain")
            return dict
        }
        
        // Migration from local file
        if FileManager.default.fileExists(atPath: backupsFilePath),
           let data = FileManager.default.contents(atPath: backupsFilePath),
           let dict = try? JSONDecoder().decode([String: AccountBackup].self, from: data) {
            log.info("[loadBackupStore] Migrating from local backups.json to Keychain...")
            // Save to keychain now (call saveBackupStore synchronously)
            _ = saveBackupStore(dict)
            // Delete old file
            try? FileManager.default.removeItem(atPath: backupsFilePath)
            log.info("[loadBackupStore] Migration complete, local backups.json removed")
            return dict
        }
        
        log.debug("[loadBackupStore] No existing backups, returning empty")
        return [:]
    }

    private func saveBackupStore(_ store: [String: AccountBackup]) -> Bool {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(store)
            
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: appBackupService,
                kSecAttrAccount as String: appBackupAccount
            ]
            
            let attributes: [String: Any] = [
                kSecValueData as String: data
            ]
            
            var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            
            if status == errSecItemNotFound {
                var newItem = query
                newItem[kSecValueData as String] = data
                status = SecItemAdd(newItem as CFDictionary, nil)
            }
            
            let success = status == errSecSuccess
            if success {
                log.debug("[saveBackupStore] Saved \(store.count) entries to Keychain")
            } else {
                log.error("[saveBackupStore] Failed to save to Keychain, OSStatus: \(status)")
            }
            return success
        } catch {
            log.error("[saveBackupStore] Failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Codex Account Backups

    func saveCodexAccountBackup(_ backup: CodexAccountBackup, forAccountId accountId: String) -> Bool {
        log.info("[saveCodexBackup] Saving for \(accountId) (\(backup.email)), auth length=\(backup.authJSON.count)")
        var store = loadCodexBackupStore()
        store[accountId] = backup
        let result = saveCodexBackupStore(store)
        log.info("[saveCodexBackup] Result: \(result)")
        return result
    }

    func getCodexAccountBackup(forAccountId accountId: String) -> CodexAccountBackup? {
        let store = loadCodexBackupStore()
        let backup = store[accountId]
        if let backup {
            log.info("[getCodexBackup] Found for \(accountId) (\(backup.email)), auth length=\(backup.authJSON.count)")
        } else {
            log.error("[getCodexBackup] No backup for accountId=\(accountId)")
        }
        return backup
    }

    @discardableResult
    func removeCodexAccountBackup(forAccountId accountId: String) -> Bool {
        log.info("[removeCodexBackup] Removing for accountId=\(accountId)")
        var store = loadCodexBackupStore()
        store.removeValue(forKey: accountId)
        return saveCodexBackupStore(store)
    }

    private func loadCodexBackupStore() -> [String: CodexAccountBackup] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: codexBackupService,
            kSecAttrAccount as String: codexBackupAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecSuccess, let data = item as? Data,
           let dict = try? JSONDecoder().decode([String: CodexAccountBackup].self, from: data) {
            log.debug("[loadCodexBackupStore] Loaded \(dict.count) entries from Keychain")
            return dict
        }

        log.debug("[loadCodexBackupStore] No existing Codex backups, returning empty")
        return [:]
    }

    private func saveCodexBackupStore(_ store: [String: CodexAccountBackup]) -> Bool {
        do {
            let data = try JSONEncoder().encode(store)

            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: codexBackupService,
                kSecAttrAccount as String: codexBackupAccount
            ]

            let attributes: [String: Any] = [
                kSecValueData as String: data
            ]

            var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

            if status == errSecItemNotFound {
                var newItem = query
                newItem[kSecValueData as String] = data
                status = SecItemAdd(newItem as CFDictionary, nil)
            }

            let success = status == errSecSuccess
            if success {
                log.debug("[saveCodexBackupStore] Saved \(store.count) entries to Keychain")
            } else {
                log.error("[saveCodexBackupStore] Failed to save to Keychain, OSStatus: \(status)")
            }
            return success
        } catch {
            log.error("[saveCodexBackupStore] Failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - `security` CLI (only for Claude's keychain entry)

    private func runSecurity(args: [String]) -> String? {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                log.debug("[runSecurity] Exit \(process.terminationStatus) for: security \(args.prefix(3).joined(separator: " "))...")
                return nil
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return output?.isEmpty == true ? nil : output
        } catch {
            log.error("[runSecurity] Launch failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func runSecurityStatus(args: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let ok = process.terminationStatus == 0
            if !ok {
                log.debug("[runSecurityStatus] Exit \(process.terminationStatus) for: security \(args.prefix(3).joined(separator: " "))...")
            }
            return ok
        } catch {
            log.error("[runSecurityStatus] Launch failed: \(error.localizedDescription)")
            return false
        }
    }
}
