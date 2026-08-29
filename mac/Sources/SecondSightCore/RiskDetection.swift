import Foundation

public enum RiskLevel: String, Codable, Equatable, Sendable {
    case safe
    case warning
    case danger
}

public struct RiskDetectionResult: Codable, Equatable, Sendable {
    public let level: RiskLevel
    public let matchedRules: [String]
    public let message: String

    public init(level: RiskLevel, matchedRules: [String], message: String) {
        self.level = level
        self.matchedRules = matchedRules
        self.message = message
    }
}

public enum FastRiskDetector {
    private struct TextView {
        let normalized: String
        let tokens: Set<String>

        init(_ text: String) {
            let folded = text
                .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
                .lowercased()
            normalized = folded
                .split { !$0.isLetter && !$0.isNumber }
                .joined(separator: " ")
            tokens = Set(normalized.split(separator: " ").map(String.init))
        }

        func contains(phrase: String) -> Bool {
            let candidate = TextView.normalizePhrase(phrase)
            if candidate.contains(where: { $0.isWhitespace }) {
                return " \(normalized) ".contains(" \(candidate) ")
            }
            if candidate.containsCJK {
                return normalized.contains(candidate)
            }
            return tokens.contains(candidate)
        }

        func contains(any phrases: [String]) -> Bool {
            phrases.contains(where: contains(phrase:))
        }

        private static func normalizePhrase(_ phrase: String) -> String {
            phrase
                .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
                .lowercased()
                .split { !$0.isLetter && !$0.isNumber }
                .joined(separator: " ")
        }
    }

    private struct KeywordRule {
        let id: String
        let phrases: [String]
    }

    private static let keywordRules: [KeywordRule] = [
        .init(id: "verification_code", phrases: ["verification code", "security code", "验证码"]),
        .init(id: "otp", phrases: ["otp", "one time password", "one time code", "一次性密码"]),
        .init(id: "password", phrases: ["password", "passcode", "密码"]),
        .init(id: "pin", phrases: ["pin", "personal identification number"]),
        .init(id: "bank_account", phrases: ["bank account", "banking details", "银行卡", "银行账户", "银行账号"]),
        .init(id: "credit_card", phrases: ["credit card", "card number", "信用卡"]),
        .init(id: "cvv", phrases: ["cvv", "cvc", "security digits"]),
        .init(id: "gift_card", phrases: ["gift card", "礼品卡"]),
        .init(id: "crypto", phrases: ["crypto", "cryptocurrency", "bitcoin", "加密货币", "比特币"]),
        .init(id: "install_software", phrases: ["install software", "install an app", "download software", "安装软件", "安装应用"]),
        .init(id: "remote_access", phrases: ["remote access", "remote control", "远程访问", "远程控制"]),
        .init(id: "anydesk", phrases: ["anydesk"]),
        .init(id: "teamviewer", phrases: ["teamviewer"]),
        .init(id: "screen_sharing", phrases: ["screen sharing", "share your screen", "共享屏幕", "屏幕共享"]),
    ]

    private static let sensitiveRuleIDs: Set<String> = [
        "verification_code", "otp", "password", "pin", "bank_account", "credit_card", "cvv",
    ]

    private static let financialRuleIDs: Set<String> = [
        "bank_account", "credit_card", "gift_card", "crypto",
    ]

    private static let requestPhrases = [
        "tell me", "tell us", "send me", "send us", "give me", "give us", "share it", "share your",
        "read it", "read out", "provide", "what is", "show me", "告诉我", "发给我", "给我", "提供",
        "念给我", "读给我", "说出", "分享",
    ]

    private static let moneyActionPhrases = [
        "transfer money", "send money", "wire money", "make a transfer", "转账", "汇款", "打款",
    ]

    private static let remoteActionPhrases = [
        "install", "download", "run", "control your", "control the", "connect remotely", "give me access",
        "安装", "下载", "控制你的", "控制电脑", "允许远程", "开启远程",
    ]

    private static let paymentActionPhrases = [
        "buy", "purchase", "pay with", "send", "transfer", "wire", "购买", "付款", "支付", "转账", "汇款",
    ]

