import { strict as assert } from 'node:assert'

Deno.test('initial migration creates the contract tables with deny-by-default RLS', async () => {
  const sql = await Deno.readTextFile(
    new URL('../migrations/20260829084019_initial.sql', import.meta.url),
  )

  for (const table of ['sessions', 'session_events', 'alerts']) {
    assert.match(sql, new RegExp(`create table ${table}\\b`, 'i'))
    assert.match(sql, new RegExp(`alter table ${table} enable row level security`, 'i'))
  }
  assert.doesNotMatch(sql, /create\s+policy/i)
  assert.match(sql, /code text not null unique/i)
  assert.match(sql, /references sessions\s*\(id\)/i)
})

Deno.test('server access migration grants only the backend role', async () => {
  const sql = await Deno.readTextFile(
    new URL('../migrations/20260829101945_grant_server_table_access.sql', import.meta.url),
  )

  assert.match(sql, /grant select, insert, update on table public\.sessions to service_role/i)
  assert.match(sql, /grant select, insert on table public\.session_events to service_role/i)
  assert.match(sql, /grant select, insert on table public\.alerts to service_role/i)
  assert.match(
    sql,
    /grant usage, select on sequence public\.session_events_id_seq to service_role/i,
  )
  assert.match(sql, /grant usage, select on sequence public\.alerts_id_seq to service_role/i)
  assert.doesNotMatch(sql, /\bto\s+(anon|authenticated|public)\b/i)
})

Deno.test('automatic RLS helper is not exposed through the Data API', async () => {
  const sql = await Deno.readTextFile(
    new URL('../migrations/20260829084447_secure_auto_rls_trigger.sql', import.meta.url),
  )

  assert.match(
    sql,
    /revoke\s+execute\s+on\s+function\s+public\.rls_auto_enable\(\)\s+from\s+public,\s*anon,\s*authenticated/i,
  )
})
