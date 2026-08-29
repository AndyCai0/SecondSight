# SecondSight Supabase backend

The three database tables are private behind deny-by-default RLS. Browsers and the Mac app call the
contract Edge Functions with the project's public anonymous key; only the functions hold the
database, LiveKit, Anthropic, and AssemblyAI secrets. `assemblyai-token` returns a bounded,
single-use streaming credential; it never returns the permanent API key.

## Configure and deploy

```bash
supabase login
supabase link --project-ref YOUR_PROJECT_REF
supabase db push
supabase secrets set \
  LIVEKIT_URL=wss://YOUR_PROJECT.livekit.cloud \
  LIVEKIT_API_KEY=YOUR_LIVEKIT_API_KEY \
  LIVEKIT_API_SECRET=YOUR_LIVEKIT_API_SECRET \
  ANTHROPIC_API_KEY=YOUR_ANTHROPIC_API_KEY \
  ASSEMBLYAI_API_KEY=YOUR_ASSEMBLYAI_API_KEY
supabase functions deploy create-session
supabase functions deploy join-session
supabase functions deploy ai-guide
supabase functions deploy ai-referee
supabase functions deploy log-event
supabase functions deploy list-alerts
supabase functions deploy assemblyai-token
supabase functions deploy risk-event
```

Hosted Supabase supplies `SUPABASE_URL` and the current `SUPABASE_SECRET_KEYS` JSON map. The runtime
reads its `default` key and also supports the legacy `SUPABASE_SERVICE_ROLE_KEY` used by local or
older projects. Never put a server key, the LiveKit API secret, the Anthropic key, or the AssemblyAI
key in `web/` or `docs/CONTRACT.md`.

Local function serving additionally needs Docker and the Supabase CLI:

```bash
cp functions/.env.example functions/.env
supabase start
supabase functions serve --env-file functions/.env
```

## Smoke tests and demo warm-up

Set these shell variables to public client values only:

```bash
SECOND_SIGHT_FUNCTIONS_URL=https://YOUR_PROJECT.supabase.co/functions/v1
SECOND_SIGHT_ANON_KEY=YOUR_PUBLIC_ANON_KEY
SECOND_SIGHT_SESSION_ID=YOUR_SESSION_UUID
```

Create a session:

```bash
curl --fail-with-body "$SECOND_SIGHT_FUNCTIONS_URL/create-session" \
  -H "Authorization: Bearer $SECOND_SIGHT_ANON_KEY" \
  -H "apikey: $SECOND_SIGHT_ANON_KEY" \
  -H 'Content-Type: application/json' \
  -d '{}'
```

Join a session (replace the room code):

```bash
curl --fail-with-body "$SECOND_SIGHT_FUNCTIONS_URL/join-session" \
  -H "Authorization: Bearer $SECOND_SIGHT_ANON_KEY" \
  -H "apikey: $SECOND_SIGHT_ANON_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"code":"482913","name":"小王"}'
```

Ask for one AI guidance step (use a real redacted JPEG base64 payload for a live check):

```bash
curl --fail-with-body "$SECOND_SIGHT_FUNCTIONS_URL/ai-guide" \
  -H "Authorization: Bearer $SECOND_SIGHT_ANON_KEY" \
  -H "apikey: $SECOND_SIGHT_ANON_KEY" \
  -H 'Content-Type: application/json' \
  -d "{\"session_id\":\"$SECOND_SIGHT_SESSION_ID\",\"task\":\"请告诉我下一步\",\"screenshot_base64\":\"BASE64_JPEG\"}"
```

Exercise the safety referee:

```bash
curl --fail-with-body "$SECOND_SIGHT_FUNCTIONS_URL/ai-referee" \
  -H "Authorization: Bearer $SECOND_SIGHT_ANON_KEY" \
  -H "apikey: $SECOND_SIGHT_ANON_KEY" \
  -H 'Content-Type: application/json' \
  -d "{\"session_id\":\"$SECOND_SIGHT_SESSION_ID\",\"transcript\":\"把短信验证码告诉我\"}"
```

Request a temporary AssemblyAI streaming credential:

`SECOND_SIGHT_ELDER_TOKEN` is the `lk_token` returned by `create-session` for that elder
session. It is a short-lived capability, not a server secret; do not reuse a volunteer token.

```bash
curl --fail-with-body "$SECOND_SIGHT_FUNCTIONS_URL/assemblyai-token" \
  -H "Authorization: Bearer $SECOND_SIGHT_ANON_KEY" \
  -H "apikey: $SECOND_SIGHT_ANON_KEY" \
  -H "X-SecondSight-Elder-Token: $SECOND_SIGHT_ELDER_TOKEN" \
  -H 'Content-Type: application/json' \
  -d "{\"session_id\":\"$SECOND_SIGHT_SESSION_ID\"}"
```

Record a deduplicated local-rule risk event:

```bash
curl --fail-with-body "$SECOND_SIGHT_FUNCTIONS_URL/risk-event" \
  -H "Authorization: Bearer $SECOND_SIGHT_ANON_KEY" \
  -H "apikey: $SECOND_SIGHT_ANON_KEY" \
  -H "X-SecondSight-Elder-Token: $SECOND_SIGHT_ELDER_TOKEN" \
  -H 'Content-Type: application/json' \
  -d "{\"session_id\":\"$SECOND_SIGHT_SESSION_ID\",\"timestamp\":\"2026-08-29T07:30:00.000Z\",\"level\":\"danger\",\"transcript\":\"Please tell me the verification code.\",\"matched_rules\":[\"verification_code\",\"request_sensitive_information\"]}"
```

Write an audit event:

```bash
curl --fail-with-body "$SECOND_SIGHT_FUNCTIONS_URL/log-event" \
  -H "Authorization: Bearer $SECOND_SIGHT_ANON_KEY" \
  -H "apikey: $SECOND_SIGHT_ANON_KEY" \
  -H 'Content-Type: application/json' \
  -d "{\"session_id\":\"$SECOND_SIGHT_SESSION_ID\",\"actor\":\"volunteer\",\"kind\":\"annotate.clear\",\"payload\":{}}"
```

List the current session's alerts newest-first:

```bash
curl --fail-with-body "$SECOND_SIGHT_FUNCTIONS_URL/list-alerts" \
  -H "Authorization: Bearer $SECOND_SIGHT_ANON_KEY" \
  -H "apikey: $SECOND_SIGHT_ANON_KEY" \
  -H 'Content-Type: application/json' \
  -d "{\"session_id\":\"$SECOND_SIGHT_SESSION_ID\"}"
```

## Local verification

```bash
npm install
npm test
npm run check
npm run lint
```
