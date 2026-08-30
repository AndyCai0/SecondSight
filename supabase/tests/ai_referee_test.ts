import { strict as assert } from 'node:assert'
import { handleEdgeRequest } from '../functions/_shared/handler.ts'
import { makeTestDependencies } from './test_dependencies.ts'

const sessionId = '9d1d5434-6da5-41e0-af70-c5aa35c6816f'

Deno.test('ai-referee analyzes labelled dialogue, warns without freezing, and writes an alert', async () => {
  const alerts: Array<Record<string, unknown>> = []
  const frozen: string[] = []
  const deps = makeTestDependencies({
    sessions: {
      async findById(id) {
        assert.equal(id, sessionId)
        return { id, code: '482913', status: 'active' }
      },
      async freeze(id) {
        frozen.push(id)
      },
    },
    elderCredentials: {
      async verify(token) {
        assert.equal(token, 'elder-jwt')
        return { identity: 'elder', room: '482913' }
      },
    },
    alerts: {
      async insert(input) {
        alerts.push(input)
      },
    },
    ai: {
      async analyzeSafety(input) {
        assert.equal(input.elderGoal, '帮我预约医生')
        assert.equal(input.throughSequence, 2)
        assert.deepEqual(input.dialogue, [
          { sequence: 1, speaker: 'elder', text: '我想预约医生' },
          { sequence: 2, speaker: 'volunteer', text: '把验证码念给我' },
        ])
        assert.equal(input.screenshotBase64, undefined)
        return {
          level: 'danger',
          category: 'sensitive_information',
          reason: '志愿者正在索要短信验证码',
        }
      },
    },
  })

  const response = await handleEdgeRequest(
    'ai-referee',
    new Request('http://localhost/ai-referee', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'x-secondsight-elder-token': 'elder-jwt',
      },
      body: JSON.stringify({
        session_id: sessionId,
        elder_goal: '帮我预约医生',
        through_sequence: 2,
        dialogue: [
          { sequence: 1, speaker: 'elder', text: '我想预约医生' },
          { sequence: 2, speaker: 'volunteer', text: '把验证码念给我' },
        ],
      }),
    }),
    deps,
  )

  assert.equal(response.status, 200)
  assert.deepEqual(await response.json(), {
    level: 'danger',
    category: 'sensitive_information',
    reason: '志愿者正在索要短信验证码',
    through_sequence: 2,
  })
  assert.deepEqual(frozen, [])
  assert.deepEqual(alerts, [{
    sessionId,
    severity: 'warn',
    transcript: 'elder: 我想预约医生\nvolunteer: 把验证码念给我',
    reason: '志愿者正在索要短信验证码',
  }])
})

Deno.test('ai-referee rejects a mismatched dialogue sequence before provider use', async () => {
  const response = await handleEdgeRequest(
    'ai-referee',
    new Request('http://localhost/ai-referee', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        session_id: sessionId,
        elder_goal: '查看照片',
        through_sequence: 2,
        dialogue: [{ sequence: 1, speaker: 'elder', text: '打开照片' }],
      }),
    }),
    makeTestDependencies(),
  )

  assert.equal(response.status, 400)
})