    public static func detect(
        transcript: String,
        recentTranscript: [String] = []
    ) -> RiskDetectionResult {
        let current = TextView(transcript)
        guard !current.normalized.isEmpty else {
            return .init(level: .safe, matchedRules: [], message: "")
        }

        let contextText = (recentTranscript + [transcript]).joined(separator: " ")
        let context = TextView(contextText)
        var matched = Set<String>()

        for rule in keywordRules where context.contains(any: rule.phrases) {
            matched.insert(rule.id)
        }

        let hasSensitiveContext = !matched.isDisjoint(with: sensitiveRuleIDs)
        let requestsInformation = current.contains(any: requestPhrases)
        if hasSensitiveContext && requestsInformation {
            matched.insert("request_sensitive_information")
        }

        let hasFinancialContext = !matched.isDisjoint(with: financialRuleIDs)
        let explicitMoneyAction = current.contains(any: moneyActionPhrases)
        let genericTransfer = current.tokens.contains("transfer") || current.tokens.contains("send")
        let mentionsAmount = current.tokens.contains("dollar") || current.tokens.contains("dollars") ||
            current.tokens.contains("money") || current.normalized.contains("元")
        if explicitMoneyAction || (genericTransfer && (hasFinancialContext || mentionsAmount)) {
            matched.insert("money_transfer_request")
        }

        let hasRemoteTool = matched.contains("anydesk") || matched.contains("teamviewer")
        let hasRemoteContext = hasRemoteTool || matched.contains("remote_access") || matched.contains("screen_sharing") || matched.contains("install_software")
        if hasRemoteContext && current.contains(any: remoteActionPhrases) {
            matched.insert("remote_control_request")
        }

        let hasAlternativePayment = matched.contains("gift_card") || matched.contains("crypto")
        if hasAlternativePayment && current.contains(any: paymentActionPhrases) {
            matched.insert("alternative_payment_request")
        }

        let dangerRules: Set<String> = [
            "request_sensitive_information",
            "money_transfer_request",
            "remote_control_request",
            "alternative_payment_request",
        ]
        let isDanger = !matched.isDisjoint(with: dangerRules)

        if isDanger {
            return .init(
                level: .danger,
                matchedRules: matched.sorted(),
                message: "Someone may be asking for sensitive information or a risky action."
            )
        }

        if !matched.isEmpty {
            return .init(
                level: .warning,
                matchedRules: matched.sorted(),
                message: "Sensitive information or remote access was mentioned."
            )
        }

        return .init(level: .safe, matchedRules: [], message: "")
    }
}

private extension String {
    var containsCJK: Bool {
        unicodeScalars.contains { scalar in
            (0x3400...0x4DBF).contains(scalar.value) ||
                (0x4E00...0x9FFF).contains(scalar.value)
        }
    }
}

public struct RiskEventDeduplicator: Sendable {
    public let cooldown: TimeInterval
    private var lastEmittedAt: [String: Date] = [:]

    public init(cooldown: TimeInterval = 8) {
        self.cooldown = max(0, cooldown)
    }

    public mutating func shouldEmit(
        _ result: RiskDetectionResult,
        transcript _: String,
        eventID: String? = nil,
        at date: Date = Date()
    ) -> Bool {
        guard result.level != .safe else { return false }

        lastEmittedAt = lastEmittedAt.filter { date.timeIntervalSince($0.value) <= cooldown }
        let riskFingerprint = Self.fingerprint(for: result)
        // AssemblyAI keeps one turn_order while an interim transcript grows. Use that stable
        // event identity when available so newly matched words cannot bypass the cooldown.
        let fingerprint = eventID.map { "streaming-event:\($0)" } ?? riskFingerprint
        if let previous = lastEmittedAt[fingerprint], date.timeIntervalSince(previous) < cooldown {
            return false
        }
        lastEmittedAt[fingerprint] = date
        return true
    }

    public static func fingerprint(for result: RiskDetectionResult) -> String {
        ([result.level.rawValue] + result.matchedRules.sorted()).joined(separator: ":")
    }
}

public struct RecentTranscriptBuffer: Sendable {
    private struct Entry: Sendable {
        let transcript: String
        let timestamp: Date
    }

    public let window: TimeInterval
    public let maximumEntries: Int
    private var entries: [Entry] = []

    public init(window: TimeInterval = 25, maximumEntries: Int = 40) {
        self.window = max(1, window)
        self.maximumEntries = max(1, maximumEntries)
    }

    public mutating func append(_ transcript: String, at date: Date = Date()) {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        entries.append(.init(transcript: trimmed, timestamp: date))
        prune(at: date)
    }

    public mutating func transcripts(at date: Date = Date()) -> [String] {
        prune(at: date)
        return entries.map(\.transcript)
    }

    private mutating func prune(at date: Date) {
        let cutoff = date.addingTimeInterval(-window)
        entries.removeAll { $0.timestamp < cutoff }
        if entries.count > maximumEntries {
            entries.removeFirst(entries.count - maximumEntries)
        }
    }
}

public struct RiskContextInput: Equatable, Sendable {
    public let transcript: String
    public let recentTranscript: [String]
    public let currentContext: [String: String]

    public init(
        transcript: String,
        recentTranscript: [String],
        currentContext: [String: String] = [:]
    ) {
        self.transcript = transcript
        self.recentTranscript = recentTranscript
        self.currentContext = currentContext
    }
}

public protocol RiskContextAnalyzing: Sendable {
    func analyzeContextWithAI(_ input: RiskContextInput) async -> RiskDetectionResult?
}

public struct NoopRiskContextAnalyzer: RiskContextAnalyzing {
    public init() {}

    public func analyzeContextWithAI(_: RiskContextInput) async -> RiskDetectionResult? {
        nil
    }
}

public struct RiskPipeline: Sendable {
    private let contextAnalyzer: any RiskContextAnalyzing

    public init(contextAnalyzer: any RiskContextAnalyzing = NoopRiskContextAnalyzer()) {
        self.contextAnalyzer = contextAnalyzer
    }

    public func analyze(
        transcript: String,
        recentTranscript: [String],
        currentContext: [String: String] = [:]
    ) async -> RiskDetectionResult {
        let fastDecision = FastRiskDetector.detect(
            transcript: transcript,
            recentTranscript: recentTranscript
        )

        guard fastDecision.level == .warning else { return fastDecision }
        let input = RiskContextInput(
            transcript: transcript,
            recentTranscript: recentTranscript,
            currentContext: currentContext
        )
        return await contextAnalyzer.analyzeContextWithAI(input) ?? fastDecision
    }
}
