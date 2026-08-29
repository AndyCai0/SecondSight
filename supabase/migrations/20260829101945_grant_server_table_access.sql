grant select, insert, update on table public.sessions to service_role;
grant select, insert on table public.session_events to service_role;
grant select, insert on table public.alerts to service_role;

grant usage, select on sequence public.session_events_id_seq to service_role;
grant usage, select on sequence public.alerts_id_seq to service_role;
