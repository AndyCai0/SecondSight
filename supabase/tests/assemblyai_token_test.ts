import { strict as assert } from 'node:assert'
import { handleEdgeRequest } from '../functions/_shared/handler.ts'
import { makeTestDependencies } from './test_dependencies.ts'

Deno.test('assemblyai-token returns a short-lived server-issued credential for an active session', async () => {
  const requested: Array<Record<string, number>> = []
  const deps = makeTestDependencies({
    elderCredentials: {
      async verify(token) {
        assert.equal(token, 'elder-session-token')
        return { identity: 'elder', room: '482913' }
      },
    },
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
      headers: {
        'content-type': 'application/json',
        'x-secondsight-elder-token': 'elder-session-token',
      },
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
      elderCredentials: {
        async verify() {
          return { identity: 'elder', room: '482913' }
        },
      },
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
        headers: { 'x-secondsight-elder-token': 'elder-session-token' },
        body: JSON.stringify({ session_id: 'session-1' }),
      }),
      deps,
    )
    assert.equal(response.status, expectedStatus)
  }
})

Deno.test('assemblyai-token requires the elder credential for the matching room', async () => {
  let requestedCredential = false
  const baseDependencies = {
    sessions: {
      async findById(sessionId: string) {
        return { id: sessionId, code: '482913', status: 'active' as const }
      },
    },
    assemblyAI: {
      async createStreamingToken() {
        requestedCredential = true
        return { token: 'must-not-be-issued', expiresInSeconds: 60 }
      },
    },
  }

  const missing = await handleEdgeRequest(
    'assemblyai-token',
    new Request('http://localhost/assemblyai-token', {
      method: 'POST',
      body: JSON.stringify({ session_id: 'session-1' }),
    }),
    makeTestDependencies(baseDependencies),
  )
  assert.equal(missing.status, 401)

  const volunteer = await handleEdgeRequest(
    'assemblyai-token',
    new Request('http://localhost/assemblyai-token', {
      method: 'POST',
      headers: { 'x-secondsight-elder-token': 'volunteer-token' },
      body: JSON.stringify({ session_id: 'session-1' }),
    }),
    makeTestDependencies({
      ...baseDependencies,
      elderCredentials: {
        async verify() {
          return { identity: 'volunteer:helper', room: '482913' }
        },
      },
    }),
  )
  assert.equal(volunteer.status, 403)

  const wrongRoom = await handleEdgeRequest(
    'assemblyai-token',
    new Request('http://localhost/assemblyai-token', {
      method: 'POST',
      headers: { 'x-secondsight-elder-token': 'wrong-room-token' },
      body: JSON.stringify({ session_id: 'session-1' }),
    }),
    makeTestDependencies({
      ...baseDependencies,
      elderCredentials: {
        async verify() {
          return { identity: 'elder', room: '000000' }
        },
      },
    }),
  )
  assert.equal(wrongRoom.status, 403)
  assert.equal(requestedCredential, false)
})
