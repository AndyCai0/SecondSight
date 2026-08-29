import Foundation

public enum ElderMediaKind: String, CaseIterable, Hashable, Sendable {
    case camera
    case screen
    case microphone

    public var trackName: String {
        switch self {
        case .camera: "elder-camera"
        case .screen: "screen-redacted"
        case .microphone: "elder-microphone"
        }
    }

    public var displayName: String {
        switch self {
        case .camera: "摄像头"
        case .screen: "电脑画面"
        case .microphone: "麦克风"
        }
    }
}
