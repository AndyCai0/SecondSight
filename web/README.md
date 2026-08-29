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
secret, or Anthropic key to this directory.

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
- `/fake-elder.html` creates an elder session (or accepts a manually signed elder token), shares a
  browser screen, and displays every received DataChannel payload for integration testing.
- `/alerts.html?session_id=SESSION_UUID` loads that session's warning/freeze history through the
  read-only demo Edge Function. The active volunteer session links to this page automatically.

The fake-elder page is a development/demo fixture. It must not be presented as the privacy-redacted
Mac elder client.

The 100 ms HTTP poll is intentionally bounded to one in-flight request per tab for the demo. Before
scaling beyond a small volunteer pool, replace transport with Supabase Realtime Broadcast + Presence
while retaining the server-side atomic claim endpoint.
