import AppKit
import AVFoundation
import Combine
import Foundation
import LiveKit
import SecondSightCore

enum SafetyMonitoringState: Equatable {
    case off
    case connecting
    case listening
    case degraded
    case disconnected

    func headline(for language: AppLanguage) -> String {
        switch self {
        case .off: localized("安全监听：已关闭", "Safety monitoring: Off", for: language)
        case .connecting: localized("安全监听：连接中", "Safety monitoring: Connecting", for: language)
        case .listening: localized("安全监听：已开启", "Safety monitoring: On", for: language)
        case .degraded: localized("安全监听：部分功能异常", "Safety monitoring: Partially unavailable", for: language)
        case .disconnected: localized("安全监听：连接已断开", "Safety monitoring: Disconnected", for: language)
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var phase: SessionPhase = .idle
    @Published private(set) var roomCode: String?
    @Published var language = AppLanguage.savedOrSystemDefault {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: AppLanguage.preferenceKey)
            overlay.model.language = language
        }
    }
    @Published var statusMessage = copy(
        "可以呼叫在线助手，也可以使用分享码",
        "Call an online volunteer or use a room code"
    )
    @Published var errorMessage: LocalizedCopy?
    @Published var guideStatus = copy(
        "按住说话，松开后我会给您指路",
        "Hold to speak, then release for guidance"
    )
    @Published var isGuideRecording = false
    @Published private(set) var safetyState: SafetyMonitoringState = .off
    @Published private(set) var safetyStatusMessage = copy(
        "点击“开始安全监听”后才会启用保护。",
        "Select “Start safety monitoring” to turn on protection."
    )
    @Published private(set) var livePartialTranscript = ""
    @Published private(set) var recentTranscriptLines: [String] = []
    @Published var isCameraConsentPresented = false
    @Published private(set) var isPreparingHelp = false
    @Published private(set) var cameraNeedsSettings = false
    @Published private(set) var mediaRecoveryMessage: LocalizedCopy?
    @Published private(set) var assistanceDiscoveryMode: AssistanceDiscoveryMode?
    @Published private(set) var notifiedAssistantCount: Int?
    @Published private(set) var broadcastMessage: LocalizedCopy?
    @Published private(set) var isCallTransportConnected = false

    private static let defaultAIEnabled = false

    let aiFeaturesEnabled: Bool
    let permissions: PermissionManager

    private var machine = SessionStateMachine()
    private var api: EdgeAPIClient?
    private var sessionID: UUID?
    private var elderLiveKitCredential: String?
    private let scanner = AccessibilityScanner()
    private lazy var capture = ScreenCaptureService(scanner: scanner)
    private let transport = LiveKitTransport()
    private let overlay = OverlayWindowController()
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
    private var screenCaptureFailed = false
    private var pendingDiscoveryMode: AssistanceDiscoveryMode?
    private var isEndingSession = false
    private var broadcastSessionID: UUID?

    init() {
        aiFeaturesEnabled = Self.defaultAIEnabled
        permissions = PermissionManager(includeAIFeatures: Self.defaultAIEnabled)
        do { api = EdgeAPIClient(configuration: try AppConfiguration.load()) }
        catch { errorMessage = localizedError(error) }
        overlay.model.language = language
        wireServices()
    }

    func startHelp(using discoveryMode: AssistanceDiscoveryMode) {
        guard phase == .idle || phase == .ended else { return }
        guard permissions.allAuthorized else {
            errorMessage = copy(
                "请先把下面列出的权限都设为“已允许”。",
                "Set every permission below to “Allowed” first."
            )
            return
        }
        errorMessage = nil
        cameraNeedsSettings = false
        pendingDiscoveryMode = discoveryMode
        isCameraConsentPresented = true
    }

