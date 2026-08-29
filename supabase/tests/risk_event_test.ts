import { strict as assert } from 'node:assert'
import { handleEdgeRequest } from '../functions/_shared/handler.ts'
import { makeTestDependencies } from './test_dependencies.ts'

Deno.test('risk-event validates and stores the minimum deduplicated risk evidence', async () => {
  const events: Array<Record<string, unknown>> = []
  const deps = makeTestDependencies({
    sessions: {
      async findById(sessionId) {
        return { id: sessionId, code: '482913', status: 'active' }
      },
    },
    events: {
      async insert(input) {
        events.push(input)
      },
    },
  })
  const response = await handleEdgeRequest(
    'risk-event',
    new Request('http://localhost/risk-event', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        session_id: 'session-1',
        timestamp: '2026-08-29T07:30:00.000Z',
        level: 'danger',
        transcript: 'Please tell me the verification code you just received.',
        matched_rules: ['verification_code', 'request_sensitive_information'],
      }),
    }),
    deps,
  )

  assert.equal(response.status, 200)
  assert.deepEqual(await response.json(), {
    ok: true,
    fingerprint: 'danger:request_sensitive_information:verification_code',
  })
  assert.deepEqual(events, [{
    sessionId: 'session-1',
    actor: 'safety_monitor',
    kind: 'safety.risk',
    payload: {
      timestamp: '2026-08-29T07:30:00.000Z',
      level: 'danger',
      transcript: 'Please tell me the verification code you just received.',
      matched_rules: ['request_sensitive_information', 'verification_code'],
      fingerprint: 'danger:request_sensitive_information:verification_code',
    },
  }])
})

Deno.test('risk-event rejects safe, malformed, and unknown-session payloads', async () => {
  const valid = {
    session_id: 'session-1',
    timestamp: '2026-08-29T07:30:00.000Z',
    level: 'warning',
    transcript: 'A verification code was mentioned.',
    matched_rules: ['verification_code'],
  }
  const cases: Array<[Record<string, unknown>, number]> = [
    [{ ...valid, level: 'safe' }, 400],
    [{ ...valid, timestamp: 'not-a-date' }, 400],
    [{ ...valid, matched_rules: [] }, 400],
    [{ ...valid, matched_rules: ['bad rule'] }, 400],
  ]

  for (const [body, expectedStatus] of cases) {
    const response = await handleEdgeRequest(
      'risk-event',
      new Request('http://localhost/risk-event', { method: 'POST', body: JSON.stringify(body) }),
      makeTestDependencies(),
    )
    assert.equal(response.status, expectedStatus)
  }

  const response = await handleEdgeRequest(
    'risk-event',
    new Request('http://localhost/risk-event', { method: 'POST', body: JSON.stringify(valid) }),
    makeTestDependencies({
      sessions: {
        async findById() {
          return null
        },
      },
    }),
  )
  assert.equal(response.status, 404)
})
