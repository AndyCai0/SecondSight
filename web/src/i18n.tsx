/* oxlint-disable react/only-export-components -- shared localization is intentionally dependency-free */
import { useEffect, useMemo, useState } from 'react'

export type UILanguage = 'en' | 'zh'

const STORAGE_KEY = 'secondsight-ui-language'

export const messages = {
  volunteerPageTitle: { en: 'SecondSight · Volunteer Assistance', zh: 'SecondSight · 志愿者协助端' },
  volunteerPageDescription: {
    en: 'SecondSight volunteer-guided remote assistance',
    zh: 'SecondSight 志愿者远程协助',
  },
  alertsPageTitle: { en: 'SecondSight · Safety Alert History', zh: 'SecondSight · 安全提醒记录' },
  alertsPageDescription: {
    en: 'SecondSight safety alerts for one assistance session',
    zh: 'SecondSight 单次协助会话安全提醒',
  },
  homeAria: { en: 'SecondSight home', zh: 'SecondSight 首页' },
  tagline: { en: 'A second pair of eyes', zh: '您的第二双眼睛' },
  safetyPromise: {
    en: 'You can only watch and guide. The elder stays in control.',
    zh: '志愿者只能观看和指导，控制权始终在老人手中。',
  },
  language: { en: 'Language', zh: '语言' },
  switchToChinese: { en: '中文', zh: '中文' },
  switchToEnglish: { en: 'English', zh: 'English' },
  watchListenGuide: { en: 'WATCH · LISTEN · GUIDE', zh: '观看 · 倾听 · 指导' },
  heroTitle: {
    en: 'Help older adults navigate the digital world with confidence',
    zh: '陪伴老人安心使用数字世界',
  },
  heroIntro: {
    en: "Enter the room code shown on the elder's screen. You can talk, circle a location, and draw arrows, but you cannot click, type, or control their device.",
    zh: '输入老人屏幕上的房间码。您可以通话、圈出位置和画箭头，但不能点击、输入或控制对方设备。',
  },
  trustMasked: {
    en: "Sensitive areas are masked on the elder's device",
    zh: '敏感区域会在老人设备上自动遮挡',
  },
  trustMonitoring: {
    en: 'AI safety monitoring stays active throughout the session',
    zh: 'AI 安全监听会在协助期间持续保护老人',
  },
  trustAudit: {
    en: 'Important guidance and alerts are recorded for review',
    zh: '重要指导和安全提醒会留下记录，方便复核',
  },
  volunteerAccess: { en: 'VOLUNTEER ACCESS', zh: '志愿者入口' },
  remoteAssistance: { en: 'Remote Assistance', zh: '远程协助' },
  keepOpen: {
    en: 'Keep this page open to receive live help requests as soon as they arrive.',
    zh: '请保持此页面打开，新求助到达后会立即显示。',
  },
  availableVolunteer: { en: 'Available Volunteer', zh: '在线志愿者' },
  receiverConnecting: { en: 'Connecting to the request service', zh: '正在连接求助服务' },
  receiverReceiving: { en: 'Listening for help requests', zh: '正在接收求助广播' },
  receiverReconnecting: { en: 'Reconnecting to the request service', zh: '正在重新连接求助服务' },
  receiverUnavailable: { en: 'Live requests are not configured', zh: '尚未配置在线求助服务' },
  receiverConnectingDetail: { en: 'Registering your availability…', zh: '正在登记您的在线状态……' },
  receiverReceivingDetail: { en: 'New elder requests will appear automatically', zh: '新的老人求助会自动显示' },
  receiverReconnectingDetail: {
    en: 'The page will resume automatically without duplicate claims',
    zh: '页面会自动恢复，不会重复响应求助',
  },
  receiverUnavailableDetail: {
    en: 'You can still join with the 6-digit room code below',
    zh: '您仍可使用下方 6 位房间码加入',
  },
  newRequests: { en: 'New Help Requests', zh: '新的求助' },
  requestCount: { en: '{count} request', zh: '{count} 个求助' },
  requestsCount: { en: '{count} requests', zh: '{count} 个求助' },
  elderWaiting: { en: '{elder} is waiting for help', zh: '{elder}正在等待帮助' },
  responding: { en: 'Responding…', zh: '正在响应……' },
  respond: { en: 'Respond', zh: '响应求助' },
  roomDivider: { en: 'Or use a room code', zh: '或者使用房间码' },
  roomCodeLabel: { en: '6-digit room code', zh: '6 位房间码' },
  displayNameLabel: { en: 'Your display name', zh: '您的显示名称' },
  namePlaceholder: { en: 'e.g. Alex', zh: '例如：小李' },
  connectingSecurely: { en: 'Connecting securely…', zh: '正在安全连接……' },
  joinSession: { en: 'Join Assistance Session', zh: '加入协助' },
  mediaPermission: {
    en: 'Your browser asks for camera and microphone access only after you choose to join or respond. Both are required for live assistance.',
    zh: '只有在您加入或响应求助后，浏览器才会申请摄像头和麦克风权限；实时协助需要同时允许这两项权限。',
  },
  roomContext: { en: 'Room {code}', zh: '房间 {code}' },
  liveRequestContext: { en: 'Live help request', zh: '在线求助' },
  assistanceInProgress: { en: 'Assistance in Progress', zh: '正在协助' },
  volunteerName: { en: 'Volunteer: {name}', zh: '志愿者：{name}' },
  securelyConnected: { en: 'Securely connected', zh: '已安全连接' },
  viewAlerts: { en: 'View Safety Alerts', zh: '查看安全提醒' },
  endAssistance: { en: 'End Assistance', zh: '结束协助' },
  volunteerCameraStatus: { en: 'Volunteer camera status', zh: '志愿者摄像头状态' },
  cameraPreview: { en: 'Your camera preview', zh: '您的摄像头预览' },
  cameraOn: { en: 'Camera is on', zh: '摄像头已开启' },
  cameraAutoOff: {
    en: 'It turns off automatically when assistance ends',
    zh: '协助结束后会自动关闭',
  },
  liveSafetyAlert: { en: 'LIVE SAFETY ALERT', zh: '实时安全提醒' },
  dangerousLanguage: {
    en: 'Potentially dangerous language detected',
    zh: '检测到可能有危险的说法',
  },
  transcriptShortened: {
    en: 'The transcript was shortened to the first 1,000 characters.',
    zh: '文字记录已缩短为前 1,000 个字符。',
  },
  stopSensitiveRequest: {
    en: 'Stop asking for verification codes, passwords, payment details, or remote-control access immediately.',
    zh: '请立即停止索要验证码、密码、付款信息或远程控制权限。',
  },
  dismiss: { en: 'Dismiss', zh: '关闭提醒' },
  liveTranscriptKicker: { en: 'LIVE CONVERSATION', zh: '实时对话' },
  liveTranscript: { en: 'Live Transcript', zh: '实时字幕' },
  transcribing: { en: 'Transcribing', zh: '正在转写' },
  waitingForSpeech: { en: 'Waiting for speech', zh: '等待说话' },
  transcriptWaiting: {
    en: 'The elder and volunteer transcript will appear here as they speak.',
    zh: '老人和志愿者说话后，字幕会显示在这里。',
  },
  elderSpeaker: { en: 'Elder', zh: '老人' },
  volunteerSpeaker: { en: 'Volunteer', zh: '志愿者' },
  partialCaption: { en: 'listening…', zh: '正在听……' },
  faceToFace: { en: 'FACE-TO-FACE VIDEO', zh: '面对面视频' },
  elderCamera: { en: 'Elder Camera', zh: '老人摄像头' },
  videoConnected: { en: 'Video connected', zh: '视频已连接' },
  waitingVideo: { en: 'Waiting for video', zh: '等待视频' },
  elderCameraAria: { en: 'Elder camera video', zh: '老人摄像头视频' },
  waitingElderCamera: {
    en: 'Waiting for the elder to turn on their camera…',
    zh: '正在等待老人开启摄像头……',
  },
  videoAutoAppears: {
    en: 'The video will appear automatically when it is ready',
    zh: '视频准备好后会自动显示',
  },
  cameraSeparate: {
    en: 'Camera video is shown separately from the masked computer screen. Annotations only appear on the shared screen.',
    zh: '摄像头视频与已遮挡敏感信息的电脑画面分开显示；标注只会出现在共享屏幕上。',
  },
  remember: { en: 'Remember:', zh: '请记住：' },
  guidanceReminder: {
    en: 'Describe only what you can see on the screen. Never ask for passwords, verification codes, or payment details.',
    zh: '只描述屏幕上能看到的内容，绝不要索要密码、验证码或付款信息。',
  },
  auditFailed: {
    en: 'The audit record could not be delivered. The assistance view is still active.',
    zh: '审计记录暂时未能送达，但协助画面仍在正常工作。',
  },
  safetyActive: { en: 'SAFETY PROTECTION IS ACTIVE', zh: '安全保护已启动' },
  safetyPaused: {
    en: 'The AI safety monitor paused this session',
    zh: 'AI 安全监听已暂停本次通话',
  },
  safetyGuidance: {
    en: 'Stop asking for sensitive information. Only the elder can decide whether to resume.',
    zh: '请停止索要敏感信息。只有老人本人可以决定是否恢复通话。',
  },
  remoteScreenAria: { en: 'Remote assistance screen', zh: '远程协助屏幕' },
  elderScreenAria: { en: "Elder's shared screen", zh: '老人共享的屏幕' },
  annotationCanvas: { en: 'Annotation canvas', zh: '标注画布' },
  waitingElderScreen: {
    en: 'Waiting for the elder to share their screen…',
    zh: '正在等待老人共享屏幕……',
  },
  annotationTools: { en: 'Annotation tools', zh: '标注工具' },
  circleLocation: { en: 'Circle a location', zh: '圈出位置' },
  drawArrow: { en: 'Draw an arrow', zh: '画箭头' },
  laserPointer: { en: 'Laser pointer', zh: '激光指针' },
  clearAnnotations: { en: 'Clear annotations', zh: '清除标注' },
  enterRoomCode: { en: 'Enter the 6-digit room code.', zh: '请输入 6 位房间码。' },
  enterName: { en: 'Enter your display name.', zh: '请输入您的显示名称。' },
  enterNameBeforeResponding: {
    en: 'Enter your display name before responding to a request.',
    zh: '响应求助前，请先输入您的显示名称。',
  },
  serviceNotConfigured: {
    en: 'The service is not configured. Set the public Supabase environment variables first.',
    zh: '服务尚未配置，请先设置公开的 Supabase 环境变量。',
  },
  connectionInterrupted: {
    en: 'The connection was interrupted. Rejoin the room to continue.',
    zh: '连接已中断，请重新加入房间后继续。',
  },
  disconnectUnclean: {
    en: 'Assistance ended and your camera and microphone were stopped, but the connection did not close cleanly.',
    zh: '协助已结束，摄像头和麦克风也已停止，但连接未能正常关闭。',
  },
  annotationSendFailed: {
    en: 'Could not send the annotation. Check your connection.',
    zh: '标注发送失败，请检查网络连接。',
  },
  roomNotFound: {
    en: 'Room not found. Check the room code with the elder.',
    zh: '找不到房间，请和老人核对房间码。',
  },
  sessionEnded: {
    en: 'This assistance session has ended. Ask the elder to start a new one.',
    zh: '本次协助已经结束，请让老人重新发起求助。',
  },
  sessionPaused: {
    en: 'The safety monitor paused this session. Wait for the elder to continue.',
    zh: '安全监听已暂停本次通话，请等待老人决定是否继续。',
  },
  alreadyClaimed: {
    en: 'Another volunteer already responded to this request.',
    zh: '另一位志愿者已经响应了这次求助。',
  },
  invalidCredentials: {
    en: 'The connection credentials are invalid. Contact the session coordinator.',
    zh: '连接凭证无效，请联系会话协调人员。',
  },
  mediaRequired: {
    en: 'Camera and microphone access are required to assist. Allow access, then try again.',
    zh: '协助需要摄像头和麦克风权限，请允许后重试。',
  },
  mediaUnavailable: {
    en: 'The camera or microphone did not become available. Close other calls, then try again.',
    zh: '摄像头或麦克风暂时不可用，请先关闭其他通话后重试。',
  },
  joinFailed: {
    en: 'Unable to join the room. Check your connection, then try again.',
    zh: '无法加入房间，请检查网络后重试。',
  },
  justClaimed: {
    en: 'Another volunteer just responded to this request. Wait for the next request.',
    zh: '另一位志愿者刚刚响应了这次求助，请等待下一次求助。',
  },
  sentJustNow: { en: 'Sent just now', zh: '刚刚发出' },
  sentAt: { en: 'Sent at {time}', zh: '{time} 发出' },
  defaultElder: { en: 'The elder', zh: '老人' },
  backToConsole: { en: 'Back to Volunteer Console', zh: '返回志愿者控制台' },
  traceable: { en: 'SecondSight · Traceable by Design', zh: 'SecondSight · 全程可追溯' },
  safetyAudit: { en: 'SESSION SAFETY AUDIT', zh: '会话安全审计' },
  alertHistory: { en: 'Safety Alert History', zh: '安全提醒记录' },
  alertIntro: {
    en: 'Only alerts and session pauses generated by the AI safety monitor are shown.',
    zh: '这里仅显示 AI 安全监听生成的提醒和会话暂停记录。',
  },
  missingSession: {
    en: 'Session ID is missing. Open the alert history from the assistance page.',
    zh: '缺少会话 ID，请从协助页面打开安全提醒记录。',
  },
  loadingAlerts: { en: 'Loading safety alerts…', zh: '正在加载安全提醒……' },
  loadAlertsFailed: {
    en: 'Unable to load the alert history. Please try again shortly.',
    zh: '无法加载安全提醒记录，请稍后重试。',
  },
  noAlerts: {
    en: 'No safety alerts have been recorded for this session.',
    zh: '本次会话没有安全提醒记录。',
  },
  sessionPausedLabel: { en: 'Session Paused', zh: '会话已暂停' },
  safetyAlertLabel: { en: 'Safety Alert', zh: '安全提醒' },
  fakeElderPageTitle: { en: 'SecondSight · Fake Elder Protocol Test', zh: 'SecondSight · 模拟老人端协议测试' },
  fakeElderTitle: { en: 'Fake Elder Protocol Test', zh: '模拟老人端协议测试' },
  fakeElderIntro: {
    en: 'Call create-session or use a signed elder token, publish the browser screen, and display received DataChannel messages unchanged.',
    zh: '调用 create-session 或使用已签名的老人端令牌，共享浏览器屏幕，并原样显示收到的 DataChannel 消息。',
  },
  supabaseUrl: { en: 'Supabase URL', zh: 'Supabase 地址' },
  publicAnonKey: { en: 'Public anon key', zh: '公开匿名密钥' },
  signedLiveKitUrl: { en: 'Signed LiveKit URL (optional)', zh: '已签名 LiveKit 地址（可选）' },
  signedElderToken: { en: 'Signed elder token (optional)', zh: '已签名老人端令牌（可选）' },
  createAndShare: { en: 'Create Room and Share Screen', zh: '创建房间并共享屏幕' },
  statusLabel: { en: 'Status:', zh: '状态：' },
  notConnected: { en: 'Not connected', zh: '尚未连接' },
  roomCode: { en: 'Room code:', zh: '房间码：' },
  sharedScreenPreview: { en: 'Shared screen preview', zh: '共享屏幕预览' },
  receivedMessages: { en: 'Received DataChannel Messages', zh: '收到的 DataChannel 消息' },
  creatingAndConnecting: { en: 'Creating and connecting…', zh: '正在创建并连接……' },
  fakeElderCredentialRequired: {
    en: 'Enter a Supabase URL and public anon key, or provide both a signed LiveKit URL and token.',
    zh: '请输入 Supabase 地址和公开匿名密钥，或者同时提供已签名的 LiveKit 地址和令牌。',
  },
  disconnected: { en: 'Disconnected', zh: '连接已断开' },
  connectedSharing: {
    en: 'Connected as {identity}. Sharing the screen.',
    zh: '已以 {identity} 身份连接，正在共享屏幕。',
  },
  connected: { en: 'Connected', zh: '已连接' },
  connectionFailed: { en: 'Connection failed', zh: '连接失败' },
} as const

