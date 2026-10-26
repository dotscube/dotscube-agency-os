-- =====================================================================
-- 0001 FOUNDATION: tenancy, profiles, RBAC, departments, audit
-- =====================================================================
create extension if not exists pgcrypto with schema extensions;

create schema if not exists app;            -- private helpers, NOT exposed via PostgREST
revoke all on schema app from public;
grant usage on schema app to authenticated, service_role;

-- ---------- generic helpers ----------
create or replace function app.touch_updated_at() returns trigger
language plpgsql set search_path = '' as $$
begin new.updated_at := now(); return new; end $$;

-- ---------- organizations ----------
create table public.organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) between 2 and 120),
  slug text not null unique check (slug ~ '^[a-z0-9][a-z0-9-]{1,48}$'),
  timezone text not null default 'Asia/Kolkata',
  currency char(3) not null default 'INR',
  employee_code_prefix text not null default 'EMP' check (employee_code_prefix ~ '^[A-Z0-9]{1,8}$'),
  employee_code_seq integer not null default 0,
  settings jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger trg_org_touch before update on public.organizations for each row execute function app.touch_updated_at();

-- ---------- profiles (1:1 with auth.users) ----------
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  org_id uuid references public.organizations(id) on delete restrict,
  client_id uuid,                                   -- set for client-portal users (FK added in 0003)
  full_name text not null default '' check (length(full_name) <= 120),
  email text not null,
  avatar_url text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index on public.profiles(org_id);
create index on public.profiles(client_id);
create trigger trg_profiles_touch before update on public.profiles for each row execute function app.touch_updated_at();

-- ---------- RBAC ----------
create table public.permissions (
  key text primary key check (key ~ '^[a-z_]+\.[a-z_]+$'),
  module text not null,
  description text not null
);

create table public.roles (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  key text not null check (key ~ '^[a-z0-9_]{2,40}$'),
  name text not null,
  description text,
  is_system boolean not null default false,
  is_client_role boolean not null default false,
  created_at timestamptz not null default now(),
  unique (org_id, key),
  unique (org_id, id)
);

create table public.role_permissions (
  role_id uuid not null references public.roles(id) on delete cascade,
  permission_key text not null references public.permissions(key) on delete cascade,
  org_id uuid not null references public.organizations(id) on delete cascade,
  primary key (role_id, permission_key),
  foreign key (org_id, role_id) references public.roles(org_id, id) on delete cascade
);
create index on public.role_permissions(org_id);

create table public.user_roles (
  user_id uuid not null references public.profiles(id) on delete cascade,
  role_id uuid not null references public.roles(id) on delete cascade,
  org_id uuid not null references public.organizations(id) on delete cascade,
  assigned_by uuid references public.profiles(id) on delete set null,
  assigned_at timestamptz not null default now(),
  primary key (user_id, role_id),
  foreign key (org_id, role_id) references public.roles(org_id, id) on delete cascade
);
create index on public.user_roles(org_id);
create index on public.user_roles(role_id);

-- ---------- security helper functions ----------
-- All SECURITY DEFINER with empty search_path; they only reveal facts about the caller.
create or replace function app.org_id() returns uuid
language sql stable security definer set search_path = '' as $$
  select p.org_id from public.profiles p where p.id = auth.uid() and p.is_active
$$;

create or replace function app.client_id() returns uuid
language sql stable security definer set search_path = '' as $$
  select p.client_id from public.profiles p where p.id = auth.uid() and p.is_active
$$;

create or replace function app.is_internal() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.profiles p
                 where p.id = auth.uid() and p.is_active and p.org_id is not null and p.client_id is null)
$$;

create or replace function app.has_perm(p_key text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1
    from public.profiles p
    join public.user_roles ur on ur.user_id = p.id and ur.org_id = p.org_id
    join public.role_permissions rp on rp.role_id = ur.role_id
    where p.id = auth.uid() and p.is_active and p.client_id is null
      and rp.permission_key = p_key)
$$;

