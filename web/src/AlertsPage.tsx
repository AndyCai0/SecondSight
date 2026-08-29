import { useEffect, useMemo, useState } from 'react'
import {
  createSecondSightApi,
  type AlertRecord,
  type SecondSightApi,
} from './api'
import { LanguageSwitch, localizeDocument, type UILanguage, useUILanguage } from './i18n'

interface AlertsPageProps {
  api?: SecondSightApi
  sessionId?: string
}

function AlertsPage({ api, sessionId }: AlertsPageProps) {
  const { language, setLanguage, t } = useUILanguage()
  const environment = import.meta.env
  const configuredApi = useMemo(() => api ?? createSecondSightApi({
    supabaseUrl: environment.VITE_SUPABASE_URL ?? '',
    supabaseAnonKey: environment.VITE_SUPABASE_ANON_KEY ?? '',
  }), [api, environment.VITE_SUPABASE_ANON_KEY, environment.VITE_SUPABASE_URL])
  const resolvedSessionId = sessionId ?? new URLSearchParams(window.location.search)
    .get('session_id')?.trim() ?? ''
  const [alerts, setAlerts] = useState<AlertRecord[]>([])
  const [loading, setLoading] = useState(resolvedSessionId.length > 0)
  const [error, setError] = useState('')

  useEffect(() => {
    localizeDocument(language, 'alertsPageTitle', 'alertsPageDescription')
  }, [language])

  useEffect(() => {
    if (!resolvedSessionId) return
    let isActive = true
    configuredApi.listAlerts(resolvedSessionId)
      .then((records) => {
        if (isActive) setAlerts(records)
      })
      .catch(() => {
        if (isActive) setError(t('loadAlertsFailed'))
      })
      .finally(() => {
        if (isActive) setLoading(false)
      })
    return () => { isActive = false }
  }, [configuredApi, resolvedSessionId, t])

  return (
    <div className="alerts-shell">
      <header className="alerts-header">
        <a href="/" aria-label={t('backToConsole')}>← {t('backToConsole')}</a>
        <div className="alerts-header__actions">
          <span>{t('traceable')}</span>
          <LanguageSwitch language={language} onChange={setLanguage} />
        </div>
      </header>
      <main className="alerts-main">
        <p className="eyebrow">{t('safetyAudit')}</p>
        <h1>{t('alertHistory')}</h1>
        <p className="alerts-intro">{t('alertIntro')}</p>

        {!resolvedSessionId && <p role="alert">{t('missingSession')}</p>}
        {loading && <p role="status">{t('loadingAlerts')}</p>}
        {error && <p className="form-error" role="alert">{error}</p>}
        {!loading && !error && resolvedSessionId && alerts.length === 0 && (
          <p className="alerts-empty">{t('noAlerts')}</p>
        )}
        <ol className="alerts-list">
          {alerts.map((alert) => (
            <li className={`alert-card alert-card--${alert.severity}`} key={alert.id}>
              <div className="alert-card__meta">
                <strong>{t(alert.severity === 'freeze' ? 'sessionPausedLabel' : 'safetyAlertLabel')}</strong>
                <time dateTime={alert.timestamp}>{formatTimestamp(alert.timestamp, language)}</time>
              </div>
              <h2>{alert.reason}</h2>
              <p>{alert.transcript}</p>
            </li>
          ))}
        </ol>
      </main>
    </div>
  )
}

function formatTimestamp(value: string, language: UILanguage): string {
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return value
  return new Intl.DateTimeFormat(language === 'zh' ? 'zh-CN' : 'en-AU', {
    dateStyle: 'medium',
    timeStyle: 'short',
  }).format(date)
}

export default AlertsPage
