import { describe, expect, it, vi } from 'vitest'
import { publishContractMessage } from './transport'

describe('LiveKit DataChannel publishing', () => {
  it('publishes pointer updates lossily and persistent annotations reliably', async () => {
    const publishData = vi.fn(async (
      _data: Uint8Array,
      _options: { reliable: boolean },
    ) => undefined)
    const publisher = { publishData }

    await publishContractMessage(publisher, { v: 1, type: 'pointer', x: 0.4, y: 0.6 })
    await publishContractMessage(publisher, {
      v: 1,
      type: 'annotate.circle',
      id: 'a1',
      x: 0.4,
      y: 0.6,
      r: 0.05,
      ttl_ms: 6000,
    })

    expect(publishData.mock.calls[0][1]).toEqual({ reliable: false })
    expect(publishData.mock.calls[1][1]).toEqual({ reliable: true })

    // @ts-expect-error Volunteers are never allowed to publish elder control messages.
    await publishContractMessage(publisher, { v: 1, type: 'control.freeze', reason: 'no' })
  })
})
