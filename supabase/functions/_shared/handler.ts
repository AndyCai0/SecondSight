export type SessionStatus = 'waiting' | 'active' | 'frozen' | 'ended'

export interface SessionRecord {
  id: string
  code: string
  status: SessionStatus
}

export interface AlertRecord {
  id: number
  ts: string
  severity: 'warn' | 'freeze'
  transcript: string
  reason: string
}

export interface BroadcastRecord {
  sessionId: string
  requestedAt: string
  elderLabel: string
}

export interface TokenGrant {
  identity: string
  room: string
  canPublish: boolean
  canSubscribe: boolean
  canPublishSources?: readonly ('microphone' | 'camera')[]
}

export interface ElderCredentialGrant {
  identity: string
  room: string
}

export type SafetySpeaker = 'elder' | 'volunteer'
export type SafetyLevel = 'safe' | 'warning' | 'danger'
export type SafetyCategory =
  | 'none'
  | 'sensitive_information'
  | 'financial_request'
  | 'software_installation'
  | 'unknown_link'
  | 'pressure'
  | 'goal_mismatch'
  | 'screen_mismatch'
  | 'other'

export interface SafetyAnalysisInput {
  elderGoal: string
  throughSequence: number
  dialogue: Array<{ sequence: number; speaker: SafetySpeaker; text: string }>
  screenshotBase64?: string
  screenRevision?: number
}

export interface EdgeDependencies {
  sessions: {
    create(code: string): Promise<SessionRecord>
    findByCode(code: string): Promise<SessionRecord | null>
    findById(sessionId: string): Promise<SessionRecord | null>
    activate(sessionId: string, volunteerName: string): Promise<boolean>
    freeze(sessionId: string): Promise<void>
  }
  events: {
    insert(input: {
      sessionId: string
      actor: string
      kind: string
      payload: Record<string, unknown>
    }): Promise<void>
  }
  alerts: {
    insert(input: {
      sessionId: string
      severity: 'warn' | 'freeze'
      transcript: string
      reason: string
    }): Promise<void>
    list(sessionId: string): Promise<AlertRecord[]>
  }
  assistants: {
    touch(input: { id: string; displayName: string; seenAt: string }): Promise<void>
    countSince(cutoff: string): Promise<number>
  }
  broadcasts: {
    setActive(sessionId: string, isActive: boolean, startedAt: string): Promise<boolean>
    listActive(cutoff: string): Promise<BroadcastRecord[]>
    findClaimable(sessionId: string, cutoff: string): Promise<SessionRecord | null>
    claim(sessionId: string, volunteerName: string, cutoff: string): Promise<boolean>
  }
  tokens: {
    sign(grant: TokenGrant): Promise<string>
  }
  elderCredentials: {
    verify(token: string): Promise<ElderCredentialGrant>
  }
  assemblyAI: {
    createStreamingToken(input: {
      expiresInSeconds: number
      maxSessionDurationSeconds: number
    }): Promise<{
      token: string
      expiresInSeconds: number
    }>
  }
  ai: {
    guide(input: {
      task: string
      screenshotBase64: string
      axSummary?: string
    }): Promise<{
      instructionText: string
      targetRect: { x: number; y: number; w: number; h: number } | null
      confidence: number
    }>
    analyzeSafety(input: SafetyAnalysisInput): Promise<{
      level: SafetyLevel
      category: SafetyCategory
      reason: string
    }>
  }
  publicLiveKitUrl: string
  makeCode(): string
  now(): Date
}

export type EdgeFunctionName =
  | 'create-session'
  | 'join-session'
  | 'ai-guide'
  | 'ai-referee'
  | 'list-alerts'
  | 'log-event'
  | 'broadcast-session'
  | 'assistant-poll'
  | 'claim-broadcast'
  | 'assemblyai-token'
  | 'risk-event'

export class SessionCodeConflictError extends Error {
  constructor() {
    super('Session code already exists')
    this.name = 'SessionCodeConflictError'
  }
}

export class AIUnavailableError extends Error {
  constructor() {
    super('AI features are not enabled')
    this.name = 'AIUnavailableError'
  }
}

export type ServerOperationErrorCode =
  | 'SERVER_CONFIGURATION_ERROR'
  | 'SERVER_DATABASE_ERROR'
  | 'SERVER_TOKEN_SIGNING_ERROR'

