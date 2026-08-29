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

  it('loads one session alert history for the traceability page', async () => {
    const alerts = [{
      id: 12,
      timestamp: '2026-08-29T06:30:00.000Z',
      severity: 'freeze' as const,
      transcript: '把验证码念给我',
      reason: '索要短信验证码',
    }]
    const fetcher = vi.fn(async () => Response.json({
      alerts: [{
        id: 12,
        ts: '2026-08-29T06:30:00.000Z',
        severity: 'freeze',
        transcript: '把验证码念给我',
        reason: '索要短信验证码',
      }],
    }))
    const api = createSecondSightApi({
      supabaseUrl: 'https://example.supabase.co',
      supabaseAnonKey: 'public-anon-key',
      fetcher,
    })

    await expect(api.listAlerts('session-2')).resolves.toEqual(alerts)
    expect(fetcher).toHaveBeenCalledWith(
      'https://example.supabase.co/functions/v1/list-alerts',
      expect.objectContaining({ body: JSON.stringify({ session_id: 'session-2' }) }),
    )
  })

  it('refreshes assistant presence, parses broadcasts, and claims without exposing a room code', async () => {
    const fetcher = vi.fn()
      .mockResolvedValueOnce(Response.json({
        broadcasts: [{
          session_id: '9d1d5434-6da5-41e0-af70-c5aa35c6816f',
          requested_at: '2026-08-29T10:00:00.000Z',
          elder_label: '李奶奶',
        }],
      }))
      .mockResolvedValueOnce(Response.json({
        session_id: '9d1d5434-6da5-41e0-af70-c5aa35c6816f',
        lk_url: 'wss://demo.livekit.cloud',
        lk_token: 'volunteer-jwt',
      }))
    const api = createSecondSightApi({
      supabaseUrl: 'https://example.supabase.co',
      supabaseAnonKey: 'public-anon-key',
      fetcher,
    })
    const assistantId = '5f028bd8-9602-40ed-8c39-e35c6bca1a21'

    await expect(api.pollBroadcasts({ assistantId, name: '待命助手' })).resolves.toEqual([{
      sessionId: '9d1d5434-6da5-41e0-af70-c5aa35c6816f',
      requestedAt: '2026-08-29T10:00:00.000Z',
      elderLabel: '李奶奶',
    }])
    await expect(api.claimBroadcast({
      sessionId: '9d1d5434-6da5-41e0-af70-c5aa35c6816f',
      assistantId,
      name: '小王',
    })).resolves.toEqual({
      sessionId: '9d1d5434-6da5-41e0-af70-c5aa35c6816f',
      liveKitUrl: 'wss://demo.livekit.cloud',
      liveKitToken: 'volunteer-jwt',
    })

    expect(fetcher.mock.calls[0][0]).toBe(
      'https://example.supabase.co/functions/v1/assistant-poll',
    )
    expect(JSON.parse(String(fetcher.mock.calls[0][1]?.body))).toEqual({
      assistant_id: assistantId,
      name: '待命助手',
    })
    expect(fetcher.mock.calls[1][0]).toBe(
      'https://example.supabase.co/functions/v1/claim-broadcast',
    )
    expect(JSON.parse(String(fetcher.mock.calls[1][1]?.body))).toEqual({
      session_id: '9d1d5434-6da5-41e0-af70-c5aa35c6816f',
      assistant_id: assistantId,
      name: '小王',
    })
  })
})
