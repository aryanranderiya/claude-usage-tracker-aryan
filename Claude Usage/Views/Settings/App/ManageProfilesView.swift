//
//  ManageProfilesView.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-01-07.
//

import SwiftUI

struct ManageProfilesView: View {
    @StateObject private var profileManager = ProfileManager.shared
    @State private var showingCreateProfile = false
    @State private var newProfileName = ""
    @State private var newProfileProvider: Provider = .anthropic
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.section) {
                // Page Header
                SettingsPageHeader(
                    title: "profiles.title".localized,
                    subtitle: "profiles.subtitle".localized
                )

                if profileManager.displayMode == .single {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.accentColor)
                        Text("profiles.primary_hint".localized)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 2)
                }

                // Profile List
                SettingsContentCard {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
                        ForEach(profileManager.profiles) { profile in
                            ProfileRow(profile: profile)
                                .padding(.vertical, DesignTokens.Spacing.extraSmall)

                            if profile.id != profileManager.profiles.last?.id {
                                Divider()
                            }
                        }
                    }
                }

                // Create New Profile Button
                SettingsButton(
                    title: "profiles.create_new".localized,
                    icon: "plus.circle.fill"
                ) {
                    showingCreateProfile = true
                }

                // Multi-Profile Display Section
                SettingsSectionCard(
                    title: "multiprofile.title".localized,
                    subtitle: "multiprofile.subtitle".localized
                ) {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.cardPadding) {
                        // Main toggle
                        SettingToggle(
                            title: "multiprofile.enable_title".localized,
                            description: "multiprofile.enable_description".localized,
                            isOn: Binding(
                                get: { profileManager.displayMode == .multi },
                                set: { enabled in
                                    profileManager.updateDisplayMode(enabled ? .multi : .single)
                                    // Post notification for menu bar to update
                                    NotificationCenter.default.post(name: .displayModeChanged, object: nil)
                                }
                            )
                        )

                        // Profile selection (visible when multi-profile is ON)
                        if profileManager.displayMode == .multi {
                            Divider()

                            VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
                                Text("multiprofile.select_profiles".localized)
                                    .font(DesignTokens.Typography.caption)
                                    .foregroundColor(.secondary)

                                ForEach(profileManager.profiles) { profile in
                                    ProfileSelectionRow(
                                        profile: profile,
                                        isSelected: profile.isSelectedForDisplay,
                                        isActive: profileManager.activeProfile?.id == profile.id,
                                        onToggle: {
                                            // Ensure at least one profile stays selected
                                            let selectedCount = profileManager.profiles.filter { $0.isSelectedForDisplay }.count
                                            if profile.isSelectedForDisplay && selectedCount <= 1 {
                                                // Can't deselect the last one
                                                return
                                            }
                                            profileManager.toggleProfileSelection(profile.id)
                                            // Post notification for menu bar to update (incremental, not full recreate)
                                            NotificationCenter.default.post(name: .multiProfileConfigChanged, object: nil)
                                        }
                                    )
                                }

                                // Warning if trying to deselect last profile
                                if profileManager.profiles.filter({ $0.isSelectedForDisplay }).count == 1 {
                                    HStack(alignment: .top, spacing: 6) {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .font(.system(size: 10))
                                            .foregroundColor(.orange)
                                        Text("multiprofile.at_least_one".localized)
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(.top, 4)
                                }
                            }

                            Divider()
                                .padding(.vertical, DesignTokens.Spacing.small)

                            // Icon Style Picker
                            VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
                                Text("multiprofile.icon_style".localized)
                                    .font(DesignTokens.Typography.caption)
                                    .foregroundColor(.secondary)

                                Picker("", selection: Binding(
                                    get: { profileManager.multiProfileConfig.iconStyle },
                                    set: { newStyle in
                                        var config = profileManager.multiProfileConfig
                                        config.iconStyle = newStyle
                                        profileManager.updateMultiProfileConfig(config)
                                        NotificationCenter.default.post(name: .multiProfileConfigChanged, object: nil)
                                    }
                                )) {
                                    ForEach(MultiProfileIconStyle.allCases, id: \.self) { style in
                                        Text(style.shortNameKey.localized).tag(style)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            // Show Week Toggle
                            SettingToggle(
                                title: "multiprofile.show_week".localized,
                                description: "multiprofile.show_week_description".localized,
                                isOn: Binding(
                                    get: { profileManager.multiProfileConfig.showWeek },
                                    set: { showWeek in
                                        var config = profileManager.multiProfileConfig
                                        config.showWeek = showWeek
                                        profileManager.updateMultiProfileConfig(config)
                                        NotificationCenter.default.post(name: .multiProfileConfigChanged, object: nil)
                                    }
                                )
                            )

                            // Show Profile Label Toggle
                            SettingToggle(
                                title: "multiprofile.show_label".localized,
                                description: "multiprofile.show_label_description".localized,
                                isOn: Binding(
                                    get: { profileManager.multiProfileConfig.showProfileLabel },
                                    set: { showLabel in
                                        var config = profileManager.multiProfileConfig
                                        config.showProfileLabel = showLabel
                                        profileManager.updateMultiProfileConfig(config)
                                        NotificationCenter.default.post(name: .multiProfileConfigChanged, object: nil)
                                    }
                                )
                            )

                            // Use System Color Toggle
                            SettingToggle(
                                title: "multiprofile.use_system_color".localized,
                                description: "multiprofile.use_system_color_description".localized,
                                isOn: Binding(
                                    get: { profileManager.multiProfileConfig.useSystemColor },
                                    set: { useSystemColor in
                                        var config = profileManager.multiProfileConfig
                                        config.useSystemColor = useSystemColor
                                        profileManager.updateMultiProfileConfig(config)
                                        NotificationCenter.default.post(name: .multiProfileConfigChanged, object: nil)
                                    }
                                )
                            )

                            // Show Time Marker Toggle
                            SettingToggle(
                                title: "appearance.show_time_marker_title".localized,
                                description: "appearance.show_time_marker_description".localized,
                                isOn: Binding(
                                    get: { profileManager.multiProfileConfig.showTimeMarker },
                                    set: { showMarker in
                                        var config = profileManager.multiProfileConfig
                                        config.showTimeMarker = showMarker
                                        profileManager.updateMultiProfileConfig(config)
                                        NotificationCenter.default.post(name: .multiProfileConfigChanged, object: nil)
                                    }
                                )
                            )

                            // Pace Marker Toggle
                            SettingToggle(
                                title: "appearance.show_pace_marker_title".localized,
                                description: "appearance.show_pace_marker_description".localized,
                                isOn: Binding(
                                    get: { profileManager.multiProfileConfig.showPaceMarker },
                                    set: { showPace in
                                        var config = profileManager.multiProfileConfig
                                        config.showPaceMarker = showPace
                                        profileManager.updateMultiProfileConfig(config)
                                        NotificationCenter.default.post(name: .multiProfileConfigChanged, object: nil)
                                    }
                                )
                            )

                            // Pace-Aware Bar Colors Toggle
                            SettingToggle(
                                title: "appearance.pace_coloring_title".localized,
                                description: "appearance.pace_coloring_description".localized,
                                isOn: Binding(
                                    get: { profileManager.multiProfileConfig.usePaceColoring },
                                    set: { usePace in
                                        var config = profileManager.multiProfileConfig
                                        config.usePaceColoring = usePace
                                        profileManager.updateMultiProfileConfig(config)
                                        NotificationCenter.default.post(name: .multiProfileConfigChanged, object: nil)
                                    }
                                )
                            )

                            // Exclude Weekends from Weekly Pace Toggle
                            SettingToggle(
                                title: "appearance.exclude_weekends_title".localized,
                                description: "appearance.exclude_weekends_description".localized,
                                isOn: Binding(
                                    get: { profileManager.multiProfileConfig.excludeWeekendsFromWeeklyPace },
                                    set: { excludeWeekends in
                                        var config = profileManager.multiProfileConfig
                                        config.excludeWeekendsFromWeeklyPace = excludeWeekends
                                        profileManager.updateMultiProfileConfig(config)
                                        NotificationCenter.default.post(name: .multiProfileConfigChanged, object: nil)
                                    }
                                )
                            )

                            // Show Remaining Percentage Toggle
                            SettingToggle(
                                title: "appearance.show_remaining_title".localized,
                                description: "appearance.show_remaining_description".localized,
                                isOn: Binding(
                                    get: { profileManager.multiProfileConfig.showRemainingPercentage },
                                    set: { showRemaining in
                                        var config = profileManager.multiProfileConfig
                                        config.showRemainingPercentage = showRemaining
                                        profileManager.updateMultiProfileConfig(config)
                                        NotificationCenter.default.post(name: .multiProfileConfigChanged, object: nil)
                                    }
                                )
                            )

                            // Show Active Profile Indicator Toggle
                            SettingToggle(
                                title: "multiprofile.active_indicator_title".localized,
                                description: "multiprofile.active_indicator_description".localized,
                                isOn: Binding(
                                    get: { profileManager.multiProfileConfig.showActiveProfileIndicator },
                                    set: { showIndicator in
                                        var config = profileManager.multiProfileConfig
                                        config.showActiveProfileIndicator = showIndicator
                                        profileManager.updateMultiProfileConfig(config)
                                        NotificationCenter.default.post(name: .multiProfileConfigChanged, object: nil)
                                    }
                                )
                            )

                            // Info message
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "info.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundColor(.blue)
                                Text("multiprofile.info".localized)
                                    .font(DesignTokens.Typography.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.top, DesignTokens.Spacing.small)
                        }
                    }
                }

                // Auto-Switch Profile Section
                SettingsSectionCard(
                    title: "auto_switch.title".localized,
                    subtitle: "auto_switch.subtitle".localized
                ) {
                    SettingToggle(
                        title: "auto_switch.enable_title".localized,
                        description: "auto_switch.enable_description".localized,
                        isOn: Binding(
                            get: { SharedDataStore.shared.loadAutoSwitchProfileEnabled() },
                            set: { enabled in
                                SharedDataStore.shared.saveAutoSwitchProfileEnabled(enabled)
                            }
                        )
                    )
                }

                // Info Card
                SettingsContentCard {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
                        HStack(spacing: DesignTokens.Spacing.small) {
                            Image(systemName: "info.circle.fill")
                                .foregroundColor(.blue)
                                .font(.system(size: DesignTokens.Icons.standard))
                            Text("profiles.about_title".localized)
                                .font(DesignTokens.Typography.sectionTitle)
                        }

                        Text("profiles.about_description".localized)
                            .font(DesignTokens.Typography.caption)
                            .foregroundColor(.secondary)

                        VStack(alignment: .leading, spacing: DesignTokens.Spacing.extraSmall) {
                            BulletPoint("profiles.about_credentials".localized)
                            BulletPoint("profiles.about_api".localized)
                            BulletPoint("profiles.about_cli".localized)
                            BulletPoint("profiles.about_appearance".localized)
                            BulletPoint("profiles.about_notifications".localized)
                            BulletPoint("profiles.about_refresh".localized)
                        }
                        .font(DesignTokens.Typography.caption)
                        .foregroundColor(.secondary)
                        .padding(.leading, DesignTokens.Spacing.small)
                    }
                }

                if let error = errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.system(size: 11))
                }
            }
            .padding()
        }
        .sheet(isPresented: $showingCreateProfile) {
            CreateProfileSheet(
                profileName: $newProfileName,
                selectedProvider: $newProfileProvider,
                onSave: {
                    createNewProfile()
                },
                onCancel: {
                    showingCreateProfile = false
                    newProfileName = ""
                    newProfileProvider = .anthropic
                }
            )
        }
    }

    private func createNewProfile() {
        let name = newProfileName.isEmpty ? nil : newProfileName
        _ = profileManager.createProfile(name: name, provider: newProfileProvider)
        showingCreateProfile = false
        newProfileName = ""
        newProfileProvider = .anthropic
    }
}

