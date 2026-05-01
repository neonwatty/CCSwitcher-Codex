import Foundation

private let codexParserLog = FileLog("CodexUsageParser")

/// Parses local Codex CLI logs for API-equivalent cost and activity.
///
/// Codex currently stores user prompt history in ~/.codex/history.jsonl and
/// response token telemetry in ~/.codex/logs_2.sqlite. The telemetry rows used
/// here are local `codex_otel.log_only` response.completed events.
final class CodexUsageParser: Sendable {
    static let shared = CodexUsageParser()

    private let codexDir: String

    private init() {
        self.codexDir = NSHomeDirectory() + "/.codex"
    }

    func getCostSummary() -> CostSummary {
        let usages = parseTokenUsage()

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let todayStr = formatter.string(from: Date())

        var dateGroups: [String: [TokenUsage]] = [:]
        var dateSessions: [String: Set<String>] = [:]

        for usage in usages {
            let date = formatter.string(from: usage.timestamp)
            dateGroups[date, default: []].append(usage)
            dateSessions[date, default: []].insert(usage.sessionFile)
        }

        var dailyCosts: [DailyCost] = []
        for (date, usages) in dateGroups {
            var modelCosts: [String: Double] = [:]
            var input = 0
            var output = 0
            var cacheWrite = 0
            var cacheRead = 0

            for usage in usages {
                let shortModel = Self.shortModelName(usage.model)
                modelCosts[shortModel, default: 0] += usage.cost
                input += usage.inputTokens
                output += usage.outputTokens
                cacheWrite += usage.cacheWriteTokens
                cacheRead += usage.cacheReadTokens
            }

            dailyCosts.append(DailyCost(
                date: date,
                totalCost: modelCosts.values.reduce(0, +),
                modelBreakdown: modelCosts,
                sessionCount: dateSessions[date]?.count ?? 0,
                inputTokens: input,
                outputTokens: output,
                cacheWriteTokens: cacheWrite,
                cacheReadTokens: cacheRead
            ))
        }

        dailyCosts.sort { $0.date > $1.date }
        let todayCost = dailyCosts.first(where: { $0.date == todayStr })?.totalCost ?? 0
        codexParserLog.info("[getCostSummary] Parsed \(usages.count) Codex usage entries, \(dailyCosts.count) days, today=$\(String(format: "%.2f", todayCost))")
        return CostSummary(todayCost: todayCost, dailyCosts: dailyCosts)
    }

    func getTodayStats() -> ActivityStats {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let todayStr = formatter.string(from: Date())

        let prompts = parseHistoryPrompts().filter { formatter.string(from: $0.timestamp) == todayStr }
        let usages = parseTokenUsage().filter { formatter.string(from: $0.timestamp) == todayStr }

        var sessionTimestamps: [String: [Date]] = [:]
        for prompt in prompts {
            sessionTimestamps[prompt.sessionId, default: []].append(prompt.timestamp)
        }
        for usage in usages {
            sessionTimestamps[usage.sessionFile, default: []].append(usage.timestamp)
        }

        var modelUsage: [String: Int] = [:]
        for usage in usages {
            modelUsage[Self.shortModelName(usage.model), default: 0] += 1
        }

        let activeMinutes = Self.calculateActiveMinutes(from: sessionTimestamps)
        codexParserLog.info("[getTodayStats] turns=\(prompts.count) active=\(activeMinutes)m models=\(modelUsage)")
        return ActivityStats(
            conversationTurns: prompts.count,
            activeCodingMinutes: activeMinutes,
            toolUsage: [:],
            linesWritten: 0,
            modelUsage: modelUsage
        )
    }

    // MARK: - Token Telemetry

