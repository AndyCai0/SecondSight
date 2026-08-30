import { useEffect, useMemo, useRef, useState, type FormEvent } from 'react'
import { AnnotationSurface } from './AnnotationSurface'
import {
  LanguageSwitch,
  localizeDocument,
  type MessageKey,
  type UILanguage,
  useUILanguage,
} from './i18n'
import {
  ApiError,
  createSecondSightApi,
  type HelpBroadcast,
  type JoinedSession,
  type SecondSightApi,
} from './api'
import type {
  CaptionTranscriptMessage,
  SafetyRiskMessage,
  VolunteerOutboundMessage,
} from './contracts'
import {
  acquireVolunteerMedia,
  connectVolunteerSession,
  type AcquireVolunteerMedia,
  type ConnectVolunteerSession,
  type PreparedVolunteerMedia,
  type VolunteerSession,
} from './transport'
import './App.css'

interface ActiveSession {
  joined: JoinedSession
  live: VolunteerSession
  context: { kind: 'room'; code: string } | { kind: 'live-request' }
  volunteerName: string
}

type ReceiverStatus = 'connecting' | 'receiving' | 'reconnecting' | 'unavailable'
type Translator = (key: MessageKey, values?: Record<string, string | number>) => string

interface AppProps {
  api?: SecondSightApi
  acquireMedia?: AcquireVolunteerMedia
  connectSession?: ConnectVolunteerSession
}

interface CaptionDisplay extends CaptionTranscriptMessage {
  receivedOrder: number
}

