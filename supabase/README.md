# SecondSight Supabase backend

The three database tables are private behind deny-by-default RLS. Browsers and the Mac app call the
contract Edge Functions with the project's public anonymous key; only the functions hold the
database, LiveKit, Anthropic, and AssemblyAI secrets. `assemblyai-token` returns a bounded,
single-use streaming credential; it never returns the permanent API key.

## Configure and deploy

```bash
npm ci
npm exec -- supabase login
npm exec -- supabase link --project-ref YOUR_PROJECT_REF
npm exec -- supabase db push
cp functions/.env.example functions/.env.deploy
chmod 600 functions/.env.deploy
# Edit functions/.env.deploy with hosted values, then load it without putting
# secrets in shell history or process arguments.
npm exec -- supabase secrets set --env-file functions/.env.deploy
npm exec -- supabase functions deploy create-session
npm exec -- supabase functions deploy join-session
npm exec -- supabase functions deploy ai-guide
npm exec -- supabase functions deploy ai-referee
npm exec -- supabase functions deploy log-event
npm exec -- supabase functions deploy list-alerts
npm exec -- supabase functions deploy assemblyai-token
npm exec -- supabase functions deploy risk-event
```

Hosted Supabase supplies `SUPABASE_URL` and the current `SUPABASE_SECRET_KEYS` JSON map. The runtime
reads its `default` key and also supports the legacy `SUPABASE_SERVICE_ROLE_KEY` used by local or
older projects. The local CLI injects its own `SUPABASE_*` values and skips attempts to override
them in `functions/.env`. Never put a server key, the LiveKit API secret, the Anthropic key, or the
AssemblyAI key in `web/` or `docs/CONTRACT.md`.

Local function serving additionally needs Docker and the Supabase CLI:

```bash
npm ci
cp functions/.env.example functions/.env
chmod 600 functions/.env
npm exec -- supabase start
npm exec -- supabase functions serve --env-file functions/.env
```

The CLI is pinned in `package.json`; run it through `npm exec --` so every collaborator uses the same
version. `.env`, `.env.deploy`, `.branches`, and `.temp` are local-only and must not be committed.

Run the Web client in a second terminal:

```bash
cd ../web
npm ci
npm run dev -- --host 127.0.0.1
```

Readiness checks should all return HTTP 200 before opening the Mac app. The `list-alerts` probe is
side-effect-free and confirms that an Edge Function can reach the local database, not only that Kong
is listening. The extracted anonymous key is a public client value:

```bash
SECOND_SIGHT_ANON_KEY="$(npm exec -- supabase status --output json | \
  python3 -c 'import json,sys; print(json.load(sys.stdin)["ANON_KEY"])')"
curl --fail --output /dev/null http://127.0.0.1:54321/rest/v1/
curl --fail --output /dev/null http://127.0.0.1:54321/functions/v1/list-alerts \
  -H "Authorization: Bearer $SECOND_SIGHT_ANON_KEY" \
  -H "apikey: $SECOND_SIGHT_ANON_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"session_id":"00000000-0000-0000-0000-000000000000"}'
curl --fail --output /dev/null http://127.0.0.1:7880/
curl --fail --output /dev/null http://127.0.0.1:5173/
```

These checks plus the automated tests prove only local process, API, and rule-engine readiness. Mark
the realtime safety path `live_pass` only after a real volunteer microphone produces an AssemblyAI
partial transcript, the Mac shows the warning, and the Web client receives the risk card. Otherwise
record it as `blocked` or `not_tested`; a running process is not evidence of the full network path.

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
