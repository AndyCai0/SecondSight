import { describe, expect, it, vi } from 'vitest'
import { createSecondSightApi } from './api'

describe('SecondSight API', () => {
  it('joins with the exact contract request and response shape', async () => {
    const fetcher = vi.fn(async () => Response.json({
      session_id: 'session-1',
      lk_url: 'wss://demo.livekit.cloud',
      lk_token: 'volunteer-jwt',
    }))
    const api = createSecondSightApi({
      supabaseUrl: 'https://example.supabase.co',
      supabaseAnonKey: 'public-anon-key',
      fetcher,
    })

    await expect(api.joinSession({ code: '482913', name: '小王' })).resolves.toEqual({
      sessionId: 'session-1',
      liveKitUrl: 'wss://demo.livekit.cloud',
      liveKitToken: 'volunteer-jwt',
    })
    expect(fetcher).toHaveBeenCalledWith(
      'https://example.supabase.co/functions/v1/join-session',
      expect.objectContaining({
        method: 'POST',
        body: JSON.stringify({ code: '482913', name: '小王' }),
        headers: expect.objectContaining({
          Authorization: 'Bearer public-anon-key',
          apikey: 'public-anon-key',
          'Content-Type': 'application/json',
        }),
      }),
    )
  })

  it('creates elder sessions and writes annotation audit events', async () => {
    const fetcher = vi.fn()
      .mockResolvedValueOnce(Response.json({
        session_id: 'session-2',
        code: '482913',
        lk_url: 'wss://demo.livekit.cloud',
        lk_token: 'elder-jwt',
      }))
      .mockResolvedValueOnce(Response.json({ ok: true }))
    const api = createSecondSightApi({
      supabaseUrl: 'https://example.supabase.co',
      supabaseAnonKey: 'public-anon-key',
      fetcher,
    })

    await expect(api.createSession()).resolves.toEqual({
      sessionId: 'session-2',
      code: '482913',
      liveKitUrl: 'wss://demo.livekit.cloud',
      liveKitToken: 'elder-jwt',
    })
    await expect(api.logEvent({
      sessionId: 'session-2',
      actor: 'volunteer',
      kind: 'annotate.clear',
      payload: { v: 1, type: 'annotate.clear' },
    })).resolves.toBeUndefined()

    expect(fetcher.mock.calls[1][0]).toBe(
      'https://example.supabase.co/functions/v1/log-event',
    )
    expect(JSON.parse(String(fetcher.mock.calls[1][1]?.body))).toEqual({
      session_id: 'session-2',
      actor: 'volunteer',
      kind: 'annotate.clear',
      payload: { v: 1, type: 'annotate.clear' },
    })
  })
})
