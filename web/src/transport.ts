import {
  Room,
  RoomEvent,
  Track,
  type LocalParticipant,
  type RemoteTrackPublication,
} from 'livekit-client'
import type { JoinedSession } from './api'
import {
  decodeDataMessage,
  encodeDataMessage,
  isReliableMessage,
  type VolunteerOutboundMessage,
} from './contracts'

interface DataPublisher {
  publishData(data: Uint8Array, options: { reliable: boolean }): Promise<void>
}

export interface LiveSessionEvents {
  onFreeze(reason: string): void
  onResume(): void
  onDisconnected(): void
  onScreenShareChanged(available: boolean): void
  onElderCameraChanged(available: boolean): void
}

export interface VolunteerSession {
  attachMedia(
    screenVideo: HTMLVideoElement,
    elderCameraVideo: HTMLVideoElement,
    audio: HTMLAudioElement,
  ): void
  send(message: VolunteerOutboundMessage): Promise<void>
  disconnect(): Promise<void>
}

export type ConnectVolunteerSession = (
  joined: JoinedSession,
  events: LiveSessionEvents,
) => Promise<VolunteerSession>

export async function publishContractMessage(
  publisher: DataPublisher,
  message: VolunteerOutboundMessage,
): Promise<void> {
  await publisher.publishData(encodeDataMessage(message), {
    reliable: isReliableMessage(message),
  })
}

export const connectVolunteerSession: ConnectVolunteerSession = async (joined, events) => {
  const room = new Room({ adaptiveStream: true, dynacast: true })
  let screenVideoElement: HTMLVideoElement | null = null
  let elderCameraVideoElement: HTMLVideoElement | null = null
  let audioElement: HTMLAudioElement | null = null

  function attachPublication(publication: RemoteTrackPublication): void {
    const track = publication.track
    if (!track) return
    if (track.kind === Track.Kind.Audio && audioElement) {
      track.attach(audioElement)
      return
    }
    if (track.kind !== Track.Kind.Video) return
    if (publication.source === Track.Source.ScreenShare && screenVideoElement) {
      track.attach(screenVideoElement)
      events.onScreenShareChanged(true)
    } else if (publication.source === Track.Source.Camera && elderCameraVideoElement) {
      track.attach(elderCameraVideoElement)
      events.onElderCameraChanged(true)
    }
  }

  function attachElderTracks(): void {
    const elder = room.remoteParticipants.get('elder')
    if (!elder) return
    for (const publication of elder.trackPublications.values()) {
      attachPublication(publication)
    }
  }

  room.on(RoomEvent.TrackSubscribed, (_track, publication, participant) => {
    if (participant.identity === 'elder') attachPublication(publication)
  })
  room.on(RoomEvent.TrackUnsubscribed, (_track, publication, participant) => {
    if (participant.identity !== 'elder') return
    if (publication.source === Track.Source.ScreenShare) events.onScreenShareChanged(false)
    if (publication.source === Track.Source.Camera) events.onElderCameraChanged(false)
  })
  room.on(RoomEvent.DataReceived, (payload, participant) => {
    if (participant?.identity !== 'elder') return
    try {
      const message = decodeDataMessage(payload)
      if (message.type === 'control.freeze') events.onFreeze(message.reason)
      if (message.type === 'control.resume') events.onResume()
    } catch {
      // Ignore malformed or future-version room messages.
    }
  })
  room.on(RoomEvent.Disconnected, events.onDisconnected)

  try {
    await room.connect(joined.liveKitUrl, joined.liveKitToken)
    await Promise.all([
      room.localParticipant.setMicrophoneEnabled(true),
      room.localParticipant.setCameraEnabled(true),
    ])
  } catch (error) {
    await room.disconnect()
    throw error
  }

  return {
    attachMedia(screenVideo, elderCameraVideo, audio) {
      screenVideoElement = screenVideo
      elderCameraVideoElement = elderCameraVideo
      audioElement = audio
      attachElderTracks()
    },
    send(message) {
      return publishContractMessage(
        room.localParticipant as Pick<LocalParticipant, 'publishData'>,
        message,
      )
    },
    disconnect() {
      return room.disconnect()
    },
  }
}