export class ServerOperationError extends Error {
  constructor(
    public readonly code: ServerOperationErrorCode,
    public readonly providerCode?: string,
  ) {
    super(code)
    this.name = 'ServerOperationError'
  }
}

export async function handleEdgeRequest(
  functionName: EdgeFunctionName,
  request: Request,
  dependencies: EdgeDependencies,
): Promise<Response> {
  if (request.method === 'OPTIONS') {
    return preflightResponse()
  }
  if (request.method !== 'POST') {
    return jsonResponse({ error: 'Method not allowed' }, 405)
  }

  if (functionName === 'broadcast-session') {
    const body = await readObject(request)
    const sessionId = stringField(body, 'session_id').trim()
    const isActive = body.is_active
    if (!isUuid(sessionId) || typeof isActive !== 'boolean') {
      return jsonResponse({ error: 'Invalid broadcast request' }, 400)
    }

    const now = dependencies.now()
    const updated = await dependencies.broadcasts.setActive(
      sessionId,
      isActive,
      now.toISOString(),
    )
    if (!updated) {
      return jsonResponse({ error: 'Session is not available for broadcast' }, 409)
    }
    if (!isActive) return jsonResponse({ ok: true })

    const notifiedAssistants = await dependencies.assistants.countSince(
      new Date(now.getTime() - ASSISTANT_PRESENCE_TTL_MS).toISOString(),
    )
    return jsonResponse({ ok: true, notified_assistants: notifiedAssistants })
  }

  if (functionName === 'assistant-poll') {
    const body = await readObject(request)
    const assistantId = stringField(body, 'assistant_id').trim()
    const displayName = stringField(body, 'name').trim()
    if (!isUuid(assistantId) || displayName.length === 0 || displayName.length > 40) {
      return jsonResponse({ error: 'Invalid assistant presence' }, 400)
    }

    const now = dependencies.now()
    await dependencies.assistants.touch({
      id: assistantId,
      displayName,
      seenAt: now.toISOString(),
    })
    const broadcasts = await dependencies.broadcasts.listActive(
      new Date(now.getTime() - BROADCAST_TTL_MS).toISOString(),
    )
    return jsonResponse({
      broadcasts: broadcasts.map((broadcast) => ({
        session_id: broadcast.sessionId,
        requested_at: broadcast.requestedAt,
        elder_label: broadcast.elderLabel,
      })),
    })
  }

  if (functionName === 'claim-broadcast') {
    const body = await readObject(request)
    const sessionId = stringField(body, 'session_id').trim()
    const assistantId = stringField(body, 'assistant_id').trim()
    const name = stringField(body, 'name').trim()
    if (!isUuid(sessionId) || !isUuid(assistantId) || name.length === 0 || name.length > 40) {
      return jsonResponse({ error: 'Invalid broadcast claim' }, 400)
    }

    const now = dependencies.now()
    const cutoff = new Date(now.getTime() - BROADCAST_TTL_MS).toISOString()
    await dependencies.assistants.touch({
      id: assistantId,
      displayName: name,
      seenAt: now.toISOString(),
    })
    const session = await dependencies.broadcasts.findClaimable(sessionId, cutoff)
    if (!session) {
      return jsonResponse({ error: 'Broadcast has already been claimed or expired' }, 409)
    }

    // Signing before the conditional update prevents a provider outage from
    // leaving the elder session claimed without a usable token. A race loser
    // never receives its unused token.
    const token = await dependencies.tokens.sign({
      identity: `volunteer:${name}`,
      room: session.code,
      canPublish: true,
      canSubscribe: true,
      canPublishSources: ['microphone', 'camera'],
    })
    const claimed = await dependencies.broadcasts.claim(session.id, name, cutoff)
    if (!claimed) {
      return jsonResponse({ error: 'Broadcast has already been claimed or expired' }, 409)
    }

    return jsonResponse({
      session_id: session.id,
      lk_url: dependencies.publicLiveKitUrl,
      lk_token: token,
    })
  }

  if (functionName === 'assemblyai-token') {
    const body = await readObject(request)
    const sessionId = stringField(body, 'session_id').trim()
    if (sessionId.length === 0) {
      return jsonResponse({ error: 'Invalid session' }, 400)
    }

    const elderGrant = await readElderCredential(request, dependencies)
    if (elderGrant instanceof Response) return elderGrant

    const session = await dependencies.sessions.findById(sessionId)
    if (!session) return jsonResponse({ error: 'Session not found' }, 404)
    if (elderGrant.identity !== 'elder' || elderGrant.room !== session.code) {
      return jsonResponse({ error: 'Elder credential is not valid for this session' }, 403)
    }
    if (session.status === 'ended') return jsonResponse({ error: 'Session has ended' }, 410)
    if (session.status === 'frozen') return jsonResponse({ error: 'Session is frozen' }, 423)

    const maxSessionDurationSeconds = 3_600
    const credential = await dependencies.assemblyAI.createStreamingToken({
      expiresInSeconds: 60,
      maxSessionDurationSeconds,
    })
    return jsonResponse({
      token: credential.token,
      expires_in_seconds: credential.expiresInSeconds,
      max_session_duration_seconds: maxSessionDurationSeconds,
    })
  }

  if (functionName === 'risk-event') {
    const body = await readObject(request)
    const sessionId = stringField(body, 'session_id').trim()
    const timestamp = stringField(body, 'timestamp').trim()
    const level = stringField(body, 'level')
    const transcript = stringField(body, 'transcript').trim()
    const rawRules = body.matched_rules
    const matchedRules = Array.isArray(rawRules) && rawRules.every((rule) =>
        typeof rule === 'string' && /^[a-z0-9_]{1,64}$/.test(rule)
      )
      ? [...new Set(rawRules as string[])].sort()
      : null
    const timestampMilliseconds = Date.parse(timestamp)
    if (
      sessionId.length === 0 || !['warning', 'danger'].includes(level) ||
      transcript.length === 0 || new TextEncoder().encode(transcript).byteLength > 4_096 ||
      matchedRules === null || matchedRules.length === 0 || matchedRules.length > 20 ||
      !Number.isFinite(timestampMilliseconds)
    ) {
      return jsonResponse({ error: 'Invalid risk event' }, 400)
    }

    const elderGrant = await readElderCredential(request, dependencies)
    if (elderGrant instanceof Response) return elderGrant

    const session = await dependencies.sessions.findById(sessionId)
    if (!session) return jsonResponse({ error: 'Session not found' }, 404)
    if (elderGrant.identity !== 'elder' || elderGrant.room !== session.code) {
      return jsonResponse({ error: 'Elder credential is not valid for this session' }, 403)
    }
    if (session.status === 'ended') return jsonResponse({ error: 'Session has ended' }, 410)

    const normalizedTimestamp = new Date(timestampMilliseconds).toISOString()
    const fingerprint = [level, ...matchedRules].join(':')
    await dependencies.events.insert({
      sessionId,
      actor: 'safety_monitor',
      kind: 'safety.risk',
      payload: {
        timestamp: normalizedTimestamp,
        level,
        transcript,
        matched_rules: matchedRules,
        fingerprint,
      },
    })
    return jsonResponse({ ok: true, fingerprint })
  }

  if (functionName === 'ai-guide') {
    const body = await readObject(request)
    const sessionId = stringField(body, 'session_id').trim()
    const task = stringField(body, 'task').trim()
    const screenshotBase64 = stringField(body, 'screenshot_base64')
    const rawAxSummary = body.ax_summary
    const axSummary = typeof rawAxSummary === 'string' && rawAxSummary.length > 0
      ? rawAxSummary
      : undefined
    const taskBytes = new TextEncoder().encode(task).byteLength
    if (
      !isUuid(sessionId) || task.length === 0 || taskBytes > 4_096 ||
      screenshotBase64.length === 0 || screenshotBase64.length > 6_000_000 ||
      (axSummary !== undefined && new TextEncoder().encode(axSummary).byteLength > 8_192)
    ) {
      return jsonResponse({ error: 'Invalid AI guide request' }, 400)
    }

    const elderGrant = await readElderCredential(request, dependencies)
    if (elderGrant instanceof Response) return elderGrant
    const session = await dependencies.sessions.findById(sessionId)
    if (!session) return jsonResponse({ error: 'Session not found' }, 404)
    if (elderGrant.identity !== 'elder' || elderGrant.room !== session.code) {
      return jsonResponse({ error: 'Elder credential is not valid for this session' }, 403)
    }
    if (session.status === 'ended') return jsonResponse({ error: 'Session has ended' }, 410)
    if (session.status === 'frozen') return jsonResponse({ error: 'Session is frozen' }, 423)

    const result = await dependencies.ai.guide({ task, screenshotBase64, axSummary })
    const responseBody = {
      instruction_text: result.instructionText,
      target_rect: result.targetRect,
      confidence: result.confidence,
    }
    await dependencies.events.insert({
      sessionId,
      actor: 'ai_guide',
      kind: 'ai.instruction',
      payload: responseBody,
    })
    return jsonResponse(responseBody)
  }

  if (functionName === 'ai-referee') {
    const body = await readObject(request)
    const sessionId = stringField(body, 'session_id').trim()
    const elderGoal = stringField(body, 'elder_goal').trim()
    const throughSequence = body.through_sequence
    const rawDialogue = body.dialogue
    const screenshotBase64 =
      typeof body.screenshot_base64 === 'string' && body.screenshot_base64.length > 0
        ? body.screenshot_base64
        : undefined
    const screenRevision = body.screen_revision
    const dialogue = parseSafetyDialogue(rawDialogue)
    const encodedGoalLength = new TextEncoder().encode(elderGoal).byteLength
    const totalDialogueBytes = dialogue?.reduce(
      (total, turn) => total + new TextEncoder().encode(turn.text).byteLength,
      0,
    ) ?? 0
    if (
      !isUuid(sessionId) || elderGoal.length === 0 || encodedGoalLength > 4_096 ||
      !Number.isInteger(throughSequence) || (throughSequence as number) <= 0 ||
      dialogue === null || dialogue.at(-1)?.sequence !== throughSequence ||
      totalDialogueBytes > 16_384 ||
      (screenshotBase64 !== undefined && screenshotBase64.length > 6_000_000) ||
      (screenshotBase64 !== undefined &&
        (!Number.isInteger(screenRevision) || (screenRevision as number) <= 0)) ||
      (screenshotBase64 === undefined && screenRevision !== undefined)
    ) {
      return jsonResponse({ error: 'Invalid safety analysis request' }, 400)
    }

    const elderGrant = await readElderCredential(request, dependencies)
    if (elderGrant instanceof Response) return elderGrant
    const session = await dependencies.sessions.findById(sessionId)
    if (!session) return jsonResponse({ error: 'Session not found' }, 404)
    if (elderGrant.identity !== 'elder' || elderGrant.room !== session.code) {
      return jsonResponse({ error: 'Elder credential is not valid for this session' }, 403)
    }
    if (session.status === 'ended') return jsonResponse({ error: 'Session has ended' }, 410)
    if (session.status === 'frozen') return jsonResponse({ error: 'Session is frozen' }, 423)

    const result = await dependencies.ai.analyzeSafety({
      elderGoal,
      throughSequence: throughSequence as number,
      dialogue,
      screenshotBase64,
      screenRevision: screenshotBase64 === undefined ? undefined : screenRevision as number,
    })
    const transcript = dialogue.map((turn) => `${turn.speaker}: ${turn.text}`).join('\n')
    if (result.level !== 'safe') {
      await dependencies.alerts.insert({
        sessionId,
        severity: 'warn',
        transcript,
        reason: result.reason,
      })
    }
    return jsonResponse({ ...result, through_sequence: throughSequence })
  }

  if (functionName === 'log-event') {
    const body = await readObject(request)
    const sessionId = stringField(body, 'session_id')
    const actor = stringField(body, 'actor')
    const kind = stringField(body, 'kind')
    const payload = isObject(body.payload) ? body.payload : null
    if (sessionId.length === 0 || actor.length === 0 || kind.length === 0 || payload === null) {
      return jsonResponse({ error: 'Invalid event' }, 400)
    }

    await dependencies.events.insert({ sessionId, actor, kind, payload })
    return jsonResponse({ ok: true })
  }

  if (functionName === 'list-alerts') {
    const body = await readObject(request)
    const sessionId = stringField(body, 'session_id').trim()
    if (sessionId.length === 0) {
      return jsonResponse({ error: 'Invalid session' }, 400)
    }
    return jsonResponse({ alerts: await dependencies.alerts.list(sessionId) })
  }

  if (functionName === 'join-session') {
    const body = await readObject(request)
    const code = stringField(body, 'code')
    const name = stringField(body, 'name').trim()
    if (!/^\d{6}$/.test(code) || name.length === 0 || name.length > 40) {
      return jsonResponse({ error: 'Invalid room code or volunteer name' }, 400)
    }

    const session = await dependencies.sessions.findByCode(code)
    if (!session) {
      return jsonResponse({ error: 'Room code not found' }, 404)
    }
    if (session.status === 'ended') {
      return jsonResponse({ error: 'Session has ended' }, 410)
    }
    if (session.status === 'frozen') {
      return jsonResponse({ error: 'Session is frozen' }, 423)
    }
    if (session.status === 'active') {
      return jsonResponse({ error: 'Session already has a volunteer' }, 409)
    }

    const activated = await dependencies.sessions.activate(session.id, name)
    if (!activated) {
      return jsonResponse({ error: 'Session is no longer joinable' }, 423)
    }
    const token = await dependencies.tokens.sign({
      identity: `volunteer:${name}`,
      room: code,
      canPublish: true,
      canSubscribe: true,
      canPublishSources: ['microphone', 'camera'],
    })

    return jsonResponse({
      session_id: session.id,
      lk_url: dependencies.publicLiveKitUrl,
      lk_token: token,
    })
  }

  if (functionName !== 'create-session') {
    return jsonResponse({ error: 'Not implemented' }, 501)
  }

  const created = await createSessionWithUniqueCode(dependencies)
  if (!created) {
    return jsonResponse({ error: 'Unable to allocate a room code' }, 503)
  }
  const { code, session } = created
  const token = await dependencies.tokens.sign({
    identity: 'elder',
    room: code,
    canPublish: true,
    canSubscribe: true,
    canPublishSources: undefined,
  })

  return jsonResponse({
    session_id: session.id,
    code,
    lk_url: dependencies.publicLiveKitUrl,
    lk_token: token,
  })
}

