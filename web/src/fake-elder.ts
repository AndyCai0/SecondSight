import { Room, RoomEvent } from 'livekit-client'
import { createSecondSightApi } from './api'
import {
  persistLanguage,
  resolveInitialLanguage,
  translate,
} from './i18n'

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
let language = resolveInitialLanguage()
let connectionState: 'idle' | 'connecting' | 'connected' = 'idle'

for (const control of document.querySelectorAll<HTMLButtonElement>('[data-language]')) {
  control.addEventListener('click', () => {
    const requested = control.dataset.language
    if (requested !== 'en' && requested !== 'zh') return
    language = requested
    persistLanguage(language)
    renderCopy()
  })
}

renderCopy()

supabaseUrl.value = import.meta.env.VITE_SUPABASE_URL ?? ''
anonKey.value = import.meta.env.VITE_SUPABASE_ANON_KEY ?? ''

form.addEventListener('submit', (event) => {
  event.preventDefault()
  void connect()
})

async function connect(): Promise<void> {
  connectionState = 'connecting'
  button.disabled = true
  status.textContent = translate(language, 'creatingAndConnecting')
  let room: Room | null = null
  try {
    let liveKitUrl = manualLiveKitUrl.value.trim()
    let liveKitToken = manualLiveKitToken.value.trim()
    if (!liveKitUrl || !liveKitToken) {
      if (!supabaseUrl.value.trim() || !anonKey.value.trim()) {
        throw new Error(translate(language, 'fakeElderCredentialRequired'))
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
      status.textContent = translate(language, 'disconnected')
    })

    await room.connect(liveKitUrl, liveKitToken)
    const publication = await room.localParticipant.setScreenShareEnabled(true, {
      audio: false,
      contentHint: 'detail',
    })
    publication?.track?.attach(preview)
    status.textContent = translate(language, 'connectedSharing', {
      identity: room.localParticipant.identity,
    })
    button.textContent = translate(language, 'connected')
    connectionState = 'connected'
  } catch (error) {
    await room?.disconnect()
    status.textContent = error instanceof Error ? error.message : translate(language, 'connectionFailed')
    button.disabled = false
    connectionState = 'idle'
  }
}

function renderCopy(): void {
  persistLanguage(language)
  document.title = translate(language, 'fakeElderPageTitle')
  requiredElement<HTMLAnchorElement>('back-link').textContent = `← ${translate(language, 'backToConsole')}`
  requiredElement<HTMLElement>('page-title').textContent = translate(language, 'fakeElderTitle')
  requiredElement<HTMLElement>('page-intro').innerHTML = translate(language, 'fakeElderIntro')
    .replace('create-session', '<code>create-session</code>')
    .replace('DataChannel', '<code>DataChannel</code>')
  requiredElement<HTMLElement>('supabase-url-label').textContent = translate(language, 'supabaseUrl')
  requiredElement<HTMLElement>('anon-key-label').textContent = translate(language, 'publicAnonKey')
  requiredElement<HTMLElement>('livekit-url-label').textContent = translate(language, 'signedLiveKitUrl')
  requiredElement<HTMLElement>('livekit-token-label').textContent = translate(language, 'signedElderToken')
  button.textContent = translate(
    language,
    connectionState === 'connected'
      ? 'connected'
      : connectionState === 'connecting'
        ? 'creatingAndConnecting'
        : 'createAndShare',
  )
  requiredElement<HTMLElement>('status-label').textContent = translate(language, 'statusLabel')
  if (status.textContent === 'Not connected' || status.textContent === '尚未连接') {
    status.textContent = translate(language, 'notConnected')
  }
  requiredElement<HTMLElement>('room-code-label').textContent = translate(language, 'roomCode')
  preview.setAttribute('aria-label', translate(language, 'sharedScreenPreview'))
  requiredElement<HTMLElement>('messages-title').textContent = translate(language, 'receivedMessages')
  for (const control of document.querySelectorAll<HTMLButtonElement>('[data-language]')) {
    control.setAttribute('aria-pressed', String(control.dataset.language === language))
  }
  document.querySelector<HTMLElement>('.language-switch')?.setAttribute(
    'aria-label',
    translate(language, 'language'),
  )
}

function requiredElement<ElementType extends HTMLElement>(id: string): ElementType {
  const element = document.getElementById(id)
  if (!element) throw new Error(`Missing #${id}`)
  return element as ElementType
}
