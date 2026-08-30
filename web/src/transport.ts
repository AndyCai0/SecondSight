import {
  createLocalTracks,
  getEmptyAudioStreamTrack,
  getEmptyVideoStreamTrack,
  LocalAudioTrack,
  LocalVideoTrack,
  Room,
  RoomEvent,
  Track,
  type LocalParticipant,
  type LocalTrack,
  type RemoteTrack,
} from 'livekit-client'
import type { JoinedSession } from './api'
import {
  decodeDataMessage,
  encodeDataMessage,
  isReliableMessage,
  type CaptionTranscriptMessage,
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
  onCaption(caption: CaptionTranscriptMessage): void
}

export interface VolunteerSession {
  attachMedia(
    screenVideo: HTMLVideoElement,
    cameraVideo: HTMLVideoElement,
    audio: HTMLAudioElement,
  ): void
  attachLocalCamera(video: HTMLVideoElement): void
  send(message: VolunteerOutboundMessage): Promise<void>
  disconnect(): Promise<void>
}

export interface PreparedVolunteerMedia {
  camera: LocalTrack
  microphone: LocalTrack
  stop(): void
}

export type AcquireVolunteerMedia = () => Promise<PreparedVolunteerMedia>

export type ConnectVolunteerSession = (
  joined: JoinedSession,
  events: LiveSessionEvents,
  media: PreparedVolunteerMedia,
) => Promise<VolunteerSession>

export type ElderVideoKind = 'screen' | 'camera'

const volunteerMediaAcquisitionTimeoutMilliseconds = 15_000

type DeviceCaptureOption = true | { deviceId: { exact: string } }

export function isLoopbackMediaTestHost(hostname: string): boolean {
  return hostname === '127.0.0.1' || hostname === 'localhost' || hostname === '[::1]'
}

async function volunteerCaptureOptions(): Promise<{
  audio: DeviceCaptureOption
  video: DeviceCaptureOption
}> {
  const useSecondaryCamera = isLoopbackMediaTestHost(window.location.hostname)
    && new URLSearchParams(window.location.search).get('test_secondary_camera') === '1'
  if (!useSecondaryCamera) return { audio: true, video: true }

  try {
    const devices = await navigator.mediaDevices.enumerateDevices()
    const cameras = devices
      .filter((device) => device.kind === 'videoinput' && device.deviceId)
    const microphones = devices
      .filter((device) => device.kind === 'audioinput' && device.deviceId)
    const secondary = cameras.at(-1)
    const secondaryMicrophone = microphones.at(-1)
    return {
      audio: microphones.length > 1 && secondaryMicrophone
        ? { deviceId: { exact: secondaryMicrophone.deviceId } }
        : true,
      video: cameras.length > 1 && secondary
        ? { deviceId: { exact: secondary.deviceId } }
        : true,
    }
  } catch {
    // The normal browser permission flow below remains the fallback.
  }
  return { audio: true, video: true }
}

async function acquireTracksWithTimeout(): Promise<LocalTrack[]> {
  const search = new URLSearchParams(window.location.search)
  const allowTestMedia = isLoopbackMediaTestHost(window.location.hostname)
  const useSyntheticMedia = allowTestMedia
    && search.get('test_synthetic_media') === '1'
  if (useSyntheticMedia) {
    return [
      new LocalVideoTrack(getEmptyVideoStreamTrack()),
      new LocalAudioTrack(getEmptyAudioStreamTrack()),
    ]
  }

  let timedOut = false
  let timeout: number | undefined
  const useSyntheticVideo = allowTestMedia && search.get('test_audio_only') === '1'
  const captureOptions = await volunteerCaptureOptions()
  const acquisition = createLocalTracks({
    audio: captureOptions.audio,
    video: useSyntheticVideo ? false : captureOptions.video,
  }).then((tracks) => {
    if (timedOut) {
      tracks.forEach((track) => track.stop())
      throw new Error('Camera and microphone access timed out')
    }
    return useSyntheticVideo
      ? [new LocalVideoTrack(getEmptyVideoStreamTrack()), ...tracks]
      : tracks
  })
  const deadline = new Promise<never>((_, reject) => {
    timeout = window.setTimeout(() => {
      timedOut = true
      reject(new Error('Camera and microphone access timed out'))
    }, volunteerMediaAcquisitionTimeoutMilliseconds)
  })
  try {
    return await Promise.race([acquisition, deadline])
  } finally {
    if (timeout !== undefined) window.clearTimeout(timeout)
  }
}

export const acquireVolunteerMedia: AcquireVolunteerMedia = async () => {
  const tracks = await acquireTracksWithTimeout()
  const camera = tracks.find((track) => track.kind === Track.Kind.Video)
  const microphone = tracks.find((track) => track.kind === Track.Kind.Audio)
  if (!camera || !microphone) {
    tracks.forEach((track) => track.stop())
    throw new Error('Camera and microphone tracks are required')
  }

  let stopped = false
  return {
    camera,
    microphone,
    stop() {
      if (stopped) return
      stopped = true
      tracks.forEach((track) => track.stop())
    },
  }
}

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
  if (message.type === 'caption.transcript') events.onCaption(message)
}

export const connectVolunteerSession: ConnectVolunteerSession = async (joined, events, media) => {
  const room = new Room({ adaptiveStream: true, dynacast: true })
  let screenVideoElement: HTMLVideoElement | null = null
  let cameraVideoElement: HTMLVideoElement | null = null
  let audioElement: HTMLAudioElement | null = null
  let localCameraTrack: LocalTrack | null = null
  let localMediaStopped = false
  let disconnectNotified = false

  function stopLocalMedia(): void {
    if (localMediaStopped) return
    localMediaStopped = true
    media.stop()
  }

  function notifyDisconnected(): void {
    if (disconnectNotified) return
    disconnectNotified = true
    stopLocalMedia()
    events.onDisconnected()
  }

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
  room.on(RoomEvent.ParticipantDisconnected, (participant) => {
    if (participant.identity !== 'elder') return
    void room.disconnect(true).finally(notifyDisconnected)
  })
  room.on(RoomEvent.Disconnected, notifyDisconnected)

  try {
    await room.connect(joined.liveKitUrl, joined.liveKitToken)
    const cameraPublication = await room.localParticipant.publishTrack(media.camera, {
      source: Track.Source.Camera,
    })
    if (!cameraPublication.track) throw new Error('Camera track was not published')
    localCameraTrack = cameraPublication.track
    const microphonePublication = await room.localParticipant.publishTrack(media.microphone, {
      source: Track.Source.Microphone,
    })
    if (!microphonePublication.track) throw new Error('Microphone track was not published')
  } catch (error) {
    stopLocalMedia()
    try {
      await room.disconnect(true)
    } catch {
      // Preserve the connection/publication error while still stopping local capture.
    }
    throw error
  }

  return {
    attachMedia(screenVideo, cameraVideo, audio) {
      screenVideoElement = screenVideo
      cameraVideoElement = cameraVideo
      audioElement = audio
      attachElderTracks()
    },
    attachLocalCamera(video) {
      localCameraTrack?.attach(video)
    },
    send(message) {
      return publishContractMessage(
        room.localParticipant as Pick<LocalParticipant, 'publishData'>,
        message,
      )
    },
    async disconnect() {
      stopLocalMedia()
      try {
        await room.disconnect(true)
      } finally {
        stopLocalMedia()
      }
    },
  }
}
