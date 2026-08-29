import { strict as assert } from 'node:assert'
import { handleEdgeRequest } from '../functions/_shared/handler.ts'
import { makeTestDependencies } from './test_dependencies.ts'

const sessionId = '9d1d5434-6da5-41e0-af70-c5aa35c6816f'
const assistantId = '5f028bd8-9602-40ed-8c39-e35c6bca1a21'
const now = new Date('2026-08-29T10:00:00.000Z')

Deno.test('broadcast-session registers a waiting request and counts live assistants', async () => {
  const updates: unknown[] = []
  const cutoffs: string[] = []
  const deps = makeTestDependencies({
    broadcasts: {
      async setActive(id, isActive, startedAt) {
        updates.push({ id, isActive, startedAt })
        return true
      },
    },
    assistants: {
      async countSince(cutoff) {
        cutoffs.push(cutoff)
        return 4
      },
    },
    now: () => now,
  })

  const response = await handleEdgeRequest(
    'broadcast-session',
    post({ session_id: sessionId, is_active: true }),
    deps,
  )

  assert.equal(response.status, 200)
  assert.deepEqual(await response.json(), { ok: true, notified_assistants: 4 })
  assert.deepEqual(updates, [{ id: sessionId, isActive: true, startedAt: now.toISOString() }])
  assert.deepEqual(cutoffs, ['2026-08-29T09:59:57.000Z'])
})

Deno.test('assistant-poll refreshes presence and returns only backend-filtered broadcasts', async () => {
  const touches: unknown[] = []
  const expected = [{
    sessionId,
    requestedAt: '2026-08-29T09:59:58.000Z',
    elderLabel: '李奶奶',
  }]
  const deps = makeTestDependencies({
    assistants: {
      async touch(input) {
        touches.push(input)
      },
    },
    broadcasts: {
      async listActive(cutoff) {
        assert.equal(cutoff, '2026-08-29T09:45:00.000Z')
        return expected
      },
    },
    now: () => now,
  })

  const response = await handleEdgeRequest(
    'assistant-poll',
    post({ assistant_id: assistantId, name: '待命助手' }),
    deps,
  )

  assert.equal(response.status, 200)
  assert.deepEqual(await response.json(), {
    broadcasts: [{
      session_id: sessionId,
      requested_at: '2026-08-29T09:59:58.000Z',
      elder_label: '李奶奶',
    }],
  })
  assert.deepEqual(touches, [{
    id: assistantId,
    displayName: '待命助手',
    seenAt: now.toISOString(),
  }])
})

Deno.test('claim-broadcast conditionally claims once and returns a camera-and-microphone token', async () => {
  const claims: unknown[] = []
  const grants: unknown[] = []
  const deps = makeTestDependencies({
    assistants: {
      async touch() {},
    },
    broadcasts: {
      async findClaimable(id, cutoff) {
        assert.equal(id, sessionId)
        assert.equal(cutoff, '2026-08-29T09:45:00.000Z')
        return { id: sessionId, code: '482913', status: 'waiting' }
      },
      async claim(id, volunteerName, cutoff) {
        claims.push({ id, volunteerName, cutoff })
        return true
      },
    },
    tokens: {
      async sign(grant) {
        grants.push(grant)
        return 'volunteer-jwt'
      },
    },
    now: () => now,
  })

  const response = await handleEdgeRequest(
    'claim-broadcast',
    post({ session_id: sessionId, assistant_id: assistantId, name: ' 小王 ' }),
    deps,
  )

  assert.equal(response.status, 200)
  assert.deepEqual(await response.json(), {
    session_id: sessionId,
    lk_url: 'wss://demo.livekit.cloud',
    lk_token: 'volunteer-jwt',
  })
  assert.deepEqual(claims, [{
    id: sessionId,
    volunteerName: '小王',
    cutoff: '2026-08-29T09:45:00.000Z',
  }])
  assert.deepEqual(grants, [{
    identity: 'volunteer:小王',
    room: '482913',
    canPublish: true,
    canSubscribe: true,
    canPublishSources: ['microphone', 'camera'],
  }])
})

Deno.test('claim-broadcast race loser never receives the signed token', async () => {
  const deps = makeTestDependencies({
    assistants: {
      async touch() {},
    },
    broadcasts: {
      async findClaimable() {
        return { id: sessionId, code: '482913', status: 'waiting' }
      },
      async claim() {
        return false
      },
    },
    tokens: {
      async sign() {
        return 'unused-race-loser-token'
      },
    },
  })

  const response = await handleEdgeRequest(
    'claim-broadcast',
    post({ session_id: sessionId, assistant_id: assistantId, name: '小王' }),
    deps,
  )

  assert.equal(response.status, 409)
  assert.deepEqual(await response.json(), {
    error: 'Broadcast has already been claimed or expired',
  })
})

function post(body: unknown): Request {
  return new Request('http://localhost/function', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  })
}
