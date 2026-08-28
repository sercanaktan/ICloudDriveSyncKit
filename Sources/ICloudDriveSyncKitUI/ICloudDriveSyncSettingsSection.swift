import SwiftUI
import ICloudDriveSyncKit

/// Visual styling for `ICloudDriveSyncSettingsSection`. Behavior (thresholds,
/// copy, retry limits) comes from `ICloudDriveSyncConfig`/JSON, since that's
/// meaningfully shareable across apps — colors and fonts aren't (every app's
/// design system is its own thing), so this is a plain Swift struct you fill
/// in once per app, not something loaded from JSON.
///
/// The defaults render a reasonable card out of the box with zero setup;
/// `cardBackground` is the one hook worth overriding to match an existing
/// app's exact card chrome (see the README for a worked example matching
/// TimeNote's `.tnCard()`).
public struct ICloudDriveSyncSectionStyle {
    public var accentColor: Color
    public var primaryTextColor: Color
    public var secondaryTextColor: Color
    public var errorColor: Color
    public var titleFont: Font
    public var valueFont: Font
    public var captionFont: Font
    public var buttonFont: Font
    /// Wraps a card's raw content in whatever chrome your app uses
    /// (background, corner radius, shadow, internal padding, ...).
    public var cardBackground: (AnyView) -> AnyView

    public init(
        accentColor: Color = .accentColor,
        primaryTextColor: Color = .primary,
        secondaryTextColor: Color = .secondary,
        errorColor: Color = .red,
        titleFont: Font = .system(size: 14, weight: .semibold, design: .rounded),
        valueFont: Font = .system(size: 14, weight: .semibold, design: .rounded),
        captionFont: Font = .system(size: 11, weight: .medium, design: .rounded),
        buttonFont: Font = .system(size: 13, weight: .semibold, design: .rounded),
        cardBackground: @escaping (AnyView) -> AnyView = { content in
            AnyView(
                content
                    .padding(15)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            )
        }
    ) {
        self.accentColor = accentColor
        self.primaryTextColor = primaryTextColor
        self.secondaryTextColor = secondaryTextColor
        self.errorColor = errorColor
        self.titleFont = titleFont
        self.valueFont = valueFont
        self.captionFont = captionFont
        self.buttonFont = buttonFont
        self.cardBackground = cardBackground
    }
}

/// A complete, ready-to-embed "iCloud Backup" settings section: an auto-sync
/// toggle, manual Back Up / Restore buttons (surfaced automatically only
/// when they're actually relevant — auto-sync off, or a backup couldn't be
/// restored), last-backup / estimated-size info rows, and — right below Back
/// Up/Restore, so only alongside them — an opt-in Delete Backup button (see
/// `showDeleteBackupOption` on `init`). Drop straight into any settings
/// screen; every string and color is configurable, everything else (loading
/// states, confirmation alerts, error copy) is handled internally.
public struct ICloudDriveSyncSettingsSection: View {
    @ObservedObject private var engine: ICloudDriveSyncEngine
    private let style: ICloudDriveSyncSectionStyle
    private let autoSyncTitle: String
    private let manualBackupTitle: String
    private let manualRestoreTitle: String
    private let lastSyncTitle: String
    private let storageTitle: String
    private let neverSyncedLabel: String
    private let noBackupLabel: String
    private let autoSyncEnabledMessage: String
    private let autoSyncDisabledMessage: String
    private let showDeleteBackupOption: Bool
    private let deleteBackupTitle: String

    @State private var manualAction: ManualAction?
    @State private var manualResult: ManualResult?
    @State private var showRestoreWarning = false
    @State private var showBackupOverwriteWarning = false
    @State private var showDeleteBackupWarning = false

    /// `showDeleteBackupOption` is off by default — an existing embed of
    /// this section (like TimeNote's) gets no UI change at all until a host
    /// opts in explicitly. When `true`, adds a destructive Delete Backup
    /// button directly below Back Up/Restore (so it only ever shows
    /// alongside them — manual-sync mode, or an unrestored-backup state)
    /// that presents its own confirmation alert (sourced from
    /// `engine.messages.deleteBackupConfirmationMessage`) before calling
    /// `engine.deleteBackupManually()` — no extra `@State` or alert code
    /// needed in your own settings screen, same as every other action this
    /// section already handles internally.
    public init(
        engine: ICloudDriveSyncEngine,
        style: ICloudDriveSyncSectionStyle = ICloudDriveSyncSectionStyle(),
        autoSyncTitle: String = "Auto Sync",
        manualBackupTitle: String = "Back Up",
        manualRestoreTitle: String = "Restore",
        lastSyncTitle: String = "Last Backup",
        storageTitle: String = "Estimated Size",
        neverSyncedLabel: String = "Never",
        noBackupLabel: String = "No backup",
        autoSyncEnabledMessage: String = "Automatically backs up with iCloud.",
        autoSyncDisabledMessage: String = "You can manage backups manually.",
        showDeleteBackupOption: Bool = false,
        deleteBackupTitle: String = "Delete Backup"
    ) {
        self.engine = engine
        self.style = style
        self.autoSyncTitle = autoSyncTitle
        self.manualBackupTitle = manualBackupTitle
        self.manualRestoreTitle = manualRestoreTitle
        self.lastSyncTitle = lastSyncTitle
        self.storageTitle = storageTitle
        self.neverSyncedLabel = neverSyncedLabel
        self.noBackupLabel = noBackupLabel
        self.autoSyncEnabledMessage = autoSyncEnabledMessage
        self.autoSyncDisabledMessage = autoSyncDisabledMessage
        self.showDeleteBackupOption = showDeleteBackupOption
        self.deleteBackupTitle = deleteBackupTitle
    }

