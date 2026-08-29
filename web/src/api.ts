export interface JoinSessionInput {
  code: string
  name: string
}

export interface JoinedSession {
  sessionId: string
  liveKitUrl: string
  liveKitToken: string
}

export interface CreatedSession extends JoinedSession {
  code: string
}

export interface LogEventInput {
  sessionId: string
  actor: string
  kind: string
  payload: Record<string, unknown>
}

export interface AlertRecord {
  id: number
  timestamp: string
  severity: 'warn' | 'freeze'
  transcript: string
  reason: string
}

export interface SecondSightApi {
  joinSession(input: JoinSessionInput): Promise<JoinedSession>
  createSession(): Promise<CreatedSession>
  logEvent(input: LogEventInput): Promise<void>
  listAlerts(sessionId: string): Promise<AlertRecord[]>
}

export class ApiError extends Error {
  readonly status: number

  constructor(
    message: string,
    status: number,
  ) {
    super(message)
    this.name = 'ApiError'
    this.status = status
  }
}

interface ApiOptions {
  supabaseUrl: string
  supabaseAnonKey: string
  fetcher?: typeof fetch
}

export function createSecondSightApi(options: ApiOptions): SecondSightApi {
  const baseUrl = options.supabaseUrl.replace(/\/+$/, '')
  const fetcher = options.fetcher ?? fetch

  async function request(path: string, body: unknown): Promise<unknown> {
    const response = await fetcher(`${baseUrl}/functions/v1/${path}`, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${options.supabaseAnonKey}`,
        apikey: options.supabaseAnonKey,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(body),
    })
    const payload: unknown = await response.json().catch(() => ({}))
    if (!response.ok) {
      const message = isRecord(payload) && typeof payload.error === 'string'
        ? payload.error
        : '请求失败，请稍后重试'
      throw new ApiError(message, response.status)
    }
    return payload
  }

  return {
    async joinSession(input) {
      const payload = await request('join-session', input)
      if (
        !isRecord(payload) || typeof payload.session_id !== 'string' ||
        typeof payload.lk_url !== 'string' || typeof payload.lk_token !== 'string'
      ) {
        throw new ApiError('服务返回了无法识别的数据', 502)
      }
      return {
        sessionId: payload.session_id,
        liveKitUrl: payload.lk_url,
        liveKitToken: payload.lk_token,
      }
    },
    async createSession() {
      const payload = await request('create-session', {})
      if (
        !isRecord(payload) || typeof payload.session_id !== 'string' ||
        typeof payload.code !== 'string' || typeof payload.lk_url !== 'string' ||
        typeof payload.lk_token !== 'string'
      ) {
        throw new ApiError('服务返回了无法识别的数据', 502)
      }
      return {
        sessionId: payload.session_id,
        code: payload.code,
        liveKitUrl: payload.lk_url,
        liveKitToken: payload.lk_token,
      }
    },
    async logEvent(input) {
      const payload = await request('log-event', {
        session_id: input.sessionId,
        actor: input.actor,
        kind: input.kind,
        payload: input.payload,
      })
      if (!isRecord(payload) || payload.ok !== true) {
        throw new ApiError('审计事件未被服务确认', 502)
      }
    },
    async listAlerts(sessionId) {
      const payload = await request('list-alerts', { session_id: sessionId })
      if (!isRecord(payload) || !Array.isArray(payload.alerts)) {
        throw new ApiError('告警记录格式无效', 502)
      }
      return payload.alerts.map(parseAlert)
    },
  }
}

function parseAlert(value: unknown): AlertRecord {
  if (
    !isRecord(value) || typeof value.id !== 'number' || typeof value.ts !== 'string' ||
    !['warn', 'freeze'].includes(String(value.severity)) ||
    typeof value.transcript !== 'string' || typeof value.reason !== 'string'
  ) {
    throw new ApiError('告警记录格式无效', 502)
  }
  return {
    id: value.id,
    timestamp: value.ts,
    severity: value.severity as AlertRecord['severity'],
    transcript: value.transcript,
    reason: value.reason,
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}
