import Foundation

public enum PermissionPromptWindowPolicy {
    public static let systemPromptBundleIdentifier =
        "com.apple.accessibility.universalAccessAuthWarn"

    public static func mayUseWindow(
        bundleIdentifier: String?,
        wasVisibleBeforeRequest: Bool
    ) -> Bool {
        !wasVisibleBeforeRequest || bundleIdentifier == systemPromptBundleIdentifier
    }
}

public enum PermissionSettingsGuideLayout {
    public static let panelSize = CGSize(width: 460, height: 190)
    public static let arrowTipTrailingInset: CGFloat = 52

    public static func panelFrame(
        systemSettingsFrame: CGRect,
        appRowFrame: CGRect?,
        switchFrame: CGRect?,
        visibleScreenFrame: CGRect
    ) -> CGRect {
        let target = switchTarget(
            systemSettingsFrame: systemSettingsFrame,
            appRowFrame: appRowFrame,
            switchFrame: switchFrame
        )
        let desiredOrigin = CGPoint(
            x: target.x - (panelSize.width - arrowTipTrailingInset),
            y: target.y + 8
        )

        let maximumX = max(visibleScreenFrame.minX, visibleScreenFrame.maxX - panelSize.width)
        let maximumY = max(visibleScreenFrame.minY, visibleScreenFrame.maxY - panelSize.height)
        let origin = CGPoint(
            x: min(max(desiredOrigin.x, visibleScreenFrame.minX), maximumX),
            y: min(max(desiredOrigin.y, visibleScreenFrame.minY), maximumY)
        )
        return CGRect(origin: origin, size: panelSize)
    }

    public static func switchTarget(
        systemSettingsFrame: CGRect,
        appRowFrame: CGRect?,
        switchFrame: CGRect?
    ) -> CGPoint {
        let rowFrame = appRowFrame.flatMap { candidate in
            candidate.intersects(systemSettingsFrame) ? candidate : nil
        }
        if let switchFrame, switchFrame.intersects(systemSettingsFrame) {
            return CGPoint(x: switchFrame.midX, y: switchFrame.midY)
        }
        return CGPoint(
            x: systemSettingsFrame.maxX - min(72, systemSettingsFrame.width * 0.065),
            y: rowFrame?.midY ?? systemSettingsFrame.minY + systemSettingsFrame.height * 0.45
        )
    }
}
