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
