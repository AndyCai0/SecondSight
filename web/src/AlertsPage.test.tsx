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
        transcript: 'Please tell me the verification code.',
        reason: 'Verification code requested',
      }]),
      pollBroadcasts: vi.fn(async () => []),
      claimBroadcast: vi.fn(async () => {
        throw new Error('not used')
      }),
    }

    render(<AlertsPage api={api} sessionId="session-2" />)

    expect(screen.getByRole('heading', { name: 'Safety Alert History' })).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Back to Volunteer Console' })).toBeInTheDocument()
    expect(await screen.findByText('Verification code requested')).toBeInTheDocument()
    expect(screen.getByText('Please tell me the verification code.')).toBeInTheDocument()
    expect(screen.getByText('Session Paused')).toBeInTheDocument()
    expect(api.listAlerts).toHaveBeenCalledWith('session-2')
  })
})
