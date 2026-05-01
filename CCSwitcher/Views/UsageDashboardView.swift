import SwiftUI

/// Hover tooltip that works inside MenuBarExtra panels (where `.help()` doesn't).
private struct StatWithTooltip<Content: View>: View {
    let tooltip: LocalizedStringKey
    @ViewBuilder let content: Content
    @State private var isHovering = false
    @Environment(\.locale) private var locale

    var body: some View {
        content
            .onHover { isHovering = $0 }
            .popover(isPresented: $isHovering, arrowEdge: .bottom) {
                Text(tooltip)
                    .font(.caption)
                    .padding(8)
                    .frame(width: 200)
                    .environment(\.locale, locale)
            }
    }
}

/// Shows real usage limits from Claude API, one card per account.
struct UsageDashboardView: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("showFullEmail") private var showFullEmail = false
    @State private var selectedProvider: ProviderUsageFilter = .all

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if appState.accounts.isEmpty && appState.isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading usage data...")
                            .font(.caption)
                            .foregroundStyle(.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                } else if appState.accounts.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "chart.bar.xaxis")
                            .font(.system(size: 32))
                            .foregroundStyle(.textSecondary)
                        Text("Usage data unavailable")
                            .font(.subheadline)
                            .foregroundStyle(.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                } else {
                    providerFilter

                    if selectedProvider == .all {
                        combinedOverview
                    } else {
                        todayCostBanner
                    }

                    todayActivityCard

                    ForEach(visibleAccounts) { account in
                        accountUsageCard(account: account, usage: appState.accountUsage[account.id])
                    }
                }

                // Last updated
                if let lastRefresh = appState.lastUsageRefresh {
                    HStack(spacing: 4) {
                        Spacer()
                        Image(systemName: "arrow.clockwise")
                            .font(.caption2)
                        Text(lastRefresh, style: .relative)
                    }
                    .font(.caption)
                    .foregroundStyle(.textSecondary)
                    .padding(.horizontal, 16)
                }
            }
            .padding(.vertical, 12)
        }
    }

    private enum ProviderUsageFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case claude = "Claude"
        case codex = "Codex"

        var id: String { rawValue }

        var provider: AIProviderType? {
            switch self {
            case .all: return nil
            case .claude: return .claudeCode
            case .codex: return .codex
            }
        }

        var title: String {
            switch self {
            case .all: return "All"
            case .claude: return "Claude Code"
            case .codex: return "Codex"
            }
        }

        var tint: Color {
            switch self {
            case .all: return .brand
            case .claude: return .brand
            case .codex: return .blue
            }
        }
    }

    private var providerFilter: some View {
        Picker("Provider", selection: $selectedProvider) {
            ForEach(ProviderUsageFilter.allCases) { filter in
                Text(filter.rawValue).tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .sectionPadding()
    }

    private var visibleAccounts: [Account] {
        guard let provider = selectedProvider.provider else { return appState.accounts }
        return appState.accounts.filter { $0.provider == provider }
    }

    private var selectedCostSummary: CostSummary {
        switch selectedProvider {
        case .all: return appState.costSummary
        case .claude: return appState.claudeCostSummary
        case .codex: return appState.codexCostSummary
        }
    }

    private var selectedActivityStats: ActivityStats {
        switch selectedProvider {
        case .all: return appState.activityStats
        case .claude: return appState.claudeActivityStats
        case .codex: return appState.codexActivityStats
        }
    }

    private var combinedOverview: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.subheadline)
                    .foregroundStyle(.brand)
                Text("Today's Usage")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(formatCost(appState.costSummary.todayCost))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.green)
            }

            HStack(spacing: 8) {
                providerSummaryCard(
                    provider: .claudeCode,
                    title: "Claude Code",
                    account: appState.activeClaudeAccount,
                    usage: appState.activeClaudeAccount.flatMap { appState.accountUsage[$0.id] },
                    cost: appState.claudeCostSummary,
                    stats: appState.claudeActivityStats,
                    tint: .brand
                )
                providerSummaryCard(
                    provider: .codex,
                    title: "Codex",
                    account: appState.activeCodexAccount,
                    usage: appState.activeCodexAccount.flatMap { appState.accountUsage[$0.id] },
                    cost: appState.codexCostSummary,
                    stats: appState.codexActivityStats,
                    tint: .blue
                )
            }
        }
        .cardStyle()
        .sectionPadding()
    }

    private func providerSummaryCard(
        provider: AIProviderType,
        title: String,
        account: Account?,
        usage: UsageAPIResponse?,
        cost: CostSummary,
        stats: ActivityStats,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: provider.iconName)
                    .font(.caption)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            Text(account?.effectiveDisplayName(obfuscated: !showFullEmail) ?? "No active account")
                .font(.caption2)
                .foregroundStyle(.textSecondary)
                .lineLimit(1)

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(formatCost(cost.todayCost))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.green)
                    Text("Cost")
                        .font(.caption2)
                        .foregroundStyle(.textSecondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(stats.conversationTurns)")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                    Text(provider == .codex ? "Turns" : "Messages")
                        .font(.caption2)
                        .foregroundStyle(.textSecondary)
                }
            }

            if let usage {
                miniUsageBar(label: "Session", utilization: usage.fiveHour?.utilization ?? 0)
                miniUsageBar(label: "Weekly", utilization: usage.sevenDay?.utilization ?? 0)
            } else {
                Text("Usage unavailable")
                    .font(.caption2)
                    .foregroundStyle(.textSecondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(tint.opacity(0.10))
                .strokeBorder(tint.opacity(0.22), lineWidth: 1)
        )
    }

    private func miniUsageBar(label: LocalizedStringKey, utilization: Double) -> some View {
        VStack(spacing: 3) {
            HStack {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.textSecondary)
                Spacer()
                Text("\(Int(utilization))%")
                    .font(.caption2.weight(.medium).monospacedDigit())
                    .foregroundStyle(colorForUtilization(utilization))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.progressTrack)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(colorForUtilization(utilization))
                        .frame(width: max(0, geo.size.width * min(utilization / 100.0, 1.0)))
                }
            }
            .frame(height: 5)
        }
    }

    // MARK: - Today Cost Banner

    private var todayCostBanner: some View {
        let cost = selectedCostSummary.todayCost
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "dollarsign.circle")
                    .font(.subheadline)
                    .foregroundStyle(.green)
                Text("\(selectedProvider.title) API-Equivalent Cost")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer()
            }

            StatWithTooltip(tooltip: Self.costDisclaimer) {
                Text(formatCost(cost))
                    .font(.title.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.green)
            }
        }
        .cardStyle()
        .sectionPadding()
    }

    private static let costDisclaimer: LocalizedStringKey = "Estimated API-equivalent cost of your Claude Code and Codex usage, for reference only."

    // MARK: - Today Activity Card

    private var todayActivityCard: some View {
        let stats = selectedActivityStats
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg")
                    .font(.subheadline)
                    .foregroundStyle(selectedProvider.tint)
                Text("\(selectedProvider.title) Activity")
                    .font(.subheadline.weight(.medium))
                Spacer()
            }

            // Top stats row
            HStack(spacing: 0) {
                activityStat(icon: "bubble.left.and.bubble.right", value: "\(stats.conversationTurns)", label: selectedProvider == .claude ? "Messages" : "Turns",
                             tooltip: selectedProvider == .all ? "Messages you sent to Claude Code and turns you sent to Codex today." : "Interactions parsed from this provider's local logs today.")
                activityStat(icon: "clock", value: stats.activeCodingTimeString, label: "Active",
                             tooltip: "Estimated active time today. Parallel sessions stack. Idle gaps >10 min excluded. This is an approximation based on message timestamps, not exact.")
                activityStat(icon: "doc.text", value: "\(stats.linesWritten)", label: "Lines",
                             tooltip: selectedProvider == .codex ? "Codex line-count parsing is not included yet." : "Estimated lines of code written by Claude Code via Edit/Write tools.")
            }

            let topModels = Array(stats.topModels.prefix(4))
            if !topModels.isEmpty {
                HStack(spacing: 0) {
                    ForEach(topModels, id: \.name) { model in
                        modelStat(name: model.name, count: model.count,
                                  tooltip: "Model response count parsed from local Claude Code and Codex logs.")
                    }
                }
            }
        }
        .cardStyle()
        .sectionPadding()
    }

    private func activityStat(icon: String, value: String, label: LocalizedStringKey, tooltip: LocalizedStringKey) -> some View {
        StatWithTooltip(tooltip: tooltip) {
            VStack(spacing: 3) {
                Text(value)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                HStack(spacing: 3) {
                    Image(systemName: icon)
                        .font(.caption2)
                        .foregroundStyle(.textSecondary)
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(.textSecondary)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func modelStat(name: String, count: Int, tooltip: LocalizedStringKey) -> some View {
        StatWithTooltip(tooltip: tooltip) {
            VStack(spacing: 3) {
                Text("\(count)")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(count > 0 ? .primary : .quaternary)
                HStack(spacing: 3) {
                    Circle()
                        .fill(modelColor(name))
                        .frame(width: 7, height: 7)
                    Text(name)
                        .font(.caption2)
                        .foregroundStyle(count > 0 ? .tertiary : .quaternary)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func modelColor(_ name: String) -> Color {
        switch name {
        case "Opus": return .brand
        case "Sonnet": return .blue
        case "Haiku": return .green
        case "GPT-5.5": return .purple
        case "GPT-5.4": return .cyan
        case "GPT-5.4 mini": return .mint
        case "Codex", "Codex Spark": return .orange
        default: return .gray
        }
    }

    private func formatCost(_ cost: Double) -> String {
        cost >= 1 ? String(format: "$%.2f", cost) : String(format: "$%.4f", cost)
    }

    // MARK: - Per-Account Card

    private func accountUsageCard(account: Account, usage: UsageAPIResponse?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            accountHeader(account)
            if let usage = usage {
                usageBars(usage)
                extraUsageRow(usage.extraUsage)
            } else if let errorState = appState.accountUsageErrors[account.id] {
                HStack {
                    Image(systemName: errorState.isRateLimited ? "timer" : (errorState.isExpired ? "exclamationmark.triangle" : "xmark.circle"))
                        .foregroundStyle(errorState.isExpired ? .yellow : .red)
                    Text(errorState.message)
                        .font(.caption)
                        .foregroundStyle(.textSecondary)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(.top, 4)
            } else {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.yellow)
                    Text("Token expired. Switch to this account in Claude Code to refresh.")
                        .font(.caption)
                        .foregroundStyle(.textSecondary)
                    Spacer()
                }
                .padding(.top, 4)
            }
        }
        .cardStyle(fill: account.isActive ? .cardFill : .cardFill)
        .sectionPadding()
    }

    @ViewBuilder
    private func accountHeader(_ account: Account) -> some View {
        HStack(spacing: 8) {
            Image(systemName: account.provider.iconName)
                .font(.subheadline)
                .foregroundStyle(account.isActive ? .brand : .secondary)

            Text(account.displayEmail(obfuscated: !showFullEmail))
                .font(.subheadline.weight(.medium))
                .lineLimit(1)

            if account.isActive {
                Badge(text: String(localized: "Active"), color: .green)
            }

            Spacer()

            if let sub = account.displaySubscriptionType {
                Badge(text: sub, color: .brand)
            }
        }
    }

    @ViewBuilder
    private func usageBars(_ usage: UsageAPIResponse) -> some View {
        if let session = usage.fiveHour {
            usageRow(label: "Session", resetText: session.resetTimeString, utilization: session.utilization ?? 0)
        }
        if let weekly = usage.sevenDay {
            usageRow(label: "Weekly", resetText: weekly.resetTimeString, utilization: weekly.utilization ?? 0)
        }
    }

    @ViewBuilder
    private func extraUsageRow(_ extra: ExtraUsage?) -> some View {
        if let extra {
            let enabled = extra.isEnabled == true
            let iconColor: Color = enabled ? .orange : .gray
            let statusColor: Color = enabled ? .orange : .gray
            HStack(spacing: 6) {
                Image(systemName: enabled ? "bolt.fill" : "bolt.slash")
                    .font(.caption)
                    .foregroundStyle(iconColor)
                Text("Extra usage")
                    .font(.caption)
                    .foregroundStyle(.textSecondary)
                Spacer()
                Text(LocalizedStringKey(enabled ? "On" : "Off"))
                    .font(.caption)
                    .foregroundStyle(statusColor)
            }
        }
    }

    // MARK: - Usage Row

    private func usageRow(label: LocalizedStringKey, resetText: String?, utilization: Double) -> some View {
        VStack(spacing: 5) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.textSecondary)
                Spacer()
                if let resetText {
                    Text("Resets in \(resetText)")
                        .font(.caption)
                        .foregroundStyle(.textSecondary)
                }
            }

            HStack(spacing: 8) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(.progressTrack)
                            .frame(height: 7)

                        RoundedRectangle(cornerRadius: 3)
                            .fill(colorForUtilization(utilization))
                            .frame(width: max(0, geo.size.width * min(utilization / 100.0, 1.0)), height: 7)
                    }
                }
                .frame(height: 7)

                Text("\(Int(utilization))%")
                    .font(.caption.weight(.medium).monospacedDigit())
                    .foregroundStyle(colorForUtilization(utilization))
                    .frame(width: 34, alignment: .trailing)
            }
        }
    }

    private func colorForUtilization(_ pct: Double) -> Color {
        if pct >= 90 { return .red }
        if pct >= 60 { return .orange }
        return .green
    }
}
