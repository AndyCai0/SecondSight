import { strict as assert } from 'node:assert'
import {
  collectAllAlerts,
  createAnthropicClient,
  createAssemblyAIClient,
  createProductionDependencies,
  createSupabaseServiceFetcher,
  readProductionConfig,
} from '../functions/_shared/dependencies.ts'
import { ServerOperationError } from '../functions/_shared/handler.ts'

Deno.test('production config reads LiveKit settings without requiring AI configuration', () => {
  const values: Record<string, string> = {
    SUPABASE_URL: 'https://project.supabase.co',
    SUPABASE_SECRET_KEYS: JSON.stringify({ default: 'sb_secret_example' }),
    LIVEKIT_API_KEY: 'lk-key',
    LIVEKIT_API_SECRET: 'lk-secret',
    LIVEKIT_URL: 'wss://project.livekit.cloud',
  }

  assert.deepEqual(readProductionConfig((name) => values[name]), {
    supabaseUrl: values.SUPABASE_URL,
    supabaseServiceKey: 'sb_secret_example',
    supabaseDbUrl: undefined,
    liveKitApiKey: values.LIVEKIT_API_KEY,
    liveKitApiSecret: values.LIVEKIT_API_SECRET,
    liveKitUrl: values.LIVEKIT_URL,
    anthropicApiKey: undefined,
    assemblyAIApiKey: undefined,
  })
})

Deno.test('hosted config prefers the service-role JWT for supabase-js RLS bypass', () => {
  const values: Record<string, string> = {
    SUPABASE_URL: 'https://project.supabase.co',
    SUPABASE_SERVICE_ROLE_KEY: 'legacy-service-role-jwt',
    SUPABASE_SECRET_KEYS: JSON.stringify({ default: 'sb_secret_example' }),
    LIVEKIT_API_KEY: 'lk-key',
    LIVEKIT_API_SECRET: 'lk-secret',
    LIVEKIT_URL: 'wss://project.livekit.cloud',
  }

  assert.equal(
    readProductionConfig((name) => values[name]).supabaseServiceKey,
    values.SUPABASE_SERVICE_ROLE_KEY,
  )
})

Deno.test('production config does not expose missing secret names', () => {
  assert.throws(
    () => readProductionConfig(() => undefined),
    (error) =>
      error instanceof ServerOperationError &&
      error.code === 'SERVER_CONFIGURATION_ERROR' &&
      !error.message.includes('LIVEKIT'),
  )
})

Deno.test('AI key is ignored unless the feature is explicitly enabled', () => {
  const values: Record<string, string> = {
    SUPABASE_URL: 'https://project.supabase.co',
    SUPABASE_SECRET_KEYS: JSON.stringify({ default: 'sb_secret_example' }),
    LIVEKIT_API_KEY: 'lk-key',
    LIVEKIT_API_SECRET: 'lk-secret',
    LIVEKIT_URL: 'wss://project.livekit.cloud',
    ANTHROPIC_API_KEY: 'must-not-be-used',
  }

  assert.equal(readProductionConfig((name) => values[name]).anthropicApiKey, undefined)
  values.AI_ENABLED = 'true'
  assert.equal(
    readProductionConfig((name) => values[name]).anthropicApiKey,
    values.ANTHROPIC_API_KEY,
  )
})

Deno.test('opaque Supabase secret keys are sent only in apikey, not Authorization', async () => {
  const observedHeaders: Headers[] = []
  const serviceKey = 'sb_secret_server_only'
  const fetcher = createSupabaseServiceFetcher(serviceKey, async (_input, init) => {
    observedHeaders.push(new Headers(init?.headers))
    return Response.json({ ok: true })
  })

  await fetcher('https://project.supabase.co/rest/v1/sessions', {
    headers: {
      apikey: serviceKey,
      authorization: `Bearer ${serviceKey}`,
    },
  })

  assert.equal(observedHeaders[0].get('apikey'), serviceKey)
  assert.equal(observedHeaders[0].get('authorization'), null)
})

Deno.test('legacy service-role JWT keeps its Authorization header', async () => {
  const observedHeaders: Headers[] = []
  const legacyKey = 'legacy-service-role-jwt'
  const fetcher = createSupabaseServiceFetcher(legacyKey, async (_input, init) => {
    observedHeaders.push(new Headers(init?.headers))
    return Response.json({ ok: true })
  })

  await fetcher('https://project.supabase.co/rest/v1/sessions', {
    headers: { authorization: `Bearer ${legacyKey}` },
  })

  assert.equal(observedHeaders[0].get('authorization'), `Bearer ${legacyKey}`)
})

Deno.test('AssemblyAI adapter requests a bounded temporary streaming token server-side', async () => {
  let capturedURL = ''
  let capturedAuthorization = ''
  const client = createAssemblyAIClient('server-only-key', async (input, init) => {
    capturedURL = String(input)
    capturedAuthorization = new Headers(init?.headers).get('authorization') ?? ''
    return Response.json({ token: 'temporary-token', expires_in_seconds: 60 })
  })

  const credential = await client.createStreamingToken({
    expiresInSeconds: 60,
    maxSessionDurationSeconds: 3_600,
  })

  assert.equal(
    capturedURL,
    'https://streaming.assemblyai.com/v3/token?expires_in_seconds=60&max_session_duration_seconds=3600',
  )
  assert.equal(capturedAuthorization, 'server-only-key')
  assert.deepEqual(credential, { token: 'temporary-token', expiresInSeconds: 60 })
})

