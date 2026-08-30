export type CircleAnnotation = {
  v: 1
  type: 'annotate.circle'
  id: string
  x: number
  y: number
  r: number
  ttl_ms: number
}

export type ArrowAnnotation = {
  v: 1
  type: 'annotate.arrow'
  id: string
  x1: number
  y1: number
  x2: number
  y2: number
  ttl_ms: number
}

export type PointerMessage = {
  v: 1
  type: 'pointer'
  x: number
  y: number
}

export type SafetyRiskMessage = {
  v: 1
  type: 'safety.risk'
  level: 'warning' | 'danger'
  transcript: string
  transcript_truncated?: boolean
  matched_rules: string[]
}

export type CaptionTranscriptMessage = {
  v: 1
  type: 'caption.transcript'
  speaker: 'elder' | 'volunteer'
  turn_order: number
  text: string
  is_final: boolean
}

export type DataMessage =
  | CircleAnnotation
  | ArrowAnnotation
  | PointerMessage
  | { v: 1; type: 'annotate.clear' }
  | { v: 1; type: 'control.freeze'; reason: string }
  | { v: 1; type: 'control.resume' }
  | { v: 1; type: 'chat.tts'; text: string }
  | SafetyRiskMessage
  | CaptionTranscriptMessage

export type VolunteerOutboundMessage = Exclude<
  DataMessage,
  { type: 'control.freeze' | 'control.resume' | 'safety.risk' | 'caption.transcript' }
>

export function decodeDataMessage(bytes: Uint8Array): DataMessage {
  let value: unknown
  try {
    value = JSON.parse(new TextDecoder().decode(bytes))
  } catch {
    throw new Error('DataChannel message is not valid JSON')
  }
  if (!isRecord(value) || value.v !== 1 || typeof value.type !== 'string') {
    throw new Error('Unsupported DataChannel message')
  }

  switch (value.type) {
    case 'annotate.circle':
      assertId(value.id)
      assertCoordinate(value.x, 'x')
      assertCoordinate(value.y, 'y')
      assertPositiveUnit(value.r, 'r')
      assertTtl(value.ttl_ms)
      return value as CircleAnnotation
    case 'annotate.arrow':
      assertId(value.id)
      assertCoordinate(value.x1, 'x1')
      assertCoordinate(value.y1, 'y1')
      assertCoordinate(value.x2, 'x2')
      assertCoordinate(value.y2, 'y2')
      assertTtl(value.ttl_ms)
      return value as ArrowAnnotation
    case 'pointer':
      assertCoordinate(value.x, 'x')
      assertCoordinate(value.y, 'y')
      return value as PointerMessage
    case 'annotate.clear':
    case 'control.resume':
      return value as DataMessage
    case 'control.freeze':
      assertText(value.reason, 'reason')
      return value as DataMessage
    case 'chat.tts':
      assertText(value.text, 'text')
      return value as DataMessage
    case 'safety.risk':
      if (value.level !== 'warning' && value.level !== 'danger') {
        throw new Error('level must be warning or danger')
      }
      assertText(value.transcript, 'transcript', Number.MAX_SAFE_INTEGER)
      if (Array.from(value.transcript).length > 1_000) {
        throw new Error('transcript must contain at most 1000 Unicode scalar values')
      }
      if (value.transcript_truncated !== undefined && value.transcript_truncated !== true) {
        throw new Error('transcript_truncated must be true when present')
      }
      assertRiskRules(value.matched_rules)
      return value as SafetyRiskMessage
    case 'caption.transcript':
      if (value.speaker !== 'elder' && value.speaker !== 'volunteer') {
        throw new Error('speaker must be elder or volunteer')
      }
      if (!Number.isInteger(value.turn_order) || (value.turn_order as number) < 0) {
        throw new Error('turn_order must be a non-negative integer')
      }
      assertText(value.text, 'text', 2_000)
      if (typeof value.is_final !== 'boolean') {
        throw new Error('is_final must be boolean')
      }
      return value as CaptionTranscriptMessage
    default:
      throw new Error(`Unsupported DataChannel message type: ${value.type}`)
  }
}

export function encodeDataMessage(message: DataMessage): Uint8Array {
  return new TextEncoder().encode(JSON.stringify(message))
}

export function isReliableMessage(message: DataMessage): boolean {
  return message.type !== 'pointer' &&
    !(message.type === 'caption.transcript' && !message.is_final)
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

function assertCoordinate(value: unknown, field: string): asserts value is number {
  if (typeof value !== 'number' || !Number.isFinite(value) || value < 0 || value > 1) {
    throw new Error(`${field} must be a normalized coordinate`)
  }
}

function assertPositiveUnit(value: unknown, field: string): asserts value is number {
  assertCoordinate(value, field)
  if (value === 0) {
    throw new Error(`${field} must be greater than zero`)
  }
}

function assertTtl(value: unknown): asserts value is number {
  if (!Number.isInteger(value) || (value as number) <= 0 || (value as number) > 60_000) {
    throw new Error('ttl_ms must be between 1 and 60000')
  }
}

function assertId(value: unknown): asserts value is string {
  if (typeof value !== 'string' || value.length === 0 || value.length > 64) {
    throw new Error('annotation id is invalid')
  }
}

function assertText(value: unknown, field: string, maximumLength = 500): asserts value is string {
  if (typeof value !== 'string' || value.trim().length === 0 || value.length > maximumLength) {
    throw new Error(`${field} is invalid`)
  }
}

function assertRiskRules(value: unknown): asserts value is string[] {
  if (
    !Array.isArray(value) || value.length === 0 || value.length > 20 ||
    value.some((rule) => typeof rule !== 'string' || !/^[a-z0-9_]{1,64}$/.test(rule)) ||
    new Set(value).size !== value.length
  ) {
    throw new Error('matched_rules is invalid')
  }
}
