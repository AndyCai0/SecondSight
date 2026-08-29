import { strict as assert } from 'node:assert'
import { handleEdgeRequest } from '../functions/_shared/handler.ts'
import { makeTestDependencies } from './test_dependencies.ts'

Deno.test('log-event accepts the contract payload and acknowledges the write', async () => {
  const events: Array<Record<string, unknown>> = []
  const deps = makeTestDependencies({
    events: {
      async insert(input) {
        events.push(input)
      },
    },
  })

  const response = await handleEdgeRequest(
    'log-event',
    new Request('http://localhost/log-event', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        session_id: 'session-1',
        actor: 'volunteer',
        kind: 'annotate.circle',
        payload: { id: 'a1', x: 0.42, y: 0.31 },
      }),
    }),
    deps,
  )

  assert.equal(response.status, 200)
  assert.deepEqual(await response.json(), { ok: true })
  assert.deepEqual(events, [
    {
      sessionId: 'session-1',
      actor: 'volunteer',
      kind: 'annotate.circle',
      payload: { id: 'a1', x: 0.42, y: 0.31 },
    },
  ])
})