create or replace function public.my_permissions() returns setof text
language sql stable security definer set search_path = '' as $$
  select distinct rp.permission_key
  from public.profiles p
  join public.user_roles ur on ur.user_id = p.id and ur.org_id = p.org_id
  join public.role_permissions rp on rp.role_id = ur.role_id
  where p.id = auth.uid() and p.is_active and p.client_id is null
$$;

-- ---------- departments ----------
create table public.departments (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  name text not null check (length(trim(name)) between 2 and 80),
  head_profile_id uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (org_id, name)
);

-- ---------- audit log ----------
create table public.audit_logs (
  id bigint generated always as identity primary key,
  org_id uuid references public.organizations(id) on delete cascade,
  actor_id uuid,
  action text not null check (action in ('INSERT','UPDATE','DELETE','EVENT')),
  table_name text not null,
  record_id text,
  old_data jsonb,
  new_data jsonb,
  created_at timestamptz not null default now()
);
create index on public.audit_logs(org_id, created_at desc);
create index on public.audit_logs(table_name, record_id);

create or replace function app.audit() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_old jsonb; v_new jsonb; v_row jsonb;
begin
  if tg_op in ('UPDATE','DELETE') then v_old := to_jsonb(old); end if;
  if tg_op in ('INSERT','UPDATE') then v_new := to_jsonb(new); end if;
  if tg_op = 'UPDATE' and v_old - 'updated_at' = v_new - 'updated_at' then return new; end if;
  v_row := coalesce(v_new, v_old);
  insert into public.audit_logs(org_id, actor_id, action, table_name, record_id, old_data, new_data)
  values (nullif(v_row->>'org_id','')::uuid, auth.uid(), tg_op, tg_table_name,
          coalesce(v_row->>'id', v_row->>'user_id'), v_old, v_new);
  return coalesce(new, old);
end $$;

create or replace function app.audit_event(p_org uuid, p_table text, p_record text, p_data jsonb)
returns void language sql security definer set search_path = '' as $$
  insert into public.audit_logs(org_id, actor_id, action, table_name, record_id, new_data)
  values (p_org, auth.uid(), 'EVENT', p_table, p_record, p_data)
$$;

create trigger trg_audit after insert or update or delete on public.organizations for each row execute function app.audit();
create trigger trg_audit after insert or update or delete on public.roles for each row execute function app.audit();
create trigger trg_audit after insert or update or delete on public.role_permissions for each row execute function app.audit();
create trigger trg_audit after insert or update or delete on public.user_roles for each row execute function app.audit();
create trigger trg_audit after update or delete on public.profiles for each row execute function app.audit();

-- ---------- RBAC integrity rules ----------
create or replace function app.guard_user_roles() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_role public.roles; v_prof public.profiles; v_remaining int;
begin
  if tg_op = 'INSERT' then
    select * into v_role from public.roles where id = new.role_id;
    select * into v_prof from public.profiles where id = new.user_id;
    if v_prof.org_id is distinct from new.org_id or v_role.org_id is distinct from new.org_id then
      raise exception 'Role and user must belong to the same organization' using errcode = '42501';
    end if;
    if v_role.is_client_role <> (v_prof.client_id is not null) then
      raise exception 'Client roles can only be given to client users and vice versa' using errcode = '42501';
    end if;
    if auth.uid() is not null and new.user_id = auth.uid() and not app.has_perm('roles.manage') then
      raise exception 'You cannot change your own roles' using errcode = '42501';
    end if;
    if v_role.key = 'super_admin' and auth.uid() is not null and not exists (
        select 1 from public.user_roles ur join public.roles r on r.id = ur.role_id
        where ur.user_id = auth.uid() and r.key = 'super_admin') then
      raise exception 'Only a Super Admin can grant Super Admin' using errcode = '42501';
    end if;
    return new;
  else
    select * into v_role from public.roles where id = old.role_id;
    if v_role.key = 'super_admin' and v_role.org_id is not null then
      select count(*) into v_remaining from public.user_roles ur
        join public.profiles p on p.id = ur.user_id and p.is_active
       where ur.role_id = old.role_id and ur.user_id <> old.user_id;
      if v_remaining = 0 and exists (select 1 from public.organizations where id = v_role.org_id) then
        raise exception 'Cannot remove the last Super Admin' using errcode = '42501';
      end if;
    end if;
    return old;
  end if;
