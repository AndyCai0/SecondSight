import AppKit
import Combine
import LiveKit
import SecondSightCore
import SwiftUI

struct OverlayAnnotation: Identifiable, Equatable {
    enum Shape: Equatable {
        case circle(x: Double, y: Double, radius: Double)
        case arrow(x1: Double, y1: Double, x2: Double, y2: Double)
        case pointer(x: Double, y: Double)
        case rectangle(NormalizedRect)
    }

    let id: String
    let shape: Shape
    let expiresAt: Date
}

struct SafetyWarning: Equatable {
    let level: RiskLevel
    let transcript: String
}

@MainActor
final class OverlayModel: ObservableObject {
    @Published var annotations: [OverlayAnnotation] = []
    @Published var warning: String?
    @Published var frozenReason: String?
    @Published private(set) var volunteerCameraTrack: RemoteVideoTrack?
    @Published var safetyWarning: SafetyWarning?
    @Published var language = AppLanguage.savedOrSystemDefault
    var onResume: (() -> Void)?
    var onSafetyPause: (() -> Void)?
    var onSafetyDismiss: (() -> Void)?
    var onContactVolunteer: (() -> Void)?
    private var cleanupTimer: Timer?
    private var warningTask: Task<Void, Never>?

    init() {
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.removeExpired() }
        }
    }

    deinit {
        cleanupTimer?.invalidate()
        warningTask?.cancel()
    }

    func handle(_ message: DataMessage) {
        let now = Date()
        switch message {
        case let .circle(id, x, y, radius, ttl):
            upsert(OverlayAnnotation(id: id, shape: .circle(x: x, y: y, radius: radius), expiresAt: now.addingTimeInterval(Double(ttl) / 1_000)))
        case let .arrow(id, x1, y1, x2, y2, ttl):
            upsert(OverlayAnnotation(id: id, shape: .arrow(x1: x1, y1: y1, x2: x2, y2: y2), expiresAt: now.addingTimeInterval(Double(ttl) / 1_000)))
        case let .pointer(x, y):
            upsert(OverlayAnnotation(id: "pointer", shape: .pointer(x: x, y: y), expiresAt: now.addingTimeInterval(0.35)))
        case .clear:
            annotations.removeAll()
        case .freeze, .resume, .textToSpeech, .safetyRisk, .caption:
            break
        }
    }

    func guide(rect: NormalizedRect, ttl: TimeInterval = 8) {
        upsert(OverlayAnnotation(id: "ai-guide", shape: .rectangle(rect), expiresAt: Date().addingTimeInterval(ttl)))
    }

    func showWarning(_ text: String) {
        warningTask?.cancel()
        warning = text
        warningTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.warning = nil }
        }
    }

    func freeze(reason: String) { frozenReason = reason }
    func resume() { frozenReason = nil }
    func showVolunteerCamera(_ track: RemoteVideoTrack) { volunteerCameraTrack = track }
    func hideVolunteerCamera() { volunteerCameraTrack = nil }
    func showSafetyWarning(level: RiskLevel, transcript: String) {
        safetyWarning = .init(level: level, transcript: transcript)
    }
    func dismissSafetyWarning() { safetyWarning = nil }

    private func upsert(_ item: OverlayAnnotation) {
        annotations.removeAll { $0.id == item.id }
        annotations.append(item)
    }

    private func removeExpired() {
        let now = Date()
        annotations.removeAll { $0.expiresAt <= now }
    }
}

struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        ZStack {
            TimelineView(.animation) { context in
                Canvas { graphics, size in
                    drawAnnotations(graphics: &graphics, size: size, time: context.date)
                }
            }
            if let warning = model.warning {
                VStack {
                    Text(warning)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 20)
                        .background(.yellow, in: RoundedRectangle(cornerRadius: 18))
                        .shadow(radius: 12)
                    Spacer()
                }
                .padding(.top, 48)
            }
            if let track = model.volunteerCameraTrack {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        VStack(alignment: .leading, spacing: 0) {
                            SwiftUIVideoView(track, layoutMode: .fill)
                                .frame(width: 320, height: 180)
                                .clipped()
                            Text(localized("帮助您的人", "Your Volunteer", for: model.language))
                                .font(.system(size: 22, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 16)
                                .frame(height: 48)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.black.opacity(0.82))
                        }
                        .frame(width: 320)
                        .background(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .overlay {
                            RoundedRectangle(cornerRadius: 18)
                                .stroke(.white.opacity(0.9), lineWidth: 3)
                        }
                        .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
                    }
                }
                .padding(32)
            }
            if let warning = model.safetyWarning, model.frozenReason == nil {
                VStack(spacing: 22) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .font(.system(size: 72))
                    Text(localized("安全警告", "Safety Alert", for: model.language))
                        .font(.system(size: 42, weight: .heavy))
                    Text(localized(
                        "对方可能正在索要您的敏感信息。",
                        "The other person may be asking for sensitive information.",
                        for: model.language
                    ))
                        .font(.system(size: 30, weight: .bold))
                        .multilineTextAlignment(.center)
                    Text(localized(
                        "不要告诉任何人验证码、密码、PIN 或银行卡信息。",
                        "Never share verification codes, passwords, PINs, or bank details.",
                        for: model.language
                    ))
                        .font(.system(size: 28, weight: .heavy))
                        .multilineTextAlignment(.center)
                    Text("“\(warning.transcript)”")
                        .font(.system(size: 24, weight: .medium))
                        .lineLimit(3)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 22)
                    HStack(spacing: 18) {
                        Button { model.onSafetyPause?() } label: {
                            ActionButtonLabel(title: localized(
                                "暂停通话",
                                "Pause Call",
                                for: model.language
                            ))
                        }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                            .secondSightActionButton()
                        Button { model.onSafetyDismiss?() } label: {
                            ActionButtonLabel(title: localized(
                                "关闭提醒",
                                "Dismiss",
                                for: model.language
                            ))
                        }
                            .buttonStyle(.bordered)
                            .secondSightActionButton()
                        Button { model.onContactVolunteer?() } label: {
                            ActionButtonLabel(title: localized(
                                "联系志愿者",
                                "Contact Volunteer",
                                for: model.language
                            ))
                        }
                            .buttonStyle(.borderedProminent)
                            .secondSightActionButton()
                    }
                }
                .foregroundStyle(.black)
                .padding(36)
                .frame(maxWidth: 900)
                .background(Color.yellow, in: RoundedRectangle(cornerRadius: 28))
                .overlay(
                    RoundedRectangle(cornerRadius: 28)
                        .stroke(warning.level == .danger ? Color.red : Color.black, lineWidth: 8)
                )
                .shadow(color: .black.opacity(0.55), radius: 28, y: 10)
                .padding(40)
            }
            if let reason = model.frozenReason {
                VStack(spacing: 32) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .font(.system(size: 88))
                    Text(localized(
                        "检测到可疑请求，通话已暂停",
                        "A Suspicious Request Was Detected. The Call Is Paused.",
                        for: model.language
                    ))
                        .font(.system(size: 42, weight: .heavy))
                    Text(localized(
                        "请勿告诉任何人您的密码或验证码",
                        "Never share your password or verification code",
                        for: model.language
                    ))
                        .font(.system(size: 32, weight: .bold))
                    Text(reason)
                        .font(.system(size: 24))
                    Button { model.onResume?() } label: {
                        ActionButtonLabel(title: localized(
                            "是误报，继续通话",
                            "False Alarm — Resume Call",
                            for: model.language
                        ))
                    }
                        .buttonStyle(.borderedProminent)
                        .secondSightActionButton()
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.red.opacity(0.86))
            }
        }
        .background(.clear)
    }

    private func drawAnnotations(graphics: inout GraphicsContext, size: CGSize, time: Date) {
        let pulse = 1 + 0.08 * sin(time.timeIntervalSinceReferenceDate * 5)
        for item in model.annotations {
            switch item.shape {
            case let .circle(x, y, radius):
                let center = CGPoint(x: x * size.width, y: y * size.height)
                let r = radius * min(size.width, size.height) * pulse
                graphics.stroke(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)), with: .color(.orange), lineWidth: 9)
            case let .arrow(x1, y1, x2, y2):
                let start = CGPoint(x: x1 * size.width, y: y1 * size.height)
                let end = CGPoint(x: x2 * size.width, y: y2 * size.height)
                var path = Path(); path.move(to: start); path.addLine(to: end)
                let angle = atan2(end.y - start.y, end.x - start.x)
                for delta in [Double.pi * 0.82, -Double.pi * 0.82] {
                    path.move(to: end)
                    path.addLine(to: CGPoint(x: end.x + 28 * cos(angle + delta), y: end.y + 28 * sin(angle + delta)))
                }
                graphics.stroke(path, with: .color(.orange), style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
            case let .pointer(x, y):
                let center = CGPoint(x: x * size.width, y: y * size.height)
                graphics.fill(Path(ellipseIn: CGRect(x: center.x - 12, y: center.y - 12, width: 24, height: 24)), with: .color(.red))
            case let .rectangle(rect):
                let box = CGRect(x: rect.x * size.width, y: rect.y * size.height, width: rect.width * size.width, height: rect.height * size.height)
                graphics.stroke(Path(roundedRect: box.insetBy(dx: -8, dy: -8), cornerRadius: 14), with: .color(.cyan), lineWidth: 9)
            }
        }
    }
}

@MainActor
final class OverlayWindowController {
    let model = OverlayModel()
    private var window: NSWindow?

    func show() {
        guard window == nil, let screen = NSScreen.main else { return }
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        // This controller owns the window through a strong Swift reference.
        // AppKit's default release-on-close ownership conflicts with ARC and
        // can over-release the window when close() also clears that reference.
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .screenSaver
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.contentView = NSHostingView(rootView: OverlayView(model: model))
        window.orderFrontRegardless()
        self.window = window
    }

    func setFrozen(_ frozen: Bool) {
        show()
        window?.ignoresMouseEvents = !(frozen || model.safetyWarning != nil)
        if frozen { window?.makeKeyAndOrderFront(nil) }
    }

    func setSafetyWarningVisible(_ visible: Bool) {
        if visible { show() }
        guard window != nil else { return }
        window?.ignoresMouseEvents = !(visible || model.frozenReason != nil)
        if visible { window?.makeKeyAndOrderFront(nil) }
    }

    func close() {
        window?.close()
        window = nil
        model.hideVolunteerCamera()
    }
}
