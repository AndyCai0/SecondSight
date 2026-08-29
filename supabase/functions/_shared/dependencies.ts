import { createClient } from 'npm:@supabase/supabase-js@2.112.4'
import { AccessToken, TokenVerifier, TrackSource } from 'npm:livekit-server-sdk@2.18.0'
import {
  type AlertRecord,
  type EdgeDependencies,
  SessionCodeConflictError,
  type SessionRecord,
} from './handler.ts'

export interface ProductionConfig {
  supabaseUrl: string
  supabaseServiceKey: string
  liveKitApiKey: string
  liveKitApiSecret: string
  liveKitUrl: string
  anthropicApiKey: string
  assemblyAIApiKey: string
}

type EnvironmentReader = (name: string) => string | undefined
type Fetcher = typeof fetch
type AlertPageLoader = (
  from: number,
  to: number,
) => PromiseLike<{ data: AlertRecord[] | null; error: unknown }>

const ALERT_PAGE_SIZE = 1_000

export function readProductionConfig(
  readEnvironment: EnvironmentReader = Deno.env.get,
): ProductionConfig {
  return {
    supabaseUrl: requiredEnvironment(readEnvironment, 'SUPABASE_URL'),
    supabaseServiceKey: readSupabaseServiceKey(readEnvironment),
    liveKitApiKey: requiredEnvironment(readEnvironment, 'LIVEKIT_API_KEY'),
    liveKitApiSecret: requiredEnvironment(readEnvironment, 'LIVEKIT_API_SECRET'),
    liveKitUrl: requiredEnvironment(readEnvironment, 'LIVEKIT_URL'),
    anthropicApiKey: requiredEnvironment(readEnvironment, 'ANTHROPIC_API_KEY'),
    assemblyAIApiKey: requiredEnvironment(readEnvironment, 'ASSEMBLYAI_API_KEY'),
  }
}

export function createProductionDependencies(
  config = readProductionConfig(),
  fetcher: Fetcher = fetch,
): EdgeDependencies {
  const database = createClient(config.supabaseUrl, config.supabaseServiceKey, {
    auth: {
      autoRefreshToken: false,
      detectSessionInUrl: false,
      persistSession: false,
    },
    global: {
      fetch: createSupabaseServiceFetcher(config.supabaseServiceKey, fetcher),
    },
  })
  const ai = createAnthropicClient(config.anthropicApiKey, fetcher)
  const assemblyAI = createAssemblyAIClient(config.assemblyAIApiKey, fetcher)
  const elderCredentials = createLiveKitElderCredentialVerifier(
    config.liveKitApiKey,
    config.liveKitApiSecret,
  )

  return {
    sessions: {
      async create(code) {
        const { data, error } = await database
          .from('sessions')
          .insert({ code, status: 'waiting' })
          .select('id, code, status')
          .single()
        if (error?.code === '23505') throw new SessionCodeConflictError()
        if (error || !data) throw new Error('Unable to create session')
        return data as SessionRecord
      },
      async findByCode(code) {
        const { data, error } = await database
          .from('sessions')
          .select('id, code, status')
          .eq('code', code)
          .maybeSingle()
        if (error) throw new Error('Unable to find session')
        return data as SessionRecord | null
      },
      async findById(sessionId) {
        const { data, error } = await database
          .from('sessions')
          .select('id, code, status')
          .eq('id', sessionId)
          .maybeSingle()
        if (error) throw new Error('Unable to find session')
        return data as SessionRecord | null
      },
      async activate(sessionId, volunteerName) {
        const { data, error } = await database
          .from('sessions')
          .update({ status: 'active', volunteer_label: volunteerName })
          .eq('id', sessionId)
          .in('status', ['waiting', 'active'])
          .select('id')
          .maybeSingle()
        if (error) throw new Error('Unable to activate session')
        return data !== null
      },
      async freeze(sessionId) {
        const { error } = await database
          .from('sessions')
          .update({ status: 'frozen' })
          .eq('id', sessionId)
        if (error) throw new Error('Unable to freeze session')
      },
    },
    events: {
      async insert(input) {
        const { error } = await database.from('session_events').insert({
          session_id: input.sessionId,
          actor: input.actor,
          kind: input.kind,
          payload: input.payload,
        })
        if (error) throw new Error('Unable to record event')
        if (input.kind === 'safety.risk') {
          console.info('[safety-risk]', {
            session_id: input.sessionId,
            level: input.payload.level,
            matched_rules: input.payload.matched_rules,
          })
        }
      },
    },
    alerts: {
      async insert(input) {
        const { error } = await database.from('alerts').insert({
          session_id: input.sessionId,
          severity: input.severity,
          transcript: input.transcript,
          reason: input.reason,
        })
        if (error) throw new Error('Unable to record alert')
      },
      async list(sessionId) {
        return await collectAllAlerts(async (from, to) => {
          const { data, error } = await database
            .from('alerts')
            .select('id, ts, severity, transcript, reason')
            .eq('session_id', sessionId)
            .order('ts', { ascending: false })
            .order('id', { ascending: false })
            .range(from, to)
          return { data: (data ?? []) as AlertRecord[], error }
        })
      },
    },
    tokens: {
      async sign(grant) {
        const token = new AccessToken(config.liveKitApiKey, config.liveKitApiSecret, {
          identity: grant.identity,
          ttl: '2h',
        })
        token.addGrant({
          roomJoin: true,
          room: grant.room,
          canPublish: grant.canPublish,
          canSubscribe: grant.canSubscribe,
          canPublishSources: grant.canPublishSources?.map((source) => {
            if (source !== 'microphone') throw new Error('Unsupported publish source')
            return TrackSource.MICROPHONE
          }),
        })
        return await token.toJwt()
      },
    },
    elderCredentials,
    assemblyAI,
    ai,
    publicLiveKitUrl: config.liveKitUrl,
    makeCode: randomSixDigitCode,
  }
}

