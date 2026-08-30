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
    @Published var helpRequestGoal = ""
    @Published private(set) var isEndingSession = false

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
    private let elderSafetyStreaming = AssemblyAIStreamingService()
    private let volunteerSafetyStreaming = AssemblyAIStreamingService()
    private let guideSpeech = PushToTalkSpeechService()
    private let riskPipeline = RiskPipeline()
    private var riskDeduplicator = RiskEventDeduplicator(cooldown: 8)
    private var recentTranscript = RecentTranscriptBuffer(window: 25, maximumEntries: 40)
    private var volunteerAudioTrack: RemoteAudioTrack?
    private var safetyStartRequested = false
    private var safetyRequestID: UUID?
    private var safetyCredentialRequestsInFlight: Set<CaptionSpeaker> = []
    private var connectedSafetySpeakers: Set<CaptionSpeaker> = []
    private var activeElderGoal = ""
    private struct TimedDialogueTurn: Sendable {
        let turn: AISafetyDialogueTurn
        let timestamp: Date
    }
    private struct PreparedSafetyScreenshot: Sendable {
        let base64: String
        let candidate: SignificantScreenChangeMonitor.Candidate
    }
    private var dialogueTurns: [TimedDialogueTurn] = []
    private var nextDialogueSequence = 1
    private var lastAnalyzedSequence = 0
    private var safetyAnalysisPending = false
    private var safetyAnalysisTask: Task<Void, Never>?
    private var pendingSafetyScreenshot: PreparedSafetyScreenshot?
    private let screenChangeMonitor = SignificantScreenChangeMonitor()
    private var currentSafetyRisk: RiskDetectionResult?
    private var currentRiskTranscript = ""
    private var screenCaptureFailed = false
    private var pendingDiscoveryMode: AssistanceDiscoveryMode?
    private var broadcastSessionID: UUID?
    private var helpAttemptGate = SessionAttemptGate()
    private var helpTask: Task<Void, Never>?
    private var cancelledHelpTaskToDrain: Task<Void, Never>?

    init() {
        aiFeaturesEnabled = Self.defaultAIEnabled
        permissions = PermissionManager(includeAIFeatures: Self.defaultAIEnabled)
        do { api = EdgeAPIClient(configuration: try AppConfiguration.load()) }
        catch { errorMessage = localizedError(error) }
        overlay.model.language = language
        wireServices()
    }

    func startHelp(using discoveryMode: AssistanceDiscoveryMode) {
        guard !isEndingSession, phase == .idle || phase == .ended else { return }
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
            !isEndingSession,
            phase == .idle || phase == .ended,
            let discoveryMode = pendingDiscoveryMode
        else { return }
        isCameraConsentPresented = false
        isPreparingHelp = true
        statusMessage = copy("正在准备摄像头……", "Preparing the camera…")
        let attemptID = helpAttemptGate.begin()
        helpTask = Task {
            defer { finishHelpAttempt(attemptID) }
            let granted = await requestCameraAccess()
            guard isCurrentHelpAttempt(attemptID) else { return }
            guard granted else {
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
            await beginHelpSession(using: discoveryMode, attemptID: attemptID)
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

    private func beginHelpSession(
        using discoveryMode: AssistanceDiscoveryMode,
        attemptID: UUID
    ) async {
        guard isCurrentHelpAttempt(attemptID) else { return }
        if api == nil {
            do {
                api = EdgeAPIClient(configuration: try AppConfiguration.load())
            } catch {
                guard isCurrentHelpAttempt(attemptID) else { return }
                errorMessage = localizedError(error)
                return
            }
        }
        guard let api else { return }
        do {
            guard isCurrentHelpAttempt(attemptID) else { return }
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
            activeElderGoal = helpRequestGoal.trimmingCharacters(in: .whitespacesAndNewlines)
            if activeElderGoal.isEmpty {
                activeElderGoal = localized(
                    "老人没有说明具体目标；只判断明显安全风险，不判断是否偏离需求。",
                    "The elder did not state a goal. Assess obvious safety risks only, not goal mismatch.",
                    for: language
                )
            }
            let response = try await api.createSession()
            guard isCurrentHelpAttempt(attemptID), phase == .requesting else { return }
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
            guard isCurrentHelpAttempt(attemptID) else { return }
            isCallTransportConnected = true
            try await capture.start()
            guard isCurrentHelpAttempt(attemptID) else { return }

            if discoveryMode == .broadcast {
                await startAssistantBroadcast(
                    sessionID: response.sessionID,
                    fallbackCode: response.code,
                    attemptID: attemptID
                )
            } else {
                speakShareCode(response.code)
            }
        } catch {
            guard isCurrentHelpAttempt(attemptID) else { return }
            finishHelpAttempt(attemptID)
            await failAndEnd(error)
        }
    }

    private func startAssistantBroadcast(
        sessionID: UUID,
        fallbackCode: String,
        attemptID: UUID
    ) async {
        guard isCurrentHelpAttempt(attemptID), let api else { return }
        broadcastSessionID = sessionID
        statusMessage = copy(
            "正在向在线助手广播求助……",
            "Broadcasting your request to online volunteers…"
        )
        do {
            let response = try await api.setSessionBroadcast(
                BroadcastSessionRequest(sessionID: sessionID, isActive: true)
            )
            guard isCurrentHelpAttempt(attemptID) else { return }
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
            guard isCurrentHelpAttempt(attemptID), phase == .waiting else { return }
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
        cancelPendingHelpAttempt()
        Task { await endSessionNow() }
    }

    private func isCurrentHelpAttempt(_ attemptID: UUID) -> Bool {
        !Task.isCancelled && helpAttemptGate.accepts(attemptID)
    }

    private func finishHelpAttempt(_ attemptID: UUID) {
        guard helpAttemptGate.finish(attemptID) else { return }
        helpTask = nil
        isPreparingHelp = false
    }

    private func cancelPendingHelpAttempt() {
        helpAttemptGate.invalidate()
        guard let helpTask else {
            isPreparingHelp = false
            return
        }
        helpTask.cancel()
        cancelledHelpTaskToDrain = helpTask
        self.helpTask = nil
        isPreparingHelp = false
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
        safetyCredentialRequestsInFlight = []
        connectedSafetySpeakers = []
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
        dialogueTurns = []
        nextDialogueSequence = 1
        lastAnalyzedSequence = 0
        safetyAnalysisPending = false
        safetyAnalysisTask?.cancel()
        safetyAnalysisTask = nil
        pendingSafetyScreenshot = nil
        screenChangeMonitor.reset()
        errorMessage = nil

        beginSafetyStreaming(speaker: .elder, track: transport.elderMicrophoneTrack())
        if let volunteerAudioTrack {
            beginSafetyStreaming(speaker: .volunteer, track: volunteerAudioTrack)
        }
    }

    private func stopSafetyListening() {
        safetyStartRequested = false
        safetyRequestID = nil
        safetyCredentialRequestsInFlight = []
        connectedSafetySpeakers = []
        elderSafetyStreaming.stop()
        volunteerSafetyStreaming.stop()
        safetyAnalysisTask?.cancel()
        safetyAnalysisTask = nil
        safetyAnalysisPending = false
        pendingSafetyScreenshot = nil
        screenChangeMonitor.reset()
        safetyState = .off
        safetyStatusMessage = copy("安全监听已经停止。", "Safety monitoring has stopped.")
        livePartialTranscript = ""
        dismissSafetyWarning()
    }

    private func remoteAudioBecameAvailable(_ track: RemoteAudioTrack) {
        volunteerAudioTrack = track
        if safetyStartRequested, !connectedSafetySpeakers.contains(.volunteer) {
            beginSafetyStreaming(speaker: .volunteer, track: track)
        }
    }

    private func remoteAudioBecameUnavailable() {
        volunteerAudioTrack = nil
        volunteerSafetyStreaming.stop()
        connectedSafetySpeakers.remove(.volunteer)
        safetyCredentialRequestsInFlight.remove(.volunteer)
        if safetyStartRequested, connectedSafetySpeakers.contains(.elder) {
            markSafetyMonitoringDegraded(reason: copy(
                "志愿者声音已经断开，仍在监听老人端。",
                "The volunteer’s audio disconnected; elder-side monitoring remains active."
            ))
        } else {
            safetyMonitoringDisconnected(reason: copy(
                "志愿者声音已经断开。",
                "The volunteer’s audio disconnected."
            ))
        }
    }

    private func beginSafetyStreaming(speaker: CaptionSpeaker, track: any AudioTrack) {
        guard safetyStartRequested,
              !safetyCredentialRequestsInFlight.contains(speaker),
              !connectedSafetySpeakers.contains(speaker),
              let sessionID, let api, let elderLiveKitCredential,
              let requestID = safetyRequestID
        else { return }
        safetyCredentialRequestsInFlight.insert(speaker)
        safetyStatusMessage = copy("正在连接实时字幕……", "Connecting live captions…")

        Task {
            do {
                let credential = try await api.createAssemblyAIStreamingCredential(
                    sessionID: sessionID,
                    elderCredential: elderLiveKitCredential
                )
                guard safetyStartRequested,
                      safetyRequestID == requestID
                else { return }
                safetyCredentialRequestsInFlight.remove(speaker)
                try streamingService(for: speaker).start(track: track, token: credential.token)
            } catch {
                guard safetyRequestID == requestID else { return }
                safetyCredentialRequestsInFlight.remove(speaker)
                if connectedSafetySpeakers.isEmpty, safetyCredentialRequestsInFlight.isEmpty {
                    safetyMonitoringDisconnected(reason: copy(
                        "无法连接实时字幕服务，请稍后重试。",
                        "Could not connect to live captions. Try again later."
                    ))
                } else if !connectedSafetySpeakers.isEmpty {
                    markSafetyMonitoringDegraded(reason: copy(
                        "有一路实时字幕暂时不可用。",
                        "One live-caption audio source is temporarily unavailable."
                    ))
                } else {
                    safetyStatusMessage = copy(
                        "一路实时字幕连接失败，正在等待另一路……",
                        "One live-caption source failed; waiting for the other…"
                    )
                }
            }
        }
    }

    private func streamingService(for speaker: CaptionSpeaker) -> AssemblyAIStreamingService {
        speaker == .elder ? elderSafetyStreaming : volunteerSafetyStreaming
    }

    private func safetyStreamConnected(_ speaker: CaptionSpeaker) {
        guard safetyStartRequested else { return }
        connectedSafetySpeakers.insert(speaker)
        if connectedSafetySpeakers.contains(.elder), connectedSafetySpeakers.contains(.volunteer) {
            safetyState = .listening
            safetyStatusMessage = copy("正在监听双方对话……", "Listening to both sides…")
        } else {
            safetyState = .degraded
            safetyStatusMessage = copy(
                "正在监听一路声音，等待另一路接入……",
                "Listening to one side while waiting for the other…"
            )
        }
    }

    private func safetyStreamDisconnected(_ speaker: CaptionSpeaker) {
        connectedSafetySpeakers.remove(speaker)
        safetyCredentialRequestsInFlight.remove(speaker)
        guard safetyStartRequested else { return }
        if connectedSafetySpeakers.isEmpty {
            safetyMonitoringDisconnected(reason: copy(
                "实时字幕连接已断开，请稍后重试。",
                "Live captions disconnected. Try again later."
            ))
        } else {
            markSafetyMonitoringDegraded(reason: copy(
                "有一路实时字幕连接已断开。",
                "One live-caption audio source disconnected."
            ))
        }
    }

    private func safetyMonitoringDisconnected(reason: LocalizedCopy) {
        guard safetyState == .connecting || safetyState == .listening || safetyState == .degraded else { return }
        safetyStartRequested = false
        safetyRequestID = nil
        safetyCredentialRequestsInFlight = []
        connectedSafetySpeakers = []
        elderSafetyStreaming.stop()
        volunteerSafetyStreaming.stop()
        safetyAnalysisTask?.cancel()
        safetyAnalysisTask = nil
        safetyAnalysisPending = false
        pendingSafetyScreenshot = nil
        screenChangeMonitor.reset()
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

    private func handleSafetyTranscript(_ update: StreamingTranscript, speaker: CaptionSpeaker) async {
        guard safetyState == .listening || safetyState == .degraded else { return }
        let now = Date()
        let context = recentTranscript.transcripts(at: now)

        Task {
            try? await transport.publish(
                .caption(
                    speaker: speaker,
                    turnOrder: update.turnOrder,
                    text: update.text,
                    isFinal: update.isFinal
                ),
                reliable: update.isFinal
            )
        }

        if update.isFinal {
            livePartialTranscript = ""
            let speakerLabel = speaker == .elder
                ? localized("老人", "Elder", for: language)
                : localized("志愿者", "Volunteer", for: language)
            recentTranscript.append("\(speaker.rawValue): \(update.text)", at: now)
            recentTranscriptLines.append("\(speakerLabel)：\(update.text)")
            if recentTranscriptLines.count > 6 {
                recentTranscriptLines.removeFirst(recentTranscriptLines.count - 6)
            }
            dialogueTurns.append(.init(
                turn: .init(sequence: nextDialogueSequence, speaker: speaker, text: update.text),
                timestamp: now
            ))
            nextDialogueSequence += 1
            dialogueTurns.removeAll { now.timeIntervalSince($0.timestamp) > 30 }
            if dialogueTurns.count > 24 {
                dialogueTurns.removeFirst(dialogueTurns.count - 24)
            }
            scheduleSafetyAnalysis()
        } else {
            livePartialTranscript = "\(speaker == .elder ? localized("老人", "Elder", for: language) : localized("志愿者", "Volunteer", for: language))：\(update.text)"
        }

        guard speaker == .volunteer else { return }
        let decision = await riskPipeline.analyze(
            transcript: update.text,
            recentTranscript: context,
            currentContext: ["source": "volunteer_live_audio"]
        )
        guard decision.level != .safe,
              riskDeduplicator.shouldEmit(
                  decision,
                  transcript: update.text,
                  eventID: "volunteer-turn-\(update.turnOrder)",
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

    private func scheduleSafetyAnalysis() {
        safetyAnalysisPending = true
        guard safetyAnalysisTask == nil else { return }
        let requestID = safetyRequestID
        safetyAnalysisTask = Task { [weak self] in
            await self?.drainSafetyAnalysis(requestID: requestID)
        }
    }

    private func drainSafetyAnalysis(requestID: UUID?) async {
        defer {
            safetyAnalysisTask = nil
            if safetyAnalysisPending, safetyStartRequested, safetyRequestID == requestID {
                scheduleSafetyAnalysis()
            }
        }

        while safetyAnalysisPending, !Task.isCancelled,
              safetyStartRequested, safetyRequestID == requestID
        {
            safetyAnalysisPending = false
            guard let sessionID, let api, let elderLiveKitCredential,
                  let newest = dialogueTurns.last,
                  newest.turn.sequence > lastAnalyzedSequence
            else { continue }

            let screenshot = await prepareSafetyScreenshotIfNeeded()
            let request = AISafetyAnalysisRequest(
                sessionID: sessionID,
                elderGoal: activeElderGoal,
                throughSequence: newest.turn.sequence,
                dialogue: dialogueTurns.map(\.turn),
                screenshotBase64: screenshot?.base64,
                screenRevision: screenshot?.candidate.revision
            )

            do {
                let response = try await api.analyzeSafety(
                    request,
                    elderCredential: elderLiveKitCredential
                )
                guard safetyStartRequested, safetyRequestID == requestID,
                      response.throughSequence >= lastAnalyzedSequence
                else { continue }
                lastAnalyzedSequence = response.throughSequence
                if let screenshot {
                    screenChangeMonitor.commit(screenshot.candidate)
                    pendingSafetyScreenshot = nil
                }
                guard response.level != .safe else { continue }
                let transcript = dialogueTurns
                    .map { "\($0.turn.speaker.rawValue): \($0.turn.text)" }
                    .joined(separator: "\n")
                let decision = RiskDetectionResult(
                    level: response.level,
                    matchedRules: ["ai_\(response.category.rawValue)"],
                    message: response.reason
                )
                await emitAISafetyRisk(
                    decision,
                    transcript: transcript,
                    eventID: "ai-through-\(response.throughSequence)"
                )
            } catch is CancellationError {
                return
            } catch {
                markSafetyMonitoringDegraded(reason: copy(
                    "DeepSeek 安全分析暂时不可用，实时字幕和本机高危词提醒仍在工作。",
                    "DeepSeek safety analysis is unavailable; live captions and on-device high-risk checks still work."
                ))
            }
        }
    }

    private func prepareSafetyScreenshotIfNeeded() async -> PreparedSafetyScreenshot? {
        if let pendingSafetyScreenshot { return pendingSafetyScreenshot }
        guard let frame = capture.latestFrame.get(),
              let candidate = screenChangeMonitor.candidate(for: frame),
              let jpeg = await Task.detached(
                  priority: .utility,
                  operation: { RedactedJPEGEncoder.encode(frame) }
              ).value
        else { return nil }
        let prepared = PreparedSafetyScreenshot(
            base64: jpeg.base64EncodedString(),
            candidate: candidate
        )
        pendingSafetyScreenshot = prepared
        return prepared
    }

    private func emitAISafetyRisk(
        _ decision: RiskDetectionResult,
        transcript: String,
        eventID: String
    ) async {
        let now = Date()
        guard riskDeduplicator.shouldEmit(
            decision,
            transcript: transcript,
            eventID: eventID,
            at: now
        ), let sessionID, let api, let elderLiveKitCredential
        else { return }

        currentSafetyRisk = decision
        currentRiskTranscript = transcript
        overlay.model.showSafetyWarning(level: decision.level, transcript: decision.message)
        overlay.setSafetyWarningVisible(true)
        speech.speak(localized(
            "安全提醒。志愿者的指导可能有风险或偏离您的需求，请先停下来核对。",
            "Safety alert. The guidance may be risky or may not match your request. Pause and check before continuing.",
            for: language
        ))
        let message = DataMessage.safetyRisk(
            level: decision.level,
            transcript: transcript,
            matchedRules: decision.matchedRules
        )
        let boundedEventTranscript = String(transcript.prefix(1_000))
        let event = RiskEventRequest(
            sessionID: sessionID,
            timestamp: ISO8601DateFormatter().string(from: now),
            level: decision.level,
            transcript: boundedEventTranscript,
            matchedRules: decision.matchedRules
        )
        do { try await transport.publish(message) }
        catch { markSafetyMonitoringDegraded(reason: copy("志愿者通知暂时不可用。", "Volunteer notifications are temporarily unavailable.")) }
        do { _ = try await api.recordRiskEvent(event, elderCredential: elderLiveKitCredential) }
        catch { markSafetyMonitoringDegraded(reason: copy("后端告警记录暂时不可用。", "Server-side alert records are temporarily unavailable.")) }
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
        elderSafetyStreaming.onConnected = { [weak self] in
            Task { @MainActor in
                self?.safetyStreamConnected(.elder)
            }
        }
        elderSafetyStreaming.onTranscript = { [weak self] update in
            Task { @MainActor in await self?.handleSafetyTranscript(update, speaker: .elder) }
        }
        elderSafetyStreaming.onDisconnected = { [weak self] _ in
            Task { @MainActor in
                self?.safetyStreamDisconnected(.elder)
            }
        }
        volunteerSafetyStreaming.onConnected = { [weak self] in
            Task { @MainActor in
                self?.safetyStreamConnected(.volunteer)
            }
        }
        volunteerSafetyStreaming.onTranscript = { [weak self] update in
            Task { @MainActor in await self?.handleSafetyTranscript(update, speaker: .volunteer) }
        }
        volunteerSafetyStreaming.onDisconnected = { [weak self] _ in
            Task { @MainActor in
                self?.safetyStreamDisconnected(.volunteer)
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
        case .safetyRisk, .caption:
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
            guard let sessionID,
                  let elderLiveKitCredential,
                  let protectedFrame = capture.latestFrame.getSnapshot(),
                  let api
            else { return }
            guard let jpeg = await Task.detached(
                priority: .userInitiated,
                operation: { RedactedJPEGEncoder.encode(protectedFrame.frame) }
            ).value else {
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
                    axSummary: protectedFrame.axSummary
                )
                let response = try await api.requestGuide(
                    request,
                    elderCredential: elderLiveKitCredential
                )
                guideStatus = .verbatim(response.instructionText)
                speech.speak(response.instructionText)
                if let rect = response.targetRect { overlay.model.guide(rect: rect) }
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

        cancelPendingHelpAttempt()
        let cancelledHelpTask = cancelledHelpTaskToDrain
        cancelledHelpTaskToDrain = nil
        await cancelledHelpTask?.value

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
        activeElderGoal = ""
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
