import { beforeEach, describe, expect, it, vi } from 'vitest'

const liveKit = vi.hoisted(() => {
  const localCameraAttach = vi.fn()
  const cameraTrack = {
    attach: localCameraAttach,
    kind: 'video',
    stop: vi.fn(),
  }
  const microphoneTrack = {
    kind: 'audio',
    stop: vi.fn(),
  }
  const createLocalTracks = vi.fn(async () => [cameraTrack, microphoneTrack])
  const publishTrack = vi.fn(async (track: object) => ({ track }))
  const localParticipant = {
    publishData: vi.fn(async () => undefined),
    publishTrack,
  }
  const room = {
    connect: vi.fn(async () => undefined),
    disconnect: vi.fn(async (_stopTracks?: boolean) => undefined),
    localParticipant,
    on: vi.fn(),
    remoteParticipants: new Map(),
  }
  const Room = vi.fn(function Room() {
    return room
  })
  return {
    cameraTrack,
    createLocalTracks,
    localCameraAttach,
    microphoneTrack,
    publishTrack,
    room,
    Room,
  }
})

vi.mock('livekit-client', () => ({
  createLocalTracks: liveKit.createLocalTracks,
  Room: liveKit.Room,
  RoomEvent: {
    DataReceived: 'dataReceived',
    Disconnected: 'disconnected',
    TrackSubscribed: 'trackSubscribed',
    TrackUnsubscribed: 'trackUnsubscribed',
  },
  Track: {
    Kind: { Audio: 'audio', Video: 'video' },
    Source: {
      Camera: 'camera',
      Microphone: 'microphone',
      ScreenShare: 'screen_share',
      Unknown: 'unknown',
    },
  },
}))

import {
  acquireVolunteerMedia,
  connectVolunteerSession,
  type LiveSessionEvents,
  type PreparedVolunteerMedia,
} from './transport'

const joined = {
  sessionId: 'session-1',
  liveKitUrl: 'wss://demo.livekit.cloud',
  liveKitToken: 'volunteer-jwt',
}

const events: LiveSessionEvents = {
  onFreeze: vi.fn(),
  onResume: vi.fn(),
  onDisconnected: vi.fn(),
  onMediaChanged: vi.fn(),
  onRisk: vi.fn(),
}

function preparedMedia(): PreparedVolunteerMedia {
  return {
    camera: liveKit.cameraTrack,
    microphone: liveKit.microphoneTrack,
    stop: vi.fn(),
  } as unknown as PreparedVolunteerMedia
}

beforeEach(() => {
  vi.clearAllMocks()
  liveKit.createLocalTracks.mockResolvedValue([
    liveKit.cameraTrack,
    liveKit.microphoneTrack,
  ])
  liveKit.publishTrack.mockImplementation(async (track: object) => ({ track }))
  liveKit.room.disconnect.mockResolvedValue(undefined)
})

describe('volunteer media connection', () => {
  it('acquires camera and microphone together before a room is claimed', async () => {
    const media = await acquireVolunteerMedia()

    expect(liveKit.createLocalTracks).toHaveBeenCalledWith({ audio: true, video: true })
    expect(media.camera).toBe(liveKit.cameraTrack)
    expect(media.microphone).toBe(liveKit.microphoneTrack)

    media.stop()
    media.stop()
    expect(liveKit.cameraTrack.stop).toHaveBeenCalledOnce()
    expect(liveKit.microphoneTrack.stop).toHaveBeenCalledOnce()
  })

  it('publishes prepared tracks and exposes the local camera preview', async () => {
    const media = preparedMedia()
    const session = await connectVolunteerSession(joined, events, media)

    expect(liveKit.room.connect).toHaveBeenCalledWith(
      'wss://demo.livekit.cloud',
      'volunteer-jwt',
    )
    expect(liveKit.publishTrack).toHaveBeenNthCalledWith(1, media.camera, {
      source: 'camera',
    })
    expect(liveKit.publishTrack).toHaveBeenNthCalledWith(2, media.microphone, {
      source: 'microphone',
    })

    const preview = document.createElement('video')
    session.attachLocalCamera(preview)
    expect(liveKit.localCameraAttach).toHaveBeenCalledWith(preview)

    await session.disconnect()
    expect(liveKit.room.disconnect).toHaveBeenCalledWith(true)
    expect(media.stop).toHaveBeenCalledOnce()
  })

  it('stops local capture even when room disconnect fails', async () => {
    const media = preparedMedia()
    const session = await connectVolunteerSession(joined, events, media)
    liveKit.room.disconnect.mockRejectedValueOnce(new Error('disconnect failed'))

    await expect(session.disconnect()).rejects.toThrow('disconnect failed')
    expect(media.stop).toHaveBeenCalledOnce()
  })

  it('stops prepared tracks and disconnects the partial room when publication fails', async () => {
    const media = preparedMedia()
    liveKit.publishTrack.mockRejectedValueOnce(new Error('publish failed'))

    await expect(connectVolunteerSession(joined, events, media)).rejects.toThrow('publish failed')
    expect(media.stop).toHaveBeenCalledOnce()
    expect(liveKit.room.disconnect).toHaveBeenCalledWith(true)
  })
})
