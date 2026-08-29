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

export type DataMessage =
  | CircleAnnotation
  | ArrowAnnotation
  | PointerMessage
  | { v: 1; type: 'annotate.clear' }
  | { v: 1; type: 'control.freeze'; reason: string }
  | { v: 1; type: 'control.resume' }
  | { v: 1; type: 'chat.tts'; text: string }

export type VolunteerOutboundMessage = Exclude<
  DataMessage,
  { type: 'control.freeze' | 'control.resume' }
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
    default:
      throw new Error(`Unsupported DataChannel message type: ${value.type}`)
  }
}

export function encodeDataMessage(message: DataMessage): Uint8Array {
  return new TextEncoder().encode(JSON.stringify(message))
}

export function isReliableMessage(message: DataMessage): boolean {
  return message.type !== 'pointer'
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

function assertText(value: unknown, field: string): asserts value is string {
  if (typeof value !== 'string' || value.trim().length === 0 || value.length > 500) {
    throw new Error(`${field} is invalid`)
  }
}
