import { strict as assert } from 'node:assert'
import { runFunction } from '../functions/_shared/runtime.ts'

Deno.test('runtime sanitizes unexpected failures and preserves browser CORS', async () => {
  const reported: unknown[] = []
  const response = await runFunction(
    'create-session',
    new Request('http://localhost/create-session', { method: 'POST', body: '{}' }),
    () => {
      throw new Error('database details must not reach clients')
    },
    (error) => reported.push(error),
  )

  assert.equal(response.status, 500)
  assert.equal(response.headers.get('access-control-allow-origin'), '*')
  assert.deepEqual(await response.json(), { error: 'Internal server error' })
  assert.equal(reported.length, 1)
})

Deno.test('runtime answers browser preflight before loading secrets', async () => {
  const response = await runFunction(
    'join-session',
    new Request('http://localhost/join-session', { method: 'OPTIONS' }),
    () => {
      throw new Error('secrets should not load for preflight')
    },
    () => {
      throw new Error('preflight should not be reported as a runtime failure')
    },
  )

  assert.equal(response.status, 204)
  assert.equal(response.headers.get('access-control-allow-origin'), '*')
})
