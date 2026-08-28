import SwiftUI
import ICloudDriveSyncKit

public struct ICloudDriveInitialRestoreOverlayStyle {
    public var accentColor: Color
    public var primaryTextColor: Color
    public var secondaryTextColor: Color
    public var dimColor: Color
    public var borderColor: Color
    public var titleFont: Font
    public var captionFont: Font
    public var percentFont: Font
    public var width: CGFloat
    public var cornerRadius: CGFloat

    public init(
        accentColor: Color = .accentColor,
        primaryTextColor: Color = .primary,
        secondaryTextColor: Color = .secondary,
        dimColor: Color = .black.opacity(0.08),
        borderColor: Color = .primary.opacity(0.08),
        titleFont: Font = .system(size: 14, weight: .semibold, design: .rounded),
        captionFont: Font = .system(size: 11, weight: .regular, design: .rounded),
        percentFont: Font = .system(size: 13, weight: .semibold, design: .rounded),
        width: CGFloat = 310,
        cornerRadius: CGFloat = 12
    ) {
        self.accentColor = accentColor
        self.primaryTextColor = primaryTextColor
        self.secondaryTextColor = secondaryTextColor
        self.dimColor = dimColor
        self.borderColor = borderColor
        self.titleFont = titleFont
        self.captionFont = captionFont
        self.percentFont = percentFont
        self.width = width
        self.cornerRadius = cornerRadius
    }
}

public struct ICloudDriveInitialRestoreOverlay: View {
    @ObservedObject private var engine: ICloudDriveSyncEngine
    private let style: ICloudDriveInitialRestoreOverlayStyle
    private let fallbackTitle: String
    private let itemLabel: String

    public init(
        engine: ICloudDriveSyncEngine,
        style: ICloudDriveInitialRestoreOverlayStyle = ICloudDriveInitialRestoreOverlayStyle(),
        fallbackTitle: String = "Restoring data from iCloud",
        itemLabel: String = "items"
    ) {
        self.engine = engine
        self.style = style
        self.fallbackTitle = fallbackTitle
        self.itemLabel = itemLabel
    }

    public var body: some View {
        ZStack {
            style.dimColor
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    ProgressView()
                        .tint(style.accentColor)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(engine.syncMessage ?? progressTitle)
                            .font(style.titleFont)
                            .foregroundStyle(style.primaryTextColor)
                        Text(progressTitle)
                            .font(style.captionFont)
                            .foregroundStyle(style.secondaryTextColor)
                    }
                    if let percent = progress.percentCompleted {
                        Spacer(minLength: 12)
                        Text("\(percent)%")
                            .font(style.percentFont)
                            .foregroundStyle(style.accentColor)
                    }
                }

                if let fraction = progress.fractionCompleted {
                    ProgressView(value: fraction)
                        .tint(style.accentColor)
                        .progressViewStyle(.linear)
                } else {
                    ProgressView()
                        .tint(style.accentColor)
                        .progressViewStyle(.linear)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .frame(width: style.width, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
                    .stroke(style.borderColor, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.14), radius: 16, y: 8)
        }
        .contentShape(Rectangle())
    }

    private var progress: ICloudDriveSyncProgress {
        engine.syncProgress
    }

    private var progressTitle: String {
        let countSuffix: String
        if let total = progress.totalUnitCount, total > 0 {
            countSuffix = " \(progress.completedUnitCount)/\(total)"
        } else {
            countSuffix = ""
        }

        switch progress.phase {
        case .checkingBackup:
            return "Checking iCloud backup\(countSuffix)"
        case .waitingForNetwork:
            return "Waiting for iCloud\(countSuffix)"
        case .downloadingEnvelope, .downloadingManifest:
            return "Downloading backup\(countSuffix)"
        case .downloadingItems:
            return "Downloading \(itemLabel)\(countSuffix)"
        case .downloadingPreferences:
            return "Downloading preferences\(countSuffix)"
        case .applyingRestore:
            return "Restoring data\(countSuffix)"
        case .uploadingItems:
            return "Uploading \(itemLabel)\(countSuffix)"
        case .uploadingManifest, .uploadingEnvelope:
            return "Uploading backup\(countSuffix)"
        case .uploadingPreferences:
            return "Uploading preferences\(countSuffix)"
        case .deletingBackup:
            return "Deleting backup\(countSuffix)"
        case .refreshingStatus:
            return "Refreshing iCloud status\(countSuffix)"
        case .idle, .finished, .failed:
            return fallbackTitle
        }
    }
}
