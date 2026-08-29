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
})