function App({
  api,
  acquireMedia = acquireVolunteerMedia,
  connectSession = connectVolunteerSession,
}: AppProps) {
  const { language, setLanguage, t } = useUILanguage()
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
  const [captions, setCaptions] = useState<CaptionDisplay[]>([])
  const [broadcasts, setBroadcasts] = useState<HelpBroadcast[]>([])
  const [receiverStatus, setReceiverStatus] = useState<ReceiverStatus>(
    broadcastConfigured ? 'connecting' : 'unavailable',
  )
  const [claimingSessionId, setClaimingSessionId] = useState<string | null>(null)
  const videoRef = useRef<HTMLVideoElement>(null)
  const cameraRef = useRef<HTMLVideoElement>(null)
  const audioRef = useRef<HTMLAudioElement>(null)
  const localCameraRef = useRef<HTMLVideoElement>(null)
  const currentSession = useRef<VolunteerSession | null>(null)
  const manualDisconnect = useRef(false)
  const entryInFlight = useRef(false)
  const nameRef = useRef(name)
  const captionOrder = useRef(0)
  const assistantId = useMemo(() => resolveAssistantId(), [])

  useEffect(() => {
    localizeDocument(language, 'volunteerPageTitle', 'volunteerPageDescription')
  }, [language])

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
          name: nameRef.current.trim() || t('availableVolunteer'),
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
  }, [active, assistantId, broadcastConfigured, configuredApi, t])

  useEffect(() => {
    if (
      active && videoRef.current && cameraRef.current && audioRef.current &&
      localCameraRef.current
    ) {
      active.live.attachMedia(videoRef.current, cameraRef.current, audioRef.current)
      active.live.attachLocalCamera(localCameraRef.current)
    }
  }, [active])

  useEffect(() => () => {
    manualDisconnect.current = true
    const session = currentSession.current
    currentSession.current = null
    void session?.disconnect().catch(() => undefined)
  }, [])

  async function handleJoin(event: FormEvent<HTMLFormElement>): Promise<void> {
    event.preventDefault()
    if (entryInFlight.current) return
    setError('')
    if (!/^\d{6}$/.test(code)) {
      setError(t('enterRoomCode'))
      return
    }
    if (!name.trim()) {
      setError(t('enterName'))
      return
    }
    if (!api && (!environment.VITE_SUPABASE_URL || !environment.VITE_SUPABASE_ANON_KEY)) {
      setError(t('serviceNotConfigured'))
      return
    }

    entryInFlight.current = true
    setJoining(true)
    setHasScreenMedia(false)
    setHasCameraMedia(false)
    setAuditFailed(false)
    setSafetyRisk(null)
    setCaptions([])
    manualDisconnect.current = false
    let media: PreparedVolunteerMedia | null = null
    try {
      media = await acquireMedia()
      const joined = await configuredApi.joinSession({ code, name: name.trim() })
      await activateSession(joined, { kind: 'room', code }, name.trim(), media)
      media = null
    } catch (cause) {
      media?.stop()
      setError(joinFailureMessage(cause, t))
    } finally {
      entryInFlight.current = false
      setJoining(false)
    }
  }

  async function claimBroadcast(broadcast: HelpBroadcast): Promise<void> {
    if (entryInFlight.current) return
    const volunteerName = name.trim()
    setError('')
    if (!volunteerName) {
      setError(t('enterNameBeforeResponding'))
      return
    }

    entryInFlight.current = true
    setClaimingSessionId(broadcast.sessionId)
    setHasScreenMedia(false)
    setHasCameraMedia(false)
    setAuditFailed(false)
    setSafetyRisk(null)
    setCaptions([])
    manualDisconnect.current = false
    let media: PreparedVolunteerMedia | null = null
    try {
      media = await acquireMedia()
      const joined = await configuredApi.claimBroadcast({
        sessionId: broadcast.sessionId,
        assistantId,
        name: volunteerName,
      })
      await activateSession(joined, { kind: 'live-request' }, volunteerName, media)
      media = null
    } catch (cause) {
      media?.stop()
      setError(claimFailureMessage(cause, t))
    } finally {
      entryInFlight.current = false
      setClaimingSessionId(null)
    }
  }

  async function activateSession(
    joined: JoinedSession,
    context: ActiveSession['context'],
    volunteerName: string,
    media: PreparedVolunteerMedia,
  ): Promise<void> {
    const live = await connectSession(joined, {
      onFreeze: (reason) => setFrozenReason(reason),
      onResume: () => setFrozenReason(null),
      onDisconnected: () => {
        if (manualDisconnect.current) return
        currentSession.current = null
        setActive(null)
        setCaptions([])
        setError(t('connectionInterrupted'))
      },
      onMediaChanged: (kind, isAvailable) => {
        if (kind === 'screen') setHasScreenMedia(isAvailable)
        if (kind === 'camera') setHasCameraMedia(isAvailable)
      },
      onRisk: setSafetyRisk,
      onCaption: handleCaption,
    }, media)
    currentSession.current = live
    setActive({ joined, live, context, volunteerName })
  }

  async function leaveSession(): Promise<void> {
    if (!active) return
    manualDisconnect.current = true
    let disconnectFailed = false
    try {
      await active.live.disconnect()
    } catch {
      disconnectFailed = true
    } finally {
      currentSession.current = null
      setActive(null)
      setFrozenReason(null)
      setHasScreenMedia(false)
      setHasCameraMedia(false)
      setSafetyRisk(null)
      setCaptions([])
    }
    if (disconnectFailed) {
      setError(t('disconnectUnclean'))
    }
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

  function handleCaption(caption: CaptionTranscriptMessage): void {
    setCaptions((current) => {
      const index = current.findIndex((item) =>
        item.speaker === caption.speaker && item.turn_order === caption.turn_order
      )
      const receivedOrder = index >= 0
        ? current[index].receivedOrder
        : captionOrder.current++
      const next = index >= 0
        ? current.map((item, itemIndex) =>
          itemIndex === index ? { ...caption, receivedOrder } : item
        )
        : [...current, { ...caption, receivedOrder }]
      return next.sort((a, b) => a.receivedOrder - b.receivedOrder).slice(-10)
    })
  }

  return (
    <div className="app-shell">
      <header className="site-header">
        <a className="brand" href="/" aria-label={t('homeAria')}>
          <span className="brand-mark" aria-hidden="true">S</span>
          <span>
            <strong>SecondSight</strong>
            <small>{t('tagline')}</small>
          </span>
        </a>
        <div className="header-actions">
          <div className="safety-promise">
            <span aria-hidden="true">✓</span>
            {t('safetyPromise')}
          </div>
          <LanguageSwitch language={language} onChange={setLanguage} />
        </div>
      </header>

      {!active ? (
        <main className="join-layout">
          <section className="join-copy">
            <p className="eyebrow">{t('watchListenGuide')}</p>
            <h1>{t('heroTitle')}</h1>
            <p className="intro">{t('heroIntro')}</p>
            <ul className="trust-list">
              <li><span aria-hidden="true">01</span> {t('trustMasked')}</li>
              <li><span aria-hidden="true">02</span> {t('trustMonitoring')}</li>
              <li><span aria-hidden="true">03</span> {t('trustAudit')}</li>
            </ul>
          </section>

          <section className="join-card" aria-labelledby="join-title">
            <p className="card-step">{t('volunteerAccess')}</p>
            <h2 id="join-title">{t('remoteAssistance')}</h2>
            <p className="card-description">{t('keepOpen')}</p>
            <div className={`receiver-status receiver-status--${receiverStatus}`} role="status">
              <i aria-hidden="true" />
              <span>
                <strong>{receiverStatusLabel(receiverStatus, t)}</strong>
                <small>{receiverStatusDetail(receiverStatus, t)}</small>
              </span>
            </div>

            {broadcasts.length > 0 && (
              <section className="broadcast-list" aria-labelledby="broadcast-title">
                <div className="broadcast-list__heading">
                  <h3 id="broadcast-title">{t('newRequests')}</h3>
                  <span>{t(broadcasts.length === 1 ? 'requestCount' : 'requestsCount', { count: broadcasts.length })}</span>
                </div>
                {broadcasts.map((broadcast) => (
                  <article className="broadcast-card" key={broadcast.sessionId}>
                    <div>
                      <strong>{t('elderWaiting', { elder: displayElderLabel(broadcast.elderLabel, t) })}</strong>
                      <time dateTime={broadcast.requestedAt}>
                        {formatBroadcastTime(broadcast.requestedAt, language, t)}
                      </time>
                    </div>
                    <button
                      type="button"
                      disabled={joining || claimingSessionId !== null}
                      onClick={() => void claimBroadcast(broadcast)}
                    >
                      {t(claimingSessionId === broadcast.sessionId ? 'responding' : 'respond')}
                    </button>
                  </article>
                ))}
              </section>
            )}

            <div className="join-divider"><span>{t('roomDivider')}</span></div>
            <form onSubmit={handleJoin}>
              <label htmlFor="room-code">{t('roomCodeLabel')}</label>
              <input
                id="room-code"
                value={code}
                onChange={(event) => setCode(event.target.value.replace(/\D/g, '').slice(0, 6))}
                inputMode="numeric"
                autoComplete="one-time-code"
                placeholder="000 000"
                aria-describedby={error ? 'join-error' : undefined}
              />
              <label htmlFor="volunteer-name">{t('displayNameLabel')}</label>
              <input
                id="volunteer-name"
                value={name}
                onChange={(event) => setName(event.target.value.slice(0, 40))}
                autoComplete="nickname"
                placeholder={t('namePlaceholder')}
              />
              {error && <p className="form-error" id="join-error" role="alert">{error}</p>}
              <button
                className="primary-button"
                type="submit"
                disabled={joining || claimingSessionId !== null}
              >
                {t(joining ? 'connectingSecurely' : 'joinSession')}
              </button>
            </form>
            <p className="media-permission-note">
              {t('mediaPermission')}
            </p>
          </section>
        </main>
      ) : (
        <main className="session-layout">
          <section className="session-heading">
            <div>
              <p className="eyebrow">
                {active.context.kind === 'room'
                  ? t('roomContext', { code: active.context.code })
                  : t('liveRequestContext')}
              </p>
              <h1>{t('assistanceInProgress')}</h1>
              <p>{t('volunteerName', { name: active.volunteerName })}</p>
            </div>
            <div className="session-actions">
              <span className="connection-pill"><i /> {t('securelyConnected')}</span>
              <a
                className="alerts-link"
                href={`/alerts.html?session_id=${encodeURIComponent(active.joined.sessionId)}`}
                target="_blank"
                rel="noreferrer"
              >
                {t('viewAlerts')}
              </a>
              <button className="leave-button" type="button" onClick={() => void leaveSession()}>
                {t('endAssistance')}
              </button>
            </div>
          </section>

          <section className="volunteer-camera-card" aria-label={t('volunteerCameraStatus')}>
            <video
              ref={localCameraRef}
              aria-label={t('cameraPreview')}
              autoPlay
              playsInline
              muted
            />
            <div>
              <strong><i aria-hidden="true" /> {t('cameraOn')}</strong>
              <small>{t('cameraAutoOff')}</small>
            </div>
          </section>

          {safetyRisk && (
            <section className={`safety-risk-card ${safetyRisk.level}`} role="alert">
              <div className="safety-risk-icon" aria-hidden="true">!</div>
              <div>
                <p className="eyebrow">{t('liveSafetyAlert')}</p>
                <h2>{t('dangerousLanguage')}</h2>
                <p className="risk-transcript">“{safetyRisk.transcript}”</p>
                {safetyRisk.transcript_truncated && <p>{t('transcriptShortened')}</p>}
                <p>{t('stopSensitiveRequest')}</p>
              </div>
              <button type="button" onClick={() => setSafetyRisk(null)}>{t('dismiss')}</button>
            </section>
          )}

          <section className="live-transcript-card" aria-labelledby="live-transcript-title">
            <div className="live-transcript-heading">
              <div>
                <p className="eyebrow">{t('liveTranscriptKicker')}</p>
                <h2 id="live-transcript-title">{t('liveTranscript')}</h2>
              </div>
              <span aria-live="polite">{captions.length > 0 ? t('transcribing') : t('waitingForSpeech')}</span>
            </div>
            {captions.length === 0 ? (
              <p className="transcript-empty">{t('transcriptWaiting')}</p>
            ) : (
              <ol className="transcript-lines" aria-live="polite">
                {captions.map((caption) => (
                  <li
                    key={`${caption.speaker}:${caption.turn_order}`}
                    className={caption.is_final ? '' : 'partial'}
                  >
                    <strong>{t(caption.speaker === 'elder' ? 'elderSpeaker' : 'volunteerSpeaker')}</strong>
                    <span>{caption.text}</span>
                    {!caption.is_final && <small>{t('partialCaption')}</small>}
                  </li>
                ))}
              </ol>
            )}
          </section>

          <div className="session-media-grid">
            <AnnotationSurface
              videoRef={videoRef}
              hasMedia={hasScreenMedia}
              disabled={frozenReason !== null}
              language={language}
              send={(message) => active.live.send(message)}
              log={audit}
              onSendError={() => setError(t('annotationSendFailed'))}
            />
            <aside className="camera-panel" aria-labelledby="elder-camera-title">
              <div className="camera-heading">
                <div>
                  <p className="camera-kicker">{t('faceToFace')}</p>
                  <h2 id="elder-camera-title">{t('elderCamera')}</h2>
                </div>
                <span className={`camera-status ${hasCameraMedia ? 'connected' : ''}`}>
                  {t(hasCameraMedia ? 'videoConnected' : 'waitingVideo')}
                </span>
              </div>
              <div className="camera-stage">
                <video ref={cameraRef} autoPlay playsInline aria-label={t('elderCameraAria')} />
                {!hasCameraMedia && (
                  <div className="camera-waiting" aria-live="polite">
                    <span aria-hidden="true">◎</span>
                    <strong>{t('waitingElderCamera')}</strong>
                    <small>{t('videoAutoAppears')}</small>
                  </div>
                )}
              </div>
              <p className="camera-note">
                {t('cameraSeparate')}
              </p>
            </aside>
          </div>
          <audio ref={audioRef} autoPlay />
          <div className="session-footer">
            <p><strong>{t('remember')}</strong> {t('guidanceReminder')}</p>
            {auditFailed && <p className="audit-warning" role="status">{t('auditFailed')}</p>}
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
            <p className="eyebrow">{t('safetyActive')}</p>
            <h2 id="freeze-title">{t('safetyPaused')}</h2>
            <p id="freeze-reason">{frozenReason}</p>
            <small id="freeze-guidance">{t('safetyGuidance')}</small>
          </div>
        </div>
      )}
    </div>
  )
}

