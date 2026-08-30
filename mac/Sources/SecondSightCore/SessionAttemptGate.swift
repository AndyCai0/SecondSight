import Foundation

/// Keeps asynchronous session setup responses scoped to the attempt that created them.
public struct SessionAttemptGate: Sendable {
    private var currentAttemptID: UUID?

    public init() {}

    @discardableResult
    public mutating func begin() -> UUID {
        let attemptID = UUID()
        currentAttemptID = attemptID
        return attemptID
    }

    public func accepts(_ attemptID: UUID) -> Bool {
        currentAttemptID == attemptID
    }

    public mutating func invalidate() {
        currentAttemptID = nil
    }

    @discardableResult
    public mutating func finish(_ attemptID: UUID) -> Bool {
        guard accepts(attemptID) else { return false }
        currentAttemptID = nil
        return true
    }
}
