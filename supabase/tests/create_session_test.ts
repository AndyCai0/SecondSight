import { strict as assert } from 'node:assert'
import { handleEdgeRequest, SessionCodeConflictError } from '../functions/_shared/handler.ts'
import { makeTestDependencies } from './test_dependencies.ts'

Deno.test('create-session returns the contract response and elder room grant', async () => {
  const grants: Array<Record<string, unknown>> = []
  const deps = makeTestDependencies({
    sessions: {
      async create(code) {
        return { id: 'session-1', code, status: 'waiting' }
      },
    },
    tokens: {
      async sign(grant) {
        grants.push(grant as unknown as Record<string, unknown>)
        return 'elder-jwt'
      },
    },
    makeCode: () => '482913',
  })

  const response = await handleEdgeRequest(
    'create-session',
    new Request('http://localhost/create-session', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: '{}',
    }),
    deps,
  )

  assert.equal(response.status, 200)
  assert.deepEqual(await response.json(), {
    session_id: 'session-1',
    code: '482913',
    lk_url: 'wss://demo.livekit.cloud',
    lk_token: 'elder-jwt',
  })
  assert.deepEqual(grants, [
    {
      identity: 'elder',
      room: '482913',
      canPublish: true,
      canSubscribe: true,
      canPublishSources: undefined,
    },
  ])
})

Deno.test('create-session retries a colliding six-digit code', async () => {
  const codes = ['111111', '482913']
  const attempted: string[] = []
  const deps = makeTestDependencies({
    sessions: {
      async create(code: string) {
        attempted.push(code)
        if (code === '111111') throw new SessionCodeConflictError()
        return { id: 'session-2', code, status: 'waiting' as const }
      },
    },
    tokens: {
      async sign() {
        return 'elder-jwt'
      },
    },
    makeCode: () => codes.shift() ?? '999999',
  })

  const response = await handleEdgeRequest(
    'create-session',
    new Request('http://localhost/create-session', { method: 'POST', body: '{}' }),
    deps,
  )

  assert.equal(response.status, 200)
  assert.deepEqual(attempted, ['111111', '482913'])
  assert.equal((await response.json()).code, '482913')
})
