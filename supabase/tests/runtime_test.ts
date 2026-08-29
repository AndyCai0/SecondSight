import { strict as assert } from 'node:assert'
import { AIUnavailableError, ServerOperationError } from '../functions/_shared/handler.ts'
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

Deno.test('runtime exposes only the safe stage code for operational failures', async () => {
  const reported: unknown[] = []
  const response = await runFunction(
    'create-session',
    new Request('http://localhost/create-session', { method: 'POST', body: '{}' }),
    () => {
      throw new ServerOperationError('SERVER_CONFIGURATION_ERROR')
    },
    (error) => reported.push(error),
  )

  assert.equal(response.status, 500)
  assert.deepEqual(await response.json(), {
    error: 'Internal server error',
    code: 'SERVER_CONFIGURATION_ERROR',
  })
  assert.equal(reported.length, 1)
})

Deno.test('runtime may expose a sanitized provider code without provider details', async () => {
  const response = await runFunction(
    'create-session',
    new Request('http://localhost/create-session', { method: 'POST', body: '{}' }),
    () => {
      throw new ServerOperationError('SERVER_DATABASE_ERROR', 'PGRST301')
    },
    () => {},
  )

  assert.deepEqual(await response.json(), {
    error: 'Internal server error',
    code: 'SERVER_DATABASE_ERROR',
    provider_code: 'PGRST301',
  })
})

Deno.test('runtime reports disabled AI without turning it into a server error', async () => {
  let reported = false
  const response = await runFunction(
    'ai-guide',
    new Request('http://localhost/ai-guide', { method: 'POST', body: '{}' }),
    () => {
      throw new AIUnavailableError()
    },
    () => {
      reported = true
    },
  )

  assert.equal(response.status, 503)
  assert.equal(response.headers.get('access-control-allow-origin'), '*')
  assert.deepEqual(await response.json(), { error: 'AI features are not enabled' })
  assert.equal(reported, false)
})
