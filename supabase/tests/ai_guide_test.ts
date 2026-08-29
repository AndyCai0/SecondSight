import { strict as assert } from 'node:assert'
import { handleEdgeRequest } from '../functions/_shared/handler.ts'
import { makeTestDependencies } from './test_dependencies.ts'

Deno.test('ai-guide returns one normalized instruction and records the audit event', async () => {
  const events: Array<Record<string, unknown>> = []
  const deps = makeTestDependencies({
    events: {
      async insert(input) {
        events.push(input)
      },
    },
    ai: {
      async guide(input) {
        assert.deepEqual(input, {
          task: '我想查 Medicare',
          screenshotBase64: 'jpeg-data',
          axSummary: '{"role":"button"}',
        })
        return {
          instructionText: '请点击右上角的登录按钮',
          targetRect: { x: 0.82, y: 0.05, w: 0.12, h: 0.04 },
          confidence: 0.9,
        }
      },
    },
  })

  const response = await handleEdgeRequest(
    'ai-guide',
    new Request('http://localhost/ai-guide', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        session_id: 'session-1',
        task: '我想查 Medicare',
        screenshot_base64: 'jpeg-data',
        ax_summary: '{"role":"button"}',
      }),
    }),
    deps,
  )

  assert.equal(response.status, 200)
  assert.deepEqual(await response.json(), {
    instruction_text: '请点击右上角的登录按钮',
    target_rect: { x: 0.82, y: 0.05, w: 0.12, h: 0.04 },
    confidence: 0.9,
  })
  assert.deepEqual(events, [
    {
      sessionId: 'session-1',
      actor: 'ai_guide',
      kind: 'ai.instruction',
      payload: {
        instruction_text: '请点击右上角的登录按钮',
        target_rect: { x: 0.82, y: 0.05, w: 0.12, h: 0.04 },
        confidence: 0.9,
      },
    },
  ])
})
