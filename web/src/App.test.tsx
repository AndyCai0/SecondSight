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
    expect(screen.getByText('你只能看和指，操作永远由长辈本人完成')).toBeInTheDocument()
    await user.type(screen.getByLabelText('6 位房间码'), '482913')
    await user.type(screen.getByLabelText('你的昵称'), '小王')
    await user.click(screen.getByRole('button', { name: '进入协助房间' }))

    expect(await screen.findByText('正在协助')).toBeInTheDocument()
    expect(api.joinSession).toHaveBeenCalledWith({ code: '482913', name: '小王' })
    expect(screen.getByRole('link', { name: '查看安全告警记录' })).toHaveAttribute(
      'href',
      '/alerts.html?session_id=session-1',
    )
    expect(screen.getByLabelText('长辈摄像头画面')).toBeInTheDocument()
    expect(session.attachMedia).toHaveBeenCalledWith(
      expect.any(HTMLVideoElement),
      expect.any(HTMLVideoElement),
      expect.any(HTMLAudioElement),
    )

    act(() => events?.onFreeze('检测到索要验证码'))
    expect(screen.getByRole('alertdialog')).toHaveTextContent('会话已被 AI 安全助手暂停')
    expect(screen.getByRole('alertdialog')).toHaveTextContent('检测到索要验证码')

    act(() => events?.onResume())
    act(() => events?.onRisk({
      v: 1,
      type: 'safety.risk',
      level: 'danger',
      transcript: 'Please tell me the verification code.',
      transcript_truncated: true,
      matched_rules: ['request_sensitive_information', 'verification_code'],
    }))
    expect(screen.getByRole('alert')).toHaveTextContent('长辈端检测到危险话术')
    expect(screen.getByRole('alert')).toHaveTextContent('Please tell me the verification code.')
    expect(screen.getByRole('alert')).toHaveTextContent('字幕过长')
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
    await user.type(screen.getByLabelText('6 位房间码'), '482913')
    await user.type(screen.getByLabelText('你的昵称'), '小王')
    await user.click(screen.getByRole('button', { name: '进入协助房间' }))

    const app = within(view.container)
    const sharedScreen = await app.findByLabelText('长辈共享的屏幕')
    const elderCamera = app.getByLabelText('长辈摄像头画面')
    expect(session.attachMedia).toHaveBeenCalledWith(
      sharedScreen,
      elderCamera,
      expect.any(HTMLAudioElement),
    )
    expect(app.getByText('等待长辈分享电脑画面…')).toBeInTheDocument()
    expect(app.getByText('等待长辈开启摄像头…')).toBeInTheDocument()

    act(() => events?.onMediaChanged('camera', true))
    expect(app.queryByText('等待长辈开启摄像头…')).not.toBeInTheDocument()
    expect(app.getByText('等待长辈分享电脑画面…')).toBeInTheDocument()

    act(() => events?.onMediaChanged('screen', true))
    expect(app.queryByText('等待长辈分享电脑画面…')).not.toBeInTheDocument()

    act(() => events?.onMediaChanged('camera', false))
    expect(app.getByText('等待长辈开启摄像头…')).toBeInTheDocument()
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
        elderLabel: '李奶奶',
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

    expect(await screen.findByText('正在接收广播')).toBeInTheDocument()
    expect(await screen.findByText('李奶奶正在等待帮助')).toBeInTheDocument()
    expect(api.pollBroadcasts).toHaveBeenCalledWith({
      assistantId: expect.any(String),
      name: '待命助手',
    })

    await user.type(screen.getByLabelText('你的昵称'), '小王')
    await user.click(screen.getByRole('button', { name: '响应求助' }))

    expect(await screen.findByText('正在协助')).toBeInTheDocument()
    expect(screen.getByText('在线求助已接通')).toBeInTheDocument()
    expect(api.claimBroadcast).toHaveBeenCalledWith({
      sessionId: '9d1d5434-6da5-41e0-af70-c5aa35c6816f',
      assistantId: expect.any(String),
      name: '小王',
    })
    expect(connectSession).toHaveBeenCalledWith(
      expect.objectContaining({ liveKitToken: 'claimed-volunteer-jwt' }),
      expect.any(Object),
    )
  })
})
