import Foundation

// MARK: - Token Cost Models

/// Per-model pricing in USD per 1M tokens.
struct ModelPricing {
    let input: Double
    let output: Double
    let cacheWrite: Double
    let cacheRead: Double

    // Official pricing from platform.claude.com/docs/en/about-claude/pricing
    // Cache write = 5-minute tier (1.25x base input). Cache read = 0.1x base input.
    static let pricing: [String: ModelPricing] = [
        "claude-opus-4-6": ModelPricing(input: 5.0, output: 25.0, cacheWrite: 6.25, cacheRead: 0.50),
        "claude-opus-4-5": ModelPricing(input: 5.0, output: 25.0, cacheWrite: 6.25, cacheRead: 0.50),
        "claude-opus-4-1": ModelPricing(input: 15.0, output: 75.0, cacheWrite: 18.75, cacheRead: 1.50),
        "claude-opus-4": ModelPricing(input: 15.0, output: 75.0, cacheWrite: 18.75, cacheRead: 1.50),
        "claude-sonnet-4-6": ModelPricing(input: 3.0, output: 15.0, cacheWrite: 3.75, cacheRead: 0.30),
        "claude-sonnet-4-5-20250514": ModelPricing(input: 3.0, output: 15.0, cacheWrite: 3.75, cacheRead: 0.30),
        "claude-sonnet-4": ModelPricing(input: 3.0, output: 15.0, cacheWrite: 3.75, cacheRead: 0.30),
        "claude-haiku-4-5": ModelPricing(input: 1.0, output: 5.0, cacheWrite: 1.25, cacheRead: 0.10),
        "claude-haiku-3-5": ModelPricing(input: 0.80, output: 4.0, cacheWrite: 1.0, cacheRead: 0.08),
        // OpenAI API-equivalent pricing as of 2026-05-01.
        // For OpenAI models, cacheWrite is unused and cacheRead stores cached-input tokens.
        "gpt-5.5": ModelPricing(input: 5.0, output: 30.0, cacheWrite: 0.0, cacheRead: 0.50),
        "gpt-5.4": ModelPricing(input: 2.50, output: 15.0, cacheWrite: 0.0, cacheRead: 0.25),
        "gpt-5.4-mini": ModelPricing(input: 0.75, output: 4.50, cacheWrite: 0.0, cacheRead: 0.075),
        "gpt-5.3-codex": ModelPricing(input: 1.75, output: 14.0, cacheWrite: 0.0, cacheRead: 0.175),
        "gpt-5.2-codex": ModelPricing(input: 1.75, output: 14.0, cacheWrite: 0.0, cacheRead: 0.175),
        "gpt-5.1-codex-max": ModelPricing(input: 1.25, output: 10.0, cacheWrite: 0.0, cacheRead: 0.125),
        "gpt-5.1-codex": ModelPricing(input: 1.25, output: 10.0, cacheWrite: 0.0, cacheRead: 0.125),
        "gpt-5-codex": ModelPricing(input: 1.25, output: 10.0, cacheWrite: 0.0, cacheRead: 0.125),
    ]

    static func forModel(_ model: String) -> ModelPricing? {
        if let exact = pricing[model] { return exact }
        // Prefix match for versioned model names
        for (key, value) in pricing {
            let parts = key.split(separator: "-")
            let baseParts = parts.prefix(while: { !$0.allSatisfy(\.isNumber) || $0.count < 8 })
            let base = baseParts.map(String.init).joined(separator: "-")
            if model.hasPrefix(base) { return value }
        }
        return nil
    }
}

/// Token usage from a single API call.
struct TokenUsage {
    let inputTokens: Int
    let outputTokens: Int
    let cacheWriteTokens: Int
    let cacheReadTokens: Int
    let model: String
    let timestamp: Date
    let sessionFile: String

    var cost: Double {
        guard let pricing = ModelPricing.forModel(model) else { return 0 }
        return Double(inputTokens) / 1_000_000 * pricing.input
            + Double(outputTokens) / 1_000_000 * pricing.output
            + Double(cacheWriteTokens) / 1_000_000 * pricing.cacheWrite
            + Double(cacheReadTokens) / 1_000_000 * pricing.cacheRead
    }
}

/// Aggregated cost for a single day.
struct DailyCost: Identifiable {
    let date: String // "yyyy-MM-dd"
    let totalCost: Double
    let modelBreakdown: [String: Double] // model -> cost
    let sessionCount: Int
    let inputTokens: Int
    let outputTokens: Int
    let cacheWriteTokens: Int
    let cacheReadTokens: Int

    var id: String { date }

    var totalTokens: Int {
        inputTokens + outputTokens + cacheWriteTokens + cacheReadTokens
    }

    var parsedDate: Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: date)
    }
}

/// Overall cost summary.
struct CostSummary {
    let todayCost: Double
    let dailyCosts: [DailyCost]

    var totalCost: Double {
        dailyCosts.reduce(0) { $0 + $1.totalCost }
    }

    static let empty = CostSummary(todayCost: 0, dailyCosts: [])
}

extension CostSummary {
    static func combined(_ summaries: [CostSummary]) -> CostSummary {
        var byDate: [String: DailyCostAccumulator] = [:]

        for summary in summaries {
            for day in summary.dailyCosts {
                byDate[day.date, default: DailyCostAccumulator()].add(day)
            }
        }

        let dailyCosts = byDate.map { date, accumulator in
            DailyCost(
                date: date,
                totalCost: accumulator.totalCost,
                modelBreakdown: accumulator.modelBreakdown,
                sessionCount: accumulator.sessionCount,
                inputTokens: accumulator.inputTokens,
                outputTokens: accumulator.outputTokens,
                cacheWriteTokens: accumulator.cacheWriteTokens,
                cacheReadTokens: accumulator.cacheReadTokens
            )
        }
        .sorted { $0.date > $1.date }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: Date())
        return CostSummary(
            todayCost: dailyCosts.first(where: { $0.date == today })?.totalCost ?? 0,
            dailyCosts: dailyCosts
        )
    }
}

private struct DailyCostAccumulator {
    var totalCost: Double = 0
    var modelBreakdown: [String: Double] = [:]
    var sessionCount: Int = 0
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheWriteTokens: Int = 0
    var cacheReadTokens: Int = 0

    mutating func add(_ day: DailyCost) {
        totalCost += day.totalCost
        sessionCount += day.sessionCount
        inputTokens += day.inputTokens
        outputTokens += day.outputTokens
        cacheWriteTokens += day.cacheWriteTokens
        cacheReadTokens += day.cacheReadTokens
        for (model, cost) in day.modelBreakdown {
            modelBreakdown[model, default: 0] += cost
        }
    }
}