    private enum ManualAction: Equatable {
        case backup
        case restore
        case delete
    }

    private struct ManualResult {
        let message: String
        let isSuccess: Bool
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            autoSyncCard
        }
        .onAppear {
            Task { await engine.refreshBackupStatus() }
        }
        .alert(manualRestoreTitle, isPresented: $showRestoreWarning) {
            Button("Cancel", role: .cancel) {}
            Button(manualRestoreTitle, role: .destructive) {
                runManualAction(.restore)
            }
        } message: {
            Text(engine.messages.manualRestoreWarning)
        }
        .alert(manualBackupTitle, isPresented: $showBackupOverwriteWarning) {
            Button("Cancel", role: .cancel) {}
            Button(manualBackupTitle, role: .destructive) {
                runManualAction(.backup)
            }
        } message: {
            Text(engine.messages.manualBackupOverwriteWarning)
        }
        .alert(deleteBackupTitle, isPresented: $showDeleteBackupWarning) {
            Button("Cancel", role: .cancel) {}
            Button(deleteBackupTitle, role: .destructive) {
                runManualAction(.delete)
            }
        } message: {
            Text(engine.messages.deleteBackupConfirmationMessage)
        }
    }

    private var isBusy: Bool {
        manualAction != nil || engine.isSyncing
    }

    // MARK: Auto-sync card

    private var autoSyncCard: some View {
        style.cardBackground(AnyView(
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.triangle.2.circlepath.icloud")
                        .font(.system(size: 20, weight: .medium, design: .rounded))
                        .foregroundStyle(style.accentColor)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(autoSyncTitle)
                            .font(style.titleFont)
                            .foregroundStyle(style.primaryTextColor)
                        Text(autoSyncStatusLabel)
                            .font(style.captionFont)
                            .foregroundStyle(style.secondaryTextColor)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { !engine.hasUnrestoredBackup && engine.autoSyncMode != .off },
                        set: { enabled in
                            if enabled, engine.hasUnrestoredBackup {
                                manualResult = ManualResult(message: engine.messages.restoreNeedsWiFiOrOverwrite, isSuccess: false)
                            } else {
                                engine.selectAutoSyncMode(enabled ? .always : .off)
                            }
                        }
                    ))
                    .labelsHidden()
                    .tint(style.accentColor)
                }

                if engine.autoSyncMode == .off || engine.hasUnrestoredBackup {
                    HStack(spacing: 10) {
                        manualButton(title: manualBackupTitle, action: .backup) {
                            if engine.hasUnrestoredBackup {
                                showBackupOverwriteWarning = true
                            } else {
                                runManualAction(.backup)
                            }
                        }
                        manualButton(title: manualRestoreTitle, action: .restore) {
                            showRestoreWarning = true
                        }
                    }

                    // Manual mode only, right below Back Up/Restore — deleting
                    // the backup only makes sense to offer alongside the other
                    // manual actions, never next to the auto-sync toggle alone.
                    if showDeleteBackupOption {
                        deleteBackupButton
                    }
                }

                if engine.syncProgress.isActive {
                    progressStatus
                }

                VStack(spacing: 0) {
                    if let manualResult {
                        statusMessageRow(manualResult)
                    }
                    thinSeparator
                    infoRow(iconName: "clock.arrow.circlepath", title: lastSyncTitle, value: lastSyncLabel)
                    thinSeparator
                    infoRow(iconName: "externaldrive", title: storageTitle, value: storageLabel)
                }
                .padding(.bottom, -6)
            }
        ))
    }

    private var progressStatus: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(progressTitle)
                    .font(style.captionFont)
                    .foregroundStyle(style.secondaryTextColor)
                Spacer()
                if let percent = engine.syncProgress.percentCompleted {
                    Text("\(percent)%")
                        .font(style.captionFont)
                        .foregroundStyle(style.accentColor)
                }
            }

            if let fraction = engine.syncProgress.fractionCompleted {
                ProgressView(value: fraction)
                    .tint(style.accentColor)
                    .progressViewStyle(.linear)
            } else {
                ProgressView()
                    .tint(style.accentColor)
                    .progressViewStyle(.linear)
            }
        }
    }

    // MARK: Delete backup button

    private var deleteBackupButton: some View {
        Button {
            showDeleteBackupWarning = true
        } label: {
            HStack(spacing: 7) {
                if manualAction == .delete {
                    ProgressView()
                        .tint(style.errorColor)
                        .scaleEffect(0.72)
                }
                Text(manualAction == .delete ? "\(deleteBackupTitle)…" : deleteBackupTitle)
                    .font(style.buttonFont)
            }
            .foregroundStyle(style.errorColor)
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background(style.errorColor.opacity(0.10), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .opacity(isBusy && manualAction != .delete ? 0.55 : 1)
    }

    private func manualButton(title: String, action: ManualAction, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: 7) {
                if manualAction == action {
                    ProgressView()
                        .tint(style.accentColor)
                        .scaleEffect(0.72)
                }
                Text(manualAction == action ? loadingTitle(for: action) : title)
                    .font(style.buttonFont)
            }
            .foregroundStyle(style.accentColor)
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background(style.accentColor.opacity(0.10), in: Capsule())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .disabled(isBusy)
        .opacity(isBusy && manualAction != action ? 0.55 : 1)
    }

    private func loadingTitle(for action: ManualAction) -> String {
        switch action {
        case .backup: return "\(manualBackupTitle)…"
        case .restore: return "\(manualRestoreTitle)…"
        case .delete: return "\(deleteBackupTitle)…"
        }
    }

    private func runManualAction(_ action: ManualAction) {
        guard !isBusy else { return }
        manualResult = nil
        manualAction = action
        Task {
            switch action {
            case .backup:
                await engine.syncManually()
            case .restore:
                await engine.restoreManually()
            case .delete:
                await engine.deleteBackupManually()
            }
            let message = engine.syncMessage ?? defaultSuccessMessage(for: action)
            manualResult = ManualResult(message: message, isSuccess: engine.syncOutcome.isSuccess)
            manualAction = nil
        }
    }

    private func defaultSuccessMessage(for action: ManualAction) -> String {
        switch action {
        case .backup: return engine.messages.syncedMessage
        case .restore: return engine.messages.restoredMessage
        case .delete: return engine.messages.deleteBackupSucceededMessage
        }
    }

    private var autoSyncStatusLabel: String {
        if engine.hasUnrestoredBackup {
            return engine.messages.restoreNeedsWiFiOrOverwrite
        }
        return engine.autoSyncMode == .off
            ? autoSyncDisabledMessage
            : autoSyncEnabledMessage
    }

    private var progressTitle: String {
        let progress = engine.syncProgress
        let countSuffix: String
        if let total = progress.totalUnitCount, total > 0 {
            countSuffix = " \(progress.completedUnitCount)/\(total)"
        } else {
            countSuffix = ""
        }

        switch progress.phase {
        case .checkingBackup:
            return "Checking backup\(countSuffix)"
        case .waitingForNetwork:
            return "Waiting for iCloud\(countSuffix)"
        case .downloadingEnvelope, .downloadingManifest:
            return "Downloading backup\(countSuffix)"
        case .downloadingItems:
            return "Downloading items\(countSuffix)"
        case .downloadingPreferences:
            return "Downloading preferences\(countSuffix)"
        case .applyingRestore:
            return "Restoring data\(countSuffix)"
        case .uploadingItems:
            return "Uploading items\(countSuffix)"
        case .uploadingManifest, .uploadingEnvelope:
            return "Uploading backup\(countSuffix)"
        case .uploadingPreferences:
            return "Uploading preferences\(countSuffix)"
        case .deletingBackup:
            return "Deleting backup\(countSuffix)"
        case .refreshingStatus:
            return "Refreshing status\(countSuffix)"
        case .idle, .finished, .failed:
            return ""
        }
    }

    // MARK: Status and backup info rows

    private var thinSeparator: some View {
        Rectangle()
            .fill(style.secondaryTextColor.opacity(0.16))
            .frame(height: 0.5)
    }

    private func statusMessageRow(_ result: ManualResult) -> some View {
        HStack(spacing: 8) {
            Image(systemName: result.isSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(result.isSuccess ? style.accentColor : style.errorColor)
            Text("\(result.isSuccess ? "Success" : "Fail"): \(result.message)")
                .font(style.captionFont)
                .foregroundStyle(result.isSuccess ? style.accentColor : style.errorColor)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 9)
    }

    private func infoRow(iconName: String, title: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(style.secondaryTextColor)
                .frame(width: 22)
            Text(title)
                .font(style.captionFont)
                .foregroundStyle(style.secondaryTextColor)
            Spacer()
            Text(value)
                .font(style.captionFont)
                .foregroundStyle(style.secondaryTextColor)
                .multilineTextAlignment(.trailing)
        }
        .frame(height: 34)
    }

    private var lastSyncLabel: String {
        guard let date = engine.lastSyncAt else { return neverSyncedLabel }
        return date.formatted(date: .numeric, time: .shortened)
    }

    private var storageLabel: String {
        guard engine.backupByteCount > 0 else { return noBackupLabel }
        return ByteCountFormatter.string(fromByteCount: engine.backupByteCount, countStyle: .file)
    }
}
