import SwiftUI

/// Shows real usage limits from Claude API, one card per account.
struct UsageDashboardView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if appState.accountUsage.isEmpty && appState.isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading usage data...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                } else if appState.accountUsage.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "chart.bar.xaxis")
                            .font(.system(size: 32))
                            .foregroundStyle(.secondary)
                        Text("Usage data unavailable")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                } else {
                    ForEach(appState.accounts) { account in
                        if let usage = appState.accountUsage[account.id] {
                            accountUsageCard(account: account, usage: usage)
                        }
                    }
                }

                // Last updated
                if let lastRefresh = appState.lastUsageRefresh {
                    HStack {
                        Spacer()
                        Text("Updated \(lastRefresh, style: .relative) ago")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16)
                }
            }
            .padding(.vertical, 12)
        }
    }

    // MARK: - Per-Account Card

    private func accountUsageCard(account: Account, usage: UsageAPIResponse) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            accountHeader(account)
            usageBars(usage)
            extraUsageRow(usage.extraUsage)
        }
        .padding(12)
        .background(cardBackground(isActive: account.isActive))
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func accountHeader(_ account: Account) -> some View {
        HStack(spacing: 8) {
            Image(systemName: account.provider.iconName)
                .font(.caption)
                .foregroundStyle(account.isActive ? .purple : .secondary)

            Text(account.email)
                .font(.caption.weight(.medium))
                .lineLimit(1)

            if account.isActive {
                Text("Active")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.green, in: Capsule())
            }

            Spacer()

            if let sub = account.subscriptionType {
                Text(sub)
                    .font(.caption2)
                    .foregroundStyle(.purple)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.purple.opacity(0.1), in: Capsule())
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
                    .font(.caption2)
                    .foregroundStyle(iconColor)
                Text("Extra usage")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(enabled ? "On" : "Off")
                    .font(.caption2)
                    .foregroundStyle(statusColor)
            }
        }
    }

    private func cardBackground(isActive: Bool) -> some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(isActive ? Color.purple.opacity(0.03) : Color.gray.opacity(0.03))
            .strokeBorder(isActive ? Color.purple.opacity(0.15) : Color.gray.opacity(0.12), lineWidth: 1)
    }

    // MARK: - Usage Row

    private func usageRow(label: String, resetText: String?, utilization: Double) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if let resetText {
                    Text("Resets in \(resetText)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            HStack(spacing: 8) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.gray.opacity(0.15))
                            .frame(height: 6)

                        RoundedRectangle(cornerRadius: 3)
                            .fill(colorForUtilization(utilization))
                            .frame(width: max(0, geo.size.width * min(utilization / 100.0, 1.0)), height: 6)
                    }
                }
                .frame(height: 6)

                Text("\(Int(utilization))%")
                    .font(.caption2.weight(.medium).monospacedDigit())
                    .foregroundStyle(colorForUtilization(utilization))
                    .frame(width: 32, alignment: .trailing)
            }
        }
    }

    private func colorForUtilization(_ pct: Double) -> Color {
        if pct >= 90 { return .red }
        if pct >= 60 { return .orange }
        return .green
    }
}
