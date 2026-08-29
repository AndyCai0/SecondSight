import { createClient } from 'npm:@supabase/supabase-js@2.112.4'
import { AccessToken, TokenVerifier, TrackSource } from 'npm:livekit-server-sdk@2.18.0'
import postgres from 'npm:postgres@3.4.3'
import {
  AIUnavailableError,
  type AlertRecord,
  type BroadcastRecord,
  type EdgeDependencies,
  ServerOperationError,
  SessionCodeConflictError,
  type SessionRecord,
} from './handler.ts'

export interface ProductionConfig {
  supabaseUrl: string
  supabaseServiceKey: string
  supabaseDbUrl?: string
  liveKitApiKey: string
  liveKitApiSecret: string
  liveKitUrl: string
  anthropicApiKey?: string
  assemblyAIApiKey?: string
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
  try {
    return {
      supabaseUrl: requiredEnvironment(readEnvironment, 'SUPABASE_URL'),
      supabaseServiceKey: readSupabaseServiceKey(readEnvironment),
      supabaseDbUrl: optionalEnvironment(readEnvironment, 'SUPABASE_DB_URL'),
      liveKitApiKey: requiredEnvironment(readEnvironment, 'LIVEKIT_API_KEY'),
      liveKitApiSecret: requiredEnvironment(readEnvironment, 'LIVEKIT_API_SECRET'),
      liveKitUrl: requiredEnvironment(readEnvironment, 'LIVEKIT_URL'),
      anthropicApiKey: optionalEnvironment(readEnvironment, 'AI_ENABLED') === 'true'
        ? optionalEnvironment(readEnvironment, 'ANTHROPIC_API_KEY')
        : undefined,
      assemblyAIApiKey: optionalEnvironment(readEnvironment, 'ASSEMBLYAI_API_KEY'),
    }
  } catch {
    throw new ServerOperationError('SERVER_CONFIGURATION_ERROR')
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
  const sql = config.supabaseDbUrl
    ? postgres(config.supabaseDbUrl, { prepare: false, max: 1 })
    : undefined
  const ai = config.anthropicApiKey
    ? createAnthropicClient(config.anthropicApiKey, fetcher)
    : createUnavailableAIClient()
  const assemblyAI = config.assemblyAIApiKey
    ? createAssemblyAIClient(config.assemblyAIApiKey, fetcher)
    : createUnavailableAssemblyAIClient()
  const elderCredentials = createLiveKitElderCredentialVerifier(
    config.liveKitApiKey,
    config.liveKitApiSecret,
  )

  return {
    sessions: {
      async create(code) {
        if (sql) {
          try {
            const rows = await sql<SessionRecord[]>`
              insert into public.sessions (code, status)
              values (${code}, 'waiting')
              returning id::text, code, status
            `
            if (!rows[0]) throw new ServerOperationError('SERVER_DATABASE_ERROR')
            return rows[0]
          } catch (error) {
            if (isRecord(error) && error.code === '23505') {
              throw new SessionCodeConflictError()
            }
            if (error instanceof ServerOperationError) throw error
            throw databaseOperationError(error)
          }
        }
        const { data, error } = await database
          .from('sessions')
          .insert({ code, status: 'waiting' })
          .select('id, code, status')
          .single()
        if (error?.code === '23505') throw new SessionCodeConflictError()
        if (error || !data) throw databaseOperationError(error)
        return data as SessionRecord
      },
      async findByCode(code) {
        if (sql) {
          try {
            const rows = await sql<SessionRecord[]>`
              select id::text, code, status
              from public.sessions
              where code = ${code}
              limit 1
            `
            return rows[0] ?? null
          } catch (error) {
            throw databaseOperationError(error)
          }
        }
        const { data, error } = await database
          .from('sessions')
          .select('id, code, status')
          .eq('code', code)
          .maybeSingle()
        if (error) throw databaseOperationError(error)
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
        if (sql) {
          try {
            const rows = await sql<{ id: string }[]>`
              update public.sessions
              set status = 'active', volunteer_label = ${volunteerName}
              where id = ${sessionId}
                and status = 'waiting'
              returning id::text
            `
            return rows.length > 0
          } catch (error) {
            throw databaseOperationError(error)
          }
        }
        const { data, error } = await database
          .from('sessions')
          .update({ status: 'active', volunteer_label: volunteerName })
          .eq('id', sessionId)
          .eq('status', 'waiting')
          .select('id')
          .maybeSingle()
        if (error) throw databaseOperationError(error)
        return data !== null
      },
      async freeze(sessionId) {
        if (sql) {
          try {
            await sql`
              update public.sessions
              set status = 'frozen'
              where id = ${sessionId}
            `
            return
          } catch (error) {
            throw databaseOperationError(error)
          }
        }
        const { error } = await database
          .from('sessions')
          .update({ status: 'frozen' })
          .eq('id', sessionId)
        if (error) throw databaseOperationError(error)
      },
    },
    events: {
      async insert(input) {
        if (sql) {
          try {
            await sql`
              insert into public.session_events (session_id, actor, kind, payload)
              values (
                ${input.sessionId},
                ${input.actor},
                ${input.kind},
                ${sql.json(input.payload as postgres.JSONValue)}
              )
            `
            return
          } catch (error) {
            throw databaseOperationError(error)
          }
        }
        const { error } = await database.from('session_events').insert({
          session_id: input.sessionId,
          actor: input.actor,
          kind: input.kind,
          payload: input.payload,
        })
        if (error) throw databaseOperationError(error)
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
        if (sql) {
          try {
            await sql`
              insert into public.alerts (session_id, severity, transcript, reason)
              values (
                ${input.sessionId},
                ${input.severity},
                ${input.transcript},
                ${input.reason}
              )
            `
            return
          } catch (error) {
            throw databaseOperationError(error)
          }
        }
        const { error } = await database.from('alerts').insert({
          session_id: input.sessionId,
          severity: input.severity,
          transcript: input.transcript,
          reason: input.reason,
        })
        if (error) throw databaseOperationError(error)
      },
      async list(sessionId) {
        if (sql) {
          try {
            const rows = await sql<
              Array<Omit<AlertRecord, 'ts'> & { ts: Date | string }>
            >`
              select id::float8 as id, ts, severity, transcript, reason
              from public.alerts
              where session_id = ${sessionId}
              order by ts desc, id desc
            `
            return rows.map((row) => ({
              ...row,
              ts: row.ts instanceof Date ? row.ts.toISOString() : String(row.ts),
            }))
          } catch (error) {
            throw databaseOperationError(error)
          }
        }
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
    assistants: {
      async touch(input) {
        if (sql) {
          try {
            await sql`
              insert into public.assistant_presence (id, display_name, last_seen_at)
              values (${input.id}, ${input.displayName}, ${input.seenAt})
              on conflict (id) do update
              set display_name = excluded.display_name,
                  last_seen_at = excluded.last_seen_at
            `
            return
          } catch (error) {
            throw databaseOperationError(error)
          }
        }
        const { error } = await database.from('assistant_presence').upsert({
          id: input.id,
          display_name: input.displayName,
          last_seen_at: input.seenAt,
        })
        if (error) throw databaseOperationError(error)
      },
      async countSince(cutoff) {
        if (sql) {
          try {
            const rows = await sql<{ count: number }[]>`
              select count(*)::int as count
              from public.assistant_presence
              where last_seen_at >= ${cutoff}
            `
            return rows[0]?.count ?? 0
          } catch (error) {
            throw databaseOperationError(error)
          }
        }
        const { count, error } = await database
          .from('assistant_presence')
          .select('id', { count: 'exact', head: true })
          .gte('last_seen_at', cutoff)
        if (error) throw databaseOperationError(error)
        return count ?? 0
      },
    },
    broadcasts: {
      async setActive(sessionId, isActive, startedAt) {
        if (sql) {
          try {
            const rows = isActive
              ? await sql<{ id: string }[]>`
                update public.sessions
                set broadcast_active = true, broadcast_started_at = ${startedAt}
                where id = ${sessionId} and status = 'waiting'
                returning id::text
              `
              : await sql<{ id: string }[]>`
                update public.sessions
                set broadcast_active = false, broadcast_started_at = null
                where id = ${sessionId}
                returning id::text
              `
            return rows.length > 0
          } catch (error) {
            throw databaseOperationError(error)
          }
        }
        let query = database
          .from('sessions')
          .update({
            broadcast_active: isActive,
            broadcast_started_at: isActive ? startedAt : null,
          })
          .eq('id', sessionId)
        if (isActive) query = query.eq('status', 'waiting')
        const { data, error } = await query.select('id').maybeSingle()
        if (error) throw databaseOperationError(error)
        return data !== null
      },
      async listActive(cutoff) {
        if (sql) {
          try {
            const rows = await sql<
              Array<{
                session_id: string
                requested_at: Date | string
                elder_label: string | null
              }>
            >`
              select
                id::text as session_id,
                broadcast_started_at as requested_at,
                elder_label
              from public.sessions
              where status = 'waiting'
                and broadcast_active = true
                and broadcast_started_at >= ${cutoff}
              order by broadcast_started_at
              limit 20
            `
            return rows.map(mapBroadcastRecord)
          } catch (error) {
            throw databaseOperationError(error)
          }
        }
        const { data, error } = await database
          .from('sessions')
          .select('id, broadcast_started_at, elder_label')
          .eq('status', 'waiting')
          .eq('broadcast_active', true)
          .gte('broadcast_started_at', cutoff)
          .order('broadcast_started_at', { ascending: true })
          .limit(20)
        if (error) throw databaseOperationError(error)
        return (data ?? []).map((row) =>
          mapBroadcastRecord({
            session_id: String(row.id),
            requested_at: String(row.broadcast_started_at),
            elder_label: typeof row.elder_label === 'string' ? row.elder_label : null,
          })
        )
      },
      async findClaimable(sessionId, cutoff) {
        if (sql) {
          try {
            const rows = await sql<SessionRecord[]>`
              select id::text, code, status
              from public.sessions
              where id = ${sessionId}
                and status = 'waiting'
                and broadcast_active = true
                and broadcast_started_at >= ${cutoff}
              limit 1
            `
            return rows[0] ?? null
          } catch (error) {
            throw databaseOperationError(error)
          }
        }
        const { data, error } = await database
          .from('sessions')
          .select('id, code, status')
          .eq('id', sessionId)
          .eq('status', 'waiting')
          .eq('broadcast_active', true)
          .gte('broadcast_started_at', cutoff)
          .maybeSingle()
        if (error) throw databaseOperationError(error)
        return data as SessionRecord | null
      },
      async claim(sessionId, volunteerName, cutoff) {
        if (sql) {
          try {
            const rows = await sql<{ id: string }[]>`
              update public.sessions
              set status = 'active',
                  volunteer_label = ${volunteerName},
                  broadcast_active = false,
                  broadcast_started_at = null
              where id = ${sessionId}
                and status = 'waiting'
                and broadcast_active = true
                and broadcast_started_at >= ${cutoff}
              returning id::text
            `
            return rows.length > 0
          } catch (error) {
            throw databaseOperationError(error)
          }
        }
        const { data, error } = await database
          .from('sessions')
          .update({
            status: 'active',
            volunteer_label: volunteerName,
            broadcast_active: false,
            broadcast_started_at: null,
          })
          .eq('id', sessionId)
          .eq('status', 'waiting')
          .eq('broadcast_active', true)
          .gte('broadcast_started_at', cutoff)
          .select('id')
          .maybeSingle()
        if (error) throw databaseOperationError(error)
        return data !== null
      },
    },
    tokens: {
      async sign(grant) {
        try {
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
              switch (source) {
                case 'microphone': return TrackSource.MICROPHONE
                case 'camera': return TrackSource.CAMERA
              }
            }),
          })
          return await token.toJwt()
        } catch {
          throw new ServerOperationError('SERVER_TOKEN_SIGNING_ERROR')
        }
      },
    },
    elderCredentials,
    assemblyAI,
    ai,
    publicLiveKitUrl: config.liveKitUrl,
    makeCode: randomSixDigitCode,
    now: () => new Date(),
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

function createUnavailableAssemblyAIClient(): EdgeDependencies['assemblyAI'] {
  return {
    async createStreamingToken() {
      throw new ServerOperationError('SERVER_CONFIGURATION_ERROR')
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

function createUnavailableAIClient(): EdgeDependencies['ai'] {
  const unavailable = (): never => {
    throw new AIUnavailableError()
  }
  return {
    async guide() {
      return unavailable()
    },
    async referee() {
      return unavailable()
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

function optionalEnvironment(
  readEnvironment: EnvironmentReader,
  name: string,
): string | undefined {
  return readEnvironment(name)?.trim() || undefined
}

function databaseOperationError(error: unknown): ServerOperationError {
  const rawCode = isRecord(error) && typeof error.code === 'string' ? error.code : undefined
  const providerCode = rawCode && /^[A-Z0-9_]{1,32}$/i.test(rawCode) ? rawCode : undefined
  return new ServerOperationError('SERVER_DATABASE_ERROR', providerCode)
}

function readSupabaseServiceKey(readEnvironment: EnvironmentReader): string {
  const legacyServiceRoleKey = optionalEnvironment(
    readEnvironment,
    'SUPABASE_SERVICE_ROLE_KEY',
  )
  if (legacyServiceRoleKey) return legacyServiceRoleKey

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

function mapBroadcastRecord(row: {
  session_id: string
  requested_at: Date | string
  elder_label: string | null
}): BroadcastRecord {
  return {
    sessionId: row.session_id,
    requestedAt: row.requested_at instanceof Date
      ? row.requested_at.toISOString()
      : String(row.requested_at),
    elderLabel: row.elder_label?.trim() || '长辈',
  }
}
