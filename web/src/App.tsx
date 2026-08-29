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
          name: nameRef.current.trim() || 'Available Volunteer',
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
      setError('Enter the 6-digit room code.')
      return
    }
    if (!name.trim()) {
      setError('Enter your display name.')
      return
    }
    if (!api && (!environment.VITE_SUPABASE_URL || !environment.VITE_SUPABASE_ANON_KEY)) {
      setError('The service is not configured. Set the public Supabase environment variables first.')
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
      await activateSession(joined, `Room ${code}`, name.trim())
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
      setError('Enter your display name before responding to a request.')
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
      await activateSession(joined, 'Live help request', volunteerName)
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
        setError('The connection was interrupted. Rejoin the room to continue.')
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
        <a className="brand" href="/" aria-label="SecondSight home">
          <span className="brand-mark" aria-hidden="true">S</span>
          <span>
            <strong>SecondSight</strong>
            <small>A second pair of eyes</small>
          </span>
        </a>
        <div className="safety-promise">
          <span aria-hidden="true">✓</span>
          You can only watch and guide. The elder stays in control.
        </div>
      </header>

      {!active ? (
        <main className="join-layout">
          <section className="join-copy">
            <p className="eyebrow">WATCH · LISTEN · GUIDE</p>
            <h1>Help older adults navigate<br />the digital world with confidence</h1>
            <p className="intro">
              Enter the room code shown on the elder&apos;s screen. You can talk, circle a location,
              and draw arrows, but you cannot click, type, or control their device.
            </p>
            <ul className="trust-list">
              <li><span aria-hidden="true">01</span> Sensitive areas are masked on the elder&apos;s device</li>
              <li><span aria-hidden="true">02</span> AI safety monitoring stays active throughout the session</li>
              <li><span aria-hidden="true">03</span> Important guidance and alerts are recorded for review</li>
            </ul>
          </section>

          <section className="join-card" aria-labelledby="join-title">
            <p className="card-step">VOLUNTEER ACCESS</p>
            <h2 id="join-title">Remote Assistance</h2>
            <p className="card-description">Keep this page open to receive live help requests as soon as they arrive.</p>
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
                  <h3 id="broadcast-title">New Help Requests</h3>
                  <span>{broadcasts.length} {broadcasts.length === 1 ? 'request' : 'requests'}</span>
                </div>
                {broadcasts.map((broadcast) => (
                  <article className="broadcast-card" key={broadcast.sessionId}>
                    <div>
                      <strong>{broadcast.elderLabel} is waiting for help</strong>
                      <time dateTime={broadcast.requestedAt}>
                        {formatBroadcastTime(broadcast.requestedAt)}
                      </time>
                    </div>
                    <button
                      type="button"
                      disabled={claimingSessionId !== null}
                      onClick={() => void claimBroadcast(broadcast)}
                    >
                      {claimingSessionId === broadcast.sessionId ? 'Responding…' : 'Respond'}
                    </button>
                  </article>
                ))}
              </section>
            )}

            <div className="join-divider"><span>Or use a room code</span></div>
            <form onSubmit={handleJoin}>
              <label htmlFor="room-code">6-digit room code</label>
              <input
                id="room-code"
                value={code}
                onChange={(event) => setCode(event.target.value.replace(/\D/g, '').slice(0, 6))}
                inputMode="numeric"
                autoComplete="one-time-code"
                placeholder="000 000"
                aria-describedby={error ? 'join-error' : undefined}
              />
              <label htmlFor="volunteer-name">Your display name</label>
              <input
                id="volunteer-name"
                value={name}
                onChange={(event) => setName(event.target.value.slice(0, 40))}
                autoComplete="nickname"
                placeholder="e.g. Alex"
              />
              {error && <p className="form-error" id="join-error" role="alert">{error}</p>}
              <button className="primary-button" type="submit" disabled={joining}>
                {joining ? 'Connecting securely…' : 'Join Assistance Session'}
              </button>
            </form>
            <p className="microphone-note">Your browser will request camera and microphone access after you join so you can speak with the elder.</p>
          </section>
        </main>
      ) : (
        <main className="session-layout">
          <section className="session-heading">
            <div>
              <p className="eyebrow">{active.contextLabel}</p>
              <h1>Assistance in Progress</h1>
              <p>Volunteer: {active.volunteerName}</p>
            </div>
            <div className="session-actions">
              <span className="connection-pill"><i /> Securely connected</span>
              <a
                className="alerts-link"
                href={`/alerts.html?session_id=${encodeURIComponent(active.joined.sessionId)}`}
                target="_blank"
                rel="noreferrer"
              >
                View Safety Alerts
              </a>
              <button className="leave-button" type="button" onClick={() => void leaveSession()}>
                End Assistance
              </button>
            </div>
          </section>

          {safetyRisk && (
            <section className={`safety-risk-card ${safetyRisk.level}`} role="alert">
              <div className="safety-risk-icon" aria-hidden="true">!</div>
              <div>
                <p className="eyebrow">LIVE SAFETY ALERT</p>
                <h2>Potentially dangerous language detected</h2>
                <p className="risk-transcript">“{safetyRisk.transcript}”</p>
                {safetyRisk.transcript_truncated && <p>The transcript was shortened to the first 1,000 characters.</p>}
                <p>Stop asking for verification codes, passwords, payment details, or remote-control access immediately.</p>
              </div>
              <button type="button" onClick={() => setSafetyRisk(null)}>Dismiss</button>
            </section>
          )}

          <div className="session-media-grid">
            <AnnotationSurface
              videoRef={videoRef}
              hasMedia={hasScreenMedia}
              disabled={frozenReason !== null}
              send={(message) => active.live.send(message)}
              log={audit}
              onSendError={() => setError('Could not send the annotation. Check your connection.')}
            />
            <aside className="camera-panel" aria-labelledby="elder-camera-title">
              <div className="camera-heading">
                <div>
                  <p className="camera-kicker">FACE-TO-FACE VIDEO</p>
                  <h2 id="elder-camera-title">Elder Camera</h2>
                </div>
                <span className={`camera-status ${hasCameraMedia ? 'connected' : ''}`}>
                  {hasCameraMedia ? 'Video connected' : 'Waiting for video'}
                </span>
              </div>
              <div className="camera-stage">
                <video ref={cameraRef} autoPlay playsInline aria-label="Elder camera video" />
                {!hasCameraMedia && (
                  <div className="camera-waiting" aria-live="polite">
                    <span aria-hidden="true">◎</span>
                    <strong>Waiting for the elder to turn on their camera…</strong>
                    <small>The video will appear automatically when it is ready</small>
                  </div>
                )}
              </div>
              <p className="camera-note">
                Camera video is shown separately from the masked computer screen. Annotations only appear on the shared screen.
              </p>
            </aside>
          </div>
          <audio ref={audioRef} autoPlay />
          <div className="session-footer">
            <p><strong>Remember:</strong> Describe only what you can see on the screen. Never ask for passwords, verification codes, or payment details.</p>
            {auditFailed && <p className="audit-warning" role="status">The audit record could not be delivered. The assistance view is still active.</p>}
            {error && <p className="form-error" role="alert">{error}</p>}
          </div>
        </main>
      )}

      {frozenReason && (
        <div
          className="freeze-overlay"
          role="alert"
          aria-labelledby="freeze-title"
          aria-describedby="freeze-reason freeze-guidance"
        >
          <div className="freeze-card">
            <span className="freeze-icon" aria-hidden="true">!</span>
            <p className="eyebrow">SAFETY PROTECTION IS ACTIVE</p>
            <h2 id="freeze-title">The AI safety monitor paused this session</h2>
            <p id="freeze-reason">{frozenReason}</p>
            <small id="freeze-guidance">Stop asking for sensitive information. Only the elder can decide whether to resume.</small>
          </div>
        </div>
      )}
    </div>
  )
}