async function createSessionWithUniqueCode(
  dependencies: EdgeDependencies,
): Promise<{ code: string; session: SessionRecord } | null> {
  for (let attempt = 0; attempt < 8; attempt += 1) {
    const code = dependencies.makeCode()
    try {
      return { code, session: await dependencies.sessions.create(code) }
    } catch (error) {
      if (!(error instanceof SessionCodeConflictError)) throw error
    }
  }
  return null
}

export function jsonResponse(body: unknown, status = 200): Response {
  return Response.json(body, {
    status,
    headers: {
      ...corsHeaders,
      'content-type': 'application/json; charset=utf-8',
    },
  })
}

export function preflightResponse(): Response {
  return new Response(null, { status: 204, headers: corsHeaders })
}

export const corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-methods': 'POST, OPTIONS',
  'access-control-allow-headers': 'authorization, apikey, content-type, x-secondsight-elder-token',
}

async function readElderCredential(
  request: Request,
  dependencies: EdgeDependencies,
): Promise<ElderCredentialGrant | Response> {
  const token = request.headers.get('x-secondsight-elder-token')?.trim() ?? ''
  if (token.length === 0) {
    return jsonResponse({ error: 'Missing elder credential' }, 401)
  }
  try {
    return await dependencies.elderCredentials.verify(token)
  } catch {
    return jsonResponse({ error: 'Invalid elder credential' }, 401)
  }
}