// MARK: - Profile Row

struct ProfileRow: View {
    let profile: Profile
    @StateObject private var profileManager = ProfileManager.shared
    @State private var showingEditor = false
    @State private var showingDeleteConfirmation = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                ProviderLogoView(provider: profile.provider, size: 22)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.primary.opacity(0.05)))

                Text(profile.provider.descriptor.shortName)
                    .font(.system(size: 7, weight: .bold))
                    .foregroundColor(.accentColor)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color(nsColor: .windowBackgroundColor)))
            }
            .foregroundColor(profileManager.activeProfile?.id == profile.id ? .accentColor : .secondary)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(profile.name)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if profileManager.activeProfile?.id == profile.id {
                        Text("profiles.primary_badge".localized)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor)
                            .cornerRadius(4)
                    }
                }

                Text(profileInfo)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                Button {
                    showingEditor = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help("profiles.rename".localized)

                if profileManager.activeProfile?.id != profile.id {
                    Button {
                        Task {
                            await profileManager.activateProfile(profile.id)
                        }
                    } label: {
                        Image(systemName: "pin.circle")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .help("profiles.make_primary".localized)
                }

                if profileManager.profiles.count > 1 {
                    Button {
                        showingDeleteConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                    .help("profiles.delete".localized)
                }
            }
        }
        .alert("profiles.delete_title".localized, isPresented: $showingDeleteConfirmation) {
            Button("common.cancel".localized, role: .cancel) {}
            Button("common.delete".localized, role: .destructive) {
                deleteProfile()
            }
        } message: {
            Text(String(format: "profiles.delete_confirm".localized, profile.name))
        }
        .sheet(isPresented: $showingEditor) {
            EditProfileSheet(
                profile: profile,
                onSave: { name, label in
                    // Re-read the current profile so a usage refresh that
                    // landed while the sheet was open is not overwritten.
                    guard var current = profileManager.profiles.first(where: { $0.id == profile.id }) else { return }
                    current.name = name
                    current.nameIsCustomized = true
                    current.shortLabel = label
                    profileManager.updateProfile(current)
                },
                onReset: {
                    guard var current = profileManager.profiles.first(where: { $0.id == profile.id }) else { return }
                    current.nameIsCustomized = false
                    current.shortLabel = nil
                    profileManager.updateProfile(current)
                    AutoDetectAccountsService.shared.syncNow()
                }
            )
        }
    }

    private var profileInfo: String {
        var parts: [String] = [profile.sourceDisplayName]

        if profile.isAutoDetected {
            parts.append("profiles.detected_auto".localized)
        }

        if let account = profile.detectedAccountText,
           !profile.name.localizedCaseInsensitiveContains(account) {
            parts.insert(account, at: 1)
        }

        parts.append("profiles.created".localized + " " + profile.createdAt.formatted(date: .abbreviated, time: .omitted))
        return parts.joined(separator: " • ")
    }

    private func deleteProfile() {
        do {
            try profileManager.deleteProfile(profile.id)
        } catch {
            // Error handled by ProfileManager
        }
    }
}

