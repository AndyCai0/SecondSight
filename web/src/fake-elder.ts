import { Room, RoomEvent } from 'livekit-client'
import { createSecondSightApi } from './api'

const form = requiredElement<HTMLFormElement>('connect-form')
const button = requiredElement<HTMLButtonElement>('connect-button')
const status = requiredElement<HTMLSpanElement>('status')
const roomCode = requiredElement<HTMLElement>('room-code')
const messages = requiredElement<HTMLOListElement>('messages')
const preview = requiredElement<HTMLVideoElement>('preview')
const supabaseUrl = requiredElement<HTMLInputElement>('supabase-url')
const anonKey = requiredElement<HTMLInputElement>('anon-key')
const manualLiveKitUrl = requiredElement<HTMLInputElement>('livekit-url')
const manualLiveKitToken = requiredElement<HTMLInputElement>('livekit-token')

supabaseUrl.value = import.meta.env.VITE_SUPABASE_URL ?? ''
anonKey.value = import.meta.env.VITE_SUPABASE_ANON_KEY ?? ''

form.addEventListener('submit', (event) => {
  event.preventDefault()
  void connect()
})

async function connect(): Promise<void> {
  button.disabled = true
  status.textContent = 'Creating and connecting…'
  let room: Room | null = null
  try {
    let liveKitUrl = manualLiveKitUrl.value.trim()
    let liveKitToken = manualLiveKitToken.value.trim()
    if (!liveKitUrl || !liveKitToken) {
      if (!supabaseUrl.value.trim() || !anonKey.value.trim()) {
        throw new Error('Enter a Supabase URL and public anon key, or provide both a signed LiveKit URL and token.')
      }
      const api = createSecondSightApi({
        supabaseUrl: supabaseUrl.value.trim(),
        supabaseAnonKey: anonKey.value.trim(),
      })
      const created = await api.createSession()
      liveKitUrl = created.liveKitUrl
      liveKitToken = created.liveKitToken
      roomCode.textContent = created.code
    }

    room = new Room({ adaptiveStream: true, dynacast: true })
    room.on(RoomEvent.DataReceived, (payload, participant) => {
      const raw = new TextDecoder().decode(payload)
      let display = raw
      try {
        display = JSON.stringify(JSON.parse(raw))
      } catch {
        // The raw payload is intentionally retained for protocol debugging.
      }
      console.log('[SecondSight DataChannel]', participant?.identity ?? 'server', display)
      const item = document.createElement('li')
      item.textContent = `${participant?.identity ?? 'server'}: ${display}`
      messages.prepend(item)
    })
    room.on(RoomEvent.Disconnected, () => {
      status.textContent = 'Disconnected'
    })

    await room.connect(liveKitUrl, liveKitToken)
    const publication = await room.localParticipant.setScreenShareEnabled(true, {
      audio: false,
      contentHint: 'detail',
    })
    publication?.track?.attach(preview)
    status.textContent = `Connected as ${room.localParticipant.identity}. Sharing the screen.`
    button.textContent = 'Connected'
  } catch (error) {
    await room?.disconnect()
    status.textContent = error instanceof Error ? error.message : 'Connection failed'
    button.disabled = false
  }
}

function requiredElement<ElementType extends HTMLElement>(id: string): ElementType {
  const element = document.getElementById(id)
  if (!element) throw new Error(`Missing #${id}`)
  return element as ElementType
}
