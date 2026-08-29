import { useEffect, useMemo, useRef, useState, type FormEvent } from 'react'
import { AnnotationSurface } from './AnnotationSurface'
import {
  ApiError,
  createSecondSightApi,
  type HelpBroadcast,
  type JoinedSession,
  type SecondSightApi,
} from './api'
import type { SafetyRiskMessage, VolunteerOutboundMessage } from './contracts'
import {
  connectVolunteerSession,
  type ConnectVolunteerSession,
  type VolunteerSession,
} from './transport'
import './App.css'

interface ActiveSession {
  joined: JoinedSession
  live: VolunteerSession
  contextLabel: string
  volunteerName: string
}

type ReceiverStatus = 'connecting' | 'receiving' | 'reconnecting' | 'unavailable'

interface AppProps {
  api?: SecondSightApi
  connectSession?: ConnectVolunteerSession
}

function App({ api, connectSession = connectVolunteerSession }: AppProps) {
  const environment = import.meta.env
  const configuredApi = useMemo(() => api ?? createSecondSightApi({
    supabaseUrl: environment.VITE_SUPABASE_URL ?? '',
    supabaseAnonKey: environment.VITE_SUPABASE_ANON_KEY ?? '',
  }), [api, environment.VITE_SUPABASE_ANON_KEY, environment.VITE_SUPABASE_URL])
  const broadcastConfigured = Boolean(
    api || (environment.VITE_SUPABASE_URL && environment.VITE_SUPABASE_ANON_KEY),
  )
  const [code, setCode] = useState('')
  const [name, setName] = useState('')
  const [active, setActive] = useState<ActiveSession | null>(null)
  const [joining, setJoining] = useState(false)
  const [error, setError] = useState('')
  const [frozenReason, setFrozenReason] = useState<string | null>(null)
  const [hasScreenMedia, setHasScreenMedia] = useState(false)
  const [hasCameraMedia, setHasCameraMedia] = useState(false)
  const [auditFailed, setAuditFailed] = useState(false)
  const [safetyRisk, setSafetyRisk] = useState<SafetyRiskMessage | null>(null)
  const [broadcasts, setBroadcasts] = useState<HelpBroadcast[]>([])
  const [receiverStatus, setReceiverStatus] = useState<ReceiverStatus>(
    broadcastConfigured ? 'connecting' : 'unavailable',
  )
  const [claimingSessionId, setClaimingSessionId] = useState<string | null>(null)
  const videoRef = useRef<HTMLVideoElement>(null)
  const cameraRef = useRef<HTMLVideoElement>(null)
  const audioRef = useRef<HTMLAudioElement>(null)
  const currentSession = useRef<VolunteerSession | null>(null)
  const manualDisconnect = useRef(false)
  const nameRef = useRef(name)
  const assistantId = useMemo(() => resolveAssistantId(), [])

  useEffect(() => {
    nameRef.current = name
  }, [name])

  useEffect(() => {
    if (active) return
    if (!broadcastConfigured) return

    let cancelled = false
    let timer: number | undefined
    async function poll(): Promise<void> {
      try {
        const records = await configuredApi.pollBroadcasts({
          assistantId,
          name: nameRef.current.trim() || '待命助手',
        })
        if (cancelled) return
        setBroadcasts(records)
        setReceiverStatus('receiving')
      } catch {
        if (cancelled) return
        setReceiverStatus('reconnecting')
      } finally {
        if (!cancelled) timer = window.setTimeout(() => void poll(), 100)
      }
    }

    void poll()
    return () => {
      cancelled = true
      if (timer !== undefined) window.clearTimeout(timer)
    }
  }, [active, assistantId, broadcastConfigured, configuredApi])

  useEffect(() => {
    if (active && videoRef.current && cameraRef.current && audioRef.current) {
      active.live.attachMedia(videoRef.current, cameraRef.current, audioRef.current)
    }
  }, [active])

  useEffect(() => () => {
    manualDisconnect.current = true
    void currentSession.current?.disconnect()
  }, [])

  async function handleJoin(event: FormEvent<HTMLFormElement>): Promise<void> {
    event.preventDefault()
    setError('')
    if (!/^\d{6}$/.test(code)) {
      setError('请输入 6 位数字房间码')
      return
    }
    if (!name.trim()) {
      setError('请输入你的昵称')
      return
    }
    if (!api && (!environment.VITE_SUPABASE_URL || !environment.VITE_SUPABASE_ANON_KEY)) {
      setError('服务尚未配置，请先设置 Supabase 公共环境变量')
      return
    }

    setJoining(true)
    setHasScreenMedia(false)
    setHasCameraMedia(false)
    setAuditFailed(false)
    setSafetyRisk(null)
    manualDisconnect.current = false
    try {
      const joined = await configuredApi.joinSession({ code, name: name.trim() })
      await activateSession(joined, `房间 ${code}`, name.trim())
    } catch (cause) {
      setError(joinFailureMessage(cause))
    } finally {
      setJoining(false)
    }
  }

  async function claimBroadcast(broadcast: HelpBroadcast): Promise<void> {
    const volunteerName = name.trim()
    setError('')
    if (!volunteerName) {
      setError('请先输入你的昵称，再响应求助')
      return
    }
    if (claimingSessionId) return

    setClaimingSessionId(broadcast.sessionId)
    setHasScreenMedia(false)
    setHasCameraMedia(false)
    setAuditFailed(false)
    setSafetyRisk(null)
    manualDisconnect.current = false
    try {
      const joined = await configuredApi.claimBroadcast({
        sessionId: broadcast.sessionId,
        assistantId,
        name: volunteerName,
      })
      await activateSession(joined, '在线求助已接通', volunteerName)
    } catch (cause) {
      setError(claimFailureMessage(cause))
    } finally {
      setClaimingSessionId(null)
    }
  }

  async function activateSession(
    joined: JoinedSession,
    contextLabel: string,
    volunteerName: string,
  ): Promise<void> {
    const live = await connectSession(joined, {
      onFreeze: (reason) => setFrozenReason(reason),
      onResume: () => setFrozenReason(null),
      onDisconnected: () => {
        if (manualDisconnect.current) return
        currentSession.current = null
        setActive(null)
        setError('连接已断开，请重新进入房间')
      },
      onMediaChanged: (kind, isAvailable) => {
        if (kind === 'screen') setHasScreenMedia(isAvailable)
        if (kind === 'camera') setHasCameraMedia(isAvailable)
      },
      onRisk: setSafetyRisk,
    })
    currentSession.current = live
    setActive({ joined, live, contextLabel, volunteerName })
  }

  async function leaveSession(): Promise<void> {
    if (!active) return
    manualDisconnect.current = true
    await active.live.disconnect()
    currentSession.current = null
    setActive(null)
    setFrozenReason(null)
    setHasScreenMedia(false)
    setHasCameraMedia(false)
    setSafetyRisk(null)
  }

  function audit(message: VolunteerOutboundMessage): void {
    if (!active || message.type === 'pointer') return
    void configuredApi.logEvent({
      sessionId: active.joined.sessionId,
      actor: 'volunteer',
      kind: message.type,
      payload: message as unknown as Record<string, unknown>,
    }).catch(() => setAuditFailed(true))
  }

  return (
    <div className="app-shell">
      <header className="site-header">
        <a className="brand" href="/" aria-label="SecondSight 首页">
          <span className="brand-mark" aria-hidden="true">S</span>
          <span>
            <strong>SecondSight</strong>
            <small>第二双眼睛</small>
          </span>
        </a>
        <div className="safety-promise">
          <span aria-hidden="true">✓</span>
          你只能看和指，操作永远由长辈本人完成
        </div>
      </header>

      {!active ? (
        <main className="join-layout">
          <section className="join-copy">
            <p className="eyebrow">只看 · 只听 · 只指引</p>
            <h1>陪长辈把数字世界<br />走得更安心</h1>
            <p className="intro">
              输入长辈屏幕上的房间码。你可以语音沟通、圈出位置和画箭头，
              但无法点击、输入或控制对方设备。
            </p>
            <ul className="trust-list">
              <li><span aria-hidden="true">01</span> 画面中的敏感区域由长辈设备先行遮蔽</li>
              <li><span aria-hidden="true">02</span> AI 安全助手持续守护会话</li>
              <li><span aria-hidden="true">03</span> 关键指引和告警留有审计记录</li>
            </ul>
          </section>

          <section className="join-card" aria-labelledby="join-title">
            <p className="card-step">志愿者入口</p>
            <h2 id="join-title">加入协助房间</h2>
            <p className="card-description">保持此页面打开，即可第一时间收到长辈的在线求助。</p>
            <div className={`receiver-status receiver-status--${receiverStatus}`} role="status">
              <i aria-hidden="true" />
              <span>
                <strong>{receiverStatusLabel(receiverStatus)}</strong>
                <small>{receiverStatusDetail(receiverStatus)}</small>
              </span>
            </div>

            {broadcasts.length > 0 && (
              <section className="broadcast-list" aria-labelledby="broadcast-title">
                <div className="broadcast-list__heading">
                  <h3 id="broadcast-title">收到新的求助</h3>
                  <span>{broadcasts.length} 条</span>
                </div>
                {broadcasts.map((broadcast) => (
                  <article className="broadcast-card" key={broadcast.sessionId}>
                    <div>
                      <strong>{broadcast.elderLabel}正在等待帮助</strong>
                      <time dateTime={broadcast.requestedAt}>
                        {formatBroadcastTime(broadcast.requestedAt)}
                      </time>
                    </div>
                    <button
                      type="button"
                      disabled={claimingSessionId !== null}
                      onClick={() => void claimBroadcast(broadcast)}
                    >
                      {claimingSessionId === broadcast.sessionId ? '正在响应…' : '响应求助'}
                    </button>
                  </article>
                ))}
              </section>
            )}

            <div className="join-divider"><span>或使用分享码</span></div>
            <form onSubmit={handleJoin}>
              <label htmlFor="room-code">6 位房间码</label>
              <input
                id="room-code"
                value={code}
                onChange={(event) => setCode(event.target.value.replace(/\D/g, '').slice(0, 6))}
                inputMode="numeric"
                autoComplete="one-time-code"
                placeholder="000 000"
                aria-describedby={error ? 'join-error' : undefined}
              />
              <label htmlFor="volunteer-name">你的昵称</label>
              <input
                id="volunteer-name"
                value={name}
                onChange={(event) => setName(event.target.value.slice(0, 40))}
                autoComplete="nickname"
                placeholder="例如：小王"
              />
              {error && <p className="form-error" id="join-error" role="alert">{error}</p>}
              <button className="primary-button" type="submit" disabled={joining}>
                {joining ? '正在安全连接…' : '进入协助房间'}
              </button>
            </form>
            <p className="microphone-note">进入后浏览器会请求摄像头和麦克风权限，用于和长辈视频通话。</p>
          </section>
        </main>
      ) : (
        <main className="session-layout">
          <section className="session-heading">
            <div>
              <p className="eyebrow">{active.contextLabel}</p>
              <h1>正在协助</h1>
              <p>志愿者：{active.volunteerName}</p>
            </div>
            <div className="session-actions">
              <span className="connection-pill"><i /> 已安全连接</span>
              <a
                className="alerts-link"
                href={`/alerts.html?session_id=${encodeURIComponent(active.joined.sessionId)}`}
                target="_blank"
                rel="noreferrer"
              >
                查看安全告警记录
              </a>
              <button className="leave-button" type="button" onClick={() => void leaveSession()}>
                结束本次协助
              </button>
            </div>
          </section>

          {safetyRisk && (
            <section className={`safety-risk-card ${safetyRisk.level}`} role="alert">
              <div className="safety-risk-icon" aria-hidden="true">!</div>
              <div>
                <p className="eyebrow">实时安全提醒</p>
                <h2>长辈端检测到危险话术</h2>
                <p className="risk-transcript">“{safetyRisk.transcript}”</p>
                {safetyRisk.transcript_truncated && <p>字幕过长，风险卡只显示前 1,000 个字符。</p>}
                <p>请立即停止询问验证码、密码、付款信息或远程控制权限。</p>
              </div>
              <button type="button" onClick={() => setSafetyRisk(null)}>我知道了</button>
            </section>
          )}

          <div className="session-media-grid">
            <AnnotationSurface
              videoRef={videoRef}
              hasMedia={hasScreenMedia}
              disabled={frozenReason !== null}
              send={(message) => active.live.send(message)}
              log={audit}
              onSendError={() => setError('标注发送失败，请检查连接')}
            />
            <aside className="camera-panel" aria-labelledby="elder-camera-title">
              <div className="camera-heading">
                <div>
                  <p className="camera-kicker">面对面沟通</p>
                  <h2 id="elder-camera-title">长辈本人</h2>
                </div>
                <span className={`camera-status ${hasCameraMedia ? 'connected' : ''}`}>
                  {hasCameraMedia ? '画面已连接' : '等待画面'}
                </span>
              </div>
              <div className="camera-stage">
                <video ref={cameraRef} autoPlay playsInline aria-label="长辈摄像头画面" />
                {!hasCameraMedia && (
                  <div className="camera-waiting" aria-live="polite">
                    <span aria-hidden="true">◎</span>
                    <strong>等待长辈开启摄像头…</strong>
                    <small>摄像头就绪后会自动出现</small>
                  </div>
                )}
              </div>
              <p className="camera-note">
                摄像头与脱敏电脑画面分开显示，标注只会落在电脑画面上。
              </p>
            </aside>
          </div>
          <audio ref={audioRef} autoPlay />
          <div className="session-footer">
            <p><strong>记住：</strong>只描述屏幕上看见的内容，不询问密码、验证码或付款信息。</p>
            {auditFailed && <p className="audit-warning" role="status">审计记录暂时未送达，协助画面不受影响。</p>}
            {error && <p className="form-error" role="alert">{error}</p>}
          </div>
        </main>
      )}

      {frozenReason && (
        <div className="freeze-overlay" role="alertdialog" aria-modal="true">
          <div className="freeze-card">
            <span className="freeze-icon" aria-hidden="true">!</span>
            <p className="eyebrow">安全保护已启动</p>
            <h2>会话已被 AI 安全助手暂停</h2>
            <p>{frozenReason}</p>
            <small>请停止询问敏感信息。只有长辈端可以决定是否恢复会话。</small>
          </div>
        </div>
      )}
    </div>
  )
}

