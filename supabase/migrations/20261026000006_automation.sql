-- =====================================================================
-- 0006 AUTOMATION: new client -> onboarding checklist (idempotent).
-- Checklist is configurable per org in organizations.settings->'client_onboarding_checklist'.
-- =====================================================================
create or replace function app.default_onboarding_checklist() returns text[]
language sql immutable set search_path = '' as $$
  select array['Kick-off call completed','Access to ad accounts received','Website / CMS access received',
               'Analytics & Search Console access received','Brand assets and guidelines received',
               'Billing details received','Reporting cadence agreed']
$$;

create or replace function app.trg_client_onboarding() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_items text[];
begin
  select coalesce(array(select jsonb_array_elements_text(settings->'client_onboarding_checklist')), app.default_onboarding_checklist())
    into v_items from public.organizations where id = new.org_id;
  if coalesce(array_length(v_items, 1), 0) = 0 then v_items := app.default_onboarding_checklist(); end if;
  insert into public.client_onboarding_items(org_id, client_id, title, position)
  select new.org_id, new.id, t, ord::smallint from unnest(v_items) with ordinality as x(t, ord)
  on conflict (client_id, title) do nothing;
  return new;
end $$;
create trigger trg_client_onboarding after insert on public.clients for each row execute function app.trg_client_onboarding();

revoke execute on all functions in schema app from public, anon;
grant execute on all functions in schema app to authenticated, service_role;
