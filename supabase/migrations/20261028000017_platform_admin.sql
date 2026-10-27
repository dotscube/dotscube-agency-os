-- =====================================================================
-- 0017 PLATFORM ADMIN: the platform owner (Dotscube) can see and manage
-- every agency on this installation, decide who may create a new agency,
-- suspend an agency, and set a plan / user limit.
-- * Platform admins live in their own table that no agency role, RLS
--   policy or API grant can write to: only SQL run by the database owner
--   (or an existing platform admin through platform_add_admin) adds one.
-- * Agencies stay sealed from each other. Platform functions return
--   summaries and member lists, not clients' or employees' business data.
-- * Suspending an agency makes app.org_id() return nothing for its users,
--   so every RLS policy and business function stops serving them at once.
-- =====================================================================

create table public.platform_admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  added_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

create table public.platform_settings (
  id boolean primary key default true check (id),
  org_creation text not null default 'open' check (org_creation in ('open','invite_only','closed')),
  default_plan text not null default 'free' check (default_plan ~ '^[a-z0-9_]{2,30}$'),
  default_max_users integer check (default_max_users is null or default_max_users between 1 and 100000),
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now()
);
insert into public.platform_settings(id) values (true) on conflict do nothing;

create table public.platform_invites (
  id uuid primary key default gen_random_uuid(),
  email text not null check (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  plan text check (plan is null or plan ~ '^[a-z0-9_]{2,30}$'),
  max_users integer check (max_users is null or max_users between 1 and 100000),
  note text,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '30 days',
  used_at timestamptz,
  used_by_org uuid references public.organizations(id) on delete set null
);
create unique index platform_invites_one_open on public.platform_invites(lower(email)) where used_at is null;

alter table public.organizations
  add column status text not null default 'active' check (status in ('active','suspended')),
  add column suspended_at timestamptz,
  add column suspended_reason text,
  add column plan text not null default 'free' check (plan ~ '^[a-z0-9_]{2,30}$'),
  add column max_users integer check (max_users is null or max_users between 1 and 100000),
  add column platform_notes text,
  add column created_by uuid references auth.users(id) on delete set null;

-- RLS on: nobody reads or writes these through the API except as defined below
alter table public.platform_admins enable row level security;
alter table public.platform_settings enable row level security;
alter table public.platform_invites enable row level security;
revoke all on public.platform_admins, public.platform_settings, public.platform_invites from anon, authenticated;

-- the organization columns are managed only by platform functions
revoke update on public.organizations from authenticated;
grant update (name, timezone, currency, employee_code_prefix, settings) on public.organizations to authenticated;

create or replace function app.is_platform_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.platform_admins where user_id = auth.uid())
$$;

-- Suspended agencies: their users resolve to no organization at all.
create or replace function app.org_id() returns uuid
language sql stable security definer set search_path = '' as $$
  select p.org_id from public.profiles p join public.organizations o on o.id = p.org_id
  where p.id = auth.uid() and p.is_active and o.status = 'active'
$$;

-- Every identity helper ignores suspended agencies, so permission checks inside functions fail too.
create or replace function app.client_id() returns uuid
language sql stable security definer set search_path = '' as $$
  select p.client_id from public.profiles p join public.organizations o on o.id = p.org_id
  where p.id = auth.uid() and p.is_active and o.status = 'active'
$$;

create or replace function app.is_internal() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.profiles p join public.organizations o on o.id = p.org_id
                 where p.id = auth.uid() and p.is_active and p.client_id is null and o.status = 'active')
$$;

create or replace function app.has_perm(p_key text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1
    from public.profiles p
    join public.organizations o on o.id = p.org_id and o.status = 'active'
    join public.user_roles ur on ur.user_id = p.id and ur.org_id = p.org_id
    join public.role_permissions rp on rp.role_id = ur.role_id
    where p.id = auth.uid() and p.is_active and p.client_id is null
      and rp.permission_key = p_key)
$$;

