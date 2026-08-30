import Foundation
import XCTest
@testable import SecondSightCore

final class SessionAttemptGateTests: XCTestCase {
    func testInvalidatedAttemptCannotDeliverALateResponse() {
        var gate = SessionAttemptGate()
        let attemptID = gate.begin()

        gate.invalidate()

        XCTAssertFalse(gate.accepts(attemptID))
        XCTAssertFalse(gate.finish(attemptID))
    }

    func testNewAttemptRejectsPreviousAttemptResponse() {
        var gate = SessionAttemptGate()
        let previousAttemptID = gate.begin()
        let currentAttemptID = gate.begin()

        XCTAssertFalse(gate.accepts(previousAttemptID))
        XCTAssertTrue(gate.accepts(currentAttemptID))
        XCTAssertTrue(gate.finish(currentAttemptID))
        XCTAssertFalse(gate.accepts(currentAttemptID))
    }
}
