import { render, screen } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
import AlertsPage from './AlertsPage'
import type { SecondSightApi } from './api'

describe('alerts traceability page', () => {
  it('renders one session alert history returned by the public API', async () => {
    const api: SecondSightApi = {
      joinSession: vi.fn(async () => { throw new Error('not used') }),
      createSession: vi.fn(async () => { throw new Error('not used') }),
      logEvent: vi.fn(async () => undefined),
      listAlerts: vi.fn(async () => [{
        id: 12,
        timestamp: '2026-08-29T06:30:00.000Z',
        severity: 'freeze' as const,
        transcript: '把验证码念给我',
        reason: '索要短信验证码',
      }]),
      pollBroadcasts: vi.fn(async () => []),
      claimBroadcast: vi.fn(async () => {
        throw new Error('not used')
      }),
    }

    render(<AlertsPage api={api} sessionId="session-2" />)

    expect(screen.getByRole('heading', { name: '安全告警记录' })).toBeInTheDocument()
    expect(await screen.findByText('索要短信验证码')).toBeInTheDocument()
    expect(screen.getByText('把验证码念给我')).toBeInTheDocument()
    expect(api.listAlerts).toHaveBeenCalledWith('session-2')
  })
})