end $$;
create trigger trg_guard_user_roles before insert or delete on public.user_roles
  for each row execute function app.guard_user_roles();

create or replace function app.guard_role_permissions() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_key text; v_client boolean;
begin
  select key, is_client_role into v_key, v_client from public.roles where id = coalesce(new.role_id, old.role_id);
  if v_key = 'super_admin' and auth.uid() is not null then
    raise exception 'Super Admin permissions are fixed' using errcode = '42501';
  end if;
  if tg_op = 'INSERT' and v_client then
    raise exception 'Client roles cannot hold internal permissions' using errcode = '42501';
  end if;
  return coalesce(new, old);
end $$;
create trigger trg_guard_role_permissions before insert or delete on public.role_permissions
  for each row execute function app.guard_role_permissions();

create or replace function app.guard_roles() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'DELETE' and old.is_system then raise exception 'System roles cannot be deleted' using errcode='42501'; end if;
  if tg_op = 'UPDATE' and (new.key <> old.key or new.is_system <> old.is_system or new.org_id <> old.org_id
                           or new.is_client_role <> old.is_client_role) then
    raise exception 'Role key/system flags are immutable' using errcode='42501';
  end if;
  return coalesce(new, old);
end $$;
create trigger trg_guard_roles before update or delete on public.roles for each row execute function app.guard_roles();

-- prevent users changing org/client/active flags of their own profile
create or replace function app.guard_profiles() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then return new; end if;  -- service role / migrations
  if new.org_id is distinct from old.org_id or new.client_id is distinct from old.client_id
     or new.email is distinct from old.email then
    raise exception 'Organization, client and email cannot be changed here' using errcode='42501';
  end if;
  if new.is_active is distinct from old.is_active then
    if not app.has_perm('users.manage') or old.id = auth.uid() then
      raise exception 'Not allowed to change account status' using errcode='42501';
    end if;
  end if;
  return new;
end $$;
create trigger trg_guard_profiles before update on public.profiles for each row execute function app.guard_profiles();

-- ---------- permission catalog ----------
insert into public.permissions(key, module, description) values
 ('org.manage','settings','Edit organization settings'),
 ('roles.manage','settings','Create roles and edit role permissions'),
 ('users.manage','settings','Invite, deactivate users and assign roles'),
 ('audit.view','settings','View audit logs'),
 ('departments.manage','hr','Create and edit departments'),
 ('employees.view','hr','View employee directory'),
 ('employees.create','hr','Create employees'),
 ('employees.edit','hr','Edit employees'),
 ('employees.delete','hr','Delete/exit employees'),
 ('employees.export','hr','Export employee data'),
 ('employees.view_sensitive','hr','View private employee details and documents'),
 ('salary.view','payroll','View salary structures'),
 ('salary.edit','payroll','Edit salary structures and revisions'),
 ('attendance.view_all','attendance','View attendance of all employees'),
 ('attendance.approve','attendance','Approve attendance corrections'),
 ('attendance.manage_policy','attendance','Edit schedules and attendance policy'),
 ('attendance.export','attendance','Export attendance'),
 ('leave.view_all','leave','View leave of all employees'),
 ('leave.approve','leave','Approve leave requests'),
 ('leave.manage_policy','leave','Edit leave types and balances'),
 ('leave.export','leave','Export leave data'),
 ('holidays.manage','leave','Manage holiday calendar'),
 ('clients.view','clients','View clients'),
 ('clients.create','clients','Create clients'),
 ('clients.edit','clients','Edit clients'),
 ('clients.delete','clients','Delete clients'),
 ('clients.export','clients','Export clients'),
 ('clients.view_billing','clients','View and edit client billing and contracts'),
 ('projects.view_all','projects','View all projects'),
 ('projects.create','projects','Create projects'),
 ('projects.edit','projects','Edit any project'),
 ('projects.delete','projects','Delete projects'),
 ('projects.export','projects','Export projects'),
 ('tasks.view_all','tasks','View all tasks'),
 ('tasks.create','tasks','Create tasks'),
 ('tasks.edit_all','tasks','Edit any task'),
 ('tasks.delete','tasks','Delete tasks'),
 ('tasks.manage_statuses','tasks','Configure task statuses'),
 ('announcements.manage','comms','Publish announcements'),
 ('reports.view','reports','View reports');

