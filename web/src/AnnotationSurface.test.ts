import { describe, expect, it } from 'vitest'
import { opacityForExpiry } from './annotationTiming'
import { shouldSendPointer } from './pointerThrottle'

describe('annotation surface timing', () => {
  it('allows at most one lossy pointer update every 30ms', () => {
    expect(shouldSendPointer(100, 129)).toBe(false)
    expect(shouldSendPointer(100, 130)).toBe(true)
  })

  it('fades annotations during their final 600ms', () => {
    expect(opacityForExpiry(1_000, 100)).toBe(1)
    expect(opacityForExpiry(1_000, 700)).toBe(0.5)
    expect(opacityForExpiry(1_000, 1_000)).toBe(0)
  })
})
