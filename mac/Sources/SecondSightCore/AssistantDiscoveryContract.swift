import Foundation

public enum AssistanceDiscoveryMode: String, Codable, Equatable, Sendable {
    case broadcast
    case shareCode = "share_code"
}

public struct BroadcastSessionRequest: Codable, Equatable, Sendable {
    public let sessionID: UUID
    public let isActive: Bool

    public init(sessionID: UUID, isActive: Bool) {
        self.sessionID = sessionID
        self.isActive = isActive
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case isActive = "is_active"
    }
}

public struct BroadcastSessionResponse: Codable, Equatable, Sendable {
    public let ok: Bool
    public let notifiedAssistants: Int?

    public init(ok: Bool, notifiedAssistants: Int?) {
        self.ok = ok
        self.notifiedAssistants = notifiedAssistants
    }

    enum CodingKeys: String, CodingKey {
        case ok
        case notifiedAssistants = "notified_assistants"
    }
}
