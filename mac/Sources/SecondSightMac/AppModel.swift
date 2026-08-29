import Combine
import Foundation
import LiveKit
import SecondSightCore

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var phase: SessionPhase = .idle
    @Published private(set) var roomCode: String?
    @Published var statusMessage = "需要帮助时，点下面的大按钮"
    @Published var errorMessage: String?
    @Published var guideStatus = "按住说话，松开后我会给您指路"
    @Published var isGuideRecording = false

    let permissions = PermissionManager()

    private var machine = SessionStateMachine()
    private var api: EdgeAPIClient?
    private var sessionID: UUID?
    private let scanner = AccessibilityScanner()
    private lazy var capture = ScreenCaptureService(scanner: scanner)
    private let transport = LiveKitTransport()
    private let overlay = OverlayWindowController()
    private let roomCodeWindow = RoomCodeWindowController()
    private let speech = SpeechSynthesizer()
    private let referee = RefereeSpeechService()
    private let guideSpeech = PushToTalkSpeechService()

    init() {
        do { api = EdgeAPIClient(configuration: try AppConfiguration.load()) }
        catch { errorMessage = error.localizedDescription }
        wireServices()
    }

    func startHelp() {
        guard phase == .idle || phase == .ended else { return }
        guard permissions.allAuthorized else {
            errorMessage = "请先把下面四项权限都设为“已允许”。"
            return
        }
        if api == nil {
            do { api = EdgeAPIClient(configuration: try AppConfiguration.load()) }
            catch { errorMessage = error.localizedDescription; return }
        }
        guard let api else { return }
        Task {
            do {
                if phase == .ended {
                    _ = try machine.apply(.reset)
                    phase = machine.phase
                }
                _ = try machine.apply(.requestHelp)
                phase = machine.phase
                statusMessage = "正在为您联系帮助……"
                errorMessage = nil
                let response = try await api.createSession()
                sessionID = response.sessionID
                roomCode = response.code
                _ = try machine.apply(.sessionCreated)
                phase = machine.phase
                statusMessage = "房间号码是 \(response.code)，正在等待对方加入"
                overlay.show()
                roomCodeWindow.show(code: response.code)
                speech.speak("您的房间号码是，\(response.code.map(String.init).joined(separator: "，"))")
                try await transport.connect(url: response.liveKitURL, token: response.liveKitToken)
                try await capture.start()
            } catch {
                await failAndEnd(error)
            }
        }
    }

    func endSession() {
        Task { await endSessionNow() }
    }

    func startGuideRecording() {
        guard !isGuideRecording else { return }
        guard sessionID != nil, capture.latestFrame.get() != nil else {
            errorMessage = "请先点“求助”，等画面准备好后再用 AI 帮我。"
            return
        }
        referee.pause()
        do {
            try guideSpeech.start { [weak self] result in
                Task { @MainActor in await self?.guideSpeechCompleted(result) }
            }
            isGuideRecording = true
            guideStatus = "我在听，请说您想做什么……"
        } catch {
            errorMessage = error.localizedDescription
            referee.resume()
        }
    }

    func stopGuideRecording() {
        guard isGuideRecording else { return }
        isGuideRecording = false
        guideStatus = "正在看屏幕，马上告诉您下一步……"
        guideSpeech.stop()
    }

    func resumeAfterFalsePositive() {
        guard phase == .frozen else { return }
        do {
            _ = try machine.apply(.resume)
            phase = machine.phase
            overlay.model.resume()
            overlay.setFrozen(false)
            transport.resumeMedia()
            statusMessage = "通话已恢复，画面仍会自动保护敏感信息"
            Task {
                try? await transport.publish(.resume)
                if let sessionID {
                    await api?.logEvent(LogEventRequest(sessionID: sessionID, actor: "elder", kind: "control.resume", payload: [:]))
                }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    private func wireServices() {
        capture.onFrame = { [weak transport] frame in transport?.acceptRedactedFrame(frame) }
        capture.onError = { [weak self] error in
            Task { @MainActor in self?.errorMessage = "屏幕采集停止：\(error.localizedDescription)" }
        }
        transport.onVolunteerJoined = { [weak self] identity in
            Task { @MainActor in self?.volunteerJoined(identity: identity) }
        }
        transport.onDataMessage = { [weak self] message in
            Task { @MainActor in self?.handleDataMessage(message) }
        }
        transport.onRemoteAudioTrack = { [weak referee] track in referee?.attach(to: track) }
        transport.onError = { [weak self] error in
            Task { @MainActor in self?.errorMessage = "通话连接有问题：\(error.localizedDescription)" }
        }
        referee.onTranscript = { [weak self] transcript in
            Task { @MainActor in await self?.evaluateVolunteerSpeech(transcript) }
        }
        referee.onError = { [weak self] error in
            Task { @MainActor in self?.errorMessage = error.localizedDescription }
        }
        overlay.model.onResume = { [weak self] in self?.resumeAfterFalsePositive() }
    }

    private func volunteerJoined(identity: String) {
        guard phase == .waiting else { return }
        do {
            _ = try machine.apply(.volunteerJoined)
            phase = machine.phase
            roomCodeWindow.close()
            statusMessage = "帮助您的人已经加入，只能看和指，不能控制您的电脑"
            speech.speak("帮助您的人已经加入。请记住，密码和验证码谁都不能告诉。")
        } catch { errorMessage = error.localizedDescription }
    }

    private func handleDataMessage(_ message: DataMessage) {
        switch message {
        case .circle, .arrow, .pointer, .clear:
            overlay.model.handle(message)
        case let .textToSpeech(text):
            speech.speak(text)
        case let .freeze(reason):
            Task { await freeze(reason: reason, transcript: "") }
        case .resume:
            resumeAfterFalsePositive()
        }
    }

    private func evaluateVolunteerSpeech(_ transcript: String) async {
        guard phase == .connected, let sessionID else { return }
        do {
            guard let verdict = try await api?.classify(AIRefereeRequest(sessionID: sessionID, transcript: transcript)) else { return }
            switch verdict.verdict {
            case .ok: break
            case .warn:
                overlay.model.showWarning("安全提醒：\(verdict.reason)")
                await api?.logEvent(LogEventRequest(sessionID: sessionID, actor: "ai_referee", kind: "warn", payload: ["transcript": .string(transcript), "reason": .string(verdict.reason)]))
            case .freeze:
                await freeze(reason: verdict.reason, transcript: transcript)
            }
        } catch {
            if let reason = SensitiveTextPolicy.localFreezeReason(for: transcript) {
                await freeze(reason: reason, transcript: transcript)
            } else {
                errorMessage = "安全检查暂时无法联网；本地敏感词保护仍在运行。"
            }
        }
    }

    private func freeze(reason: String, transcript: String) async {
        guard phase == .connected else { return }
        do {
            _ = try machine.apply(.freeze)
            phase = machine.phase
            statusMessage = "通话已暂停，请先看屏幕上的安全提醒"
            overlay.model.freeze(reason: reason)
            overlay.setFrozen(true)
            speech.speak("检测到可疑请求，通话已暂停。请勿告诉任何人您的密码或验证码")
            await transport.freezeMedia()
            try? await transport.publish(.freeze(reason: reason))
            if let sessionID {
                await api?.logEvent(LogEventRequest(
                    sessionID: sessionID,
                    actor: "ai_referee",
                    kind: "control.freeze",
                    payload: ["reason": .string(reason), "transcript": .string(transcript)]
                ))
            }
        } catch { errorMessage = error.localizedDescription }
    }

    private func guideSpeechCompleted(_ result: Result<String, Error>) async {
        isGuideRecording = false
        defer { referee.resume() }
        switch result {
        case let .failure(error):
            errorMessage = "没有听清：\(error.localizedDescription)"
            guideStatus = "请按住再说一次"
        case let .success(taskText):
            guard let sessionID, let frame = capture.latestFrame.get(), let api else { return }
            guard let jpeg = await Task.detached(priority: .userInitiated, operation: { RedactedJPEGEncoder.encode(frame) }).value else {
                errorMessage = "无法准备安全截图。"
                return
            }
            do {
                let request = AIGuideRequest(
                    sessionID: sessionID,
                    task: taskText,
                    screenshotBase64: jpeg.base64EncodedString(),
                    axSummary: scanner.store.current().axSummary
                )
                let response = try await api.requestGuide(request)
                guideStatus = response.instructionText
                speech.speak(response.instructionText)
                if let rect = response.targetRect { overlay.model.guide(rect: rect) }
                await api.logEvent(LogEventRequest(sessionID: sessionID, actor: "ai_guide", kind: "ai.instruction", payload: ["task": .string(taskText), "instruction": .string(response.instructionText)]))
            } catch {
                errorMessage = "AI 指路失败：\(error.localizedDescription)"
                guideStatus = "请稍后再试"
            }
        }
    }

    private func failAndEnd(_ error: Error) async {
        errorMessage = error.localizedDescription
        await endSessionNow()
    }

    private func endSessionNow() async {
        referee.stop()
        await capture.stop()
        await transport.disconnect()
        roomCodeWindow.close()
        overlay.close()
        if phase != .idle, phase != .ended {
            _ = try? machine.apply(.end)
            phase = machine.phase
        }
        roomCode = nil
        sessionID = nil
        statusMessage = "本次求助已经结束"
    }
}