-- ---------- RLS ----------
alter table public.organizations enable row level security;
alter table public.profiles enable row level security;
alter table public.permissions enable row level security;
alter table public.roles enable row level security;
alter table public.role_permissions enable row level security;
alter table public.user_roles enable row level security;
alter table public.departments enable row level security;
alter table public.audit_logs enable row level security;

create policy org_select on public.organizations for select to authenticated using (id = (select app.org_id()));
create policy org_update on public.organizations for update to authenticated
  using (id = (select app.org_id()) and (select app.has_perm('org.manage')))
  with check (id = (select app.org_id()));

create policy profiles_select on public.profiles for select to authenticated using (
  id = auth.uid() or (org_id = (select app.org_id()) and (select app.is_internal())));
create policy profiles_update on public.profiles for update to authenticated
  using (id = auth.uid() or (org_id = (select app.org_id()) and (select app.has_perm('users.manage'))))
  with check (id = auth.uid() or (org_id = (select app.org_id()) and (select app.has_perm('users.manage'))));

create policy permissions_select on public.permissions for select to authenticated using (true);

create policy roles_select on public.roles for select to authenticated using (org_id = (select app.org_id()) and (select app.is_internal()));
create policy roles_write on public.roles for all to authenticated
  using (org_id = (select app.org_id()) and (select app.has_perm('roles.manage')))
  with check (org_id = (select app.org_id()) and (select app.has_perm('roles.manage')));

create policy rp_select on public.role_permissions for select to authenticated using (org_id = (select app.org_id()) and (select app.is_internal()));
create policy rp_write on public.role_permissions for all to authenticated
  using (org_id = (select app.org_id()) and (select app.has_perm('roles.manage')))
  with check (org_id = (select app.org_id()) and (select app.has_perm('roles.manage')));

create policy ur_select on public.user_roles for select to authenticated using (
  user_id = auth.uid() or (org_id = (select app.org_id()) and (select app.is_internal())));
create policy ur_insert on public.user_roles for insert to authenticated
  with check (org_id = (select app.org_id()) and (select app.has_perm('users.manage')));
create policy ur_delete on public.user_roles for delete to authenticated
  using (org_id = (select app.org_id()) and (select app.has_perm('users.manage')));

create policy dept_select on public.departments for select to authenticated using (org_id = (select app.org_id()) and (select app.is_internal()));
create policy dept_write on public.departments for all to authenticated
  using (org_id = (select app.org_id()) and (select app.has_perm('departments.manage')))
  with check (org_id = (select app.org_id()) and (select app.has_perm('departments.manage')));

create policy audit_select on public.audit_logs for select to authenticated
  using (org_id = (select app.org_id()) and (select app.has_perm('audit.view')));

-- ---------- grants (deny by default; RLS narrows further) ----------
revoke all on all tables in schema public from anon;
grant select on public.organizations, public.permissions, public.roles, public.role_permissions,
               public.user_roles, public.departments, public.audit_logs, public.profiles to authenticated;
grant update (name, timezone, currency, employee_code_prefix, settings) on public.organizations to authenticated;
grant update (full_name, avatar_url, is_active) on public.profiles to authenticated;
grant insert, update, delete on public.roles, public.departments to authenticated;
grant insert, delete on public.role_permissions, public.user_roles to authenticated;
revoke execute on all functions in schema app from public, anon;
grant execute on all functions in schema app to authenticated, service_role;
revoke execute on function public.my_permissions() from public, anon;
grant execute on function public.my_permissions() to authenticated;
