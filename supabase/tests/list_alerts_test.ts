import { strict as assert } from 'node:assert'
import { handleEdgeRequest } from '../functions/_shared/handler.ts'
import { makeTestDependencies } from './test_dependencies.ts'

Deno.test('list-alerts returns one session alert history newest first', async () => {
  const requestedSessions: string[] = []
  const expected = [
    {
      id: 12,
      ts: '2026-08-29T06:30:00.000Z',
      severity: 'freeze' as const,
      transcript: '把验证码念给我',
      reason: '索要短信验证码',
    },
    {
      id: 11,
      ts: '2026-08-29T06:29:00.000Z',
      severity: 'warn' as const,
      transcript: '请安装这个软件',
      reason: '诱导安装软件',
    },
  ]
  const deps = makeTestDependencies({
    alerts: {
      async list(sessionId) {
        requestedSessions.push(sessionId)
        return expected
      },
    },
  })

  const response = await handleEdgeRequest(
    'list-alerts',
    new Request('http://localhost/list-alerts', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ session_id: '4cd3c7be-a8e8-4aaf-a4ec-89edcd338f32' }),
    }),
    deps,
  )

  assert.equal(response.status, 200)
  assert.deepEqual(await response.json(), { alerts: expected })
  assert.deepEqual(requestedSessions, ['4cd3c7be-a8e8-4aaf-a4ec-89edcd338f32'])
})