    private func parseTokenUsage() -> [TokenUsage] {
        let dbPath = codexDir + "/logs_2.sqlite"
        guard FileManager.default.fileExists(atPath: dbPath) else { return [] }

        let sql = """
        select id || char(9) || ts || char(9) || replace(coalesce(feedback_log_body,''), char(10), ' ')
        from logs
        where target='codex_otel.log_only'
          and feedback_log_body like '%event.kind=response.completed%'
        order by ts asc;
        """

        guard let output = runSQLite(dbPath: dbPath, sql: sql) else { return [] }

        var usages: [TokenUsage] = []
        for line in output.components(separatedBy: .newlines) where !line.isEmpty {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 3,
                  let ts = TimeInterval(parts[1]) else { continue }
            let body = parts.dropFirst(2).joined(separator: "\t")
            guard let model = field("model", in: body) ?? field("slug", in: body),
                  ModelPricing.forModel(model) != nil else { continue }

            let input = intField("input_token_count", in: body)
            let cached = intField("cached_token_count", in: body)
            let outputTokens = intField("output_token_count", in: body)
            let reasoning = intField("reasoning_token_count", in: body)
            let conversationId = field("conversation.id", in: body) ?? parts[0]

            // Codex telemetry reports input and cached-input as separate billing
            // buckets, matching the Codex/OpenAI rate cards.
            usages.append(TokenUsage(
                inputTokens: input,
                outputTokens: outputTokens + reasoning,
                cacheWriteTokens: 0,
                cacheReadTokens: cached,
                model: model,
                timestamp: Date(timeIntervalSince1970: ts),
                sessionFile: conversationId
            ))
        }

        return usages
    }

    private func runSQLite(dbPath: String, sql: String) -> String? {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [dbPath, sql]
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                codexParserLog.warning("[runSQLite] sqlite3 exited \(process.terminationStatus)")
                return nil
            }
            return String(data: data, encoding: .utf8)
        } catch {
            codexParserLog.error("[runSQLite] Failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Prompt History

    private struct HistoryPrompt {
        let sessionId: String
        let timestamp: Date
    }

    private func parseHistoryPrompts() -> [HistoryPrompt] {
        let path = codexDir + "/history.jsonl"
        guard let data = FileManager.default.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else {
            return []
        }

        var prompts: [HistoryPrompt] = []
        for line in content.components(separatedBy: .newlines) where !line.isEmpty {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sessionId = obj["session_id"] as? String,
                  let ts = obj["ts"] as? TimeInterval else { continue }
            prompts.append(HistoryPrompt(sessionId: sessionId, timestamp: Date(timeIntervalSince1970: ts)))
        }
        return prompts
    }

    // MARK: - Helpers

    private func intField(_ name: String, in text: String) -> Int {
        guard let value = field(name, in: text) else { return 0 }
        return Int(value) ?? 0
    }

    private func field(_ name: String, in text: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let pattern = #"(?:^|\s)"# + escaped + #"=(?:"([^"]*)"|([^\s]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }

        for index in [1, 2] {
            let matchRange = match.range(at: index)
            if matchRange.location != NSNotFound,
               let swiftRange = Range(matchRange, in: text) {
                return String(text[swiftRange])
            }
        }
        return nil
    }

    static func shortModelName(_ model: String) -> String {
        if model.contains("codex") {
            if model.contains("spark") { return "Codex Spark" }
            return "Codex"
        }
        if model.contains("gpt-5.5") { return "GPT-5.5" }
        if model.contains("gpt-5.4-mini") { return "GPT-5.4 mini" }
        if model.contains("gpt-5.4") { return "GPT-5.4" }
        if model.contains("gpt-5") { return "GPT-5" }
        return model
    }

    private static func calculateActiveMinutes(from sessionTimestamps: [String: [Date]]) -> Int {
        let maxGap: TimeInterval = 10 * 60
        let tailPadding: TimeInterval = 2 * 60
        var totalSeconds: TimeInterval = 0

        for (_, timestamps) in sessionTimestamps {
            guard timestamps.count >= 2 else {
                if !timestamps.isEmpty { totalSeconds += tailPadding }
                continue
            }

            let sorted = timestamps.sorted()
            var periodStart = sorted[0]
            var periodEnd = sorted[0]

            for i in 1..<sorted.count {
                let gap = sorted[i].timeIntervalSince(periodEnd)
                if gap <= maxGap {
                    periodEnd = sorted[i]
                } else {
                    totalSeconds += periodEnd.timeIntervalSince(periodStart) + tailPadding
                    periodStart = sorted[i]
                    periodEnd = sorted[i]
                }
            }
            totalSeconds += periodEnd.timeIntervalSince(periodStart) + tailPadding
        }

        return totalSeconds > 0 ? max(1, Int(totalSeconds / 60)) : 0
    }
}
