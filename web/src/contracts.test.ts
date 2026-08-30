import { describe, expect, it } from 'vitest'
import { decodeDataMessage } from './contracts'

describe('DataChannel v1 messages', () => {
  it('accepts a normalized circle annotation from the shared contract', () => {
    const bytes = new TextEncoder().encode(JSON.stringify({
      v: 1,
      type: 'annotate.circle',
      id: 'a1',
      x: 0.42,
      y: 0.31,
      r: 0.05,
      ttl_ms: 6000,
    }))

    expect(decodeDataMessage(bytes)).toEqual({
      v: 1,
      type: 'annotate.circle',
      id: 'a1',
      x: 0.42,
      y: 0.31,
      r: 0.05,
      ttl_ms: 6000,
    })
  })

  it('accepts an elder safety risk with bounded explainable rule ids', () => {
    const bytes = new TextEncoder().encode(JSON.stringify({
      v: 1,
      type: 'safety.risk',
      level: 'danger',
      transcript: 'Please tell me the verification code.',
      matched_rules: ['request_sensitive_information', 'verification_code'],
    }))

    expect(decodeDataMessage(bytes)).toEqual({
      v: 1,
      type: 'safety.risk',
      level: 'danger',
      transcript: 'Please tell me the verification code.',
      matched_rules: ['request_sensitive_information', 'verification_code'],
    })
  })

  it('rejects malformed safety risks', () => {
    const bytes = new TextEncoder().encode(JSON.stringify({
      v: 1,
      type: 'safety.risk',
      level: 'safe',
      transcript: 'not risky',
      matched_rules: [],
    }))

    expect(() => decodeDataMessage(bytes)).toThrow('level')
  })

  it('accepts a marked 1000-scalar transcript and rejects a larger one', () => {
    const risk = {
      v: 1,
      type: 'safety.risk',
      level: 'danger',
      transcript: '😀'.repeat(1_000),
      transcript_truncated: true,
      matched_rules: ['verification_code'],
    }
    expect(decodeDataMessage(new TextEncoder().encode(JSON.stringify(risk)))).toEqual(risk)

    expect(() => decodeDataMessage(new TextEncoder().encode(JSON.stringify({
      ...risk,
      transcript: `${risk.transcript}验`,
    })))).toThrow('1000 Unicode scalar values')
  })

  it('accepts speaker-labelled partial and final captions', () => {
    const caption = {
      v: 1,
      type: 'caption.transcript',
      speaker: 'volunteer',
      turn_order: 3,
      text: 'Please open Settings',
      is_final: false,
    }
    expect(decodeDataMessage(new TextEncoder().encode(JSON.stringify(caption)))).toEqual(caption)
    expect(() => decodeDataMessage(new TextEncoder().encode(JSON.stringify({
      ...caption,
      speaker: 'unknown',
    })))).toThrow('speaker')
  })
})
