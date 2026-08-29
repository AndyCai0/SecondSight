# SecondSight Supabase backend

The application database tables are private behind deny-by-default RLS. Browsers and the Mac app call
the contract Edge Functions, broadcast discovery functions, and demo-only read-only `list-alerts` function with the project's
public anonymous key; only the functions hold the database and provider secrets. LiveKit is required
for rooms and real-time media. Anthropic is optional and only enables the two AI endpoints.

## Configure and deploy

```bash
supabase login
supabase link --project-ref YOUR_PROJECT_REF
supabase db push
supabase secrets set \
  LIVEKIT_URL=wss://YOUR_PROJECT.livekit.cloud \
  LIVEKIT_API_KEY=YOUR_LIVEKIT_API_KEY \
  LIVEKIT_API_SECRET=YOUR_LIVEKIT_API_SECRET
# Optional, only when AI guidance/referee is intentionally enabled:
supabase secrets set AI_ENABLED=true ANTHROPIC_API_KEY=YOUR_ANTHROPIC_API_KEY
supabase functions deploy create-session
supabase functions deploy join-session
supabase functions deploy ai-guide
supabase functions deploy ai-referee
supabase functions deploy log-event
supabase functions deploy list-alerts
supabase functions deploy broadcast-session
supabase functions deploy assistant-poll
supabase functions deploy claim-broadcast
```

Hosted Supabase supplies `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, and the current
`SUPABASE_SECRET_KEYS` JSON map. Hosted functions also use their built-in `SUPABASE_DB_URL` for
server-only database operations, avoiding any dependency on client RLS credentials. The REST
service-key path remains available for local environments without that database URL. New opaque
`sb_secret_...` values are sent to PostgREST only through its `apikey` header; sending one as
`Authorization: Bearer` makes the gateway reject it as an invalid JWT.
Unless both `AI_ENABLED=true` and `ANTHROPIC_API_KEY` are present, `ai-guide` and `ai-referee`
return HTTP 503 while room creation, joining, and LiveKit media remain available. Never put a
server key, the LiveKit API secret, or an Anthropic key in `web/` or `docs/CONTRACT.md`.

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
