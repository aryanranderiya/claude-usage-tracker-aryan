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
            VStack(alignment: .leading, spacing: 12) {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            ProviderLogoView(provider: group.provider, size: 11)
                                .foregroundColor(group.provider.brandTint)
                            Text(group.title)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.secondary)

                            Text("\(group.profiles.count)")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.primary.opacity(0.06)))

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
                        }
                    }
                }

                Divider()
                    .padding(.top, 2)

                Button(action: onManageProfiles) {
                    HStack(spacing: 7) {
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 10, weight: .medium))
                        Text("profiles.title".localized)
                            .font(.system(size: 10, weight: .medium))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                ZStack(alignment: .bottomTrailing) {
                    ProviderLogoView(provider: profile.provider, size: 18)
                        .foregroundColor(profile.provider.brandTint)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.primary.opacity(0.05)))

                    Text(profile.provider.descriptor.shortName)
                        .font(.system(size: 6.5, weight: .bold))
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, 2)
                        .padding(.vertical, 0.5)
                        .background(Capsule().fill(Color(nsColor: .windowBackgroundColor)))
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(profile.name)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)

                        if isPrimary {
                            Text("profiles.primary_badge".localized)
                                .font(.system(size: 7.5, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(Color.accentColor)
                                .cornerRadius(3)
                        }
                    }

                    HStack(spacing: 4) {
                        Text(profile.sourceDisplayName)
                        if let plan = usage?.planType {
                            Text("· \(plan.replacingOccurrences(of: "_", with: " ").capitalized)")
                        }
                    }
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                }

                Spacer(minLength: 4)

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
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(isPrimary ? 0.055 : 0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(isPrimary ? 0.10 : 0.055), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func compactMetrics(_ usage: ClaudeUsage) -> some View {
        if usage.hasSessionLimit || usage.hasWeeklyLimit || usage.fableWeeklyPercentage > 0 {
            HStack(alignment: .top, spacing: 10) {
                if usage.hasSessionLimit {
                    CompactMetricBar(
                        label: "5h",
                        percentage: usage.effectiveSessionPercentage,
                        reset: usage.sessionResetTime,
                        showRemaining: showRemaining
                    )
                }

                if usage.hasWeeklyLimit {
                    CompactMetricBar(
                        label: "7d",
                        percentage: usage.weeklyPercentage,
                        reset: usage.weeklyResetTime,
                        showRemaining: showRemaining
                    )
                }

                if usage.fableWeeklyPercentage > 0 {
                    CompactMetricBar(
                        label: "Fable",
                        percentage: usage.fableWeeklyPercentage,
                        reset: usage.fableWeeklyResetTime ?? usage.weeklyResetTime,
                        showRemaining: showRemaining,
                        compact: true
                    )
                }
            }
        } else {
            Text("popover.no_limits_reported".localized)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
    }
}

private struct CompactMetricBar: View {
    let label: String
    let percentage: Double
    let reset: Date
    let showRemaining: Bool
    var compact: Bool = false

    private var displayPercentage: Double {
        min(100, max(0, showRemaining ? 100 - percentage : percentage))
    }

    private var color: Color {
        switch UsageStatusCalculator.calculateStatus(
            usedPercentage: percentage,
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
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.secondary)

                Text("\(Int(displayPercentage.rounded()))%")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(color)

                if !compact {
                    Spacer(minLength: 2)
                    Text(reset, style: .relative)
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
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
            .frame(height: 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