Deno.test('Anthropic adapter uses the contract models and validates JSON output', async () => {
  const bodies: Array<Record<string, unknown>> = []
  const responses = [
    {
      content: [{
        type: 'text',
        text:
          '{"instruction_text":"请点击登录按钮","target_rect":{"x":0.8,"y":0.1,"w":0.1,"h":0.05},"confidence":0.9}',
      }],
    },
    {
      content: [{
        type: 'text',
        text: '{"verdict":"freeze","reason":"索要短信验证码"}',
      }],
    },
  ]
  const client = createAnthropicClient('test-key', async (_url, init) => {
    bodies.push(JSON.parse(String(init?.body)))
    return Response.json(responses.shift())
  })

  const guide = await client.guide({
    task: '登录',
    screenshotBase64: 'abc123',
    axSummary: '{"role":"button"}',
  })
  const referee = await client.referee('把验证码告诉我')

  assert.equal(bodies[0].model, 'claude-sonnet-5')
  assert.equal(bodies[1].model, 'claude-haiku-4-5-20251001')
  assert.deepEqual(guide.targetRect, { x: 0.8, y: 0.1, w: 0.1, h: 0.05 })
  assert.deepEqual(referee, { verdict: 'freeze', reason: '索要短信验证码' })
})

Deno.test('production LiveKit token lets volunteers publish only microphone and camera', async () => {
  const dependencies = createProductionDependencies({
    supabaseUrl: 'https://project.supabase.co',
    supabaseServiceKey: 'server-key-used-only-by-the-test',
    liveKitApiKey: 'api-key',
    liveKitApiSecret: 'a-secret-long-enough-for-hmac-signing-1234567890',
    liveKitUrl: 'wss://project.livekit.cloud',
  })

  const token = await dependencies.tokens.sign({
    identity: 'volunteer:小王',
    room: '482913',
    canPublish: true,
    canSubscribe: true,
    canPublishSources: ['microphone', 'camera'],
  })
  const payload = JSON.parse(decodeBase64Url(token.split('.')[1]))

  assert.equal(payload.sub, 'volunteer:小王')
  assert.equal(payload.video.room, '482913')
  assert.deepEqual(payload.video.canPublishSources, ['microphone', 'camera'])

  const elderToken = await dependencies.tokens.sign({
    identity: 'elder',
    room: '482913',
    canPublish: true,
    canSubscribe: true,
  })
  assert.deepEqual(await dependencies.elderCredentials.verify(elderToken), {
    identity: 'elder',
    room: '482913',
  })
  await assert.rejects(() => dependencies.elderCredentials.verify('not-a-valid-jwt'))
})

Deno.test('AI calls are unavailable without blocking non-AI dependencies', async () => {
  const dependencies = createProductionDependencies({
    supabaseUrl: 'https://project.supabase.co',
    supabaseServiceKey: 'server-key-used-only-by-the-test',
    liveKitApiKey: 'api-key',
    liveKitApiSecret: 'a-secret-long-enough-for-hmac-signing-1234567890',
    liveKitUrl: 'wss://project.livekit.cloud',
  })

  const token = await dependencies.tokens.sign({
    identity: 'elder',
    room: '482913',
    canPublish: true,
    canSubscribe: true,
  })
  assert.equal(token.split('.').length, 3)
  await assert.rejects(
    () => dependencies.ai.referee('测试文本'),
    { name: 'AIUnavailableError', message: 'AI features are not enabled' },
  )
})

Deno.test('alert history pagination returns every record without a silent cap', async () => {
  const ranges: Array<[number, number]> = []
  const firstPage = Array.from({ length: 1_000 }, (_, index) => ({
    id: index + 1,
    ts: `2026-08-29T06:${String(index % 60).padStart(2, '0')}:00.000Z`,
    severity: 'warn' as const,
    transcript: `transcript-${index + 1}`,
    reason: `reason-${index + 1}`,
  }))
  const finalRecord = {
    id: 1_001,
    ts: '2026-08-29T05:00:00.000Z',
    severity: 'freeze' as const,
    transcript: 'final transcript',
    reason: 'final reason',
  }

  const alerts = await collectAllAlerts(async (from, to) => {
    ranges.push([from, to])
    return { data: from === 0 ? firstPage : [finalRecord], error: null }
  })

  assert.equal(alerts.length, 1_001)
  assert.deepEqual(alerts.at(-1), finalRecord)
  assert.deepEqual(ranges, [[0, 999], [1_000, 1_999]])
})

function decodeBase64Url(value: string): string {
  const normalized = value.replaceAll('-', '+').replaceAll('_', '/')
  return new TextDecoder().decode(Uint8Array.from(atob(normalized), (char) => char.charCodeAt(0)))
}