create or replace function public.my_permissions() returns setof text
language sql stable security definer set search_path = '' as $$
  select distinct rp.permission_key
  from public.profiles p
  join public.organizations o on o.id = p.org_id and o.status = 'active'
  join public.user_roles ur on ur.user_id = p.id and ur.org_id = p.org_id
  join public.role_permissions rp on rp.role_id = ur.role_id
  where p.id = auth.uid() and p.is_active and p.client_id is null
$$;

-- What the signed-in user's account looks like (used by the app to explain a suspension
-- and to show the Platform menu). Reveals nothing about other users.
create or replace function public.my_account_state() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'platform_admin', app.is_platform_admin(),
    'org_status', (select o.status from public.profiles p join public.organizations o on o.id = p.org_id where p.id = auth.uid()),
    'org_creation', (select org_creation from public.platform_settings))
$$;

create or replace function app.require_platform_admin() returns void
language plpgsql stable security definer set search_path = '' as $$
begin
  if not app.is_platform_admin() then raise exception 'Platform admins only' using errcode = '42501'; end if;
end $$;

-- ---------- who may create a new agency ----------
create or replace function public.create_organization(p_name text, p_slug text, p_full_name text default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_org uuid; v_prof public.profiles; v_role uuid; v_mode text; v_inv public.platform_invites; ps public.platform_settings;
begin
  select * into v_prof from public.profiles where id = auth.uid();
  if v_prof.id is null then raise exception 'Not signed in' using errcode='42501'; end if;
  if v_prof.org_id is not null or v_prof.client_id is not null then
    raise exception 'Your account already belongs to an organization' using errcode='42501'; end if;
  select * into ps from public.platform_settings;
  v_mode := coalesce(ps.org_creation, 'open');
  if not app.is_platform_admin() then
    if v_mode = 'closed' then
      raise exception 'New agencies can''t be created on this platform. If you were invited to an existing agency, sign up with the e-mail address the invitation was sent to.' using errcode = '42501'; end if;
    if v_mode = 'invite_only' then
      select * into v_inv from public.platform_invites
       where lower(email) = lower(v_prof.email) and used_at is null and expires_at > now() order by created_at desc limit 1 for update;
      if v_inv.id is null then
        raise exception 'Creating an agency is by invitation only. Ask the platform owner to invite %.', v_prof.email using errcode = '42501'; end if;
    end if;
  end if;
  insert into public.organizations(name, slug, plan, max_users, created_by)
  values (trim(p_name), lower(trim(p_slug)), coalesce(v_inv.plan, ps.default_plan, 'free'), coalesce(v_inv.max_users, ps.default_max_users), auth.uid())
  returning id into v_org;
  if v_inv.id is not null then update public.platform_invites set used_at = now(), used_by_org = v_org where id = v_inv.id; end if;
  perform app.seed_org_defaults(v_org);
  perform set_config('app.bypass_guards', 'on', true);
  update public.profiles set org_id = v_org, full_name = coalesce(nullif(trim(p_full_name),''), full_name) where id = auth.uid();
  select id into v_role from public.roles where org_id = v_org and key = 'super_admin';
  insert into public.user_roles(user_id, role_id, org_id) values (auth.uid(), v_role, v_org);
  -- a brand-new installation: whoever creates the first agency owns the platform
  insert into public.platform_admins(user_id) select auth.uid() where not exists (select 1 from public.platform_admins);
  insert into public.employee_profiles(org_id, profile_id, employee_code, full_name, work_email, designation, status, joining_date,
      department_id)
  select v_org, auth.uid(), '', coalesce(nullif(trim(p_full_name),''), nullif(v_prof.full_name,''), split_part(v_prof.email,'@',1)),
         v_prof.email, 'Founder', 'active', current_date, (select id from public.departments where org_id = v_org and name = 'Management');
  perform set_config('app.bypass_guards', '', true);
  return v_org;
end $$;
revoke execute on function public.create_organization(text,text,text) from public, anon;
grant execute on function public.create_organization(text,text,text) to authenticated;

-- ---------- user limit per agency (counts active members + open invitations) ----------
create or replace function app.guard_user_limit() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_max int; v_used int;
begin
  select max_users into v_max from public.organizations where id = new.org_id;
  if v_max is null then return new; end if;
  select (select count(*) from public.profiles where org_id = new.org_id and is_active)
       + (select count(*) from public.invitations where org_id = new.org_id and accepted_at is null and expires_at > now())
    into v_used;
  if v_used >= v_max then
    raise exception 'Your plan allows % users. Deactivate someone or ask the platform owner to raise the limit.', v_max using errcode = '22023'; end if;
  return new;
end $$;
create trigger trg_guard_user_limit before insert on public.invitations for each row execute function app.guard_user_limit();

-- ---------- platform console API ----------
create or replace function public.platform_agencies() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform app.require_platform_admin();
  return coalesce((select jsonb_agg(x order by x.created_at) from (
    select o.id, o.name, o.slug, o.status, o.plan, o.max_users, o.created_at, o.suspended_at, o.suspended_reason, o.platform_notes,
      (select jsonb_build_object('name', p.full_name, 'email', p.email) from public.profiles p where p.id = o.created_by) as founder,
      (select count(*) from public.profiles p where p.org_id = o.id and p.is_active and p.client_id is null) as staff_users,
      (select count(*) from public.profiles p where p.org_id = o.id and p.is_active and p.client_id is not null) as client_users,
      (select count(*) from public.employee_profiles e where e.org_id = o.id and e.status <> 'exited') as employees,
      (select count(*) from public.clients c where c.org_id = o.id) as clients,
      (select count(*) from public.projects pr where pr.org_id = o.id) as projects,
      (select count(*) from public.invoices i where i.org_id = o.id and i.status <> 'draft') as invoices,
      (select max(created_at) from public.audit_logs a where a.org_id = o.id) as last_activity,
      exists (select 1 from public.platform_admins pa join public.profiles p on p.id = pa.user_id where p.org_id = o.id) as is_platform_home
    from public.organizations o) x), '[]'::jsonb);
end $$;

create or replace function public.platform_agency_members(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform app.require_platform_admin();
  return coalesce((select jsonb_agg(x order by x.is_client, x.full_name) from (
    select p.id, p.full_name, p.email, p.is_active, p.client_id is not null as is_client, p.created_at,
      (select string_agg(r.name, ', ' order by r.name) from public.user_roles ur join public.roles r on r.id = ur.role_id where ur.user_id = p.id) as roles
    from public.profiles p where p.org_id = p_org) x), '[]'::jsonb);
end $$;

create or replace function public.platform_update_agency(p_org uuid, p_plan text, p_max_users integer, p_notes text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform app.require_platform_admin();
  update public.organizations set plan = coalesce(nullif(trim(p_plan), ''), plan), max_users = p_max_users, platform_notes = nullif(trim(p_notes), '')
   where id = p_org;
  if not found then raise exception 'Agency not found' using errcode = 'P0002'; end if;
  perform app.audit_event(p_org, 'organizations', p_org::text, jsonb_build_object('platform', 'update', 'plan', p_plan, 'max_users', p_max_users));
end $$;

create or replace function public.platform_set_agency_status(p_org uuid, p_status text, p_reason text default null) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform app.require_platform_admin();
  if p_status not in ('active','suspended') then raise exception 'Status must be active or suspended' using errcode = '22023'; end if;
  if p_status = 'suspended' then
    if exists (select 1 from public.platform_admins pa join public.profiles p on p.id = pa.user_id where p.org_id = p_org) then
      raise exception 'You can''t suspend the agency that platform admins belong to' using errcode = '22023'; end if;
    if coalesce(length(trim(p_reason)), 0) < 3 then raise exception 'Give a reason for the suspension' using errcode = '22023'; end if;
  end if;
  update public.organizations set status = p_status,
    suspended_at = case when p_status = 'suspended' then now() end,
    suspended_reason = case when p_status = 'suspended' then trim(p_reason) end
  where id = p_org;
  if not found then raise exception 'Agency not found' using errcode = 'P0002'; end if;
  perform app.audit_event(p_org, 'organizations', p_org::text, jsonb_build_object('platform', p_status, 'reason', p_reason));
end $$;

create or replace function public.platform_get_settings() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform app.require_platform_admin();
  return jsonb_build_object('settings', (select to_jsonb(s) from public.platform_settings s),
    'invites', coalesce((select jsonb_agg(to_jsonb(i) order by i.created_at desc) from public.platform_invites i), '[]'::jsonb),
    'admins', coalesce((select jsonb_agg(jsonb_build_object('user_id', p.id, 'name', p.full_name, 'email', p.email)) from public.platform_admins pa
      join public.profiles p on p.id = pa.user_id), '[]'::jsonb));
end $$;

create or replace function public.platform_save_settings(p_org_creation text, p_default_plan text, p_default_max_users integer) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform app.require_platform_admin();
  update public.platform_settings set org_creation = p_org_creation, default_plan = coalesce(nullif(trim(p_default_plan), ''), 'free'),
    default_max_users = p_default_max_users, updated_by = auth.uid(), updated_at = now();
end $$;

create or replace function public.platform_invite(p_email text, p_plan text default null, p_max_users integer default null, p_note text default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  perform app.require_platform_admin();
  if exists (select 1 from public.profiles where lower(email) = lower(trim(p_email)) and org_id is not null) then
    raise exception 'That e-mail already belongs to an agency' using errcode = '23505'; end if;
  begin
    insert into public.platform_invites(email, plan, max_users, note, created_by)
    values (lower(trim(p_email)), nullif(trim(p_plan), ''), p_max_users, nullif(trim(p_note), ''), auth.uid()) returning id into v_id;
  exception when unique_violation then
    raise exception 'That e-mail already has an open invitation' using errcode = '23505';
  end;
  return v_id;
end $$;

create or replace function public.platform_revoke_invite(p_invite uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform app.require_platform_admin();
  delete from public.platform_invites where id = p_invite and used_at is null;
end $$;

create or replace function public.platform_add_admin(p_email text) returns void
language plpgsql security definer set search_path = '' as $$
declare v_user uuid;
begin
  perform app.require_platform_admin();
  select id into v_user from public.profiles where lower(email) = lower(trim(p_email));
  if v_user is null then raise exception 'No account with that e-mail. They need to sign up first.' using errcode = 'P0002'; end if;
  insert into public.platform_admins(user_id, added_by) values (v_user, auth.uid()) on conflict do nothing;
end $$;

create or replace function public.platform_remove_admin(p_user uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform app.require_platform_admin();
  if p_user = auth.uid() then raise exception 'You can''t remove yourself' using errcode = '22023'; end if;
  delete from public.platform_admins where user_id = p_user;
end $$;

do $$ declare f text; begin
  foreach f in array array['my_account_state()','platform_agencies()','platform_agency_members(uuid)',
    'platform_update_agency(uuid,text,integer,text)','platform_set_agency_status(uuid,text,text)','platform_get_settings()',
    'platform_save_settings(text,text,integer)','platform_invite(text,text,integer,text)','platform_revoke_invite(uuid)',
    'platform_add_admin(text)','platform_remove_admin(uuid)'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop; end $$;

-- ---------- first platform admin + backfill ----------
-- Founders of existing agencies: the earliest Super Admin of each organization.
update public.organizations o set created_by = (
  select ur.user_id from public.user_roles ur join public.roles r on r.id = ur.role_id
  where r.org_id = o.id and r.key = 'super_admin' order by ur.assigned_at limit 1)
where created_by is null;
-- The platform owner is the founder of the first agency created on this installation (Dotscube).
insert into public.platform_admins(user_id)
select o.created_by from public.organizations o where o.created_by is not null order by o.created_at limit 1
on conflict do nothing;

revoke execute on all functions in schema app from public, anon;
grant execute on all functions in schema app to authenticated, service_role;
