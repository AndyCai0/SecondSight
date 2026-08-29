import { useEffect, useMemo, useState } from 'react'
import {
  createSecondSightApi,
  type AlertRecord,
  type SecondSightApi,
} from './api'

interface AlertsPageProps {
  api?: SecondSightApi
  sessionId?: string
}

function AlertsPage({ api, sessionId }: AlertsPageProps) {
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
    if (!resolvedSessionId) return
    let isActive = true
    configuredApi.listAlerts(resolvedSessionId)
      .then((records) => {
        if (isActive) setAlerts(records)
      })
      .catch(() => {
        if (isActive) setError('暂时无法读取告警记录，请稍后重试')
      })
      .finally(() => {
        if (isActive) setLoading(false)
      })
    return () => { isActive = false }
  }, [configuredApi, resolvedSessionId])

  return (
    <div className="alerts-shell">
      <header className="alerts-header">
        <a href="/">← 返回志愿者端</a>
        <span>SecondSight · 全程可追溯</span>
      </header>
      <main className="alerts-main">
        <p className="eyebrow">本次协助的安全审计</p>
        <h1>安全告警记录</h1>
        <p className="alerts-intro">只展示当前会话由 AI 安全助手生成的提醒与冻结记录。</p>

        {!resolvedSessionId && <p role="alert">缺少会话编号，请从协助页面打开告警记录。</p>}
        {loading && <p role="status">正在读取告警记录…</p>}
        {error && <p className="form-error" role="alert">{error}</p>}
        {!loading && !error && resolvedSessionId && alerts.length === 0 && (
          <p className="alerts-empty">当前会话尚无安全告警。</p>
        )}
        <ol className="alerts-list">
          {alerts.map((alert) => (
            <li className={`alert-card alert-card--${alert.severity}`} key={alert.id}>
              <div className="alert-card__meta">
                <strong>{alert.severity === 'freeze' ? '已暂停会话' : '安全提醒'}</strong>
                <time dateTime={alert.timestamp}>{formatTimestamp(alert.timestamp)}</time>
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

function formatTimestamp(value: string): string {
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return value
  return new Intl.DateTimeFormat('zh-CN', {
    dateStyle: 'medium',
    timeStyle: 'short',
  }).format(date)
}

export default AlertsPage
