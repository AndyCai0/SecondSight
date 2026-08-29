import { strict as assert } from 'node:assert'

Deno.test('all deployable Edge Function modules export a fetch handler', async () => {
  const modules = await Promise.all([
    import('../functions/create-session/index.ts'),
    import('../functions/join-session/index.ts'),
    import('../functions/ai-guide/index.ts'),
    import('../functions/ai-referee/index.ts'),
    import('../functions/list-alerts/index.ts'),
    import('../functions/log-event/index.ts'),
    import('../functions/assemblyai-token/index.ts'),
    import('../functions/risk-event/index.ts'),
  ])

  for (const module of modules) {
    assert.equal(typeof module.default.fetch, 'function')
  }
})
