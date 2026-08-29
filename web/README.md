# SecondSight volunteer web

Desktop React/Vite client for volunteer voice guidance and visual annotations. It deliberately has
no keyboard, mouse, or remote-control protocol. The LiveKit token permits the volunteer to publish
only a microphone track.

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
- `/fake-elder.html` creates an elder session (or accepts a manually signed elder token), shares a
  browser screen, and displays every received DataChannel payload for integration testing.

The fake-elder page is a development/demo fixture. It must not be presented as the privacy-redacted
Mac elder client.
