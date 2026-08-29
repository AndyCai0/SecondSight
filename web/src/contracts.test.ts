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
})
