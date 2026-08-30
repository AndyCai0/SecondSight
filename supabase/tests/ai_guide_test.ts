import { strict as assert } from 'node:assert'
import { handleEdgeRequest } from '../functions/_shared/handler.ts'
import { makeTestDependencies } from './test_dependencies.ts'

const sessionId = '9d1d5434-6da5-41e0-af70-c5aa35c6816f'

Deno.test('ai-guide returns one normalized instruction and records the audit event', async () => {
  const events: Array<Record<string, unknown>> = []
  const deps = makeTestDependencies({
    sessions: {
      async findById(id) {
        assert.equal(id, sessionId)
        return { id, code: '482913', status: 'active' }
      },
    },
    elderCredentials: {
      async verify(token) {
        assert.equal(token, 'elder-jwt')
        return { identity: 'elder', room: '482913' }
      },
    },
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
      headers: {
        'content-type': 'application/json',
        'x-secondsight-elder-token': 'elder-jwt',
      },
      body: JSON.stringify({
        session_id: sessionId,
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
      sessionId,
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

Deno.test('ai-guide rejects missing or mismatched elder room credentials before provider use', async () => {
  const baseDependencies = {
    sessions: {
      async findById(id: string) {
        return { id, code: '482913', status: 'active' as const }
      },
    },
  }
  const body = JSON.stringify({
    session_id: sessionId,
    task: '打开设置',
    screenshot_base64: 'jpeg-data',
  })

  const missing = await handleEdgeRequest(
    'ai-guide',
    new Request('http://localhost/ai-guide', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body,
    }),
    makeTestDependencies(baseDependencies),
  )
  assert.equal(missing.status, 401)

  const mismatched = await handleEdgeRequest(
    'ai-guide',
    new Request('http://localhost/ai-guide', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'x-secondsight-elder-token': 'volunteer-jwt',
      },
      body,
    }),
    makeTestDependencies({
      ...baseDependencies,
      elderCredentials: {
        async verify() {
          return { identity: 'volunteer:helper', room: '482913' }
        },
      },
    }),
  )
  assert.equal(mismatched.status, 403)
})
