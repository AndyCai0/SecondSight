import CoreGraphics
import Foundation

public enum SensitiveTextPolicy {
    public static let fieldKeywords = [
        "password", "passcode", "pin", "one-time code", "verification code", "security code",
        "card", "cvv", "cvc", "account number", "routing number", "bsb",
        "密码", "口令", "验证码", "安全码", "银行卡", "卡号", "账户", "账号",
    ]
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

/// Privacy rules for visible, non-editable content. Password-field protection
/// alone is insufficient because mail, messages, statements, identity records,
/// and health portals normally expose private data as ordinary static text.
public enum StaticPrivacyPolicy {
    private static let privateBundleIdentifiers: Set<String> = [
        "com.apple.AddressBook",
        "com.apple.MobileSMS",
        "com.apple.Photos",
        "com.apple.Preview",
        "com.apple.iCal",
        "com.apple.iChat",
        "com.apple.mail",
        "com.apple.passwords",
        "com.microsoft.Outlook",
        "com.microsoft.teams2",
        "com.tinyspeck.slackmacgap",
        "net.whatsapp.WhatsApp",
        "org.telegram.desktop",
        "org.whispersystems.signal-desktop",
    ]

    private static let privateWindowKeywords = [
        "gmail", "outlook", "inbox", "webmail", "mail -", "messages", "whatsapp", "messenger",
        "telegram", "signal", "slack", "teams", "calendar", "contacts", "passwords", "1password",
        "lastpass", "bitwarden", "bank", "banking", "credit card", "statement", "mygov", "medicare",
        "health", "patient", "medical", "prescription", "tax", "passport", "driver licence",
        "邮箱", "邮件", "收件箱", "信息", "短信", "聊天", "微信", "日历", "通讯录", "密码",
        "银行", "账单", "流水", "转账", "医保", "医疗", "健康", "病历", "处方", "税务",
        "护照", "身份证", "驾驶证",
    ]

    private static let privateTextKeywords = [
        "password", "passcode", "one-time code", "verification code", "security code", "cvv", "cvc",
        "account number", "routing number", "sort code", "bsb", "credit card", "card number",
        "balance", "iban", "swift code", "email address", "phone number", "mobile number",
        "date of birth", "home address", "residential address", "medicare", "passport number",
        "driver licence", "tax file number", "medical record", "diagnosis", "prescription", "patient id",
        "密码", "口令", "验证码", "安全码", "卡号", "银行卡", "账号", "账户号码", "开户行",
        "余额", "邮箱地址", "手机号", "电话号码",
        "出生日期", "家庭住址", "住宅地址", "医保号", "护照号", "身份证号", "驾驶证号",
        "税号", "病历", "诊断", "处方", "患者编号",
    ]
    private static let privateVisualKeywords = [
        "identity", "identity document", "id card", "passport", "driver licence", "medicare",
        "credit card", "bank card", "qr code", "barcode", "medical image", "prescription",
        "身份证", "证件", "护照", "驾驶证", "医保卡", "银行卡", "二维码", "条形码", "处方",
    ]

    private static let emailExpression = try! NSRegularExpression(
        pattern: #"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#,
        options: [.caseInsensitive]
    )
    private static let longNumberExpression = try! NSRegularExpression(
        pattern: #"(?<!\d)(?:\d[ -]?){12,19}(?!\d)"#
    )
    private static let internationalPhoneExpression = try! NSRegularExpression(
        pattern: #"(?<!\w)\+\d(?:[\s().-]?\d){7,14}(?!\d)"#
    )
    private static let australianPhoneExpression = try! NSRegularExpression(
        pattern: #"(?<!\d)0[23478](?:[\s().-]?\d){8}(?!\d)"#
    )
    private static let streetAddressExpression = try! NSRegularExpression(
        pattern: #"(?<!\w)\d{1,5}\s+[A-Z0-9][A-Z0-9 .'-]{1,80}\s(?:STREET|ST|ROAD|RD|AVENUE|AVE|DRIVE|DR|LANE|LN|PLACE|PL|COURT|CT|CRESCENT|CRES|HIGHWAY|HWY|WAY)\b"#,
        options: [.caseInsensitive]
    )
    private static let currencyExpression = try! NSRegularExpression(
        pattern: #"(?:AUD|USD|CNY|RMB|GBP|EUR)\s*[$¥€£]?\s*\d[\d,.]*|[$¥€£]\s*\d[\d,.]*"#,
        options: [.caseInsensitive]
    )

