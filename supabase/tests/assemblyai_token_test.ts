import { strict as assert } from 'node:assert'
import { handleEdgeRequest } from '../functions/_shared/handler.ts'
import { makeTestDependencies } from './test_dependencies.ts'

Deno.test('assemblyai-token returns a short-lived server-issued credential for an active session', async () => {
  const requested: Array<Record<string, number>> = []
  const deps = makeTestDependencies({
    sessions: {
      async findById(sessionId) {
        assert.equal(sessionId, 'session-1')
        return { id: sessionId, code: '482913', status: 'active' }
      },
    },
    assemblyAI: {
      async createStreamingToken(input) {
        requested.push(input)
        return { token: 'temporary-streaming-token', expiresInSeconds: 60 }
      },
    },
  })

  const response = await handleEdgeRequest(
    'assemblyai-token',
    new Request('http://localhost/assemblyai-token', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ session_id: 'session-1' }),
    }),
    deps,
  )

  assert.equal(response.status, 200)
  assert.deepEqual(await response.json(), {
    token: 'temporary-streaming-token',
    expires_in_seconds: 60,
    max_session_duration_seconds: 3_600,
  })
  assert.deepEqual(requested, [{ expiresInSeconds: 60, maxSessionDurationSeconds: 3_600 }])
})

Deno.test('assemblyai-token rejects missing and ended sessions before requesting a credential', async () => {
  for (
    const [session, expectedStatus] of [[null, 404], [
      { id: 'session-1', code: '482913', status: 'ended' as const },
      410,
    ]] as const
  ) {
    const deps = makeTestDependencies({
      sessions: {
        async findById() {
          return session
        },
      },
    })
    const response = await handleEdgeRequest(
      'assemblyai-token',
      new Request('http://localhost/assemblyai-token', {
        method: 'POST',
        body: JSON.stringify({ session_id: 'session-1' }),
      }),
      deps,
    )
    assert.equal(response.status, expectedStatus)
  }
})