async function readObject(request: Request): Promise<Record<string, unknown>> {
  try {
    const value: unknown = await request.json()
    return value !== null && typeof value === 'object' && !Array.isArray(value)
      ? value as Record<string, unknown>
      : {}
  } catch {
    return {}
  }
}

function stringField(body: Record<string, unknown>, key: string): string {
  return typeof body[key] === 'string' ? body[key] : ''
}

function isObject(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

function isUuid(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
    .test(value)
}

function parseSafetyDialogue(
  value: unknown,
): SafetyAnalysisInput['dialogue'] | null {
  if (!Array.isArray(value) || value.length === 0 || value.length > 24) return null
  const dialogue: SafetyAnalysisInput['dialogue'] = []
  let previousSequence = 0
  for (const rawTurn of value) {
    if (!isObject(rawTurn)) return null
    const sequence = rawTurn.sequence
    const speaker = rawTurn.speaker
    const text = typeof rawTurn.text === 'string' ? rawTurn.text.trim() : ''
    if (
      !Number.isInteger(sequence) || (sequence as number) <= previousSequence ||
      (speaker !== 'elder' && speaker !== 'volunteer') ||
      text.length === 0 || new TextEncoder().encode(text).byteLength > 4_096
    ) return null
    previousSequence = sequence as number
    dialogue.push({ sequence: previousSequence, speaker, text })
  }
  return dialogue
}

const ASSISTANT_PRESENCE_TTL_MS = 3_000
const BROADCAST_TTL_MS = 15 * 60 * 1_000