    func confirmCameraAndStartHelp() {
        guard
            !isPreparingHelp,
            phase == .idle || phase == .ended,
            let discoveryMode = pendingDiscoveryMode
        else { return }
        isCameraConsentPresented = false
        isPreparingHelp = true
        statusMessage = copy("正在准备摄像头……", "Preparing the camera…")
        Task {
            let granted = await requestCameraAccess()
            guard granted else {
                isPreparingHelp = false
                cameraNeedsSettings = AVCaptureDevice.authorizationStatus(for: .video) == .denied
                statusMessage = copy("摄像头没有打开", "The camera is not on")
                errorMessage = cameraNeedsSettings
                    ? copy(
                        "请在系统设置里允许摄像头，然后再点“求助”。",
                        "Allow camera access in System Settings, then request help again."
                    )
                    : copy(
                        "需要允许摄像头，才能进入视频通话。",
                        "Camera access is required to start a video call."
                    )
                return
            }
            cameraNeedsSettings = false
            await beginHelpSession(using: discoveryMode)
            isPreparingHelp = false
        }
    }

    func cancelCameraConsent() {
        isCameraConsentPresented = false
        pendingDiscoveryMode = nil
        statusMessage = copy("已取消，摄像头没有打开", "Cancelled. The camera is not on.")
    }

    func openCameraSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    func retryFailedMedia() {
        mediaRecoveryMessage = nil
        statusMessage = copy(
            "正在重新连接摄像头和共享画面……",
            "Reconnecting the camera and shared screen…"
        )
        transport.retryFailedMedia()
        guard screenCaptureFailed else { return }
        Task {
            do {
                try await capture.restart()
                screenCaptureFailed = false
            } catch {
                screenCaptureFailed = true
                mediaRecoveryMessage = copy(
                    "电脑画面重连失败：\(error.localizedDescription)",
                    "Could not reconnect the computer screen: \(error.localizedDescription)"
                )
                statusMessage = copy(
                    "摄像头仍可继续，电脑画面需要再次重连",
                    "The camera is still available, but the computer screen must reconnect"
                )
            }
        }
    }

