import Foundation

public enum DataMessage: Equatable, Sendable {
    case circle(id: String, x: Double, y: Double, radius: Double, ttlMilliseconds: Int)
    case arrow(id: String, x1: Double, y1: Double, x2: Double, y2: Double, ttlMilliseconds: Int)
    case pointer(x: Double, y: Double)
    case clear
    case freeze(reason: String)
    case resume
    case textToSpeech(text: String)

    public var type: String {
        switch self {
        case .circle: "annotate.circle"
        case .arrow: "annotate.arrow"
        case .pointer: "pointer"
        case .clear: "annotate.clear"
        case .freeze: "control.freeze"
        case .resume: "control.resume"
        case .textToSpeech: "chat.tts"
        }
    }
}

public enum DataMessageError: Error, Equatable {
    case invalidJSON
    case unsupportedVersion
    case unsupportedType
    case invalidValue
    case forbiddenVolunteerControl
}

public enum DataMessageCodec {
    public static func decode(_ data: Data, senderIdentity: String?) throws -> DataMessage {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["v"] as? Int,
              let type = object["type"] as? String
        else { throw DataMessageError.invalidJSON }
        guard version == 1 else { throw DataMessageError.unsupportedVersion }
        if senderIdentity?.hasPrefix("volunteer:") == true, type.hasPrefix("control.") {
            throw DataMessageError.forbiddenVolunteerControl
        }

        func number(_ key: String) throws -> Double {
            guard let value = object[key] as? NSNumber else { throw DataMessageError.invalidValue }
            let result = value.doubleValue
            guard result.isFinite else { throw DataMessageError.invalidValue }
            return result
        }
        func unit(_ key: String) throws -> Double {
            let value = try number(key)
            guard (0 ... 1).contains(value) else { throw DataMessageError.invalidValue }
            return value
        }
        func text(_ key: String, maxLength: Int = 1_000) throws -> String {
            guard let value = object[key] as? String, !value.isEmpty, value.count <= maxLength else {
                throw DataMessageError.invalidValue
            }
            return value
        }
        func ttl() throws -> Int {
            guard let value = object["ttl_ms"] as? NSNumber else { throw DataMessageError.invalidValue }
            let result = value.intValue
            guard (100 ... 60_000).contains(result) else { throw DataMessageError.invalidValue }
            return result
        }

        switch type {
        case "annotate.circle":
            return .circle(id: try text("id", maxLength: 100), x: try unit("x"), y: try unit("y"), radius: try unit("r"), ttlMilliseconds: try ttl())
        case "annotate.arrow":
            return .arrow(id: try text("id", maxLength: 100), x1: try unit("x1"), y1: try unit("y1"), x2: try unit("x2"), y2: try unit("y2"), ttlMilliseconds: try ttl())
        case "pointer":
            return .pointer(x: try unit("x"), y: try unit("y"))
        case "annotate.clear":
            return .clear
        case "control.freeze":
            return .freeze(reason: try text("reason"))
        case "control.resume":
            return .resume
        case "chat.tts":
            return .textToSpeech(text: try text("text"))
        default:
            throw DataMessageError.unsupportedType
        }
    }

    public static func encode(_ message: DataMessage) throws -> Data {
        var object: [String: Any] = ["v": 1, "type": message.type]
        switch message {
        case let .circle(id, x, y, radius, ttl):
            object.merge(["id": id, "x": x, "y": y, "r": radius, "ttl_ms": ttl]) { _, new in new }
        case let .arrow(id, x1, y1, x2, y2, ttl):
            object.merge(["id": id, "x1": x1, "y1": y1, "x2": x2, "y2": y2, "ttl_ms": ttl]) { _, new in new }
        case let .pointer(x, y): object.merge(["x": x, "y": y]) { _, new in new }
        case let .freeze(reason): object["reason"] = reason
        case let .textToSpeech(text): object["text"] = text
        case .clear, .resume: break
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
