import Foundation
import XCTest
@testable import SecondSightCore

final class FastRiskDetectorTests: XCTestCase {
    func testRequestedDemoPhrases() {
        let cases: [(String, RiskLevel)] = [
            ("Can you open the settings page?", .safe),
            ("Please tell me the verification code you just received.", .danger),
            ("Transfer five hundred dollars to this bank account.", .danger),
            ("You need to install AnyDesk so I can control your computer.", .danger),
        ]

        for (transcript, expectedLevel) in cases {
            XCTAssertEqual(
                FastRiskDetector.detect(transcript: transcript).level,
                expectedLevel,
                transcript
            )
        }
    }

    func testSensitiveRequestHasExplainableRules() {
        let result = FastRiskDetector.detect(
            transcript: "Please tell me the verification code you just received."
        )

        XCTAssertEqual(result.level, .danger)
        XCTAssertTrue(result.matchedRules.contains("verification_code"))
        XCTAssertTrue(result.matchedRules.contains("request_sensitive_information"))
        XCTAssertFalse(result.message.isEmpty)
    }

    func testChineseCombinationRules() {
        let result = FastRiskDetector.detect(transcript: "请把刚收到的验证码告诉我，然后转账到这个银行卡。")

        XCTAssertEqual(result.level, .danger)
        XCTAssertTrue(result.matchedRules.contains("verification_code"))
        XCTAssertTrue(result.matchedRules.contains("money_transfer_request"))
    }

    func testEveryRequiredEnglishAndChineseConceptIsRecognized() {
        let phrases = [
            "verification code", "OTP", "password", "PIN", "bank account", "credit card", "CVV",
            "transfer money", "send money", "gift card", "crypto", "install software", "remote access",
            "AnyDesk", "TeamViewer", "screen sharing", "验证码", "密码", "银行卡", "信用卡", "转账",
            "汇款", "礼品卡", "加密货币", "安装软件", "远程控制", "共享屏幕",
        ]

        for phrase in phrases {
            XCTAssertNotEqual(FastRiskDetector.detect(transcript: phrase).level, .safe, phrase)
        }
    }

    func testRecentContextCanCompleteAMultiTurnRisk() {
        let result = FastRiskDetector.detect(
            transcript: "Tell me that code.",
            recentTranscript: ["You should receive a verification code."]
        )

        XCTAssertEqual(result.level, .danger)
        XCTAssertTrue(result.matchedRules.contains("request_sensitive_information"))
    }
}

final class RiskEventDeduplicatorTests: XCTestCase {
    func testGrowingPartialsOnlyEmitOneEventForTheSameFingerprint() {
        var deduplicator = RiskEventDeduplicator(cooldown: 8)
        let start = Date(timeIntervalSince1970: 1_000)

        let first = FastRiskDetector.detect(transcript: "tell me the verification code")
        let second = FastRiskDetector.detect(transcript: "tell me the verification code you received")

        XCTAssertTrue(deduplicator.shouldEmit(first, transcript: "tell me the verification code", at: start))
        XCTAssertFalse(deduplicator.shouldEmit(second, transcript: "tell me the verification code you received", at: start.addingTimeInterval(2)))
        XCTAssertTrue(deduplicator.shouldEmit(second, transcript: "tell me the verification code you received", at: start.addingTimeInterval(9)))
    }

    func testNewDangerFingerprintCanEmitDuringCooldown() {
        var deduplicator = RiskEventDeduplicator(cooldown: 8)
        let start = Date(timeIntervalSince1970: 1_000)
        let codeRisk = FastRiskDetector.detect(transcript: "tell me the verification code")
        let transferRisk = FastRiskDetector.detect(transcript: "transfer money to this bank account")

        XCTAssertTrue(deduplicator.shouldEmit(codeRisk, transcript: "tell me the verification code", at: start))
        XCTAssertTrue(deduplicator.shouldEmit(transferRisk, transcript: "transfer money to this bank account", at: start.addingTimeInterval(2)))
    }
}

final class RecentTranscriptBufferTests: XCTestCase {
    func testKeepsOnlyTheRecentWindowAndCapsEntries() {
        var buffer = RecentTranscriptBuffer(window: 25, maximumEntries: 3)
        let start = Date(timeIntervalSince1970: 1_000)

        buffer.append("too old", at: start)
        buffer.append("first", at: start.addingTimeInterval(10))
        buffer.append("second", at: start.addingTimeInterval(20))
        buffer.append("third", at: start.addingTimeInterval(30))

        XCTAssertEqual(buffer.transcripts(at: start.addingTimeInterval(31)), ["first", "second", "third"])
        XCTAssertEqual(buffer.transcripts(at: start.addingTimeInterval(36)), ["second", "third"])
    }
}

final class RiskPipelineTests: XCTestCase {
    func testNoopAIAnalyzerDoesNotChangeFastDecision() async {
        let pipeline = RiskPipeline(contextAnalyzer: NoopRiskContextAnalyzer())
        let result = await pipeline.analyze(
            transcript: "Please tell me the verification code.",
            recentTranscript: []
        )

        XCTAssertEqual(result.level, .danger)
    }
}
