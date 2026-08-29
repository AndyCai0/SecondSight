import Foundation

public enum SessionPhase: String, Codable, CaseIterable, Sendable {
    case idle
    case requesting
    case waiting
    case connected
    case frozen
    case ended
}

public enum SessionEvent: Equatable, Sendable {
    case requestHelp
    case sessionCreated
    case volunteerJoined
    case freeze
    case resume
    case end
    case reset
}

public enum SessionTransitionError: Error, Equatable, LocalizedError {
    case invalid(from: SessionPhase, event: SessionEvent)

    public var errorDescription: String? {
        switch self {
        case let .invalid(from, event):
            return "会话状态 \(from.rawValue) 不能处理事件 \(event)"
        }
    }
}

public struct SessionStateMachine: Sendable {
    public private(set) var phase: SessionPhase

    public init(phase: SessionPhase = .idle) {
        self.phase = phase
    }

    @discardableResult
    public mutating func apply(_ event: SessionEvent) throws -> SessionPhase {
        let next: SessionPhase?
        switch (phase, event) {
        case (.idle, .requestHelp): next = .requesting
        case (.requesting, .sessionCreated): next = .waiting
        case (.waiting, .volunteerJoined): next = .connected
        case (.connected, .freeze): next = .frozen
        case (.frozen, .resume): next = .connected
        case (.requesting, .end), (.waiting, .end), (.connected, .end), (.frozen, .end): next = .ended
        case (.ended, .reset): next = .idle
        default: next = nil
        }
        guard let next else { throw SessionTransitionError.invalid(from: phase, event: event) }
        phase = next
        return next
    }
}
