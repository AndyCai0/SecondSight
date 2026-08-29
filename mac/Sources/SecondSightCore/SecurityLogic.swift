import CoreGraphics
import Foundation

public enum SensitiveTextPolicy {
    public static let fieldKeywords = ["password", "密码", "pin", "验证码", "card", "cvv"]
    public static let freezeKeywords = ["验证码", "密码", "转账", "汇款", "礼品卡"]

    public static func isSensitiveField(label: String) -> Bool {
        let normalized = label.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return fieldKeywords.contains { normalized.localizedCaseInsensitiveContains($0) }
    }

    public static func localFreezeReason(for transcript: String) -> String? {
        guard let keyword = freezeKeywords.first(where: { transcript.localizedCaseInsensitiveContains($0) }) else { return nil }
        return "检测到敏感词：\(keyword)"
    }
}

public enum InputPrivacyPolicy {
    private static let editableRoles: Set<String> = [
        "AXTextField",
        "AXTextArea",
        "AXComboBox",
    ]
    private static let editableSubroles: Set<String> = [
        "AXSearchField",
        "AXSecureTextField",
    ]
    private static let suggestionSurfaceRoles: Set<String> = [
        "AXDialog",
        "AXList",
        "AXMenu",
        "AXPopover",
        "AXSheet",
        "AXWindow",
    ]

    public static func isEditable(role: String, subrole: String, reportsEditable: Bool) -> Bool {
        reportsEditable || editableRoles.contains(role) || editableSubroles.contains(subrole)
    }

    public static func shouldRedactEditable(
        role: String,
        subrole: String,
        reportsEditable: Bool,
        isFocused: Bool,
        hasNonEmptyValue: Bool
    ) -> Bool {
        guard isEditable(role: role, subrole: subrole, reportsEditable: reportsEditable) else { return false }
        return subrole == "AXSecureTextField" || isFocused || hasNonEmptyValue
    }

    public static func isSuggestionSurface(role: String) -> Bool {
        suggestionSurfaceRoles.contains(role)
    }

    public static func shouldRedactSuggestionSurface(
        _ surfaceFrame: CGRect,
        near focusedInputFrame: CGRect
    ) -> Bool {
        guard !surfaceFrame.isNull,
              !surfaceFrame.isEmpty,
              !focusedInputFrame.isNull,
              !focusedInputFrame.isEmpty
        else { return false }

        // Password managers and browser autofill panels are normally small,
        // transient surfaces anchored to the active input. Reject the main
        // application window while still covering the nearby popup as a unit.
        let maximumWidth = max(720, focusedInputFrame.width * 2.5)
        let maximumHeight = max(480, focusedInputFrame.height * 12)
        guard surfaceFrame.width <= maximumWidth, surfaceFrame.height <= maximumHeight else { return false }

        let horizontalReach = max(220, focusedInputFrame.width)
        let verticalReach = max(360, focusedInputFrame.height * 10)
        let vicinity = focusedInputFrame.insetBy(dx: -horizontalReach, dy: -verticalReach)
        return vicinity.intersects(surfaceFrame)
    }

    public static func fallbackSuggestionFrame(under focusedInputFrame: CGRect) -> CGRect {
        guard !focusedInputFrame.isNull, !focusedInputFrame.isEmpty else { return .null }
        return CGRect(
            x: focusedInputFrame.minX,
            y: focusedInputFrame.maxY,
            width: max(520, focusedInputFrame.width),
            height: max(180, focusedInputFrame.height * 3)
        ).integral
    }
}

public struct CaptureGeometry: Equatable, Sendable {
    public let displayFramePoints: CGRect
    public let frameSizePixels: CGSize

    public init(displayFramePoints: CGRect, frameSizePixels: CGSize) {
        self.displayFramePoints = displayFramePoints
        self.frameSizePixels = frameSizePixels
    }

    public func pixelRect(forAXTopLeftRect rect: CGRect, marginPixels: CGFloat = 8) -> CGRect {
        guard displayFramePoints.width > 0, displayFramePoints.height > 0 else { return .null }
        let scaleX = frameSizePixels.width / displayFramePoints.width
        let scaleY = frameSizePixels.height / displayFramePoints.height
        let localX = (rect.minX - displayFramePoints.minX) * scaleX
        let localY = (rect.minY - displayFramePoints.minY) * scaleY
        let converted = CGRect(x: localX, y: localY, width: rect.width * scaleX, height: rect.height * scaleY)
            .insetBy(dx: -marginPixels, dy: -marginPixels)
        return converted.intersection(CGRect(origin: .zero, size: frameSizePixels)).integral
    }
}

public enum ImageSizing {
    public static func fittedSize(width: Int, height: Int, maximumLongEdge: Int = 1_568) -> (width: Int, height: Int) {
        guard width > 0, height > 0, maximumLongEdge > 0 else { return (0, 0) }
        let longEdge = max(width, height)
        guard longEdge > maximumLongEdge else { return (width, height) }
        let scale = Double(maximumLongEdge) / Double(longEdge)
        return (max(1, Int((Double(width) * scale).rounded())), max(1, Int((Double(height) * scale).rounded())))
    }
}
