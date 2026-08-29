-- The project-wide automatic-RLS trigger is intentionally SECURITY DEFINER so it can
-- enable RLS on newly created public tables. It never needs to be callable through
-- PostgREST, so remove the default PUBLIC execute privilege.
revoke execute on function public.rls_auto_enable() from public, anon, authenticated;