// MARK: - Edit Profile Sheet

struct EditProfileSheet: View {
    let profile: Profile
    let onSave: (String, String?) -> Void
    let onReset: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var shortLabel: String

    init(
        profile: Profile,
        onSave: @escaping (String, String?) -> Void,
        onReset: @escaping () -> Void
    ) {
        self.profile = profile
        self.onSave = onSave
        self.onReset = onReset
        _name = State(initialValue: profile.name)
        _shortLabel = State(initialValue: profile.shortLabel ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                ProviderLogoView(provider: profile.provider, size: 24)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.primary.opacity(0.05)))

                VStack(alignment: .leading, spacing: 3) {
                    Text("profiles.edit_title".localized)
                        .font(.system(size: 17, weight: .semibold))
                    Text(profile.sourceDisplayName)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Text(profile.provider.descriptor.shortName)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.accentColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("profiles.display_name".localized)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                TextField("profiles.display_name".localized, text: $name)
                    .textFieldStyle(.roundedBorder)
                Text("profiles.display_name_hint".localized)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("profiles.menu_bar_label".localized)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                TextField(profile.provider.descriptor.shortName, text: $shortLabel)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: shortLabel) { value in
                        let cleaned = String(value.uppercased().prefix(3))
                        if cleaned != value {
                            shortLabel = cleaned
                        }
                    }
                Text("profiles.menu_bar_label_hint".localized(with: profile.provider.descriptor.shortName))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            if let account = profile.detectedAccountText {
                HStack(spacing: 10) {
                    Image(systemName: "person.crop.circle")
                        .foregroundColor(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("profiles.account".localized)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Text(account)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    if profile.isAutoDetected {
                        Text("profiles.detected_auto".localized)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
            }

            HStack {
                Button("profiles.reset_detected".localized) {
                    onReset()
                    dismiss()
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)

                Spacer()

                Button("common.cancel".localized) {
                    dismiss()
                }
                Button("common.save".localized) {
                    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    let trimmedLabel = shortLabel.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSave(trimmedName, trimmedLabel.isEmpty ? nil : trimmedLabel)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 440)
    }
}

// MARK: - Create Profile Sheet

struct CreateProfileSheet: View {
    @Binding var profileName: String
    @Binding var selectedProvider: Provider
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("profiles.create_title".localized)
                .font(.system(size: 18, weight: .semibold))

            VStack(alignment: .leading, spacing: 8) {
                Text("profiles.name_label".localized)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                TextField("profiles.name_placeholder".localized, text: $profileName)
                    .textFieldStyle(.roundedBorder)

                Text("profiles.name_hint".localized)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("profiles.provider_label".localized)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                // Provider cards from the registry — new providers appear here
                // automatically once registered.
                HStack(spacing: 8) {
                    ForEach(Provider.userCreatable, id: \.self) { provider in
                        ProviderChoiceCard(
                            provider: provider,
                            isSelected: selectedProvider == provider
                        ) {
                            selectedProvider = provider
                        }
                    }
                }

                Text("profiles.provider_hint".localized)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 12) {
                Button("common.cancel".localized) {
                    onCancel()
                }
                .buttonStyle(.plain)

                Button("common.create".localized) {
                    onSave()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 400)
    }
}

/// Selectable provider card used in profile creation and the setup wizard.
struct ProviderChoiceCard: View {
    let provider: Provider
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ProviderLogoView(provider: provider, size: 20)
                Text(provider.descriptor.displayName)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(.primary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : (isHovered ? Color.primary.opacity(0.06) : Color.primary.opacity(0.03)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: isSelected ? 1.5 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

/// Provider mark: asset catalog image when present, SF Symbol fallback otherwise.
struct ProviderLogoView: View {
    let provider: Provider
    var size: CGFloat = 14

    var body: some View {
        if let image = NSImage(named: provider.descriptor.logoAssetName) {
            Image(nsImage: image)
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Image(systemName: provider.descriptor.logoSystemSymbolFallback)
                .font(.system(size: size * 0.85, weight: .medium))
                .frame(width: size, height: size)
        }
    }
}