    private func requestCameraAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            true
        case .notDetermined:
            await AVCaptureDevice.requestAccess(for: .video)
        default:
            false
        }
    }

    private func beginHelpSession(using discoveryMode: AssistanceDiscoveryMode) async {
        if api == nil {
            do { api = EdgeAPIClient(configuration: try AppConfiguration.load()) }
            catch { errorMessage = localizedError(error); return }
        }
        guard let api else { return }
        do {
            if phase == .ended {
                _ = try machine.apply(.reset)
                phase = machine.phase
            }
            _ = try machine.apply(.requestHelp)
            phase = machine.phase
            statusMessage = copy("正在为您联系帮助……", "Finding help for you…")
            errorMessage = nil
            mediaRecoveryMessage = nil
            broadcastMessage = nil
            notifiedAssistantCount = nil
            broadcastSessionID = nil
            assistanceDiscoveryMode = discoveryMode
            screenCaptureFailed = false
            let response = try await api.createSession()
            sessionID = response.sessionID
            elderLiveKitCredential = response.liveKitToken
            roomCode = response.code
            _ = try machine.apply(.sessionCreated)
            phase = machine.phase
            statusMessage = discoveryMode == .broadcast
                ? copy(
                    "正在连接摄像头和电脑画面，随后呼叫在线助手",
                    "Connecting the camera and computer screen, then calling online volunteers"
                )
                : copy(
                    "房间号码是 \(response.code)，摄像头和电脑画面正在连接",
                    "Your room code is \(response.code). Connecting the camera and computer screen."
                )
            overlay.show()
            isCallTransportConnected = false
            try await transport.connect(url: response.liveKitURL, token: response.liveKitToken)
            isCallTransportConnected = true
            try await capture.start()

            if discoveryMode == .broadcast {
                await startAssistantBroadcast(sessionID: response.sessionID, fallbackCode: response.code)
            } else {
                speakShareCode(response.code)
            }
        } catch {
            await failAndEnd(error)
        }
    }

    private func startAssistantBroadcast(sessionID: UUID, fallbackCode: String) async {
        guard let api else { return }
        broadcastSessionID = sessionID
        statusMessage = copy(
            "正在向在线助手广播求助……",
            "Broadcasting your request to online volunteers…"
        )
        do {
            let response = try await api.setSessionBroadcast(
                BroadcastSessionRequest(sessionID: sessionID, isActive: true)
            )
            guard phase == .waiting else {
                _ = try? await api.setSessionBroadcast(
                    BroadcastSessionRequest(sessionID: sessionID, isActive: false)
                )
                return
            }
            notifiedAssistantCount = response.notifiedAssistants
            if let count = response.notifiedAssistants {
                statusMessage = count > 0
                    ? copy(
                        "已通知 \(count) 位在线助手，正在等待一位助手响应",
                        "Notified \(count) online volunteer(s). Waiting for one to respond."
                    )
                    : copy(
                        "广播已经发出，目前还没有助手在线",
                        "Your request was broadcast, but no volunteers are online yet"
                    )
            } else {
                statusMessage = copy(
                    "已向在线助手广播求助，正在等待一位助手响应",
                    "Your request was broadcast. Waiting for a volunteer to respond."
                )
            }
            broadcastMessage = copy(
                "第一位响应的助手会接入；您也可以把备用分享码告诉认识的人。",
                "The first volunteer to respond will join. You can also share the backup room code with someone you know."
            )
            speech.speak(localized(
                "求助信息已经发给在线助手，请稍等。",
                "Your help request has been sent to online volunteers. Please wait.",
                for: language
            ))
        } catch {
            guard phase == .waiting else { return }
            assistanceDiscoveryMode = .shareCode
            notifiedAssistantCount = nil
            broadcastMessage = copy(
                "在线助手广播暂时不可用，房间仍然安全可用。请把下面的分享码告诉帮助您的人。",
                "Online volunteer broadcast is temporarily unavailable. The room is still secure; share the code below with someone who can help."
            )
            statusMessage = copy(
                "广播暂时不可用，请使用分享码求助",
                "Broadcast is unavailable. Use the room code to request help."
            )
            speakShareCode(fallbackCode)
        }
    }

    private func speakShareCode(_ code: String) {
        let spokenCode = code.map(String.init).joined(separator: language == .chinese ? "，" : ", ")
        speech.speak(localized(
            "您的房间号码是，\(spokenCode)",
            "Your room code is \(spokenCode)",
            for: language
        ))
    }

    func endSession() {
        Task { await endSessionNow() }
    }

    func startGuideRecording() {
        guard aiFeaturesEnabled else { return }
        guard !isGuideRecording else { return }
        guard sessionID != nil, capture.latestFrame.get() != nil else {
            errorMessage = copy(
                "请先点“求助”，等画面准备好后再用 AI 帮我。",
                "Request help first, then wait for the screen before using AI guidance."
            )
            return
        }
        do {
            try guideSpeech.start { [weak self] result in
                Task { @MainActor in await self?.guideSpeechCompleted(result) }
            }
            isGuideRecording = true
            guideStatus = copy("我在听，请说您想做什么……", "I’m listening. Tell me what you want to do…")
        } catch {
            errorMessage = localizedError(error)
        }
    }

    func stopGuideRecording() {
        guard isGuideRecording else { return }
        isGuideRecording = false
        guideStatus = copy(
            "正在看屏幕，马上告诉您下一步……",
            "Checking the screen. I’ll tell you the next step shortly…"
        )
        guideSpeech.stop()
    }

    func toggleSafetyListening() {
        switch safetyState {
        case .connecting, .listening, .degraded:
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
        Task {
            await freeze(
                reason: localized(
                    "检测到可能索要敏感信息或要求危险操作",
                    "A request for sensitive information or a dangerous action was detected",
                    for: language
                ),
                transcript: transcript
            )
        }
    }

    func contactVolunteerAboutRisk() {
        guard let risk = currentSafetyRisk else { return }
        let transcript = currentRiskTranscript
        Task {
            do {
                try await transport.publish(.safetyRisk(
                    level: risk.level,
                    transcript: transcript,
                    matchedRules: risk.matchedRules
                ))
                statusMessage = copy(
                    "安全提醒已经发送给志愿者",
                    "The safety alert was sent to the volunteer"
                )
            } catch {
                markSafetyMonitoringDegraded(reason: copy(
                    "志愿者通知暂时不可用。",
                    "Volunteer notifications are temporarily unavailable."
                ))
                errorMessage = copy(
                    "志愿者通知暂时未送达，请直接停止通话或联系信任的人。",
                    "The volunteer did not receive the alert. End the call or contact someone you trust."
                )
            }
        }
        dismissSafetyWarning()
    }

    private func startSafetyListening() {
        guard phase == .connected, isCallTransportConnected else {
            errorMessage = copy(
                "请等志愿者加入且通话连接正常后，再开始安全监听。",
                "Wait for a volunteer to join and for the call to connect before starting safety monitoring."
            )
            return
        }
        guard permissions.statuses[.microphone] == .authorized else {
            permissions.request(.microphone)
            errorMessage = copy(
                "请先允许麦克风权限，再开始安全监听。",
                "Allow microphone access before starting safety monitoring."
            )
            return
        }
        guard sessionID != nil, api != nil, elderLiveKitCredential != nil else {
            errorMessage = copy(
                "安全监听服务尚未配置。",
                "The safety monitoring service is not configured."
            )
            return
        }

        safetyStartRequested = true
        safetyRequestID = UUID()
        safetyCredentialRequestInFlight = false
        safetyState = .connecting
        safetyStatusMessage = volunteerAudioTrack == nil
            ? copy("正在等待志愿者的声音……", "Waiting for the volunteer’s audio…")
            : copy("正在连接实时字幕……", "Connecting live captions…")
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
        safetyStatusMessage = copy("安全监听已经停止。", "Safety monitoring has stopped.")
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
        safetyMonitoringDisconnected(reason: copy(
            "志愿者声音已经断开。",
            "The volunteer’s audio disconnected."
        ))
    }

    private func beginSafetyStreaming(track: RemoteAudioTrack) {
        guard safetyStartRequested, safetyState == .connecting,
              !safetyCredentialRequestInFlight,
              let sessionID, let api, let elderLiveKitCredential,
              let requestID = safetyRequestID
        else { return }
        safetyCredentialRequestInFlight = true
        safetyStatusMessage = copy("正在连接实时字幕……", "Connecting live captions…")

        Task {
            do {
                let credential = try await api.createAssemblyAIStreamingCredential(
                    sessionID: sessionID,
                    elderCredential: elderLiveKitCredential
                )
                guard safetyStartRequested, safetyState == .connecting,
                      safetyRequestID == requestID
                else { return }
                safetyCredentialRequestInFlight = false
                try safetyStreaming.start(track: track, token: credential.token)
            } catch {
                guard safetyRequestID == requestID else { return }
                safetyCredentialRequestInFlight = false
                safetyMonitoringDisconnected(reason: copy(
                    "无法连接实时字幕服务，请稍后重试。",
                    "Could not connect to live captions. Try again later."
                ))
            }
        }
    }

    private func safetyMonitoringDisconnected(reason: LocalizedCopy) {
        guard safetyState == .connecting || safetyState == .listening || safetyState == .degraded else { return }
        safetyStartRequested = false
        safetyRequestID = nil
        safetyCredentialRequestInFlight = false
        safetyStreaming.stop()
        safetyState = .disconnected
        safetyStatusMessage = copy(
            "当前没有安全保护：\(reason.chinese)",
            "Safety protection is unavailable: \(reason.english)"
        )
        livePartialTranscript = ""
    }

    private func callTransportDisconnected(reason: LocalizedCopy) {
        isCallTransportConnected = false
        volunteerAudioTrack = nil
        safetyMonitoringDisconnected(reason: reason)
    }

    private func markSafetyMonitoringDegraded(reason: LocalizedCopy) {
        guard safetyState == .listening || safetyState == .degraded else { return }
        safetyState = .degraded
        safetyStatusMessage = copy(
            "本机提醒仍在工作：\(reason.chinese)",
            "On-device alerts are still working: \(reason.english)"
        )
    }

    private func handleSafetyTranscript(_ update: StreamingTranscript) async {
        guard safetyState == .listening || safetyState == .degraded else { return }
        let now = Date()
        let context = recentTranscript.transcripts(at: now)

        if update.isFinal {
            livePartialTranscript = ""
            recentTranscript.append(update.text, at: now)
            recentTranscriptLines.append(update.text)
            if recentTranscriptLines.count > 6 {
                recentTranscriptLines.removeFirst(recentTranscriptLines.count - 6)
            }
        } else {
            livePartialTranscript = update.text
        }

        let decision = await riskPipeline.analyze(
            transcript: update.text,
            recentTranscript: context,
            currentContext: ["source": "volunteer_live_audio"]
        )
        guard decision.level != .safe,
              riskDeduplicator.shouldEmit(
                  decision,
                  transcript: update.text,
                  eventID: "turn-\(update.turnOrder)",
                  at: now
              ),
              let sessionID, let api, let elderLiveKitCredential
        else { return }

        currentSafetyRisk = decision
        currentRiskTranscript = update.text
        overlay.model.showSafetyWarning(level: decision.level, transcript: update.text)
        overlay.setSafetyWarningVisible(true)
        speech.speak(localized(
            "安全提醒。不要告诉任何人验证码、密码或银行卡信息。",
            "Safety alert. Never share verification codes, passwords, or bank details.",
            for: language
        ))

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
                markSafetyMonitoringDegraded(reason: copy(
                    "志愿者通知暂时不可用。",
                    "Volunteer notifications are temporarily unavailable."
                ))
                errorMessage = copy(
                    "本机安全提醒仍在工作，但志愿者通知暂时未送达。",
                    "On-device safety alerts still work, but the volunteer notification was not delivered."
                )
            }
            do {
                _ = try await api.recordRiskEvent(
                    request,
                    elderCredential: elderLiveKitCredential
                )
            } catch {
                markSafetyMonitoringDegraded(reason: copy(
                    "后端告警记录暂时不可用。",
                    "Server-side alert records are temporarily unavailable."
                ))
                errorMessage = copy(
                    "安全提醒仍在本机工作，但告警记录暂时未送达。",
                    "Safety alerts still work on this Mac, but the alert record was not delivered."
                )
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
            statusMessage = copy(
                "通话已恢复，画面仍会自动保护敏感信息",
                "The call has resumed. Sensitive information will still be protected automatically."
            )
            Task {
                try? await transport.publish(.resume)
                if let sessionID {
                    await api?.logEvent(LogEventRequest(sessionID: sessionID, actor: "elder", kind: "control.resume", payload: [:]))
                }
            }
        } catch { errorMessage = localizedError(error) }
    }

    private func wireServices() {
        capture.onFrame = { [weak transport] frame in transport?.acceptRedactedFrame(frame) }
        capture.onError = { [weak self] error in
            Task { @MainActor in
                self?.screenCaptureFailed = true
                self?.mediaRecoveryMessage = copy(
                    "电脑画面采集停止：\(error.localizedDescription)",
                    "Computer screen capture stopped: \(error.localizedDescription)"
                )
                self?.statusMessage = copy(
                    "摄像头仍可继续，电脑画面需要重连",
                    "The camera is still available, but the computer screen must reconnect"
                )
            }
        }
        transport.onVolunteerJoined = { [weak self] identity in
            Task { @MainActor in self?.volunteerJoined(identity: identity) }
        }
        transport.onVolunteerLeft = { [weak self] identity in
            Task { @MainActor in await self?.volunteerLeft(identity: identity) }
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
        transport.onReconnecting = { [weak self] in
            Task { @MainActor in
                self?.callTransportDisconnected(reason: copy(
                    "通话正在重新连接，安全监听已经停止。",
                    "The call is reconnecting, so safety monitoring has stopped."
                ))
            }
        }
        transport.onReconnected = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.isCallTransportConnected = true
                if self.safetyState == .disconnected {
                    self.safetyStatusMessage = copy(
                        "通话已经恢复。请重新点击“开始安全监听”。",
                        "The call has reconnected. Select “Start safety monitoring” again."
                    )
                }
            }
        }
        transport.onRemoteCameraTrack = { [weak self] track in
            Task { @MainActor in self?.overlay.model.showVolunteerCamera(track) }
        }
        transport.onRemoteCameraTrackRemoved = { [weak self] in
            Task { @MainActor in self?.overlay.model.hideVolunteerCamera() }
        }
        transport.onMediaError = { [weak self] kind, error in
            Task { @MainActor in
                self?.mediaRecoveryMessage = copy(
                    "\(kind.displayName)连接失败：\(error.localizedDescription)",
                    "Could not connect \(Self.englishDisplayName(for: kind)): \(error.localizedDescription)"
                )
                self?.statusMessage = copy(
                    "部分画面没有连上，其他通话内容仍可继续",
                    "Some video did not connect, but the rest of the call can continue"
                )
            }
        }
        transport.onAllMediaReady = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.mediaRecoveryMessage = nil
                if self.phase == .connected {
                    self.statusMessage = copy(
                        "视频通话已连接，摄像头和电脑画面都在分享",
                        "Video call connected. The camera and computer screen are both being shared."
                    )
                } else if self.assistanceDiscoveryMode == .broadcast {
                    if let count = self.notifiedAssistantCount {
                        self.statusMessage = count > 0
                            ? copy(
                                "已通知 \(count) 位在线助手，正在等待一位助手响应",
                                "Notified \(count) online volunteer(s). Waiting for one to respond."
                            )
                            : copy(
                                "广播已经发出，目前还没有助手在线",
                                "Your request was broadcast, but no volunteers are online yet"
                            )
                    } else {
                        self.statusMessage = copy(
                            "摄像头和电脑画面已连接，正在呼叫在线助手",
                            "Camera and computer screen connected. Calling online volunteers."
                        )
                    }
                } else {
                    self.statusMessage = copy(
                        "摄像头和电脑画面已连接，正在等待对方加入",
                        "Camera and computer screen connected. Waiting for the other person to join."
                    )
                }
            }
        }
        transport.onError = { [weak self] error in
            Task { @MainActor in
                self?.errorMessage = copy(
                    "通话连接有问题：\(error.localizedDescription)",
                    "There is a problem with the call connection: \(error.localizedDescription)"
                )
                self?.callTransportDisconnected(reason: copy(
                    "通话连接已中断。",
                    "The call connection was interrupted."
                ))
            }
        }
        transport.onDisconnected = { [weak self] in
            Task { @MainActor in
                self?.callTransportDisconnected(reason: copy(
                    "通话连接已经关闭。",
                    "The call connection has closed."
                ))
            }
        }
        safetyStreaming.onConnected = { [weak self] in
            Task { @MainActor in
                guard self?.safetyStartRequested == true else { return }
                self?.safetyState = .listening
                self?.safetyStatusMessage = copy("正在监听……", "Listening…")
            }
        }
        safetyStreaming.onTranscript = { [weak self] update in
            Task { @MainActor in await self?.handleSafetyTranscript(update) }
        }
        safetyStreaming.onDisconnected = { [weak self] _ in
            Task { @MainActor in
                self?.safetyMonitoringDisconnected(reason: copy(
                    "实时字幕连接已断开，请稍后重试。",
                    "Live captions disconnected. Try again later."
                ))
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
            broadcastMessage = nil
            notifiedAssistantCount = nil
            statusMessage = copy(
                "帮助您的人已经加入，只能看和指，不能控制您的电脑",
                "Your volunteer has joined. They can only watch and guide, not control your computer."
            )
            speech.speak(localized(
                "帮助您的人已经加入。请记住，密码和验证码谁都不能告诉。",
                "Your volunteer has joined. Remember: never share passwords or verification codes.",
                for: language
            ))
            if let broadcastSessionID, let api {
                Task {
                    _ = try? await api.setSessionBroadcast(
                        BroadcastSessionRequest(sessionID: broadcastSessionID, isActive: false)
                    )
                }
            }
        } catch { errorMessage = localizedError(error) }
    }

    private func volunteerLeft(identity _: String) async {
        guard phase == .waiting || phase == .connected || phase == .frozen else { return }
        await endSessionNow(statusMessage: copy(
            "帮助您的人已结束协助，本次求助已经结束",
            "The volunteer ended the assistance session."
        ))
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
            statusMessage = copy(
                "通话已暂停，请先看屏幕上的安全提醒",
                "The call is paused. Read the safety alert on screen."
            )
            overlay.model.freeze(reason: reason)
            overlay.setFrozen(true)
            speech.speak(localized(
                "检测到可疑请求，通话已暂停。请勿告诉任何人您的密码或验证码",
                "A suspicious request was detected and the call was paused. Never share passwords or verification codes.",
                for: language
            ))
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
        } catch { errorMessage = localizedError(error) }
    }

    private func guideSpeechCompleted(_ result: Result<String, Error>) async {
        isGuideRecording = false
        switch result {
        case let .failure(error):
            errorMessage = copy(
                "没有听清：\(error.localizedDescription)",
                "I couldn’t understand that: \(error.localizedDescription)"
            )
            guideStatus = copy("请按住再说一次", "Hold the button and try again")
        case let .success(taskText):
            guard let sessionID, let frame = capture.latestFrame.get(), let api else { return }
            guard let jpeg = await Task.detached(priority: .userInitiated, operation: { RedactedJPEGEncoder.encode(frame) }).value else {
                errorMessage = copy(
                    "无法准备安全截图。",
                    "Could not prepare a protected screenshot."
                )
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
                guideStatus = .verbatim(response.instructionText)
                speech.speak(response.instructionText)
                if let rect = response.targetRect { overlay.model.guide(rect: rect) }
                await api.logEvent(LogEventRequest(sessionID: sessionID, actor: "ai_guide", kind: "ai.instruction", payload: ["task": .string(taskText), "instruction": .string(response.instructionText)]))
            } catch {
                errorMessage = copy(
                    "AI 指路失败：\(error.localizedDescription)",
                    "AI guidance failed: \(error.localizedDescription)"
                )
                guideStatus = copy("请稍后再试", "Try again later")
            }
        }
    }

    private func failAndEnd(_ error: Error) async {
        errorMessage = localizedError(error)
        await endSessionNow()
    }

    private func endSessionNow(
        statusMessage finalStatusMessage: LocalizedCopy = copy(
            "本次求助已经结束",
            "This assistance session has ended"
        )
    ) async {
        guard !isEndingSession else { return }
        isEndingSession = true
        defer { isEndingSession = false }

        stopSafetyListening()
        let broadcastSessionIDToWithdraw = broadcastSessionID
        let broadcastWithdrawal = Task { [api] in
            guard let broadcastSessionID = broadcastSessionIDToWithdraw, let api else { return }
            _ = try? await api.setSessionBroadcast(
                BroadcastSessionRequest(sessionID: broadcastSessionID, isActive: false)
            )
        }
        // Stop all published tracks before draining local capture. This keeps
        // tail audio/video from being transmitted during asynchronous teardown.
        await transport.freezeMedia()
        await capture.stop()
        await transport.disconnect()
        overlay.close()
        if phase != .idle, phase != .ended {
            _ = try? machine.apply(.end)
            phase = machine.phase
        }
        roomCode = nil
        sessionID = nil
        elderLiveKitCredential = nil
        volunteerAudioTrack = nil
        isCallTransportConnected = false
        pendingDiscoveryMode = nil
        self.broadcastSessionID = nil
        assistanceDiscoveryMode = nil
        notifiedAssistantCount = nil
        broadcastMessage = nil
        mediaRecoveryMessage = nil
        screenCaptureFailed = false
        statusMessage = finalStatusMessage

        // Withdrawal starts before local cleanup but never delays it.
        await broadcastWithdrawal.value
    }

    private func localizedError(_ error: Error) -> LocalizedCopy {
        let description = error.localizedDescription
        return .verbatim(description)
    }

    private static func englishDisplayName(for kind: ElderMediaKind) -> String {
        switch kind {
        case .camera: "camera"
        case .screen: "computer screen"
        case .microphone: "microphone"
        }
    }
}
