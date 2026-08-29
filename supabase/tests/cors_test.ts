import { strict as assert } from 'node:assert'
import { handleEdgeRequest } from '../functions/_shared/handler.ts'
import { makeTestDependencies } from './test_dependencies.ts'

Deno.test('all Edge Functions answer browser preflight without invoking dependencies', async () => {
  const deps = makeTestDependencies()

  const response = await handleEdgeRequest(
    'join-session',
    new Request('http://localhost/join-session', { method: 'OPTIONS' }),
    deps,
  )

  assert.equal(response.status, 204)
  assert.equal(response.headers.get('access-control-allow-origin'), '*')
  assert.equal(response.headers.get('access-control-allow-methods'), 'POST, OPTIONS')
  assert.match(response.headers.get('access-control-allow-headers') ?? '', /authorization/i)
})