    public static func isPrivateContext(
        applicationName: String?,
        bundleIdentifier: String?,
        windowTitle: String?
    ) -> Bool {
        if let bundleIdentifier, privateBundleIdentifiers.contains(bundleIdentifier) {
            return true
        }
        let context = [applicationName, windowTitle]
            .compactMap { $0 }
            .joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return privateWindowKeywords.contains { context.localizedCaseInsensitiveContains($0) }
    }

    public static func shouldRedactElement(
        role: String,
        hasChildren: Bool,
        inPrivateContext: Bool
    ) -> Bool {
        guard inPrivateContext else { return false }
        switch role {
        case "AXStaticText", "AXImage", "AXLink", "AXCell", "AXRow", "AXListItem", "AXHeading":
            return true
        case "AXWebArea", "AXGroup":
            // Use the container only as a last-resort region when the provider
            // does not expose finer-grained descendants. Normal accessible web
            // pages retain their buttons and chrome while content nodes mask.
            return !hasChildren
        default:
            return false
        }
    }

    /// Only leaf-like content is precise enough to become a direct mask. AX
    /// providers often repeat all page text on AXWebArea, AXScrollArea, or
    /// AXGroup containers; masking those containers would hide the screen
    /// instead of the private value inside it.
    public static func mayDirectlyRedactSensitiveText(
        role: String,
        hasChildren: Bool
    ) -> Bool {
        switch role {
        case "AXStaticText", "AXLink", "AXCell", "AXRow", "AXListItem", "AXHeading":
            return true
        case "AXGroup":
            return !hasChildren
        default:
            return false
        }
    }

    public static func containsSensitiveContent(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let normalized = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        if privateTextKeywords.contains(where: { normalized.localizedCaseInsensitiveContains($0) }) {
            return true
        }
        return matches(emailExpression, in: trimmed)
            || matches(longNumberExpression, in: trimmed)
            || matches(internationalPhoneExpression, in: trimmed)
            || matches(australianPhoneExpression, in: trimmed)
            || matches(streetAddressExpression, in: trimmed)
            || matches(currencyExpression, in: trimmed)
    }

    public static func containsSensitiveVisualDescription(_ text: String) -> Bool {
        let normalized = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return privateVisualKeywords.contains { normalized.localizedCaseInsensitiveContains($0) }
    }

    private static func matches(_ expression: NSRegularExpression, in text: String) -> Bool {
        expression.firstMatch(
            in: text,
            range: NSRange(text.startIndex ..< text.endIndex, in: text)
        ) != nil
    }
}

public enum VisionPrivacyGeometry {
    /// Vision observations use normalized bottom-left coordinates while AX and
    /// the screen redactor use top-left display points.
    public static func topLeftRect(
        forNormalizedBottomLeftRect rect: CGRect,
        displayFramePoints: CGRect
    ) -> CGRect {
        guard !rect.isNull,
              !rect.isEmpty,
              displayFramePoints.width > 0,
              displayFramePoints.height > 0
        else { return .null }
        return CGRect(
            x: displayFramePoints.minX + rect.minX * displayFramePoints.width,
            y: displayFramePoints.minY + (1 - rect.maxY) * displayFramePoints.height,
            width: rect.width * displayFramePoints.width,
            height: rect.height * displayFramePoints.height
        )
    }
}

public enum CapturePrivacyPolicy {
    /// System-owned overlays can contain notifications, clipboard suggestions,
    /// device names, or account status and are never needed by a volunteer.
    public static let excludedBundleIdentifiers: Set<String> = [
        "com.apple.controlcenter",
        "com.apple.dock",
        "com.apple.notificationcenterui",
        "com.apple.systemuiserver",
    ]

    public static func shouldExcludeApplication(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return excludedBundleIdentifiers.contains(bundleIdentifier)
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
        if editableRoles.contains(role) || editableSubroles.contains(subrole) {
            return true
        }
        // Safari and some custom apps report AXEditable on a whole document
        // container. It is metadata about the document, not an input field.
        let aggregateContainerRoles: Set<String> = [
            "AXApplication",
            "AXWindow",
            "AXScrollArea",
            "AXWebArea",
        ]
        return reportsEditable && !aggregateContainerRoles.contains(role)
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