function joinFailureMessage(cause: unknown): string {
  if (cause instanceof ApiError) {
    if (cause.status === 404) return 'Room not found. Check the room code with the elder.'
    if (cause.status === 410) return 'This assistance session has ended. Ask the elder to start a new one.'
    if (cause.status === 423) return 'The safety monitor paused this session. Wait for the elder to continue.'
    if (cause.status === 409) return 'Another volunteer already responded to this request.'
    if (cause.status === 401 || cause.status === 403) return 'The connection credentials are invalid. Contact the session coordinator.'
    return cause.message
  }
  if (cause instanceof DOMException && cause.name === 'NotAllowedError') {
    return 'Camera and microphone access are required to assist. Allow access, then try again.'
  }
  return 'Unable to join the room. Check your connection, then try again.'
}

function claimFailureMessage(cause: unknown): string {
  if (cause instanceof ApiError && cause.status === 409) {
    return 'Another volunteer just responded to this request. Wait for the next request.'
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
    case 'connecting': return 'Connecting to the request service'
    case 'receiving': return 'Listening for help requests'
    case 'reconnecting': return 'Reconnecting to the request service'
    case 'unavailable': return 'Live requests are not configured'
  }
}

function receiverStatusDetail(status: ReceiverStatus): string {
  switch (status) {
    case 'connecting': return 'Registering your availability…'
    case 'receiving': return 'New elder requests will appear automatically'
    case 'reconnecting': return 'The page will resume automatically without duplicate claims'
    case 'unavailable': return 'You can still join with the 6-digit room code below'
  }
}

function formatBroadcastTime(value: string): string {
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return 'Sent just now'
  return `Sent at ${new Intl.DateTimeFormat('en-AU', {
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
  }).format(date)}`
}

export default App
