import { useEffect, useMemo, useRef, useState, type FormEvent } from 'react'
import { AnnotationSurface } from './AnnotationSurface'
import {
  ApiError,
  createSecondSightApi,
  type JoinedSession,
  type SecondSightApi,
} from './api'
import type { VolunteerOutboundMessage } from './contracts'
import {
  connectVolunteerSession,
  type ConnectVolunteerSession,
  type VolunteerSession,
} from './transport'
import './App.css'

interface ActiveSession {
  joined: JoinedSession
  live: VolunteerSession
  code: string
  volunteerName: string
}

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
  const [code, setCode] = useState('')
  const [name, setName] = useState('')
  const [active, setActive] = useState<ActiveSession | null>(null)
  const [joining, setJoining] = useState(false)
  const [error, setError] = useState('')
  const [frozenReason, setFrozenReason] = useState<string | null>(null)
  const [hasMedia, setHasMedia] = useState(false)
  const [auditFailed, setAuditFailed] = useState(false)
  const videoRef = useRef<HTMLVideoElement>(null)
  const audioRef = useRef<HTMLAudioElement>(null)
  const currentSession = useRef<VolunteerSession | null>(null)
  const manualDisconnect = useRef(false)

  useEffect(() => {
    if (active && videoRef.current && audioRef.current) {
      active.live.attachMedia(videoRef.current, audioRef.current)
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
    setHasMedia(false)
    setAuditFailed(false)
    manualDisconnect.current = false
    try {
      const joined = await configuredApi.joinSession({ code, name: name.trim() })
      const live = await connectSession(joined, {
        onFreeze: (reason) => setFrozenReason(reason),
        onResume: () => setFrozenReason(null),
        onDisconnected: () => {
          if (manualDisconnect.current) return
          currentSession.current = null
          setActive(null)
          setError('连接已断开，请重新进入房间')
        },
        onMediaChanged: () => setHasMedia(true),
      })
      currentSession.current = live
      setActive({ joined, live, code, volunteerName: name.trim() })
    } catch (cause) {
      setError(joinFailureMessage(cause))
    } finally {
      setJoining(false)
    }
  }

  async function leaveSession(): Promise<void> {
    if (!active) return
    manualDisconnect.current = true
    await active.live.disconnect()
    currentSession.current = null
    setActive(null)
    setFrozenReason(null)
    setHasMedia(false)
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
            <p className="card-description">房间码由长辈本人提供，有效期仅限本次协助。</p>
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
            <p className="microphone-note">进入后浏览器会请求麦克风权限，用于和长辈通话。</p>
          </section>
        </main>
      ) : (
        <main className="session-layout">
          <section className="session-heading">
            <div>
              <p className="eyebrow">房间 {active.code}</p>
              <h1>正在协助</h1>
              <p>志愿者：{active.volunteerName}</p>
            </div>
            <div className="session-actions">
              <span className="connection-pill"><i /> 已安全连接</span>
              <button className="leave-button" type="button" onClick={() => void leaveSession()}>
                结束本次协助
              </button>
            </div>
          </section>

          <AnnotationSurface
            videoRef={videoRef}
            hasMedia={hasMedia}
            disabled={frozenReason !== null}
            send={(message) => active.live.send(message)}
            log={audit}
            onSendError={() => setError('标注发送失败，请检查连接')}
          />
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
    if (cause.status === 401 || cause.status === 403) return '连接凭证无效，请联系现场负责人'
    return cause.message
  }
  if (cause instanceof DOMException && cause.name === 'NotAllowedError') {
    return '需要麦克风权限才能通话，请允许后重试'
  }
  return '暂时无法加入房间，请检查网络后重试'
}

export default App
