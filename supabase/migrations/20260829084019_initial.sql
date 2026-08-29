create table sessions (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  status text not null default 'waiting',
  elder_label text default '长辈',
  volunteer_label text,
  created_at timestamptz not null default now(),
  ended_at timestamptz
);

create table session_events (
  id bigint generated always as identity primary key,
  session_id uuid not null references sessions(id),
  ts timestamptz not null default now(),
  actor text not null,
  kind text not null,
  payload jsonb not null default '{}'
);

create table alerts (
  id bigint generated always as identity primary key,
  session_id uuid not null references sessions(id),
  ts timestamptz not null default now(),
  severity text not null,
  transcript text not null,
  reason text not null
);

alter table sessions enable row level security;
alter table session_events enable row level security;
alter table alerts enable row level security;

create index session_events_session_id_ts_idx on session_events (session_id, ts desc);
create index alerts_session_id_ts_idx on alerts (session_id, ts desc);
