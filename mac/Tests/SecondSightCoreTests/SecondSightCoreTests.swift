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

    func testVolunteerDepartureCanEndWaitingOrFrozenSession() throws {
        var waiting = SessionStateMachine(phase: .waiting)
        XCTAssertEqual(try waiting.apply(.end), .ended)

        var frozen = SessionStateMachine(phase: .frozen)
        XCTAssertEqual(try frozen.apply(.end), .ended)
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

    func testSafetyAnalysisContractUsesSpeakerLabelledTurns() throws {
        let sessionID = UUID(uuidString: "9D1D5434-6DA5-41E0-AF70-C5AA35C6816F")!
        let request = AISafetyAnalysisRequest(
            sessionID: sessionID,
            elderGoal: "请帮我登录银行网站",
            throughSequence: 2,
            dialogue: [
                .init(sequence: 1, speaker: .elder, text: "我想查看余额"),
                .init(sequence: 2, speaker: .volunteer, text: "请告诉我验证码"),
            ],
            screenshotBase64: nil,
            screenRevision: nil
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        )

        XCTAssertEqual(object["elder_goal"] as? String, "请帮我登录银行网站")
        XCTAssertEqual(object["through_sequence"] as? Int, 2)
        let dialogue = try XCTUnwrap(object["dialogue"] as? [[String: Any]])
        XCTAssertEqual(dialogue[1]["speaker"] as? String, "volunteer")
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

    func testSafetyRiskEncodingBoundsLongTranscriptWithoutDroppingRules() throws {
        let data = try DataMessageCodec.encode(.safetyRisk(
            level: .danger,
            transcript: String(repeating: "验", count: 1_001),
            matchedRules: ["verification_code", "request_sensitive_information"]
        ))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let transcript = try XCTUnwrap(object["transcript"] as? String)

        XCTAssertEqual(transcript.unicodeScalars.count, DataMessageCodec.maximumRiskTranscriptScalars)
        XCTAssertEqual(object["transcript_truncated"] as? Bool, true)
        XCTAssertEqual(
            object["matched_rules"] as? [String],
            ["verification_code", "request_sensitive_information"]
        )
    }

    func testVolunteerCannotForgeSafetyRisk() {
        let data = #"{"v":1,"type":"safety.risk","level":"danger","transcript":"fake","matched_rules":["verification_code"]}"#.data(using: .utf8)!
        XCTAssertThrowsError(try DataMessageCodec.decode(data, senderIdentity: "volunteer:小王")) { error in
            XCTAssertEqual(error as? DataMessageError, .forbiddenVolunteerControl)
        }
    }

    func testCaptionRoundTripsAndVolunteerCannotForgeIt() throws {
        let message = DataMessage.caption(
            speaker: .elder,
            turnOrder: 4,
            text: "我想打开照片",
            isFinal: true
        )
        let data = try DataMessageCodec.encode(message)
        XCTAssertEqual(try DataMessageCodec.decode(data, senderIdentity: "elder"), message)
        XCTAssertThrowsError(try DataMessageCodec.decode(data, senderIdentity: "volunteer:小王")) { error in
            XCTAssertEqual(error as? DataMessageError, .forbiddenVolunteerControl)
        }
    }
}

final class ScreenChangePolicyTests: XCTestCase {
    func testFirstFrameIsSignificant() {
        XCTAssertTrue(ScreenChangePolicy.isSignificant(previous: nil, current: [0, 0, 0]))
    }

    func testSmallLocalizedChangeIsIgnored() {
        let previous = [UInt8](repeating: 100, count: 100 * 3)
        var current = previous
        current[0] = 220
        current[1] = 220
        current[2] = 220
        XCTAssertFalse(ScreenChangePolicy.isSignificant(previous: previous, current: current))
    }

    func testLargeScreenChangeIsSignificant() {
        let previous = [UInt8](repeating: 20, count: 100 * 3)
        let current = [UInt8](repeating: 220, count: 100 * 3)
        XCTAssertTrue(ScreenChangePolicy.isSignificant(previous: previous, current: current))
    }
}

final class SecurityLogicTests: XCTestCase {
    func testSensitiveLabelsAndFallbackKeywords() {
        XCTAssertTrue(SensitiveTextPolicy.isSensitiveField(label: "Card CVV"))
        XCTAssertTrue(SensitiveTextPolicy.isSensitiveField(label: "输入密码"))
        XCTAssertTrue(SensitiveTextPolicy.isSensitiveField(label: "BSB and account number"))
        XCTAssertNil(SensitiveTextPolicy.localFreezeReason(for: "请点击右上角"))
        XCTAssertNotNil(SensitiveTextPolicy.localFreezeReason(for: "把验证码念给我"))
    }

    func testSensitiveStaticTextPatternsAreProtected() {
        XCTAssertTrue(StaticPrivacyPolicy.containsSensitiveContent("From: demo.elder@example.test"))
        XCTAssertTrue(StaticPrivacyPolicy.containsSensitiveContent("Card 4111 1111 1111 1111"))
        XCTAssertTrue(StaticPrivacyPolicy.containsSensitiveContent("Call +61 412 345 678"))
        XCTAssertTrue(StaticPrivacyPolicy.containsSensitiveContent("Call 0412 345 678"))
        XCTAssertTrue(StaticPrivacyPolicy.containsSensitiveContent("1 Example Street, Sydney NSW 2000"))
        XCTAssertTrue(StaticPrivacyPolicy.containsSensitiveContent("Balance AUD $12,345.67"))
        XCTAssertTrue(StaticPrivacyPolicy.containsSensitiveContent("Diagnosis: synthetic condition"))
        XCTAssertTrue(StaticPrivacyPolicy.containsSensitiveContent("身份证号 110101199001011234"))
        XCTAssertTrue(StaticPrivacyPolicy.containsSensitiveVisualDescription("Synthetic identity document"))
        XCTAssertTrue(StaticPrivacyPolicy.containsSensitiveVisualDescription("医保卡二维码"))
    }

    func testOrdinaryStaticControlsRemainVisible() {
        XCTAssertFalse(StaticPrivacyPolicy.containsSensitiveContent("Click the blue Continue button"))
        XCTAssertFalse(StaticPrivacyPolicy.containsSensitiveContent("SecondSight volunteer session"))
    }

    func testAggregatePageTextCannotProduceAWholePageMask() {
        XCTAssertFalse(StaticPrivacyPolicy.mayDirectlyRedactSensitiveText(
            role: "AXWebArea",
            hasChildren: true
        ))
        XCTAssertFalse(StaticPrivacyPolicy.mayDirectlyRedactSensitiveText(
            role: "AXScrollArea",
            hasChildren: true
        ))
        XCTAssertFalse(StaticPrivacyPolicy.mayDirectlyRedactSensitiveText(
            role: "AXGroup",
            hasChildren: true
        ))
        XCTAssertTrue(StaticPrivacyPolicy.mayDirectlyRedactSensitiveText(
            role: "AXStaticText",
            hasChildren: false
        ))
    }

    func testPrivateContextsMaskContentNodesButNotWholeWindowControls() {
        XCTAssertTrue(StaticPrivacyPolicy.isPrivateContext(
            applicationName: "Mail",
            bundleIdentifier: "com.apple.mail",
            windowTitle: "Synthetic message"
        ))
        XCTAssertTrue(StaticPrivacyPolicy.isPrivateContext(
            applicationName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            windowTitle: "Inbox - Gmail"
        ))
        XCTAssertFalse(StaticPrivacyPolicy.isPrivateContext(
            applicationName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            windowTitle: "SecondSight Volunteer"
        ))
        XCTAssertTrue(StaticPrivacyPolicy.shouldRedactElement(
            role: "AXStaticText",
            hasChildren: false,
            inPrivateContext: true
        ))
        XCTAssertTrue(StaticPrivacyPolicy.shouldRedactElement(
            role: "AXImage",
            hasChildren: false,
            inPrivateContext: true
        ))
        XCTAssertFalse(StaticPrivacyPolicy.shouldRedactElement(
            role: "AXButton",
            hasChildren: false,
            inPrivateContext: true
        ))
        XCTAssertFalse(StaticPrivacyPolicy.shouldRedactElement(
            role: "AXWebArea",
            hasChildren: true,
            inPrivateContext: true
        ))
    }

    func testSystemPrivacyOverlaysAreExcludedFromCapture() {
        XCTAssertTrue(CapturePrivacyPolicy.shouldExcludeApplication(bundleIdentifier: "com.apple.notificationcenterui"))
        XCTAssertTrue(CapturePrivacyPolicy.shouldExcludeApplication(bundleIdentifier: "com.apple.controlcenter"))
        XCTAssertFalse(CapturePrivacyPolicy.shouldExcludeApplication(bundleIdentifier: "com.apple.Safari"))
    }

    func testCoordinateConversionIncludesRetinaScaleAndMargin() {
        let geometry = CaptureGeometry(
            displayFramePoints: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            frameSizePixels: CGSize(width: 2_880, height: 1_800)
        )
        XCTAssertEqual(geometry.pixelRect(forAXTopLeftRect: CGRect(x: 100, y: 50, width: 200, height: 40)), CGRect(x: 192, y: 92, width: 416, height: 96))
    }

    func testVisionBottomLeftCoordinatesConvertToTopLeftDisplayPoints() {
        let converted = VisionPrivacyGeometry.topLeftRect(
            forNormalizedBottomLeftRect: CGRect(x: 0.25, y: 0.6, width: 0.5, height: 0.2),
            displayFramePoints: CGRect(x: 0, y: 0, width: 1_000, height: 800)
        )
        XCTAssertEqual(converted.minX, 250, accuracy: 0.001)
        XCTAssertEqual(converted.minY, 160, accuracy: 0.001)
        XCTAssertEqual(converted.width, 500, accuracy: 0.001)
        XCTAssertEqual(converted.height, 160, accuracy: 0.001)
    }

    func testImageLongEdgeLimit() {
        let size = ImageSizing.fittedSize(width: 3_000, height: 2_000)
        XCTAssertEqual(size.width, 1_568)
        XCTAssertEqual(size.height, 1_045)
    }

    func testFocusedEditableFieldIsProtectedBeforeTyping() {
        XCTAssertTrue(InputPrivacyPolicy.shouldRedactEditable(
            role: "AXTextField",
            subrole: "",
            reportsEditable: false,
            isFocused: true,
            hasNonEmptyValue: false
        ))
    }

    func testEnteredTextRemainsProtectedAfterFocusLeaves() {
        XCTAssertTrue(InputPrivacyPolicy.shouldRedactEditable(
            role: "AXTextArea",
            subrole: "",
            reportsEditable: false,
            isFocused: false,
            hasNonEmptyValue: true
        ))
        XCTAssertFalse(InputPrivacyPolicy.shouldRedactEditable(
            role: "AXTextArea",
            subrole: "",
            reportsEditable: false,
            isFocused: false,
            hasNonEmptyValue: false
        ))
    }

    func testBrowserReportedEditableContentIsProtected() {
        XCTAssertTrue(InputPrivacyPolicy.shouldRedactEditable(
            role: "AXGroup",
            subrole: "",
            reportsEditable: true,
            isFocused: true,
            hasNonEmptyValue: false
        ))
        XCTAssertFalse(InputPrivacyPolicy.shouldRedactEditable(
            role: "AXWebArea",
            subrole: "",
            reportsEditable: true,
            isFocused: true,
            hasNonEmptyValue: true
        ))
    }

    func testNearbyAutofillSurfaceIsProtectedButMainWindowIsNot() {
        let input = CGRect(x: 480, y: 420, width: 460, height: 60)
        XCTAssertTrue(InputPrivacyPolicy.shouldRedactSuggestionSurface(
            CGRect(x: 480, y: 480, width: 370, height: 150),
            near: input
        ))
        XCTAssertFalse(InputPrivacyPolicy.shouldRedactSuggestionSurface(
            CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
            near: input
        ))
        XCTAssertEqual(
            InputPrivacyPolicy.fallbackSuggestionFrame(under: input),
            CGRect(x: 480, y: 480, width: 520, height: 180)
        )
    }
}

final class MediaTrackContractTests: XCTestCase {
    func testElderTrackNamesAreStableAndUnique() {
        XCTAssertEqual(ElderMediaKind.camera.trackName, "elder-camera")
        XCTAssertEqual(ElderMediaKind.screen.trackName, "screen-redacted")
        XCTAssertEqual(ElderMediaKind.microphone.trackName, "elder-microphone")
        XCTAssertEqual(Set(ElderMediaKind.allCases.map(\.trackName)).count, 3)
    }
}

final class PermissionPromptWindowPolicyTests: XCTestCase {
    func testExistingApplePermissionPromptCanStillBeGuided() {
        XCTAssertTrue(
            PermissionPromptWindowPolicy.mayUseWindow(
                bundleIdentifier: PermissionPromptWindowPolicy.systemPromptBundleIdentifier,
                wasVisibleBeforeRequest: true
            )
        )
    }

    func testUnrelatedExistingWindowIsRejected() {
        XCTAssertFalse(
            PermissionPromptWindowPolicy.mayUseWindow(
                bundleIdentifier: "com.example.Unrelated",
                wasVisibleBeforeRequest: true
            )
        )
        XCTAssertTrue(
            PermissionPromptWindowPolicy.mayUseWindow(
                bundleIdentifier: "com.example.Unrelated",
                wasVisibleBeforeRequest: false
            )
        )
    }

    func testSettingsGuideUsesDetectedSwitchFrameExactly() {
        let settingsFrame = CGRect(x: 220, y: 80, width: 1_000, height: 800)
        let visibleFrame = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let appRowFrame = CGRect(x: 300, y: 360, width: 700, height: 54)
        let switchFrame = CGRect(x: 1_115, y: 372, width: 46, height: 28)

        let panelFrame = PermissionSettingsGuideLayout.panelFrame(
            systemSettingsFrame: settingsFrame,
            appRowFrame: appRowFrame,
            switchFrame: switchFrame,
            visibleScreenFrame: visibleFrame
        )
        let target = PermissionSettingsGuideLayout.switchTarget(
            systemSettingsFrame: settingsFrame,
            appRowFrame: appRowFrame,
            switchFrame: switchFrame
        )

        XCTAssertTrue(visibleFrame.contains(panelFrame))
        XCTAssertEqual(target, CGPoint(x: switchFrame.midX, y: switchFrame.midY))
        XCTAssertGreaterThan(panelFrame.minY, target.y)
        XCTAssertEqual(
            panelFrame.maxX - PermissionSettingsGuideLayout.arrowTipTrailingInset,
            target.x
        )
    }

    func testSettingsGuideUsesDetectedRowWhenSwitchIsUnavailable() {
        let settingsFrame = CGRect(x: 220, y: 80, width: 1_000, height: 800)
        let appRowFrame = CGRect(x: 300, y: 360, width: 700, height: 54)

        let target = PermissionSettingsGuideLayout.switchTarget(
            systemSettingsFrame: settingsFrame,
            appRowFrame: appRowFrame,
            switchFrame: nil
        )

        XCTAssertEqual(target.y, appRowFrame.midY)
        XCTAssertGreaterThan(target.x, appRowFrame.maxX)
    }

    func testSettingsGuideFallsBackAndIsClampedOnSmallVisibleScreen() {
        let settingsFrame = CGRect(x: -80, y: -40, width: 700, height: 560)
        let visibleFrame = CGRect(x: 0, y: 0, width: 600, height: 500)

        let panelFrame = PermissionSettingsGuideLayout.panelFrame(
            systemSettingsFrame: settingsFrame,
            appRowFrame: nil,
            switchFrame: nil,
            visibleScreenFrame: visibleFrame
        )
        let target = PermissionSettingsGuideLayout.switchTarget(
            systemSettingsFrame: settingsFrame,
            appRowFrame: nil,
            switchFrame: nil
        )

        XCTAssertTrue(visibleFrame.contains(panelFrame))
        XCTAssertEqual(target.y, settingsFrame.minY + settingsFrame.height * 0.45)
    }
}
