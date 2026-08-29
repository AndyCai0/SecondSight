alter table public.sessions
  add column broadcast_active boolean not null default false,
  add column broadcast_started_at timestamptz;

alter table public.sessions
  add constraint sessions_broadcast_timestamp_check
  check (not broadcast_active or broadcast_started_at is not null);

create index sessions_active_broadcast_idx
  on public.sessions (broadcast_started_at desc)
  where broadcast_active and status = 'waiting';

create table public.assistant_presence (
  id uuid primary key,
  display_name text not null check (char_length(display_name) between 1 and 40),
  last_seen_at timestamptz not null default now()
);

alter table public.assistant_presence enable row level security;

create index assistant_presence_last_seen_idx
  on public.assistant_presence (last_seen_at desc);

-- Client code never accesses either table directly. These grants only keep the
-- server-side service-role REST fallback working on projects where new public
-- tables are no longer exposed automatically.
grant select, insert, update, delete on table public.assistant_presence to service_role;
grant select, update on table public.sessions to service_role;
