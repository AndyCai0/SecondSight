import Foundation

public struct CreateSessionResponse: Codable, Equatable, Sendable {
    public let sessionID: UUID
    public let code: String
    public let liveKitURL: String
    public let liveKitToken: String

    public init(sessionID: UUID, code: String, liveKitURL: String, liveKitToken: String) {
        self.sessionID = sessionID
        self.code = code
        self.liveKitURL = liveKitURL
        self.liveKitToken = liveKitToken
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case code
        case liveKitURL = "lk_url"
        case liveKitToken = "lk_token"
    }
}

public struct AIGuideRequest: Codable, Equatable, Sendable {
    public let sessionID: UUID
    public let task: String
    public let screenshotBase64: String
    public let axSummary: String?

    public init(sessionID: UUID, task: String, screenshotBase64: String, axSummary: String?) {
        self.sessionID = sessionID
        self.task = task
        self.screenshotBase64 = screenshotBase64
        self.axSummary = axSummary
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case task
        case screenshotBase64 = "screenshot_base64"
        case axSummary = "ax_summary"
    }
}

public struct NormalizedRect: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    enum CodingKeys: String, CodingKey {
        case x, y
        case width = "w"
        case height = "h"
    }
}

public struct AIGuideResponse: Codable, Equatable, Sendable {
    public let instructionText: String
    public let targetRect: NormalizedRect?
    public let confidence: Double

    public init(instructionText: String, targetRect: NormalizedRect?, confidence: Double) {
        self.instructionText = instructionText
        self.targetRect = targetRect
        self.confidence = confidence
    }

    enum CodingKeys: String, CodingKey {
        case instructionText = "instruction_text"
        case targetRect = "target_rect"
        case confidence
    }
}

public struct AIRefereeRequest: Codable, Equatable, Sendable {
    public let sessionID: UUID
    public let transcript: String

    public init(sessionID: UUID, transcript: String) {
        self.sessionID = sessionID
        self.transcript = transcript
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case transcript
    }
}

public enum RefereeVerdict: String, Codable, Sendable {
    case ok
    case warn
    case freeze
}

public struct AIRefereeResponse: Codable, Equatable, Sendable {
    public let verdict: RefereeVerdict
    public let reason: String

    public init(verdict: RefereeVerdict, reason: String) {
        self.verdict = verdict
        self.reason = reason
    }
}

public struct AssemblyAIStreamingCredential: Decodable, Equatable, Sendable {
    public let token: String
    public let expiresInSeconds: Int
    public let maxSessionDurationSeconds: Int

    public init(token: String, expiresInSeconds: Int, maxSessionDurationSeconds: Int) {
        self.token = token
        self.expiresInSeconds = expiresInSeconds
        self.maxSessionDurationSeconds = maxSessionDurationSeconds
    }

    enum CodingKeys: String, CodingKey {
        case token
        case expiresInSeconds = "expires_in_seconds"
        case maxSessionDurationSeconds = "max_session_duration_seconds"
    }
}

public struct AssemblyAITokenRequest: Encodable, Equatable, Sendable {
    public let sessionID: UUID

    public init(sessionID: UUID) {
        self.sessionID = sessionID
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
    }
}

public struct RiskEventRequest: Encodable, Equatable, Sendable {
    public let sessionID: UUID
    public let timestamp: String
    public let level: RiskLevel
    public let transcript: String
    public let matchedRules: [String]

    public init(
        sessionID: UUID,
        timestamp: String,
        level: RiskLevel,
        transcript: String,
        matchedRules: [String]
    ) {
        self.sessionID = sessionID
        self.timestamp = timestamp
        self.level = level
        self.transcript = transcript
        self.matchedRules = matchedRules
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case timestamp, level, transcript
        case matchedRules = "matched_rules"
    }
}

public struct RiskEventResponse: Decodable, Equatable, Sendable {
    public let ok: Bool
    public let fingerprint: String
}

public struct LogEventRequest: Encodable, Sendable {
    public let sessionID: UUID
    public let actor: String
    public let kind: String
    public let payload: [String: JSONValue]

    public init(sessionID: UUID, actor: String, kind: String, payload: [String: JSONValue]) {
        self.sessionID = sessionID
        self.actor = actor
        self.kind = kind
        self.payload = payload
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case actor, kind, payload
    }
}

public enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

public struct APIErrorResponse: Decodable, Sendable {
    public let error: String
}
