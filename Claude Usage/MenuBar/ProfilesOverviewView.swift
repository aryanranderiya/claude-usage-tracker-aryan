import AppKit
import SwiftUI

/// All detected accounts in one popover, grouped by the tool that owns them.
/// The menu bar itself stays a single primary tracker; this list is where the
/// user changes the primary and inspects any account.
struct ProfilesOverviewView: View {
    let onManageProfiles: () -> Void

    @StateObject private var profileManager = ProfileManager.shared

    private struct Group: Identifiable {
        let provider: Provider
        let title: String
        let profiles: [Profile]

        var id: String { provider.rawValue }
    }

    private var groups: [Group] {
        let order: [Provider] = [.anthropic, .cswap, .opencode, .codex]
        return order.compactMap { provider in
            let profiles = profileManager.profiles.filter { $0.provider == provider }
            guard !profiles.isEmpty else { return nil }
            return Group(provider: provider, title: Self.title(for: provider), profiles: profiles)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 7) {
                            ProviderLogoView(provider: group.provider, size: 11)
                                .foregroundColor(group.provider.brandTint)

                            Text(group.title)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.secondary)

                            Text("\(group.profiles.count)")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary.opacity(0.55))

                            Spacer()
                        }
                        .padding(.horizontal, 2)

                        ForEach(group.profiles) { profile in
                            ProfileSummaryCard(
                                profile: profile,
                                isPrimary: profileManager.activeProfile?.id == profile.id,
                                showRemaining: profile.iconConfig.showRemainingPercentage
                            ) {
                                Task {
                                    _ = await profileManager.activateProfile(profile.id)
                                }
                            }

                            if profile.id != group.profiles.last?.id {
                                Divider()
                                    .padding(.leading, 34)
                            }
                        }
                    }
                }

                Divider()
                    .padding(.top, 2)

                Button(action: onManageProfiles) {
                    HStack(spacing: 8) {
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 10, weight: .medium))
                        Text("profiles.title".localized)
                            .font(.system(size: 11, weight: .medium))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .scrollIndicators(.hidden)
    }

    private static func title(for provider: Provider) -> String {
        switch provider {
        case .anthropic:
            return "Claude Code"
        case .cswap:
            return "cswap"
        case .opencode:
            return "OpenCode"
        case .codex:
            return "Codex"
        }
    }
}

/// Compact account card: identity, primary selector, and 5h/7d/Fable bars.
/// The chevron expands into the full `SmartUsageDashboard` for that profile.
private struct ProfileSummaryCard: View {
    let profile: Profile
    let isPrimary: Bool
    let showRemaining: Bool
    let onMakePrimary: () -> Void

    @State private var isExpanded = false

    private var usage: ClaudeUsage? {
        profile.claudeUsage
    }

    private var planText: String? {
        usage?.planType?
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center, spacing: 9) {
                ProviderLogoView(provider: profile.provider, size: 20)
                    .foregroundColor(profile.provider.brandTint)
                    .frame(width: 26, height: 26)

                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .minimumScaleFactor(0.86)
                        .allowsTightening(true)

                    HStack(spacing: 5) {
                        if isPrimary {
                            Text("profiles.primary_badge".localized)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(.accentColor)
                        }

                        Text(profile.sourceDisplayName)
                        if let planText {
                            Text("· \(planText)")
                        }
                    }
                    .font(.system(size: 9.5))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                }

                Spacer(minLength: 6)

                Button(action: onMakePrimary) {
                    Image(systemName: isPrimary ? "pin.fill" : "pin")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(isPrimary ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help("profiles.make_primary".localized)
                .disabled(isPrimary)

                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Hide details" : "Show details")
            }

            if let usage {
                compactMetrics(usage)
            } else {
                Text("popover.no_usage_yet".localized)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            if isExpanded, let usage {
                Divider()
                    .padding(.vertical, 2)

                SmartUsageDashboard(
                    usage: usage,
                    apiUsage: profile.apiUsage,
                    provider: profile.provider,
                    monthlySpendLimitCents: profile.monthlySpendLimitCents,
                    profile: profile
                )
            }
        }
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private func compactMetrics(_ usage: ClaudeUsage) -> some View {
        let metrics = compactMetricModels(usage)

        if metrics.isEmpty {
            Text("popover.no_limits_reported".localized)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        } else {
            HStack(alignment: .top, spacing: 12) {
                ForEach(metrics) { metric in
                    CompactMetricColumn(
                        metric: metric,
                        showRemaining: showRemaining
                    )
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func compactMetricModels(_ usage: ClaudeUsage) -> [CompactMetric] {
        var metrics: [CompactMetric] = []

        if usage.hasSessionLimit {
            metrics.append(
                CompactMetric(
                    id: "5h",
                    label: "5h",
                    percentage: usage.effectiveSessionPercentage,
                    reset: usage.sessionResetTime
                )
            )
        }

        if usage.hasWeeklyLimit {
            metrics.append(
                CompactMetric(
                    id: "7d",
                    label: "7d",
                    percentage: usage.weeklyPercentage,
                    reset: usage.weeklyResetTime
                )
            )
        }

        if usage.fableWeeklyPercentage > 0 {
            metrics.append(
                CompactMetric(
                    id: "fable",
                    label: "Fable",
                    percentage: usage.fableWeeklyPercentage,
                    reset: usage.fableWeeklyResetTime ?? usage.weeklyResetTime
                )
            )
        }

        return metrics
    }
}

private struct CompactMetric: Identifiable {
    let id: String
    let label: String
    let percentage: Double
    let reset: Date
}

private struct CompactMetricColumn: View {
    let metric: CompactMetric
    let showRemaining: Bool

    private var displayPercentage: Double {
        min(100, max(0, showRemaining ? 100 - metric.percentage : metric.percentage))
    }

    private var color: Color {
        switch UsageStatusCalculator.calculateStatus(
            usedPercentage: metric.percentage,
            showRemaining: showRemaining
        ) {
        case .safe:
            return .adaptiveGreen
        case .moderate:
            return .orange
        case .critical:
            return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(metric.label)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.secondary)

                Spacer(minLength: 0)

                Text("\(Int(displayPercentage.rounded()))%")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(color)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(color)
                        .frame(width: max(2, geometry.size.width * displayPercentage / 100))
                }
            }
            .frame(height: 5)

            Text(Self.resetText(metric.reset))
                .font(.system(size: 8.5))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func resetText(_ date: Date) -> String {
        let seconds = date.timeIntervalSinceNow
        guard seconds > 0 else { return "now" }

        let days = Int(seconds / 86_400)
        let hours = Int(seconds.truncatingRemainder(dividingBy: 86_400) / 3_600)
        let minutes = Int(seconds.truncatingRemainder(dividingBy: 3_600) / 60)

        if days > 0 {
            return "in \(days)d \(hours)h"
        }
        if hours > 0 {
            return "in \(hours)h \(minutes)m"
        }
        return "in \(minutes)m"
    }
}

extension Provider {
    /// Brand tint for provider marks. Claude/cswap share the Claude identity;
    /// OpenCode and Codex stay visually distinct in the all-accounts list.
    var brandTint: Color {
        switch self {
        case .anthropic, .cswap:
            return Color(red: 0.85, green: 0.47, blue: 0.34)
        case .opencode:
            return .blue
        case .codex:
            return .primary
        }
    }
}
