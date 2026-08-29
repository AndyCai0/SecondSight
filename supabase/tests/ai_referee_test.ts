import { strict as assert } from 'node:assert'
import { handleEdgeRequest } from '../functions/_shared/handler.ts'
import { makeTestDependencies } from './test_dependencies.ts'

Deno.test('ai-referee freezes a dangerous session and writes an alert', async () => {
  const frozen: string[] = []
  const alerts: Array<Record<string, unknown>> = []
  const deps = makeTestDependencies({
    sessions: {
      async freeze(sessionId) {
        frozen.push(sessionId)
      },
    },
    alerts: {
      async insert(input) {
        alerts.push(input)
      },
    },
    ai: {
      async referee(transcript) {
        assert.equal(transcript, '把验证码念给我')
        return { verdict: 'freeze', reason: '索要短信验证码' }
      },
    },
  })

  const response = await handleEdgeRequest(
    'ai-referee',
    new Request('http://localhost/ai-referee', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ session_id: 'session-1', transcript: '把验证码念给我' }),
    }),
    deps,
  )

  assert.equal(response.status, 200)
  assert.deepEqual(await response.json(), {
    verdict: 'freeze',
    reason: '索要短信验证码',
  })
  assert.deepEqual(frozen, ['session-1'])
  assert.deepEqual(alerts, [
    {
      sessionId: 'session-1',
      severity: 'freeze',
      transcript: '把验证码念给我',
      reason: '索要短信验证码',
    },
  ])
})