export function createLiveKitElderCredentialVerifier(apiKey: string, apiSecret: string) {
  const verifier = new TokenVerifier(apiKey, apiSecret)
  return {
    async verify(token: string) {
      const claims = await verifier.verify(token)
      const identity = claims.sub
      const room = claims.video?.room
      if (
        typeof identity !== 'string' || identity.length === 0 ||
        claims.video?.roomJoin !== true || typeof room !== 'string' || room.length === 0
      ) {
        throw new Error('LiveKit credential is missing a room-join grant')
      }
      return { identity, room }
    },
  }
}

export function createSupabaseServiceFetcher(
  serviceKey: string,
  fetcher: Fetcher = fetch,
): Fetcher {
  if (!serviceKey.startsWith('sb_secret_')) return fetcher

  return ((input, init) => {
    const headers = new Headers(
      init?.headers ?? (input instanceof Request ? input.headers : undefined),
    )
    headers.delete('authorization')
    return fetcher(input, { ...init, headers })
  }) as Fetcher
}

export function createAssemblyAIClient(apiKey: string, fetcher: Fetcher = fetch) {
  return {
    async createStreamingToken(input: {
      expiresInSeconds: number
      maxSessionDurationSeconds: number
    }) {
      const query = new URLSearchParams({
        expires_in_seconds: String(input.expiresInSeconds),
        max_session_duration_seconds: String(input.maxSessionDurationSeconds),
      })
      const response = await fetcher(`https://streaming.assemblyai.com/v3/token?${query}`, {
        method: 'GET',
        headers: { authorization: apiKey },
      })
      if (!response.ok) {
        throw new Error(`Streaming credential provider failed with status ${response.status}`)
      }
      const body: unknown = await response.json()
      if (
        !isRecord(body) || typeof body.token !== 'string' || body.token.trim().length === 0 ||
        typeof body.expires_in_seconds !== 'number' || !Number.isFinite(body.expires_in_seconds)
      ) {
        throw new Error('Streaming credential provider returned invalid output')
      }
      return {
        token: body.token,
        expiresInSeconds: body.expires_in_seconds,
      }
    },
  }
}

export async function collectAllAlerts(loadPage: AlertPageLoader): Promise<AlertRecord[]> {
  const alerts: AlertRecord[] = []
  for (let from = 0;; from += ALERT_PAGE_SIZE) {
    const { data, error } = await loadPage(from, from + ALERT_PAGE_SIZE - 1)
    if (error) throw new Error('Unable to list alerts')
    const page = data ?? []
    alerts.push(...page)
    if (page.length < ALERT_PAGE_SIZE) return alerts
  }
}

