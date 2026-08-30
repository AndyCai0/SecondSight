# SecondSight volunteer web

Desktop React/Vite client for volunteer voice guidance and visual annotations. It deliberately has
no keyboard, mouse, or remote-control protocol. The LiveKit token permits the volunteer to publish
only microphone and camera tracks, and still forbids screen sharing. The browser acquires both
tracks only after the volunteer clicks to join or respond, before consuming that request on the
backend. It reuses those tracks for LiveKit, shows a local camera preview, and stops them when the
volunteer leaves or any later join step fails.

## Configure

```bash
cp .env.example .env.local
```

Fill only the public Supabase URL and anonymous key. Never add a Supabase server key, LiveKit API
secret, or DeepSeek key to this directory.

## Run and verify

```bash
npm install
npm run dev
npm test
npm run lint
npm run build
```

- `/` is the volunteer client.
  While it is open and not in a call, it refreshes tab-scoped presence and receives elder help
  broadcasts with a serial 100 ms poll. Only an atomic claim response can return a LiveKit token.
  During a call it also displays the latest speaker-labelled elder and volunteer captions. Partial
  captions replace in place and final captions are retained; the browser cannot publish or forge
  this elder-originated message type.
- `/fake-elder.html` creates an elder session (or accepts a manually signed elder token), shares a
  browser screen, and displays every received DataChannel payload for integration testing.
- `/alerts.html?session_id=SESSION_UUID` loads that session's warning/freeze history through the
  read-only demo Edge Function. The active volunteer session links to this page automatically.
- During `npm run dev`, `/test-fixtures/privacy-fixture.html` contains invented email, banking,
  identity, health, contact, input, message, calendar, address-suggestion, Canvas/PDF-style, face,
  and QR examples for two-display privacy verification. It contains no real user data. Append
  `?focus-input=1` to expose the synthetic suggestion surface or `?private-window=1` to exercise a
  Gmail/messages/calendar window-title context.

For localhost-only media testing, append `?test_synthetic_media=1` to use generated silent camera
and microphone tracks without occupying physical devices. `?test_secondary_camera=1` selects the
last enumerated physical camera/microphone, while `?test_audio_only=1` combines physical audio with
a generated camera. The app ignores all three switches on non-loopback hosts; they are never a
production media bypass.

The fake-elder page is a development/demo fixture. It must not be presented as the privacy-redacted
Mac elder client.

The 100 ms HTTP poll is intentionally bounded to one in-flight request per tab for the demo. Before
scaling beyond a small volunteer pool, replace transport with Supabase Realtime Broadcast + Presence
while retaining the server-side atomic claim endpoint.
