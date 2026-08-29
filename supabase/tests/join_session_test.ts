import { strict as assert } from 'node:assert'
import { handleEdgeRequest } from '../functions/_shared/handler.ts'
import { makeTestDependencies } from './test_dependencies.ts'

Deno.test('join-session activates the session and restricts publishing to microphone', async () => {
  const activations: Array<[string, string]> = []
  const grants: Array<Record<string, unknown>> = []
  const deps = makeTestDependencies({
    sessions: {
      async findByCode(code) {
        assert.equal(code, '482913')
        return { id: 'session-1', code, status: 'waiting' }
      },
      async activate(sessionId, volunteerName) {
        activations.push([sessionId, volunteerName])
        return true
      },
    },
    tokens: {
      async sign(grant) {
        grants.push(grant as unknown as Record<string, unknown>)
        return 'volunteer-jwt'
      },
    },
  })

  const response = await handleEdgeRequest(
    'join-session',
    new Request('http://localhost/join-session', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ code: '482913', name: ' 小王 ' }),
    }),
    deps,
  )

  assert.equal(response.status, 200)
  assert.deepEqual(await response.json(), {
    session_id: 'session-1',
    lk_url: 'wss://demo.livekit.cloud',
    lk_token: 'volunteer-jwt',
  })
  assert.deepEqual(activations, [['session-1', '小王']])
  assert.deepEqual(grants, [
    {
      identity: 'volunteer:小王',
      room: '482913',
      canPublish: true,
      canSubscribe: true,
      canPublishSources: ['microphone'],
    },
  ])
})

Deno.test('join-session cannot reactivate an AI-frozen session', async () => {
  let activated = false
  const deps = makeTestDependencies({
    sessions: {
      async findByCode(code) {
        return { id: 'session-1', code, status: 'frozen' }
      },
      async activate() {
        activated = true
        return true
      },
    },
  })

  const response = await handleEdgeRequest(
    'join-session',
    new Request('http://localhost/join-session', {
      method: 'POST',
      body: JSON.stringify({ code: '482913', name: '小王' }),
    }),
    deps,
  )

  assert.equal(response.status, 423)
  assert.equal(activated, false)
})

Deno.test('join-session does not issue a token when a concurrent freeze wins', async () => {
  const deps = makeTestDependencies({
    sessions: {
      async findByCode(code) {
        return { id: 'session-1', code, status: 'waiting' }
      },
      async activate() {
        return false
      },
    },
  })

  const response = await handleEdgeRequest(
    'join-session',
    new Request('http://localhost/join-session', {
      method: 'POST',
      body: JSON.stringify({ code: '482913', name: '小王' }),
    }),
    deps,
  )

  assert.equal(response.status, 423)
})
