import { act, cleanup, render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, describe, expect, it, vi } from 'vitest'
import App from './App'
import type { SecondSightApi } from './api'
import type { ConnectVolunteerSession, LiveSessionEvents, VolunteerSession } from './transport'

afterEach(cleanup)

describe('volunteer app', () => {
  it('joins a room, keeps the no-control promise visible, and mirrors an elder freeze', async () => {
    const api: SecondSightApi = {
      joinSession: vi.fn(async () => ({
        sessionId: 'session-1',
        liveKitUrl: 'wss://demo.livekit.cloud',
        liveKitToken: 'volunteer-jwt',
      })),
      createSession: vi.fn(async () => {
        throw new Error('not used')
      }),
      logEvent: vi.fn(async () => undefined),
      listAlerts: vi.fn(async () => []),
      pollBroadcasts: vi.fn(async () => []),
      claimBroadcast: vi.fn(async () => {
        throw new Error('not used')
      }),
    }
    let events: LiveSessionEvents | undefined
    const session: VolunteerSession = {
      attachMedia: vi.fn(),
      send: vi.fn(async () => undefined),
      disconnect: vi.fn(async () => undefined),
    }
    const connectSession: ConnectVolunteerSession = vi.fn(async (_joined, callbacks) => {
      events = callbacks
      return session
    })
    const user = userEvent.setup()

    render(<App api={api} connectSession={connectSession} />)
    expect(screen.getByText('You can only watch and guide. The elder stays in control.')).toBeInTheDocument()
    await user.type(screen.getByLabelText('6-digit room code'), '482913')
    await user.type(screen.getByLabelText('Your display name'), 'Alex')
    await user.click(screen.getByRole('button', { name: 'Join Assistance Session' }))

    expect(await screen.findByText('Assistance in Progress')).toBeInTheDocument()
    expect(api.joinSession).toHaveBeenCalledWith({ code: '482913', name: 'Alex' })
    expect(screen.getByRole('link', { name: 'View Safety Alerts' })).toHaveAttribute(
      'href',
      '/alerts.html?session_id=session-1',
    )
    expect(screen.getByLabelText('Elder camera video')).toBeInTheDocument()
    expect(session.attachMedia).toHaveBeenCalledWith(
      expect.any(HTMLVideoElement),
      expect.any(HTMLVideoElement),
      expect.any(HTMLAudioElement),
    )

    act(() => events?.onFreeze('A request for a verification code was detected.'))
    expect(screen.getByRole('alert')).toHaveTextContent('The AI safety monitor paused this session')
    expect(screen.getByRole('alert')).toHaveTextContent('A request for a verification code was detected.')

    act(() => events?.onResume())
    act(() => events?.onRisk({
      v: 1,
      type: 'safety.risk',
      level: 'danger',
      transcript: 'Please tell me the verification code.',
      transcript_truncated: true,
      matched_rules: ['request_sensitive_information', 'verification_code'],
    }))
    expect(screen.getByRole('alert')).toHaveTextContent('Potentially dangerous language detected')
    expect(screen.getByRole('alert')).toHaveTextContent('Please tell me the verification code.')
    expect(screen.getByRole('alert')).toHaveTextContent('The transcript was shortened to the first 1,000 characters.')
  })

  it('shows the elder camera separately without replacing the annotated screen', async () => {
    const api: SecondSightApi = {
      joinSession: vi.fn(async () => ({
        sessionId: 'session-2',
        liveKitUrl: 'wss://demo.livekit.cloud',
        liveKitToken: 'volunteer-jwt',
      })),
      createSession: vi.fn(async () => {
        throw new Error('not used')
      }),
      logEvent: vi.fn(async () => undefined),
      listAlerts: vi.fn(async () => []),
      pollBroadcasts: vi.fn(async () => []),
      claimBroadcast: vi.fn(async () => {
        throw new Error('not used')
      }),
    }
    let events: LiveSessionEvents | undefined
    const session: VolunteerSession = {
      attachMedia: vi.fn(),
      send: vi.fn(async () => undefined),
      disconnect: vi.fn(async () => undefined),
    }
    const connectSession: ConnectVolunteerSession = vi.fn(async (_joined, callbacks) => {
      events = callbacks
      return session
    })
    const user = userEvent.setup()

    const view = render(<App api={api} connectSession={connectSession} />)
    await user.type(screen.getByLabelText('6-digit room code'), '482913')
    await user.type(screen.getByLabelText('Your display name'), 'Alex')
    await user.click(screen.getByRole('button', { name: 'Join Assistance Session' }))

    const app = within(view.container)
    const sharedScreen = await app.findByLabelText("Elder's shared screen")
    const elderCamera = app.getByLabelText('Elder camera video')
    expect(session.attachMedia).toHaveBeenCalledWith(
      sharedScreen,
      elderCamera,
      expect.any(HTMLAudioElement),
    )
    expect(app.getByText('Waiting for the elder to share their screen…')).toBeInTheDocument()
    expect(app.getByText('Waiting for the elder to turn on their camera…')).toBeInTheDocument()

    act(() => events?.onMediaChanged('camera', true))
    expect(app.queryByText('Waiting for the elder to turn on their camera…')).not.toBeInTheDocument()
    expect(app.getByText('Waiting for the elder to share their screen…')).toBeInTheDocument()

    act(() => events?.onMediaChanged('screen', true))
    expect(app.queryByText('Waiting for the elder to share their screen…')).not.toBeInTheDocument()

    act(() => events?.onMediaChanged('camera', false))
    expect(app.getByText('Waiting for the elder to turn on their camera…')).toBeInTheDocument()
  })

  it('reports presence, shows the receiving state, and claims an elder broadcast', async () => {
    const api: SecondSightApi = {
      joinSession: vi.fn(async () => {
        throw new Error('not used')
      }),
      createSession: vi.fn(async () => {
        throw new Error('not used')
      }),
      logEvent: vi.fn(async () => undefined),
      listAlerts: vi.fn(async () => []),
      pollBroadcasts: vi.fn(async () => [{
        sessionId: '9d1d5434-6da5-41e0-af70-c5aa35c6816f',
        requestedAt: '2026-08-29T10:00:00.000Z',
        elderLabel: 'Margaret',
      }]),
      claimBroadcast: vi.fn(async () => ({
        sessionId: '9d1d5434-6da5-41e0-af70-c5aa35c6816f',
        liveKitUrl: 'wss://demo.livekit.cloud',
        liveKitToken: 'claimed-volunteer-jwt',
      })),
    }
    const session: VolunteerSession = {
      attachMedia: vi.fn(),
      send: vi.fn(async () => undefined),
      disconnect: vi.fn(async () => undefined),
    }
    const connectSession: ConnectVolunteerSession = vi.fn(async () => session)
    const user = userEvent.setup()

    render(<App api={api} connectSession={connectSession} />)

    expect(await screen.findByText('Listening for help requests')).toBeInTheDocument()
    expect(await screen.findByText('Margaret is waiting for help')).toBeInTheDocument()
    expect(api.pollBroadcasts).toHaveBeenCalledWith({
      assistantId: expect.any(String),
      name: 'Available Volunteer',
    })

    await user.type(screen.getByLabelText('Your display name'), 'Alex')
    await user.click(screen.getByRole('button', { name: 'Respond' }))

    expect(await screen.findByText('Assistance in Progress')).toBeInTheDocument()
    expect(screen.getByText('Live help request')).toBeInTheDocument()
    expect(api.claimBroadcast).toHaveBeenCalledWith({
      sessionId: '9d1d5434-6da5-41e0-af70-c5aa35c6816f',
      assistantId: expect.any(String),
      name: 'Alex',
    })
    expect(connectSession).toHaveBeenCalledWith(
      expect.objectContaining({ liveKitToken: 'claimed-volunteer-jwt' }),
      expect.any(Object),
    )
  })
})
