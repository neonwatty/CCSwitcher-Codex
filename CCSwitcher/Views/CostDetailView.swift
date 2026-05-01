import SwiftUI

/// Full cost breakdown tab with today's card and daily history.
struct CostDetailView: View {
    @EnvironmentObject private var appState: AppState

    private static let claudePricingURL = URL(string: "https://platform.claude.com/docs/en/about-claude/pricing")!
    private static let openAIPricingURL = URL(string: "https://openai.com/api/pricing/")!

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                todayCard
                periodSummaryCards
                dailyHistorySection
                pricingInfoSection
            }
            .padding(.vertical, 12)
        }
    }

    // MARK: - Summary Cards

    private var todayCard: some View {
        let summary = appState.costSummary
        let today = summary.dailyCosts.first(where: { $0.date == todayString() })

        return VStack(spacing: 8) {
            HStack {
                Text("Today")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.textSecondary)
                Spacer()
                Text(todayDisplayDate())
                    .font(.caption2)
                    .foregroundStyle(.textSecondary)
            }

            Text(formatCost(summary.todayCost))
                .font(.system(size: 36, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.green)

            if let today, !today.modelBreakdown.isEmpty {
                Divider()
                VStack(spacing: 4) {
                    ForEach(today.modelBreakdown.sorted(by: { $0.value > $1.value }), id: \.key) { model, cost in
                        HStack {
                            Text(model)
                                .font(.caption2)
                                .foregroundStyle(.textSecondary)
                            Spacer()
                            Text(formatCost(cost))
                                .font(.caption2.weight(.medium).monospacedDigit())
                                .foregroundStyle(.textSecondary)
                        }
                    }
                }

                HStack {
                    Label("\(today.sessionCount) sessions", systemImage: "terminal")
                        .font(.caption2)
                        .foregroundStyle(.textSecondary)
                    Spacer()
                    Text("\(formatTokenCount(today.totalTokens)) tokens")
                        .font(.caption2)
                        .foregroundStyle(.textSecondary)
                }
                .padding(.top, 2)
            }
        }
        .cardStyle()
        .sectionPadding()
    }

    private var periodSummaryCards: some View {
        let costs = appState.costSummary.dailyCosts
        let todayStr = todayString()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        let last7 = costForLastDays(7, costs: costs, today: todayStr, formatter: formatter)
        let last30 = costForLastDays(30, costs: costs, today: todayStr, formatter: formatter)

        return HStack(spacing: 10) {
            periodCard(title: "Last 7 Days", cost: last7)
            periodCard(title: "Last 30 Days", cost: last30)
        }
        .padding(.horizontal, 16)
    }

    private func periodCard(title: String, cost: Double) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.textSecondary)
            Text(formatCost(cost))
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity)
        .cardStyle()
    }

    private func costForLastDays(_ days: Int, costs: [DailyCost], today: String, formatter: DateFormatter) -> Double {
        guard let todayDate = formatter.date(from: today) else { return 0 }
        let startDate = Calendar.current.date(byAdding: .day, value: -(days - 1), to: todayDate)!
        let startStr = formatter.string(from: startDate)
        return costs.filter { $0.date >= startStr && $0.date <= today }.reduce(0) { $0 + $1.totalCost }
    }

    // MARK: - Daily History

    private var dailyHistorySection: some View {
        let costs = appState.costSummary.dailyCosts
        let maxCost = costs.map(\.totalCost).max() ?? 1

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Daily History")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.textSecondary)
                Spacer()
                Text("Total: \(formatCost(appState.costSummary.totalCost))")
                    .font(.caption2.weight(.medium).monospacedDigit())
                    .foregroundStyle(.textSecondary)
            }
            .padding(.horizontal, 16)

            if costs.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "dollarsign.circle")
                        .font(.system(size: 32))
                        .foregroundStyle(.textSecondary)
                    Text("No cost data available")
                        .font(.subheadline)
                        .foregroundStyle(.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                VStack(spacing: 1) {
                    ForEach(costs) { day in
                        dailyRow(day: day, maxCost: maxCost)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func dailyRow(day: DailyCost, maxCost: Double) -> some View {
        let isToday = day.date == todayString()
        let barRatio = maxCost > 0 ? day.totalCost / maxCost : 0

        return HStack(spacing: 8) {
            Text(shortDate(day.date))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(isToday ? .brand : .secondary)
                .frame(width: 40, alignment: .leading)

            Text(formatCost(day.totalCost))
                .font(.caption2.weight(.medium).monospacedDigit())
                .foregroundStyle(isToday ? .brand : .primary)
                .frame(width: 56, alignment: .trailing)

            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 2)
                    .fill(isToday ? Color.brand : Color.blue.opacity(0.6))
                    .frame(width: max(2, geo.size.width * barRatio), height: 8)
            }
            .frame(height: 8)

            // Compact model breakdown
            Text(day.modelBreakdown.keys.sorted().joined(separator: ", "))
                .font(.system(size: 8))
                .foregroundStyle(.textSecondary)
                .frame(width: 50, alignment: .trailing)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(isToday ? .cardFillStrong : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    // MARK: - Pricing Info

    private var pricingInfoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("How We Calculate")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 16)

            VStack(alignment: .leading, spacing: 10) {
                Text("Cost is computed from local Claude Code logs (~/.claude/projects/) and Codex logs (~/.codex/logs_2.sqlite).")
                    .font(.caption2)
                    .foregroundStyle(.textSecondary)

                // Pricing table
                VStack(spacing: 0) {
                    pricingHeader
                    Divider()
                    ForEach(pricingRows, id: \.model) { row in
                        pricingRow(row)
                        Divider()
                    }
                }
                .background(.cardFill)
                .clipShape(RoundedRectangle(cornerRadius: AppStyle.cardCornerRadius))
                .overlay(RoundedRectangle(cornerRadius: AppStyle.cardCornerRadius).strokeBorder(.cardBorder, lineWidth: 1))

                Text("Claude cache write = 5-min tier. OpenAI cached input uses cached-token pricing where available.")
                    .font(.system(size: 9))
                    .foregroundStyle(.textSecondary)

                HStack(spacing: 12) {
                    Button {
                        NSWorkspace.shared.open(Self.claudePricingURL)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "link")
                                .font(.caption2)
                            Text("Claude pricing")
                                .font(.caption2)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)

                    Button {
                        NSWorkspace.shared.open(Self.openAIPricingURL)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "link")
                                .font(.caption2)
                            Text("OpenAI pricing")
                                .font(.caption2)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                }
            }
            .cardStyle()
            .sectionPadding()
        }
    }

    private var pricingHeader: some View {
        HStack(spacing: 0) {
            Text("Model")
                .frame(width: 62, alignment: .leading)
            Text("Input")
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text("Output")
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text("Cache W")
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text("Cache R")
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(.textSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    private struct PricingRowData {
        let model: String
        let input: String
        let output: String
        let cacheW: String
        let cacheR: String
    }

    private var pricingRows: [PricingRowData] {
        [
            PricingRowData(model: "Opus 4.6", input: "$5", output: "$25", cacheW: "$6.25", cacheR: "$0.50"),
            PricingRowData(model: "Sonnet 4.6", input: "$3", output: "$15", cacheW: "$3.75", cacheR: "$0.30"),
            PricingRowData(model: "Haiku 4.5", input: "$1", output: "$5", cacheW: "$1.25", cacheR: "$0.10"),
            PricingRowData(model: "GPT-5.5", input: "$5", output: "$30", cacheW: "-", cacheR: "$0.50"),
            PricingRowData(model: "GPT-5.3 Codex", input: "$1.75", output: "$14", cacheW: "-", cacheR: "$0.175"),
            PricingRowData(model: "GPT-5.1 Codex", input: "$1.25", output: "$10", cacheW: "-", cacheR: "$0.125"),
        ]
    }

    private func pricingRow(_ row: PricingRowData) -> some View {
        HStack(spacing: 0) {
            Text(row.model)
                .frame(width: 62, alignment: .leading)
            Text(row.input)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text(row.output)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text(row.cacheW)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text(row.cacheR)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.system(size: 9).monospacedDigit())
        .foregroundStyle(.textSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    // MARK: - Helpers

    private func formatCost(_ cost: Double) -> String {
        if cost >= 1 {
            return String(format: "$%.2f", cost)
        } else {
            return String(format: "$%.4f", cost)
        }
    }

    private func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }

    private func todayString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private func todayDisplayDate() -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f.string(from: Date())
    }

    private func shortDate(_ dateStr: String) -> String {
        let parts = dateStr.split(separator: "-")
        guard parts.count == 3,
              let month = Int(parts[1]),
              let day = Int(parts[2]) else { return dateStr }
        return "\(month)/\(day)"
    }
}