function joinFailureMessage(cause: unknown, t: Translator): string {
  if (cause instanceof ApiError) {
    if (cause.status === 404) return t('roomNotFound')
    if (cause.status === 410) return t('sessionEnded')
    if (cause.status === 423) return t('sessionPaused')
    if (cause.status === 409) return t('alreadyClaimed')
    if (cause.status === 401 || cause.status === 403) return t('invalidCredentials')
    return t('joinFailed')
  }
  if (cause instanceof DOMException && cause.name === 'NotAllowedError') {
    return t('mediaRequired')
  }
  if (cause instanceof Error && cause.message === 'Camera and microphone access timed out') {
    return t('mediaUnavailable')
  }
  return t('joinFailed')
}

function claimFailureMessage(cause: unknown, t: Translator): string {
  if (cause instanceof ApiError && cause.status === 409) {
    return t('justClaimed')
  }
  return joinFailureMessage(cause, t)
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

function receiverStatusLabel(status: ReceiverStatus, t: Translator): string {
  switch (status) {
    case 'connecting': return t('receiverConnecting')
    case 'receiving': return t('receiverReceiving')
    case 'reconnecting': return t('receiverReconnecting')
    case 'unavailable': return t('receiverUnavailable')
  }
}

function receiverStatusDetail(status: ReceiverStatus, t: Translator): string {
  switch (status) {
    case 'connecting': return t('receiverConnectingDetail')
    case 'receiving': return t('receiverReceivingDetail')
    case 'reconnecting': return t('receiverReconnectingDetail')
    case 'unavailable': return t('receiverUnavailableDetail')
  }
}

function formatBroadcastTime(value: string, language: UILanguage, t: Translator): string {
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return t('sentJustNow')
  const time = new Intl.DateTimeFormat(language === 'zh' ? 'zh-CN' : 'en-AU', {
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
  }).format(date)
  return t('sentAt', { time })
}

function displayElderLabel(value: string, t: Translator): string {
  const label = value.trim()
  const isKnownDefault = label.length === 2 &&
    label.codePointAt(0) === 0x957f && label.codePointAt(1) === 0x8f88
  return !label || isKnownDefault ? t('defaultElder') : label
}

export default App
