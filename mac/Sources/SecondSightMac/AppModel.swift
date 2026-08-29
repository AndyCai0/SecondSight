import Combine
import Foundation
import LiveKit
import SecondSightCore

enum SafetyMonitoringState: Equatable {
    case off
    case connecting
    case listening
    case disconnected

    var headline: String {
        switch self {
        case .off: "Safety Monitoring: OFF"
        case .connecting: "Safety Monitoring: CONNECTING"
        case .listening: "Safety Monitoring: ON"
        case .disconnected: "Safety Monitoring: DISCONNECTED"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var phase: SessionPhase = .idle
    @Published private(set) var roomCode: String?
    @Published var statusMessage = "需要帮助时，点下面的大按钮"
    @Published var errorMessage: String?
    @Published var guideStatus = "按住说话，松开后我会给您指路"
    @Published var isGuideRecording = false
    @Published private(set) var safetyState: SafetyMonitoringState = .off
    @Published private(set) var safetyStatusMessage = "Start Safety Listening to begin protection."
    @Published private(set) var livePartialTranscript = ""
    @Published private(set) var recentTranscriptLines: [String] = []

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
    private let safetyStreaming = AssemblyAIStreamingService()
    private let guideSpeech = PushToTalkSpeechService()
    private let riskPipeline = RiskPipeline()
    private var riskDeduplicator = RiskEventDeduplicator(cooldown: 8)
    private var recentTranscript = RecentTranscriptBuffer(window: 25, maximumEntries: 40)
    private var volunteerAudioTrack: RemoteAudioTrack?
    private var safetyStartRequested = false
    private var safetyRequestID: UUID?
    private var safetyCredentialRequestInFlight = false
    private var currentSafetyRisk: RiskDetectionResult?
    private var currentRiskTranscript = ""

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
        do {
            try guideSpeech.start { [weak self] result in
                Task { @MainActor in await self?.guideSpeechCompleted(result) }
            }
            isGuideRecording = true
            guideStatus = "我在听，请说您想做什么……"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stopGuideRecording() {
        guard isGuideRecording else { return }
        isGuideRecording = false
        guideStatus = "正在看屏幕，马上告诉您下一步……"
        guideSpeech.stop()
    }

    func toggleSafetyListening() {
        switch safetyState {
        case .connecting, .listening:
            stopSafetyListening()
        case .off, .disconnected:
            startSafetyListening()
        }
    }

    func dismissSafetyWarning() {
        overlay.model.dismissSafetyWarning()
        overlay.setSafetyWarningVisible(false)
        currentSafetyRisk = nil
        currentRiskTranscript = ""
    }

    func pauseForSafetyWarning() {
        guard currentSafetyRisk != nil else { return }
        let transcript = currentRiskTranscript
        dismissSafetyWarning()
        stopSafetyListening()
        Task { await freeze(reason: "检测到可能索要敏感信息或要求危险操作", transcript: transcript) }
    }

    func contactVolunteerAboutRisk() {
        guard let risk = currentSafetyRisk else { return }
        let transcript = currentRiskTranscript
        Task {
            try? await transport.publish(.safetyRisk(
                level: risk.level,
                transcript: transcript,
                matchedRules: risk.matchedRules
            ))
        }
        statusMessage = "安全提醒已经发送给志愿者"
        dismissSafetyWarning()
    }

    private func startSafetyListening() {
        guard phase == .connected else {
            errorMessage = "请等志愿者加入后再开始安全监听。"
            return
        }
        guard permissions.statuses[.microphone] == .authorized else {
            permissions.request(.microphone)
            errorMessage = "请先允许麦克风权限，再开始安全监听。"
            return
        }
        guard sessionID != nil, api != nil else {
            errorMessage = "安全监听服务尚未配置。"
            return
        }

        safetyStartRequested = true
        safetyRequestID = UUID()
        safetyCredentialRequestInFlight = false
        safetyState = .connecting
        safetyStatusMessage = volunteerAudioTrack == nil
            ? "Waiting for volunteer audio…"
            : "Connecting to live transcription…"
        livePartialTranscript = ""
        recentTranscriptLines = []
        recentTranscript = RecentTranscriptBuffer(window: 25, maximumEntries: 40)
        riskDeduplicator = RiskEventDeduplicator(cooldown: 8)
        currentSafetyRisk = nil
        currentRiskTranscript = ""
        errorMessage = nil

        if let volunteerAudioTrack {
            beginSafetyStreaming(track: volunteerAudioTrack)
        }
    }

    private func stopSafetyListening() {
        safetyStartRequested = false
        safetyRequestID = nil
        safetyCredentialRequestInFlight = false
        safetyStreaming.stop()
        safetyState = .off
        safetyStatusMessage = "Safety listening is stopped."
        livePartialTranscript = ""
        dismissSafetyWarning()
    }

    private func remoteAudioBecameAvailable(_ track: RemoteAudioTrack) {
        volunteerAudioTrack = track
        if safetyStartRequested, safetyState == .connecting {
            beginSafetyStreaming(track: track)
        }
    }

    private func remoteAudioBecameUnavailable() {
        volunteerAudioTrack = nil
        safetyMonitoringDisconnected(reason: "Volunteer audio is no longer available.")
    }

    private func beginSafetyStreaming(track: RemoteAudioTrack) {
        guard safetyStartRequested, safetyState == .connecting,
              !safetyCredentialRequestInFlight,
              let sessionID, let api, let requestID = safetyRequestID
        else { return }
        safetyCredentialRequestInFlight = true
        safetyStatusMessage = "Connecting to live transcription…"

        Task {
            do {
                let credential = try await api.createAssemblyAIStreamingCredential(sessionID: sessionID)
                guard safetyStartRequested, safetyState == .connecting,
                      safetyRequestID == requestID
                else { return }
                safetyCredentialRequestInFlight = false
                try safetyStreaming.start(track: track, token: credential.token)
            } catch {
                guard safetyRequestID == requestID else { return }
                safetyCredentialRequestInFlight = false
                safetyMonitoringDisconnected(reason: error.localizedDescription)
            }
        }
    }

    private func safetyMonitoringDisconnected(reason: String) {
        guard safetyState == .connecting || safetyState == .listening else { return }
        safetyStartRequested = false
        safetyRequestID = nil
        safetyCredentialRequestInFlight = false
        safetyStreaming.stop()
        safetyState = .disconnected
        safetyStatusMessage = "Not protected — \(reason)"
        livePartialTranscript = ""
    }

    private func handleSafetyTranscript(_ update: StreamingTranscript) async {
        guard safetyState == .listening else { return }
        let now = Date()
        let context = recentTranscript.transcripts(at: now)

        if update.isFinal {
            livePartialTranscript = ""
            recentTranscript.append(update.text, at: now)
            recentTranscriptLines.append("Volunteer: \(update.text)")
            if recentTranscriptLines.count > 6 {
                recentTranscriptLines.removeFirst(recentTranscriptLines.count - 6)
            }
        } else {
            livePartialTranscript = "Volunteer: \(update.text)"
        }

        let decision = await riskPipeline.analyze(
            transcript: update.text,
            recentTranscript: context,
            currentContext: ["source": "volunteer_live_audio"]
        )
        guard decision.level != .safe,
              riskDeduplicator.shouldEmit(decision, transcript: update.text, at: now),
              let sessionID, let api
        else { return }

        currentSafetyRisk = decision
        currentRiskTranscript = update.text
        overlay.model.showSafetyWarning(level: decision.level, transcript: update.text)
        overlay.setSafetyWarningVisible(true)
        speech.speak("安全提醒。不要告诉任何人验证码、密码或银行卡信息。")

        let message = DataMessage.safetyRisk(
            level: decision.level,
            transcript: update.text,
            matchedRules: decision.matchedRules
        )
        let request = RiskEventRequest(
            sessionID: sessionID,
            timestamp: ISO8601DateFormatter().string(from: now),
            level: decision.level,
            transcript: update.text,
            matchedRules: decision.matchedRules
        )
        Task {
            do {
                try await transport.publish(message)
            } catch {
                errorMessage = "本机安全提醒仍在工作，但志愿者通知暂时未送达。"
            }
            do {
                _ = try await api.recordRiskEvent(request)
            } catch {
                errorMessage = "安全提醒仍在本机工作，但告警记录暂时未送达。"
            }
        }
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
        transport.onRemoteAudioTrack = { [weak self] track in
            Task { @MainActor in self?.remoteAudioBecameAvailable(track) }
        }
        transport.onRemoteAudioTrackUnavailable = { [weak self] in
            Task { @MainActor in self?.remoteAudioBecameUnavailable() }
        }
        transport.onError = { [weak self] error in
            Task { @MainActor in
                self?.errorMessage = "通话连接有问题：\(error.localizedDescription)"
                self?.safetyMonitoringDisconnected(reason: "The call connection was lost.")
            }
        }
        safetyStreaming.onConnected = { [weak self] in
            Task { @MainActor in
                guard self?.safetyStartRequested == true else { return }
                self?.safetyState = .listening
                self?.safetyStatusMessage = "Listening…"
            }
        }
        safetyStreaming.onTranscript = { [weak self] update in
            Task { @MainActor in await self?.handleSafetyTranscript(update) }
        }
        safetyStreaming.onDisconnected = { [weak self] error in
            Task { @MainActor in
                self?.safetyMonitoringDisconnected(reason: error.localizedDescription)
            }
        }
        overlay.model.onResume = { [weak self] in self?.resumeAfterFalsePositive() }
        overlay.model.onSafetyPause = { [weak self] in self?.pauseForSafetyWarning() }
        overlay.model.onSafetyDismiss = { [weak self] in self?.dismissSafetyWarning() }
        overlay.model.onContactVolunteer = { [weak self] in self?.contactVolunteerAboutRisk() }
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
        case .safetyRisk:
            break
        }
    }

    private func freeze(reason: String, transcript: String) async {
        guard phase == .connected else { return }
        do {
            stopSafetyListening()
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
                    actor: "safety_monitor",
                    kind: "control.freeze",
                    payload: ["reason": .string(reason), "transcript": .string(transcript)]
                ))
            }
        } catch { errorMessage = error.localizedDescription }
    }

    private func guideSpeechCompleted(_ result: Result<String, Error>) async {
        isGuideRecording = false
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
        stopSafetyListening()
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