export function createAnthropicClient(apiKey: string, fetcher: Fetcher = fetch) {
  async function request(body: Record<string, unknown>): Promise<unknown> {
    const response = await fetcher('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: {
        'anthropic-version': '2023-06-01',
        'content-type': 'application/json',
        'x-api-key': apiKey,
      },
      body: JSON.stringify(body),
    })
    if (!response.ok) throw new Error(`AI provider failed with status ${response.status}`)
    return await response.json()
  }

  return {
    async guide(input: {
      task: string
      screenshotBase64: string
      axSummary?: string
    }) {
      const response = await request({
        model: 'claude-sonnet-5',
        max_tokens: 500,
        system: [
          '你在指导不熟悉电脑的中国老人。一次只给一个步骤。',
          'instruction_text 必须是口语化中文短句。',
          '若有 AX 摘要，优先使用其中的控件和坐标。',
          '只输出 JSON：{"instruction_text":"...","target_rect":{"x":0,"y":0,"w":0,"h":0}|null,"confidence":0.0}。',
          'target_rect 坐标必须相对截图归一化到 0–1。',
        ].join('\n'),
        messages: [{
          role: 'user',
          content: [
            {
              type: 'text',
              text: `任务：${input.task}\nAX 摘要：${input.axSummary ?? '未提供'}`,
            },
            {
              type: 'image',
              source: {
                type: 'base64',
                media_type: 'image/jpeg',
                data: input.screenshotBase64,
              },
            },
          ],
        }],
      })
      return parseGuideResponse(response)
    },
    async referee(transcript: string) {
      const response = await request({
        model: 'claude-haiku-4-5-20251001',
        max_tokens: 160,
        system: [
          '你是老人远程协助会话的安全裁判。',
          '索要密码、验证码、PIN，或诱导转账、汇款、买礼品卡：freeze。',
          '诱导安装软件、访问陌生网址，或高压催促：warn。其他：ok。',
          '只输出 JSON：{"verdict":"ok|warn|freeze","reason":"简短中文原因"}。',
        ].join('\n'),
        messages: [{ role: 'user', content: transcript }],
      })
      return parseRefereeResponse(response)
    },
  }
}

function parseGuideResponse(value: unknown) {
  const parsed = parseClaudeJson(value)
  const instructionText = stringValue(parsed, 'instruction_text').trim()
  const confidence = parsed.confidence
  if (!instructionText || !normalizedNumber(confidence)) {
    throw new Error('AI guide returned invalid output')
  }

  let targetRect: { x: number; y: number; w: number; h: number } | null = null
  if (parsed.target_rect !== null) {
    if (!isRecord(parsed.target_rect)) throw new Error('AI guide returned invalid output')
    const { x, y, w, h } = parsed.target_rect
    if (
      !normalizedNumber(x) || !normalizedNumber(y) || !normalizedNumber(w) ||
      !normalizedNumber(h) || w <= 0 || h <= 0 || x + w > 1 || y + h > 1
    ) {
      throw new Error('AI guide returned invalid output')
    }
    targetRect = { x, y, w, h }
  }

  return { instructionText, targetRect, confidence }
}

function parseRefereeResponse(value: unknown) {
  const parsed = parseClaudeJson(value)
  const verdict = parsed.verdict
  const reason = stringValue(parsed, 'reason').trim()
  if (!['ok', 'warn', 'freeze'].includes(String(verdict)) || !reason) {
    throw new Error('AI referee returned invalid output')
  }
  return { verdict: verdict as 'ok' | 'warn' | 'freeze', reason }
}

function parseClaudeJson(value: unknown): Record<string, unknown> {
  if (!isRecord(value) || !Array.isArray(value.content)) {
    throw new Error('AI provider returned an invalid response')
  }
  const textBlock = value.content.find(
    (block): block is { type: 'text'; text: string } =>
      isRecord(block) && block.type === 'text' && typeof block.text === 'string',
  )
  if (!textBlock) throw new Error('AI provider returned no text')
  const source = textBlock.text.trim().replace(/^```(?:json)?\s*/i, '').replace(/\s*```$/, '')
  try {
    const parsed: unknown = JSON.parse(source)
    if (!isRecord(parsed)) throw new Error()
    return parsed
  } catch {
    throw new Error('AI provider returned invalid JSON')
  }
}

function randomSixDigitCode(): string {
  const random = crypto.getRandomValues(new Uint32Array(1))[0]
  return String(100_000 + (random % 900_000))
}

function requiredEnvironment(
  readEnvironment: EnvironmentReader,
  ...names: string[]
): string {
  for (const name of names) {
    const value = readEnvironment(name)?.trim()
    if (value) return value
  }
  throw new Error(`Missing required environment variable: ${names.join(' or ')}`)
}

function readSupabaseServiceKey(readEnvironment: EnvironmentReader): string {
  const secretKeysJson = readEnvironment('SUPABASE_SECRET_KEYS')
  if (secretKeysJson) {
    try {
      const keys: unknown = JSON.parse(secretKeysJson)
      if (isRecord(keys) && typeof keys.default === 'string' && keys.default.trim()) {
        return keys.default.trim()
      }
    } catch {
      throw new Error('SUPABASE_SECRET_KEYS must be a valid JSON object')
    }
  }
  return requiredEnvironment(
    readEnvironment,
    'SUPABASE_SECRET_KEY',
    'SUPABASE_SERVICE_ROLE_KEY',
  )
}

function stringValue(value: Record<string, unknown>, key: string): string {
  return typeof value[key] === 'string' ? value[key] : ''
}

function normalizedNumber(value: unknown): value is number {
  return typeof value === 'number' && Number.isFinite(value) && value >= 0 && value <= 1
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}
