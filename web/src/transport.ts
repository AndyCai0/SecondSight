import {
  Room,
  RoomEvent,
  Track,
  type LocalParticipant,
  type RemoteTrack,
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
  onMediaChanged(): void
}

export interface VolunteerSession {
  attachMedia(video: HTMLVideoElement, audio: HTMLAudioElement): void
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
  let videoElement: HTMLVideoElement | null = null
  let audioElement: HTMLAudioElement | null = null

  function attachTrack(track: RemoteTrack): void {
    if (track.kind === Track.Kind.Video && videoElement) track.attach(videoElement)
    if (track.kind === Track.Kind.Audio && audioElement) track.attach(audioElement)
    events.onMediaChanged()
  }

  function attachElderTracks(): void {
    const elder = room.remoteParticipants.get('elder')
    if (!elder) return
    for (const publication of elder.trackPublications.values()) {
      if (publication.track) attachTrack(publication.track)
    }
  }

  room.on(RoomEvent.TrackSubscribed, (track, _publication, participant) => {
    if (participant.identity === 'elder') attachTrack(track)
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
    await room.localParticipant.setMicrophoneEnabled(true)
  } catch (error) {
    await room.disconnect()
    throw error
  }

  return {
    attachMedia(video, audio) {
      videoElement = video
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
