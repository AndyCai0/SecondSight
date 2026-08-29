import { strict as assert } from 'node:assert'

Deno.test('initial migration creates the contract tables with deny-by-default RLS', async () => {
  const sql = await Deno.readTextFile(
    new URL('../migrations/202608290001_initial.sql', import.meta.url),
  )

  for (const table of ['sessions', 'session_events', 'alerts']) {
    assert.match(sql, new RegExp(`create table ${table}\\b`, 'i'))
    assert.match(sql, new RegExp(`alter table ${table} enable row level security`, 'i'))
  }
  assert.doesNotMatch(sql, /create\s+policy/i)
  assert.match(sql, /code text not null unique/i)
  assert.match(sql, /references sessions\s*\(id\)/i)
})

Deno.test('automatic RLS helper is not exposed through the Data API', async () => {
  const sql = await Deno.readTextFile(
    new URL('../migrations/20260829084356_secure_auto_rls_trigger.sql', import.meta.url),
  )

  assert.match(
    sql,
    /revoke\s+execute\s+on\s+function\s+public\.rls_auto_enable\(\)\s+from\s+public,\s*anon,\s*authenticated/i,
  )
})