export type MessageKey = keyof typeof messages

export function translate(
  language: UILanguage,
  key: MessageKey,
  values: Record<string, string | number> = {},
): string {
  let result: string = messages[key][language]
  for (const [name, value] of Object.entries(values)) {
    result = result.replaceAll(`{${name}}`, String(value))
  }
  return result
}

export function resolveInitialLanguage(): UILanguage {
  try {
    const stored = window.localStorage.getItem(STORAGE_KEY)
    if (stored === 'en' || stored === 'zh') return stored
  } catch {
    // Storage can be unavailable in privacy-focused browser contexts.
  }
  return navigator.language.toLowerCase().startsWith('zh') ? 'zh' : 'en'
}

export function persistLanguage(language: UILanguage): void {
  try {
    window.localStorage.setItem(STORAGE_KEY, language)
  } catch {
    // The current page still switches language when persistence is unavailable.
  }
  document.documentElement.lang = language === 'zh' ? 'zh-Hans' : 'en'
}

export function localizeDocument(language: UILanguage, titleKey: MessageKey, descriptionKey: MessageKey): void {
  document.title = translate(language, titleKey)
  document.querySelector<HTMLMetaElement>('meta[name="description"]')?.setAttribute(
    'content',
    translate(language, descriptionKey),
  )
}

export function useUILanguage() {
  const [language, setLanguage] = useState<UILanguage>(resolveInitialLanguage)

  useEffect(() => {
    persistLanguage(language)
  }, [language])

  const t = useMemo(
    () => (key: MessageKey, values?: Record<string, string | number>) =>
      translate(language, key, values),
    [language],
  )

  return { language, setLanguage, t }
}

interface LanguageSwitchProps {
  language: UILanguage
  onChange(language: UILanguage): void
}

export function LanguageSwitch({ language, onChange }: LanguageSwitchProps) {
  return (
    <div className="language-switch" role="group" aria-label={translate(language, 'language')}>
      <button
        type="button"
        className={language === 'zh' ? 'selected' : ''}
        aria-pressed={language === 'zh'}
        onClick={() => onChange('zh')}
      >
        中文
      </button>
      <button
        type="button"
        className={language === 'en' ? 'selected' : ''}
        aria-pressed={language === 'en'}
        onClick={() => onChange('en')}
      >
        English
      </button>
    </div>
  )
}
