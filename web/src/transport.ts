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
  type SafetyRiskMessage,
  type VolunteerOutboundMessage,
} from './contracts'

interface DataPublisher {
  publishData(data: Uint8Array, options: { reliable: boolean }): Promise<void>
}

export interface LiveSessionEvents {
  onFreeze(reason: string): void
  onResume(): void
  onDisconnected(): void
  onMediaChanged(kind: ElderVideoKind, isAvailable: boolean): void
  onRisk(risk: SafetyRiskMessage): void
}

export interface VolunteerSession {
  attachMedia(
    screenVideo: HTMLVideoElement,
    cameraVideo: HTMLVideoElement,
    audio: HTMLAudioElement,
  ): void
  send(message: VolunteerOutboundMessage): Promise<void>
  disconnect(): Promise<void>
}

export type ConnectVolunteerSession = (
  joined: JoinedSession,
  events: LiveSessionEvents,
) => Promise<VolunteerSession>

export type ElderVideoKind = 'screen' | 'camera'

export function elderVideoKind(
  track: Pick<RemoteTrack, 'kind' | 'source'>,
  trackName?: string,
): ElderVideoKind | null {
  if (track.kind !== Track.Kind.Video) return null
  if (track.source === Track.Source.ScreenShare || trackName === 'screen-redacted') return 'screen'
  if (track.source === Track.Source.Camera || trackName === 'elder-camera') return 'camera'
  return null
}

export function isSharedScreenTrack(
  track: Pick<RemoteTrack, 'kind' | 'source'>,
): boolean {
  return elderVideoKind(track) === 'screen'
}

export async function publishContractMessage(
  publisher: DataPublisher,
  message: VolunteerOutboundMessage,
): Promise<void> {
  await publisher.publishData(encodeDataMessage(message), {
    reliable: isReliableMessage(message),
  })
}

export function dispatchElderMessage(payload: Uint8Array, events: LiveSessionEvents): void {
  const message = decodeDataMessage(payload)
  if (message.type === 'control.freeze') events.onFreeze(message.reason)
  if (message.type === 'control.resume') events.onResume()
  if (message.type === 'safety.risk') events.onRisk(message)
}

export const connectVolunteerSession: ConnectVolunteerSession = async (joined, events) => {
  const room = new Room({ adaptiveStream: true, dynacast: true })
  let screenVideoElement: HTMLVideoElement | null = null
  let cameraVideoElement: HTMLVideoElement | null = null
  let audioElement: HTMLAudioElement | null = null

  function attachTrack(track: RemoteTrack, trackName?: string): void {
    const videoKind = elderVideoKind(track, trackName)
    if (videoKind === 'screen' && screenVideoElement) {
      track.attach(screenVideoElement)
      events.onMediaChanged('screen', true)
    }
    if (videoKind === 'camera' && cameraVideoElement) {
      track.attach(cameraVideoElement)
      events.onMediaChanged('camera', true)
    }
    if (track.kind === Track.Kind.Audio && audioElement) track.attach(audioElement)
  }

  function detachTrack(track: RemoteTrack, trackName?: string): void {
    const videoKind = elderVideoKind(track, trackName)
    if (videoKind === 'screen' && screenVideoElement) {
      track.detach(screenVideoElement)
      events.onMediaChanged('screen', false)
    }
    if (videoKind === 'camera' && cameraVideoElement) {
      track.detach(cameraVideoElement)
      events.onMediaChanged('camera', false)
    }
    if (track.kind === Track.Kind.Audio && audioElement) track.detach(audioElement)
  }

  function attachElderTracks(): void {
    const elder = room.remoteParticipants.get('elder')
    if (!elder) return
    for (const publication of elder.trackPublications.values()) {
      if (publication.track) attachTrack(publication.track, publication.trackName)
    }
  }

  room.on(RoomEvent.TrackSubscribed, (track, publication, participant) => {
    if (participant.identity === 'elder') attachTrack(track, publication.trackName)
  })
  room.on(RoomEvent.TrackUnsubscribed, (track, publication, participant) => {
    if (participant.identity === 'elder') detachTrack(track, publication.trackName)
  })
  room.on(RoomEvent.DataReceived, (payload, participant) => {
    if (participant?.identity !== 'elder') return
    try {
      dispatchElderMessage(payload, events)
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
    attachMedia(screenVideo, cameraVideo, audio) {
      screenVideoElement = screenVideo
      cameraVideoElement = cameraVideo
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
