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
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text(group.title)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.secondary)
                                .fixedSize()

                            Rectangle()
                                .fill(Color.primary.opacity(0.06))
                                .frame(height: 1)
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
        .scrollIndicators(.never)
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
    @State private var isHovered = false

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

                    if isPrimary || planText != nil {
                        HStack(spacing: 5) {
                            if isPrimary {
                                Text("profiles.primary_badge".localized)
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundColor(.accentColor)
                            }

                            if let planText {
                                Text(planText)
                                    .font(.system(size: 9.5))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .lineLimit(1)
                    }
                }

                Spacer(minLength: 6)

                Button(action: onMakePrimary) {
                    Image(systemName: isPrimary ? "pin.fill" : "pin")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(isPrimary ? .accentColor : .secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("profiles.make_primary".localized)
                .disabled(isPrimary)

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 12)
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
        .padding(12)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(isPrimary ? 0.07 : (isHovered ? 0.05 : 0.035)))
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .help(isExpanded ? "Collapse account details" : "Expand account details")
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
                        showRemaining: showRemaining,
                        usePaceColoring: profile.iconConfig.usePaceColoring
                    )
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private static func sameReset(_ lhs: Date, _ rhs: Date) -> Bool {
        abs(lhs.timeIntervalSince(rhs)) < 60
    }

    private func compactMetricModels(_ usage: ClaudeUsage) -> [CompactMetric] {
        var metrics: [CompactMetric] = []

        if usage.hasSessionLimit {
            metrics.append(
                CompactMetric(
                    id: "5h",
                    label: "5h",
                    percentage: usage.effectiveSessionPercentage,
                    reset: usage.sessionResetTime,
                    duration: Constants.sessionWindow,
                    excludeWeekends: false,
                    showsReset: true
                )
            )
        }

        if usage.hasWeeklyLimit {
            metrics.append(
                CompactMetric(
                    id: "7d",
                    label: "7d",
                    percentage: usage.weeklyPercentage,
                    reset: usage.weeklyResetTime,
                    duration: Constants.weeklyWindow,
                    excludeWeekends: profile.iconConfig.excludeWeekendsFromWeeklyPace,
                    showsReset: true
                )
            )
        }

        if usage.hasMonthlyLimit {
            metrics.append(
                CompactMetric(
                    id: "monthly",
                    label: "menubar.monthly".localized,
                    percentage: usage.monthlyPercentage,
                    reset: usage.monthlyResetTime ?? Date().addingTimeInterval(Constants.monthlyWindow),
                    duration: Constants.monthlyWindow,
                    excludeWeekends: false,
                    showsReset: true
                )
            )
        }

        if usage.fableWeeklyPercentage > 0 || usage.fableWeeklyResetTime != nil {
            metrics.append(
                CompactMetric(
                    id: "fable",
                    label: "Fable",
                    percentage: usage.fableWeeklyPercentage,
                    reset: usage.fableWeeklyResetTime ?? usage.weeklyResetTime,
                    duration: Constants.weeklyWindow,
                    excludeWeekends: profile.iconConfig.excludeWeekendsFromWeeklyPace,
                    showsReset: !Self.sameReset(
                        usage.fableWeeklyResetTime ?? usage.weeklyResetTime,
                        usage.weeklyResetTime
                    )
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
    let duration: TimeInterval
    let excludeWeekends: Bool
    let showsReset: Bool
}

private struct CompactMetricColumn: View {
    let metric: CompactMetric
    let showRemaining: Bool
    let usePaceColoring: Bool

    private var displayPercentage: Double {
        min(100, max(0, showRemaining ? 100 - metric.percentage : metric.percentage))
    }

    private var rawElapsedFraction: Double? {
        UsageStatusCalculator.elapsedFraction(
            resetTime: metric.reset,
            duration: metric.duration,
            showRemaining: false,
            excludingWeekends: metric.excludeWeekends
        )
    }

    private var timeMarkerFraction: CGFloat? {
        guard let elapsed = rawElapsedFraction else { return nil }
        let fraction = showRemaining ? 1.0 - elapsed : elapsed
        return CGFloat(min(max(fraction, 0), 1))
    }

    private var paceStatus: PaceStatus? {
        guard let elapsed = rawElapsedFraction else { return nil }
        return PaceStatus.calculate(usedPercentage: metric.percentage, elapsedFraction: elapsed)
    }

    private var paceColor: Color {
        paceStatus?.swiftUIColor ?? Color(nsColor: .labelColor).opacity(0.75)
    }

    private var color: Color {
        switch UsageStatusCalculator.calculateStatus(
            usedPercentage: metric.percentage,
            showRemaining: showRemaining,
            elapsedFraction: usePaceColoring ? rawElapsedFraction : nil
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
                        .frame(height: 5)

                    Capsule()
                        .fill(color)
                        .frame(width: max(2, geometry.size.width * displayPercentage / 100), height: 5)

                    if let fraction = timeMarkerFraction {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(paceColor)
                            .frame(width: 2.5, height: 9)
                            .offset(x: min(max(geometry.size.width * fraction - 1.25, 0), geometry.size.width - 2.5))
                    }
                }
                .frame(height: 9)
            }
            .frame(height: 9)

            if metric.showsReset {
                Text(Self.resetText(metric.reset))
                    .font(.system(size: 8.5))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
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