function joinFailureMessage(cause: unknown): string {
  if (cause instanceof ApiError) {
    if (cause.status === 404) return '没有找到这个房间，请和长辈核对房间码'
    if (cause.status === 410) return '这次协助已经结束，请让长辈重新发起'
    if (cause.status === 423) return '这次协助已被安全助手暂停，请等待长辈处理'
    if (cause.status === 409) return '这次求助已经有志愿者接入'
    if (cause.status === 401 || cause.status === 403) return '连接凭证无效，请联系现场负责人'
    return cause.message
  }
  if (cause instanceof DOMException && cause.name === 'NotAllowedError') {
    return '需要摄像头和麦克风权限才能通话，请允许后重试'
  }
  return '暂时无法加入房间，请检查网络后重试'
}

function claimFailureMessage(cause: unknown): string {
  if (cause instanceof ApiError && cause.status === 409) {
    return '这条求助刚刚已被其他志愿者响应，请等待下一条广播'
  }
  return joinFailureMessage(cause)
}

function resolveAssistantId(): string {
  const storageKey = 'secondsight-assistant-id'
  try {
    const stored = window.sessionStorage.getItem(storageKey)
    if (stored) return stored
    const created = crypto.randomUUID()
    window.sessionStorage.setItem(storageKey, created)
    return created
  } catch {
    return crypto.randomUUID()
  }
}

function receiverStatusLabel(status: ReceiverStatus): string {
  switch (status) {
    case 'connecting': return '正在连接广播服务'
    case 'receiving': return '正在接收广播'
    case 'reconnecting': return '广播连接正在恢复'
    case 'unavailable': return '广播服务尚未配置'
  }
}

function receiverStatusDetail(status: ReceiverStatus): string {
  switch (status) {
    case 'connecting': return '正在登记你的在线状态…'
    case 'receiving': return '页面会自动显示新的长辈求助'
    case 'reconnecting': return '不会重复认领，网络恢复后自动继续'
    case 'unavailable': return '仍可使用下方 6 位分享码加入'
  }
}

function formatBroadcastTime(value: string): string {
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return '刚刚发出'
  return `${new Intl.DateTimeFormat('zh-CN', {
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
  }).format(date)} 发出`
}

export default App
