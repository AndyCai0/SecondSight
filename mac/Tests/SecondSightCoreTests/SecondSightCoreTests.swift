import CoreGraphics
import Foundation
import XCTest
@testable import SecondSightCore

final class SessionStateTests: XCTestCase {
    func testHappyPathAndFreezeResume() throws {
        var machine = SessionStateMachine()
        XCTAssertEqual(try machine.apply(.requestHelp), .requesting)
        XCTAssertEqual(try machine.apply(.sessionCreated), .waiting)
        XCTAssertEqual(try machine.apply(.volunteerJoined), .connected)
        XCTAssertEqual(try machine.apply(.freeze), .frozen)
        XCTAssertEqual(try machine.apply(.resume), .connected)
        XCTAssertEqual(try machine.apply(.end), .ended)
        XCTAssertEqual(try machine.apply(.reset), .idle)
    }

    func testInvalidTransitionIsRejected() {
        var machine = SessionStateMachine()
        XCTAssertThrowsError(try machine.apply(.resume))
        XCTAssertEqual(machine.phase, .idle)
    }
}

final class ContractTests: XCTestCase {
    func testCreateSessionContractKeys() throws {
        let json = #"{"session_id":"9D1D5434-6DA5-41E0-AF70-C5AA35C6816F","code":"482913","lk_url":"wss://demo.livekit.cloud","lk_token":"jwt"}"#.data(using: .utf8)!
        let response = try JSONDecoder().decode(CreateSessionResponse.self, from: json)
        XCTAssertEqual(response.code, "482913")
        XCTAssertEqual(response.liveKitToken, "jwt")
    }

    func testGuideTargetRectContractKeys() throws {
        let json = #"{"instruction_text":"请点登录","target_rect":{"x":0.8,"y":0.1,"w":0.1,"h":0.05},"confidence":0.9}"#.data(using: .utf8)!
        let response = try JSONDecoder().decode(AIGuideResponse.self, from: json)
        XCTAssertEqual(response.targetRect?.width, 0.1)
        XCTAssertEqual(response.instructionText, "请点登录")
    }

    func testAssemblyAIStreamingCredentialUsesServerContractKeys() throws {
        let json = #"{"token":"temporary","expires_in_seconds":60,"max_session_duration_seconds":3600}"#.data(using: .utf8)!
        let credential = try JSONDecoder().decode(AssemblyAIStreamingCredential.self, from: json)

        XCTAssertEqual(credential.token, "temporary")
        XCTAssertEqual(credential.expiresInSeconds, 60)
        XCTAssertEqual(credential.maxSessionDurationSeconds, 3_600)
    }
}

final class DataMessageTests: XCTestCase {
    func testVolunteerControlMessageIsRejected() {
        let data = #"{"v":1,"type":"control.freeze","reason":"假的"}"#.data(using: .utf8)!
        XCTAssertThrowsError(try DataMessageCodec.decode(data, senderIdentity: "volunteer:小王")) { error in
            XCTAssertEqual(error as? DataMessageError, .forbiddenVolunteerControl)
        }
    }

    func testCircleParsesAndValidatesUnits() throws {
        let data = #"{"v":1,"type":"annotate.circle","id":"a1","x":0.42,"y":0.31,"r":0.05,"ttl_ms":6000}"#.data(using: .utf8)!
        XCTAssertEqual(try DataMessageCodec.decode(data, senderIdentity: "volunteer:小王"), .circle(id: "a1", x: 0.42, y: 0.31, radius: 0.05, ttlMilliseconds: 6000))
    }

    func testOutOfRangeCoordinateIsRejected() {
        let data = #"{"v":1,"type":"pointer","x":1.2,"y":0.4}"#.data(using: .utf8)!
        XCTAssertThrowsError(try DataMessageCodec.decode(data, senderIdentity: "volunteer:小王"))
    }

    func testSafetyRiskRoundTripsFromTheElder() throws {
        let original = DataMessage.safetyRisk(
            level: .danger,
            transcript: "Please tell me the verification code.",
            matchedRules: ["request_sensitive_information", "verification_code"]
        )

        XCTAssertEqual(
            try DataMessageCodec.decode(DataMessageCodec.encode(original), senderIdentity: "elder"),
            original
        )
    }

    func testVolunteerCannotForgeSafetyRisk() {
        let data = #"{"v":1,"type":"safety.risk","level":"danger","transcript":"fake","matched_rules":["verification_code"]}"#.data(using: .utf8)!
        XCTAssertThrowsError(try DataMessageCodec.decode(data, senderIdentity: "volunteer:小王")) { error in
            XCTAssertEqual(error as? DataMessageError, .forbiddenVolunteerControl)
        }
    }
}

final class SecurityLogicTests: XCTestCase {
    func testSensitiveLabelsAndFallbackKeywords() {
        XCTAssertTrue(SensitiveTextPolicy.isSensitiveField(label: "Card CVV"))
        XCTAssertTrue(SensitiveTextPolicy.isSensitiveField(label: "输入密码"))
        XCTAssertNil(SensitiveTextPolicy.localFreezeReason(for: "请点击右上角"))
        XCTAssertNotNil(SensitiveTextPolicy.localFreezeReason(for: "把验证码念给我"))
    }

    func testCoordinateConversionIncludesRetinaScaleAndMargin() {
        let geometry = CaptureGeometry(
            displayFramePoints: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            frameSizePixels: CGSize(width: 2_880, height: 1_800)
        )
        XCTAssertEqual(geometry.pixelRect(forAXTopLeftRect: CGRect(x: 100, y: 50, width: 200, height: 40)), CGRect(x: 192, y: 92, width: 416, height: 96))
    }

    func testImageLongEdgeLimit() {
        let size = ImageSizing.fittedSize(width: 3_000, height: 2_000)
        XCTAssertEqual(size.width, 1_568)
        XCTAssertEqual(size.height, 1_045)
    }
}
