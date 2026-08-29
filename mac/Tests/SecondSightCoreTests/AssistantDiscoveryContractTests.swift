import XCTest
@testable import SecondSightCore

final class AssistantDiscoveryContractTests: XCTestCase {
    func testBroadcastRequestUsesStableSnakeCaseContract() throws {
        let sessionID = UUID(uuidString: "9D1D5434-6DA5-41E0-AF70-C5AA35C6816F")!
        let data = try JSONEncoder().encode(
            BroadcastSessionRequest(sessionID: sessionID, isActive: true)
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(object["session_id"] as? String, sessionID.uuidString)
        XCTAssertEqual(object["is_active"] as? Bool, true)
    }

    func testBroadcastResponseAllowsRecipientCountToBeOmitted() throws {
        let minimal = #"{"ok":true}"#.data(using: .utf8)!
        let counted = #"{"ok":true,"notified_assistants":4}"#.data(using: .utf8)!

        XCTAssertEqual(
            try JSONDecoder().decode(BroadcastSessionResponse.self, from: minimal),
            BroadcastSessionResponse(ok: true, notifiedAssistants: nil)
        )
        XCTAssertEqual(
            try JSONDecoder().decode(BroadcastSessionResponse.self, from: counted),
            BroadcastSessionResponse(ok: true, notifiedAssistants: 4)
        )
    }
}
