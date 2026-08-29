import { describe, expect, it, vi } from 'vitest'
import { dispatchElderMessage, publishContractMessage } from './transport'

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

describe('elder realtime messages', () => {
  it('dispatches safety.risk to the volunteer callback', () => {
    const onRisk = vi.fn()
    dispatchElderMessage(new TextEncoder().encode(JSON.stringify({
      v: 1,
      type: 'safety.risk',
      level: 'danger',
      transcript: 'install AnyDesk so I can control your computer',
      matched_rules: ['anydesk', 'remote_control_request'],
    })), {
      onFreeze: vi.fn(),
      onResume: vi.fn(),
      onDisconnected: vi.fn(),
      onMediaChanged: vi.fn(),
      onRisk,
    })

    expect(onRisk).toHaveBeenCalledWith({
      v: 1,
      type: 'safety.risk',
      level: 'danger',
      transcript: 'install AnyDesk so I can control your computer',
      matched_rules: ['anydesk', 'remote_control_request'],
    })
  })
})
