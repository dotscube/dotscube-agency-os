-- Dotscube Agency OS: complete database setup.
-- Paste this whole file into Supabase > SQL Editor > New query > Run. Run it ONCE on a new project.
-- Generated from supabase/migrations (the source of truth).

-- ===== 20261026000001_foundation.sql =====
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

-- ===== 20261026000002_hr.sql =====
-- =====================================================================
-- 0002 HR: employees, private details, salary, schedules, holidays,
--          attendance (+breaks, corrections), leave (+balances, approvals)
-- =====================================================================

-- ---------- work schedules ----------
create table public.work_schedules (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  name text not null,
  start_time time not null default '10:00',
  end_time time not null default '19:00',
  grace_minutes smallint not null default 15 check (grace_minutes between 0 and 240),
  half_day_minutes smallint not null default 240 check (half_day_minutes > 0),
  full_day_minutes smallint not null default 480 check (full_day_minutes >= half_day_minutes),
  weekly_offs smallint[] not null default '{7}' check (weekly_offs <@ '{1,2,3,4,5,6,7}'::smallint[]), -- ISO dow, 7 = Sunday
  is_default boolean not null default false,
  created_at timestamptz not null default now(),
  unique (org_id, name)
);
create unique index work_schedules_one_default on public.work_schedules(org_id) where is_default;

create table public.holidays (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  holiday_date date not null,
  name text not null,
  is_optional boolean not null default false,
  unique (org_id, holiday_date)
);

-- ---------- employees ----------
create type public.employment_type as enum ('full_time','part_time','contract','intern','consultant');
create type public.employee_status as enum ('onboarding','probation','active','notice_period','exited');

create table public.employee_profiles (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete restrict,
  profile_id uuid unique references public.profiles(id) on delete set null,
  employee_code text not null,
  full_name text not null check (length(trim(full_name)) between 2 and 120),
  work_email text not null check (work_email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  work_phone text,
  department_id uuid references public.departments(id) on delete set null,
  designation text,
  reporting_manager_id uuid references public.employee_profiles(id) on delete set null,
  employment_type public.employment_type not null default 'full_time',
  status public.employee_status not null default 'onboarding',
  joining_date date not null,
  probation_end_date date,
  exit_date date,
  exit_reason text,
  work_schedule_id uuid references public.work_schedules(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (org_id, employee_code),
  unique (org_id, work_email),
  check (reporting_manager_id is null or reporting_manager_id <> id),
  check (probation_end_date is null or probation_end_date >= joining_date),
  check (exit_date is null or exit_date >= joining_date),
  check (status <> 'exited' or exit_date is not null)
);
create index on public.employee_profiles(org_id, status);
create index on public.employee_profiles(reporting_manager_id);
create index on public.employee_profiles(department_id);
create trigger trg_emp_touch before update on public.employee_profiles for each row execute function app.touch_updated_at();

create or replace function app.my_employee_id() returns uuid
language sql stable security definer set search_path = '' as $$
  select e.id from public.employee_profiles e
  join public.profiles p on p.id = e.profile_id and p.org_id = e.org_id
  where e.profile_id = auth.uid() and p.is_active and p.client_id is null
$$;

create or replace function app.is_manager_of(p_employee uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.employee_profiles e
                 where e.id = p_employee and e.reporting_manager_id is not null
                   and e.reporting_manager_id = app.my_employee_id())
$$;

-- self / manager / permission holder
create or replace function app.can_see_employee(p_employee uuid, p_perm text) returns boolean
language sql stable security definer set search_path = '' as $$
  select app.is_internal() and (
    p_employee = app.my_employee_id() or app.is_manager_of(p_employee) or app.has_perm(p_perm))
$$;

-- assign employee code + validate manager chain
create or replace function app.employee_before_write() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_seq int; v_prefix text; v_cursor uuid; v_depth int := 0;
begin
  if tg_op = 'INSERT' and (new.employee_code is null or new.employee_code = '') then
    update public.organizations set employee_code_seq = employee_code_seq + 1
     where id = new.org_id returning employee_code_seq, employee_code_prefix into v_seq, v_prefix;
    new.employee_code := v_prefix || lpad(v_seq::text, 4, '0');
  end if;
  if tg_op = 'UPDATE' and new.employee_code <> old.employee_code then
    raise exception 'Employee code is immutable' using errcode = '42501';
  end if;
  if new.reporting_manager_id is not null then
    if not exists (select 1 from public.employee_profiles where id = new.reporting_manager_id and org_id = new.org_id) then
      raise exception 'Reporting manager must belong to the same organization' using errcode = '23514';
    end if;
    v_cursor := new.reporting_manager_id;
    while v_cursor is not null and v_depth < 50 loop
      if v_cursor = new.id then raise exception 'Reporting line would create a cycle' using errcode = '23514'; end if;
      select reporting_manager_id into v_cursor from public.employee_profiles where id = v_cursor;
      v_depth := v_depth + 1;
    end loop;
  end if;
  if new.department_id is not null and not exists
     (select 1 from public.departments where id = new.department_id and org_id = new.org_id) then
    raise exception 'Department must belong to the same organization' using errcode = '23514';
  end if;
  if new.profile_id is not null and not exists
     (select 1 from public.profiles where id = new.profile_id and org_id = new.org_id and client_id is null) then
    raise exception 'Linked user must be an internal user of the same organization' using errcode = '23514';
  end if;
  return new;
end $$;
create trigger trg_emp_before before insert or update on public.employee_profiles
  for each row execute function app.employee_before_write();
create trigger trg_audit after insert or update or delete on public.employee_profiles for each row execute function app.audit();

create table public.employee_private (
  employee_id uuid primary key references public.employee_profiles(id) on delete cascade,
  org_id uuid not null references public.organizations(id) on delete cascade,
  personal_email text,
  personal_phone text,
  date_of_birth date,
  address text,
  emergency_contact_name text,
  emergency_contact_relation text,
  emergency_contact_phone text,
  updated_at timestamptz not null default now()
);
create trigger trg_emp_priv_touch before update on public.employee_private for each row execute function app.touch_updated_at();
create trigger trg_audit after insert or update or delete on public.employee_private for each row execute function app.audit();

create table public.employment_documents (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  employee_id uuid not null references public.employee_profiles(id) on delete cascade,
  doc_type text not null check (doc_type in ('offer_letter','appointment_letter','id_proof','address_proof','education','experience','contract','relieving_letter','other')),
  file_name text not null,
  storage_path text not null unique,   -- {org_id}/employees/{employee_id}/{uuid}-{file}
  uploaded_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
create index on public.employment_documents(employee_id);
create trigger trg_audit after insert or update or delete on public.employment_documents for each row execute function app.audit();

-- ---------- salary ----------
create table public.salary_components (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  code text not null check (code ~ '^[A-Z][A-Z0-9_]{1,19}$'),
  name text not null,
  kind text not null check (kind in ('earning','deduction')),
  is_active boolean not null default true,
  unique (org_id, code)
);

-- Append-only history. The current structure = latest revision effective on or before today.
create table public.salary_revisions (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  employee_id uuid not null references public.employee_profiles(id) on delete restrict,
  effective_from date not null,
  annual_ctc numeric(14,2) not null check (annual_ctc >= 0),
  monthly_components jsonb not null default '{}'::jsonb check (jsonb_typeof(monthly_components) = 'object'),
  reason text,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (employee_id, effective_from)
);
create trigger trg_audit after insert or update or delete on public.salary_revisions for each row execute function app.audit();

-- ---------- attendance ----------
create type public.attendance_status as enum ('in_progress','present','half_day','absent');

create table public.attendance_records (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  employee_id uuid not null references public.employee_profiles(id) on delete restrict,
  work_date date not null,
  schedule_id uuid references public.work_schedules(id) on delete set null,
  check_in_at timestamptz not null,
  check_out_at timestamptz,
  break_minutes integer not null default 0 check (break_minutes >= 0),
  worked_minutes integer check (worked_minutes >= 0),
  late_minutes integer not null default 0 check (late_minutes >= 0),
  status public.attendance_status not null default 'in_progress',
  source text not null default 'self' check (source in ('self','correction')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (employee_id, work_date),
  check (check_out_at is null or check_out_at > check_in_at)
);
create index on public.attendance_records(org_id, work_date);
create trigger trg_att_touch before update on public.attendance_records for each row execute function app.touch_updated_at();
create trigger trg_audit after insert or update or delete on public.attendance_records for each row execute function app.audit();

create table public.attendance_breaks (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  record_id uuid not null references public.attendance_records(id) on delete cascade,
  start_at timestamptz not null,
  end_at timestamptz,
  check (end_at is null or end_at >= start_at)
);
create unique index attendance_one_open_break on public.attendance_breaks(record_id) where end_at is null;

create table public.attendance_corrections (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  employee_id uuid not null references public.employee_profiles(id) on delete restrict,
  work_date date not null,
  requested_check_in timestamptz not null,
  requested_check_out timestamptz not null,
  reason text not null check (length(trim(reason)) >= 5),
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  decided_by uuid references public.profiles(id) on delete set null,
  decided_at timestamptz,
  decision_note text,
  created_at timestamptz not null default now(),
  check (requested_check_out > requested_check_in)
);
create unique index attendance_corr_one_pending on public.attendance_corrections(employee_id, work_date) where status = 'pending';
create index on public.attendance_corrections(org_id, status);
create trigger trg_audit after insert or update or delete on public.attendance_corrections for each row execute function app.audit();

-- schedule for an employee (own or org default)
create or replace function app.employee_schedule(p_employee uuid) returns public.work_schedules
language sql stable security definer set search_path = '' as $$
  select s.* from public.employee_profiles e
  join public.work_schedules s on s.org_id = e.org_id
   and (s.id = e.work_schedule_id or (e.work_schedule_id is null and s.is_default))
  where e.id = p_employee
  order by (s.id = e.work_schedule_id) desc
  limit 1
$$;

-- Pure calculation, unit-tested in supabase/tests
create or replace function app.compute_attendance(
  p_in timestamptz, p_out timestamptz, p_break_minutes int, p_tz text,
  p_start time, p_grace int, p_half int, p_full int,
  out worked_minutes int, out late_minutes int, out status public.attendance_status)
language plpgsql immutable set search_path = '' as $$
declare v_late int;
begin
  v_late := floor(extract(epoch from ((p_in at time zone p_tz)::time - p_start)) / 60);
  late_minutes := case when v_late > p_grace then v_late else 0 end;
  if p_out is null then
    worked_minutes := null; status := 'in_progress'; return;
  end if;
  worked_minutes := greatest(0, floor(extract(epoch from (p_out - p_in)) / 60)::int - coalesce(p_break_minutes, 0));
  status := case when worked_minutes >= p_full then 'present'
                 when worked_minutes >= p_half then 'half_day'
                 else 'absent' end;
end $$;

create or replace function app.recompute_attendance(p_record uuid) returns public.attendance_records
language plpgsql security definer set search_path = '' as $$
declare r public.attendance_records; s public.work_schedules; tz text; c record; v_break int;
begin
  select * into r from public.attendance_records where id = p_record for update;
  select * into s from public.work_schedules where id = r.schedule_id;
  if s.id is null then s := app.employee_schedule(r.employee_id); end if;
  select timezone into tz from public.organizations where id = r.org_id;
  select coalesce(sum(floor(extract(epoch from (coalesce(b.end_at, r.check_out_at) - b.start_at))/60)),0)::int
    into v_break from public.attendance_breaks b where b.record_id = r.id;
  v_break := greatest(v_break, case when r.source = 'correction' then r.break_minutes else 0 end);
  c := app.compute_attendance(r.check_in_at, r.check_out_at, v_break, tz,
         coalesce(s.start_time,'10:00'), coalesce(s.grace_minutes,15), coalesce(s.half_day_minutes,240), coalesce(s.full_day_minutes,480));
  update public.attendance_records set break_minutes = v_break, worked_minutes = c.worked_minutes,
         late_minutes = c.late_minutes, status = c.status
   where id = r.id returning * into r;
  return r;
end $$;

create or replace function app.require_active_employee() returns public.employee_profiles
language plpgsql stable security definer set search_path = '' as $$
declare e public.employee_profiles;
begin
  select * into e from public.employee_profiles where id = app.my_employee_id();
  if e.id is null then raise exception 'No employee profile is linked to your account' using errcode = '42501'; end if;
  if e.status = 'exited' then raise exception 'Employee has exited' using errcode = '42501'; end if;
  return e;
end $$;

create or replace function public.attendance_check_in() returns public.attendance_records
language plpgsql security definer set search_path = '' as $$
declare e public.employee_profiles; tz text; r public.attendance_records; s public.work_schedules;
begin
  e := app.require_active_employee();
  select timezone into tz from public.organizations where id = e.org_id;
  s := app.employee_schedule(e.id);
  insert into public.attendance_records(org_id, employee_id, work_date, schedule_id, check_in_at)
  values (e.org_id, e.id, (now() at time zone tz)::date, s.id, now())
  on conflict (employee_id, work_date) do nothing
  returning * into r;
  if r.id is null then raise exception 'You have already checked in today' using errcode = '23505'; end if;
  return app.recompute_attendance(r.id);
end $$;

create or replace function app.my_open_record() returns public.attendance_records
language sql stable security definer set search_path = '' as $$
  select * from public.attendance_records
  where employee_id = app.my_employee_id() and check_out_at is null
    and check_in_at > now() - interval '20 hours'
  order by check_in_at desc limit 1
$$;

create or replace function public.attendance_check_out() returns public.attendance_records
language plpgsql security definer set search_path = '' as $$
declare r public.attendance_records;
begin
  perform app.require_active_employee();
  r := app.my_open_record();
  if r.id is null then raise exception 'No open check-in found. Request an attendance correction instead.' using errcode = 'P0002'; end if;
  update public.attendance_breaks set end_at = now() where record_id = r.id and end_at is null;
  update public.attendance_records set check_out_at = now() where id = r.id;
  return app.recompute_attendance(r.id);
end $$;

create or replace function public.attendance_break_start() returns public.attendance_breaks
language plpgsql security definer set search_path = '' as $$
declare r public.attendance_records; b public.attendance_breaks;
begin
  perform app.require_active_employee();
  r := app.my_open_record();
  if r.id is null then raise exception 'Check in before starting a break' using errcode = 'P0002'; end if;
  insert into public.attendance_breaks(org_id, record_id, start_at) values (r.org_id, r.id, now())
  on conflict do nothing returning * into b;
  if b.id is null then raise exception 'A break is already in progress' using errcode = '23505'; end if;
  return b;
end $$;

create or replace function public.attendance_break_end() returns public.attendance_breaks
language plpgsql security definer set search_path = '' as $$
declare r public.attendance_records; b public.attendance_breaks;
begin
  perform app.require_active_employee();
  r := app.my_open_record();
  update public.attendance_breaks set end_at = now()
   where record_id = r.id and end_at is null returning * into b;
  if b.id is null then raise exception 'No break in progress' using errcode = 'P0002'; end if;
  perform app.recompute_attendance(r.id);
  return b;
end $$;

create or replace function public.request_attendance_correction(
  p_work_date date, p_check_in timestamptz, p_check_out timestamptz, p_reason text)
returns public.attendance_corrections
language plpgsql security definer set search_path = '' as $$
declare e public.employee_profiles; tz text; v_window int; c public.attendance_corrections;
begin
  e := app.require_active_employee();
  select timezone, coalesce((settings->>'correction_window_days')::int, 30) into tz, v_window
    from public.organizations where id = e.org_id;
  if p_work_date > (now() at time zone tz)::date then raise exception 'Cannot correct a future date' using errcode='22023'; end if;
  if p_work_date < (now() at time zone tz)::date - v_window then
    raise exception 'Corrections are only allowed within % days', v_window using errcode='22023'; end if;
  if (p_check_in at time zone tz)::date <> p_work_date then
    raise exception 'Check-in must fall on the selected date' using errcode='22023'; end if;
  if p_check_out <= p_check_in or p_check_out - p_check_in > interval '20 hours' then
    raise exception 'Invalid time range' using errcode='22023'; end if;
  if p_check_out > now() then raise exception 'Check-out cannot be in the future' using errcode='22023'; end if;
  insert into public.attendance_corrections(org_id, employee_id, work_date, requested_check_in, requested_check_out, reason)
  values (e.org_id, e.id, p_work_date, p_check_in, p_check_out, trim(p_reason)) returning * into c;
  return c;
end $$;

create or replace function public.decide_attendance_correction(p_id uuid, p_approve boolean, p_note text default null)
returns public.attendance_corrections
language plpgsql security definer set search_path = '' as $$
declare c public.attendance_corrections; r public.attendance_records; s public.work_schedules;
begin
  select * into c from public.attendance_corrections where id = p_id and org_id = app.org_id() for update;
  if c.id is null then raise exception 'Correction not found' using errcode='P0002'; end if;
  if c.status <> 'pending' then raise exception 'Correction already decided' using errcode='22023'; end if;
  if c.employee_id = app.my_employee_id() then raise exception 'You cannot approve your own correction' using errcode='42501'; end if;
  if not (app.is_internal() and (app.has_perm('attendance.approve') or app.is_manager_of(c.employee_id))) then
    raise exception 'Not authorized to decide this correction' using errcode='42501'; end if;
  update public.attendance_corrections set status = case when p_approve then 'approved' else 'rejected' end,
         decided_by = auth.uid(), decided_at = now(), decision_note = p_note
   where id = c.id returning * into c;
  if p_approve then
    s := app.employee_schedule(c.employee_id);
    insert into public.attendance_records(org_id, employee_id, work_date, schedule_id, check_in_at, check_out_at, source)
    values (c.org_id, c.employee_id, c.work_date, s.id, c.requested_check_in, c.requested_check_out, 'correction')
    on conflict (employee_id, work_date) do update
      set check_in_at = excluded.check_in_at, check_out_at = excluded.check_out_at, source = 'correction'
    returning * into r;
    update public.attendance_breaks set end_at = coalesce(end_at, c.requested_check_out) where record_id = r.id;
    perform app.recompute_attendance(r.id);
  end if;
  return c;
end $$;

-- ---------- leave ----------
create table public.leave_types (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  code text not null check (code ~ '^[A-Z]{1,6}$'),
  name text not null,
  annual_quota numeric(5,1) check (annual_quota is null or annual_quota >= 0),  -- null = unlimited
  is_paid boolean not null default true,
  allow_half_day boolean not null default true,
  approval_levels smallint not null default 1 check (approval_levels between 1 and 3),
  max_consecutive_days smallint check (max_consecutive_days is null or max_consecutive_days > 0),
  color text not null default '#64748b',
  is_active boolean not null default true,
  unique (org_id, code)
);

create table public.leave_balances (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  employee_id uuid not null references public.employee_profiles(id) on delete cascade,
  leave_type_id uuid not null references public.leave_types(id) on delete restrict,
  year smallint not null check (year between 2000 and 2100),
  allocated numeric(5,1) not null default 0 check (allocated >= 0),
  adjusted numeric(5,1) not null default 0,
  used numeric(5,1) not null default 0 check (used >= 0),
  unique (employee_id, leave_type_id, year)
);
create trigger trg_audit after insert or update or delete on public.leave_balances for each row execute function app.audit();

create table public.leave_requests (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  employee_id uuid not null references public.employee_profiles(id) on delete restrict,
  leave_type_id uuid not null references public.leave_types(id) on delete restrict,
  start_date date not null,
  end_date date not null,
  half_day text not null default 'none' check (half_day in ('none','first_half','second_half')),
  days numeric(5,1) not null check (days > 0),
  reason text,
  status text not null default 'pending' check (status in ('pending','approved','rejected','cancelled')),
  current_level smallint not null default 1,
  required_levels smallint not null default 1,
  created_at timestamptz not null default now(),
  decided_at timestamptz,
  check (end_date >= start_date),
  check (half_day = 'none' or start_date = end_date)
);
create index on public.leave_requests(org_id, status);
create index on public.leave_requests(employee_id, start_date);
create trigger trg_audit after insert or update or delete on public.leave_requests for each row execute function app.audit();

create table public.leave_approvals (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  request_id uuid not null references public.leave_requests(id) on delete cascade,
  level smallint not null,
  approver_id uuid not null references public.profiles(id) on delete restrict,
  decision text not null check (decision in ('approved','rejected')),
  note text,
  decided_at timestamptz not null default now(),
  unique (request_id, level)
);

create or replace function app.is_working_day(p_employee uuid, p_day date) returns boolean
language sql stable security definer set search_path = '' as $$
  select not (extract(isodow from p_day)::smallint = any (coalesce((app.employee_schedule(p_employee)).weekly_offs, '{7}')))
     and not exists (select 1 from public.holidays h join public.employee_profiles e on e.org_id = h.org_id
                     where e.id = p_employee and h.holiday_date = p_day and not h.is_optional)
$$;

create or replace function app.count_leave_days(p_employee uuid, p_start date, p_end date, p_half text)
returns numeric language sql stable security definer set search_path = '' as $$
  select case when p_half <> 'none'
              then case when app.is_working_day(p_employee, p_start) then 0.5 else 0 end
              else (select count(*)::numeric from generate_series(p_start, p_end, interval '1 day') d
                    where app.is_working_day(p_employee, d::date)) end
$$;

create or replace function public.preview_leave_days(p_start date, p_end date, p_half text default 'none')
returns numeric language sql stable security definer set search_path = '' as $$
  select app.count_leave_days(app.my_employee_id(), p_start, p_end, p_half)
$$;

create or replace function app.ensure_leave_balance(p_employee uuid, p_type uuid, p_year int) returns public.leave_balances
language plpgsql security definer set search_path = '' as $$
declare b public.leave_balances; t public.leave_types;
begin
  select * into t from public.leave_types where id = p_type;
  insert into public.leave_balances(org_id, employee_id, leave_type_id, year, allocated)
  values (t.org_id, p_employee, p_type, p_year, coalesce(t.annual_quota, 0))
  on conflict (employee_id, leave_type_id, year) do nothing;
  select * into b from public.leave_balances where employee_id = p_employee and leave_type_id = p_type and year = p_year for update;
  return b;
end $$;

create or replace function public.apply_leave(p_leave_type uuid, p_start date, p_end date,
  p_half text default 'none', p_reason text default null)
returns public.leave_requests
language plpgsql security definer set search_path = '' as $$
declare e public.employee_profiles; t public.leave_types; v_days numeric; b public.leave_balances;
        v_pending numeric; r public.leave_requests;
begin
  e := app.require_active_employee();
  select * into t from public.leave_types where id = p_leave_type and org_id = e.org_id and is_active;
  if t.id is null then raise exception 'Leave type not available' using errcode='P0002'; end if;
  if p_half not in ('none','first_half','second_half') then raise exception 'Invalid half-day value' using errcode='22023'; end if;
  if p_half <> 'none' and (not t.allow_half_day or p_start <> p_end) then
    raise exception 'Half-day leave must be a single day on a leave type that allows it' using errcode='22023'; end if;
  if p_end < p_start then raise exception 'End date is before start date' using errcode='22023'; end if;
  if extract(year from p_start) <> extract(year from p_end) then
    raise exception 'Leave spanning two calendar years must be split into two requests' using errcode='22023'; end if;
  if t.max_consecutive_days is not null and (p_end - p_start + 1) > t.max_consecutive_days then
    raise exception 'This leave type allows at most % consecutive days', t.max_consecutive_days using errcode='22023'; end if;
  v_days := app.count_leave_days(e.id, p_start, p_end, p_half);
  if v_days <= 0 then raise exception 'The selected dates contain no working days' using errcode='22023'; end if;

  perform pg_advisory_xact_lock(hashtextextended(e.id::text, 0));
  if exists (select 1 from public.leave_requests x
             where x.employee_id = e.id and x.status in ('pending','approved')
               and daterange(x.start_date, x.end_date, '[]') && daterange(p_start, p_end, '[]')
               and not (x.half_day <> 'none' and p_half <> 'none' and x.half_day <> p_half)) then
    raise exception 'These dates overlap an existing leave request' using errcode='23P01'; end if;

  if t.annual_quota is not null then
    b := app.ensure_leave_balance(e.id, t.id, extract(year from p_start)::int);
    select coalesce(sum(days),0) into v_pending from public.leave_requests
     where employee_id = e.id and leave_type_id = t.id and status = 'pending'
       and extract(year from start_date) = b.year;
    if b.allocated + b.adjusted - b.used - v_pending < v_days then
      raise exception 'Insufficient balance: % day(s) available', (b.allocated + b.adjusted - b.used - v_pending) using errcode='22023';
    end if;
  end if;

  insert into public.leave_requests(org_id, employee_id, leave_type_id, start_date, end_date, half_day, days, reason, required_levels)
  values (e.org_id, e.id, t.id, p_start, p_end, p_half, v_days, nullif(trim(p_reason),''), t.approval_levels)
  returning * into r;
  return r;
end $$;

create or replace function public.decide_leave(p_id uuid, p_approve boolean, p_note text default null)
returns public.leave_requests
language plpgsql security definer set search_path = '' as $$
declare r public.leave_requests; t public.leave_types; b public.leave_balances;
begin
  select * into r from public.leave_requests where id = p_id and org_id = app.org_id() for update;
  if r.id is null then raise exception 'Leave request not found' using errcode='P0002'; end if;
  if r.status <> 'pending' then raise exception 'Leave request already decided' using errcode='22023'; end if;
  if not app.is_internal() or r.employee_id = app.my_employee_id() then
    raise exception 'You cannot decide this request' using errcode='42501'; end if;
  if r.current_level = 1 then
    if not (app.has_perm('leave.approve') or app.is_manager_of(r.employee_id)) then
      raise exception 'Not authorized to approve this request' using errcode='42501'; end if;
  else
    if not app.has_perm('leave.approve') then raise exception 'Not authorized for this approval level' using errcode='42501'; end if;
    if exists (select 1 from public.leave_approvals where request_id = r.id and approver_id = auth.uid()) then
      raise exception 'The same person cannot approve more than one level' using errcode='42501'; end if;
  end if;

  insert into public.leave_approvals(org_id, request_id, level, approver_id, decision, note)
  values (r.org_id, r.id, r.current_level, auth.uid(), case when p_approve then 'approved' else 'rejected' end, p_note);

  if not p_approve then
    update public.leave_requests set status = 'rejected', decided_at = now() where id = r.id returning * into r;
  elsif r.current_level >= r.required_levels then
    select * into t from public.leave_types where id = r.leave_type_id;
    if t.annual_quota is not null then
      b := app.ensure_leave_balance(r.employee_id, r.leave_type_id, extract(year from r.start_date)::int);
      update public.leave_balances set used = used + r.days where id = b.id;
    end if;
    update public.leave_requests set status = 'approved', decided_at = now() where id = r.id returning * into r;
  else
    update public.leave_requests set current_level = current_level + 1 where id = r.id returning * into r;
  end if;
  return r;
end $$;

create or replace function public.cancel_leave(p_id uuid) returns public.leave_requests
language plpgsql security definer set search_path = '' as $$
declare r public.leave_requests; t public.leave_types; tz text; v_own boolean;
begin
  select * into r from public.leave_requests where id = p_id and org_id = app.org_id() for update;
  if r.id is null then raise exception 'Leave request not found' using errcode='P0002'; end if;
  select timezone into tz from public.organizations where id = r.org_id;
  v_own := r.employee_id = app.my_employee_id();
  if r.status not in ('pending','approved') then raise exception 'Only pending or approved leave can be cancelled' using errcode='22023'; end if;
  if not (app.has_perm('leave.approve')
          or (v_own and (r.status = 'pending' or r.start_date > (now() at time zone tz)::date))) then
    raise exception 'Not allowed to cancel this leave' using errcode='42501'; end if;
  if r.status = 'approved' then
    select * into t from public.leave_types where id = r.leave_type_id;
    if t.annual_quota is not null then
      update public.leave_balances set used = greatest(0, used - r.days)
       where employee_id = r.employee_id and leave_type_id = r.leave_type_id and year = extract(year from r.start_date);
    end if;
  end if;
  update public.leave_requests set status = 'cancelled', decided_at = now() where id = r.id returning * into r;
  return r;
end $$;

create or replace function public.allocate_leave_balances(p_year int) returns integer
language plpgsql security definer set search_path = '' as $$
declare v_count int;
begin
  if not app.has_perm('leave.manage_policy') then raise exception 'Not authorized' using errcode='42501'; end if;
  insert into public.leave_balances(org_id, employee_id, leave_type_id, year, allocated)
  select e.org_id, e.id, t.id, p_year, t.annual_quota
    from public.employee_profiles e
    join public.leave_types t on t.org_id = e.org_id and t.is_active and t.annual_quota is not null
   where e.org_id = app.org_id() and e.status <> 'exited'
  on conflict (employee_id, leave_type_id, year) do nothing;
  get diagnostics v_count = row_count;
  return v_count;
end $$;

-- ---------- RLS ----------
alter table public.work_schedules enable row level security;
alter table public.holidays enable row level security;
alter table public.employee_profiles enable row level security;
alter table public.employee_private enable row level security;
alter table public.employment_documents enable row level security;
alter table public.salary_components enable row level security;
alter table public.salary_revisions enable row level security;
alter table public.attendance_records enable row level security;
alter table public.attendance_breaks enable row level security;
alter table public.attendance_corrections enable row level security;
alter table public.leave_types enable row level security;
alter table public.leave_balances enable row level security;
alter table public.leave_requests enable row level security;
alter table public.leave_approvals enable row level security;

create policy ws_select on public.work_schedules for select to authenticated using (org_id = (select app.org_id()) and (select app.is_internal()));
create policy ws_write on public.work_schedules for all to authenticated
  using (org_id = (select app.org_id()) and (select app.has_perm('attendance.manage_policy')))
  with check (org_id = (select app.org_id()) and (select app.has_perm('attendance.manage_policy')));

create policy hol_select on public.holidays for select to authenticated using (org_id = (select app.org_id()) and (select app.is_internal()));
create policy hol_write on public.holidays for all to authenticated
  using (org_id = (select app.org_id()) and (select app.has_perm('holidays.manage')))
  with check (org_id = (select app.org_id()) and (select app.has_perm('holidays.manage')));

create policy emp_select on public.employee_profiles for select to authenticated using (
  org_id = (select app.org_id()) and (select app.is_internal())
  and ((select app.has_perm('employees.view')) or id = (select app.my_employee_id()) or app.is_manager_of(id)));
create policy emp_insert on public.employee_profiles for insert to authenticated
  with check (org_id = (select app.org_id()) and (select app.has_perm('employees.create')));
create policy emp_update on public.employee_profiles for update to authenticated
  using (org_id = (select app.org_id()) and (select app.has_perm('employees.edit')))
  with check (org_id = (select app.org_id()) and (select app.has_perm('employees.edit')));
create policy emp_delete on public.employee_profiles for delete to authenticated
  using (org_id = (select app.org_id()) and (select app.has_perm('employees.delete')));

create policy emp_priv_select on public.employee_private for select to authenticated using (
  org_id = (select app.org_id()) and (employee_id = (select app.my_employee_id()) or (select app.has_perm('employees.view_sensitive'))));
create policy emp_priv_write on public.employee_private for all to authenticated
  using (org_id = (select app.org_id()) and (employee_id = (select app.my_employee_id())
         or ((select app.has_perm('employees.view_sensitive')) and (select app.has_perm('employees.edit')))))
  with check (org_id = (select app.org_id()) and (employee_id = (select app.my_employee_id())
         or ((select app.has_perm('employees.view_sensitive')) and (select app.has_perm('employees.edit')))));

create policy emp_docs_select on public.employment_documents for select to authenticated using (
  org_id = (select app.org_id()) and (employee_id = (select app.my_employee_id()) or (select app.has_perm('employees.view_sensitive'))));
create policy emp_docs_write on public.employment_documents for insert to authenticated
  with check (org_id = (select app.org_id()) and (select app.has_perm('employees.view_sensitive')) and (select app.has_perm('employees.edit')));
create policy emp_docs_delete on public.employment_documents for delete to authenticated
  using (org_id = (select app.org_id()) and (select app.has_perm('employees.view_sensitive')) and (select app.has_perm('employees.edit')));

create policy salcomp_select on public.salary_components for select to authenticated using (
  org_id = (select app.org_id()) and (select app.is_internal()));
create policy salcomp_write on public.salary_components for all to authenticated
  using (org_id = (select app.org_id()) and (select app.has_perm('salary.edit')))
  with check (org_id = (select app.org_id()) and (select app.has_perm('salary.edit')));

create policy salrev_select on public.salary_revisions for select to authenticated using (
  org_id = (select app.org_id()) and (employee_id = (select app.my_employee_id()) or (select app.has_perm('salary.view'))));
create policy salrev_insert on public.salary_revisions for insert to authenticated
  with check (org_id = (select app.org_id()) and (select app.has_perm('salary.edit')) and created_by = auth.uid());

create policy att_select on public.attendance_records for select to authenticated using (
  org_id = (select app.org_id()) and app.can_see_employee(employee_id, 'attendance.view_all'));
create policy attb_select on public.attendance_breaks for select to authenticated using (
  org_id = (select app.org_id()) and exists (select 1 from public.attendance_records r where r.id = record_id
    and app.can_see_employee(r.employee_id, 'attendance.view_all')));
create policy attc_select on public.attendance_corrections for select to authenticated using (
  org_id = (select app.org_id()) and app.can_see_employee(employee_id, 'attendance.view_all'));

create policy lt_select on public.leave_types for select to authenticated using (org_id = (select app.org_id()) and (select app.is_internal()));
create policy lt_write on public.leave_types for all to authenticated
  using (org_id = (select app.org_id()) and (select app.has_perm('leave.manage_policy')))
  with check (org_id = (select app.org_id()) and (select app.has_perm('leave.manage_policy')));

create policy lb_select on public.leave_balances for select to authenticated using (
  org_id = (select app.org_id()) and app.can_see_employee(employee_id, 'leave.view_all'));
create policy lb_update on public.leave_balances for update to authenticated
  using (org_id = (select app.org_id()) and (select app.has_perm('leave.manage_policy')))
  with check (org_id = (select app.org_id()) and (select app.has_perm('leave.manage_policy')));

create policy lr_select on public.leave_requests for select to authenticated using (
  org_id = (select app.org_id()) and app.can_see_employee(employee_id, 'leave.view_all'));
create policy la_select on public.leave_approvals for select to authenticated using (
  org_id = (select app.org_id()) and exists (select 1 from public.leave_requests r where r.id = request_id
    and app.can_see_employee(r.employee_id, 'leave.view_all')));

-- ---------- grants ----------
grant select on public.work_schedules, public.holidays, public.employee_profiles, public.employee_private,
  public.employment_documents, public.salary_components, public.salary_revisions, public.attendance_records,
  public.attendance_breaks, public.attendance_corrections, public.leave_types, public.leave_balances,
  public.leave_requests, public.leave_approvals to authenticated;
grant insert, update, delete on public.work_schedules, public.holidays, public.employee_profiles,
  public.employee_private, public.salary_components, public.leave_types to authenticated;
grant insert, delete on public.employment_documents to authenticated;
grant insert on public.salary_revisions to authenticated;
grant update (allocated, adjusted) on public.leave_balances to authenticated;

revoke execute on all functions in schema app from public, anon;
grant execute on all functions in schema app to authenticated, service_role;
do $$ declare f text; begin
  foreach f in array array['attendance_check_in()','attendance_check_out()','attendance_break_start()','attendance_break_end()',
    'request_attendance_correction(date,timestamptz,timestamptz,text)','decide_attendance_correction(uuid,boolean,text)',
    'preview_leave_days(date,date,text)','apply_leave(uuid,date,date,text,text)','decide_leave(uuid,boolean,text)',
    'cancel_leave(uuid)','allocate_leave_balances(integer)'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop; end $$;

-- ===== 20261026000003_clients_projects_tasks.sql =====
-- =====================================================================
-- 0003 CLIENTS, PROJECTS, TASKS
-- =====================================================================

-- ---------- clients ----------
create type public.client_status as enum ('lead','onboarding','active','paused','churned');
create type public.service_type as enum ('seo','google_ads','meta_ads','social_media','website_development','local_seo','youtube','email_marketing','other');

create table public.clients (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete restrict,
  name text not null check (length(trim(name)) between 2 and 160),
  legal_name text,
  industry text,
  website text,
  city text,
  status public.client_status not null default 'onboarding',
  account_manager_id uuid references public.employee_profiles(id) on delete set null,
  brand_guidelines text,
  onboarded_at date,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (org_id, name),
  unique (org_id, id)
);
create index on public.clients(org_id, status);
create index on public.clients(account_manager_id);
create trigger trg_clients_touch before update on public.clients for each row execute function app.touch_updated_at();
create trigger trg_audit after insert or update or delete on public.clients for each row execute function app.audit();

alter table public.profiles add constraint profiles_client_fk
  foreign key (client_id) references public.clients(id) on delete restrict;

create table public.client_contacts (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  client_id uuid not null references public.clients(id) on delete cascade,
  name text not null,
  designation text,
  email text check (email is null or email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  phone text,
  is_primary boolean not null default false,
  created_at timestamptz not null default now()
);
create index on public.client_contacts(client_id);
create unique index client_one_primary_contact on public.client_contacts(client_id) where is_primary;

create table public.client_services (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  client_id uuid not null references public.clients(id) on delete cascade,
  service public.service_type not null,
  description text,
  start_date date,
  end_date date,
  status text not null default 'active' check (status in ('active','paused','ended')),
  check (end_date is null or start_date is null or end_date >= start_date)
);
create index on public.client_services(client_id);

create table public.client_billing (
  client_id uuid primary key references public.clients(id) on delete cascade,
  org_id uuid not null references public.organizations(id) on delete cascade,
  billing_name text,
  billing_email text,
  gst_number text check (gst_number is null or gst_number ~ '^[0-9A-Z]{15}$'),
  billing_address text,
  payment_terms_days smallint not null default 15 check (payment_terms_days between 0 and 180),
  currency char(3) not null default 'INR',
  updated_at timestamptz not null default now()
);
create trigger trg_audit after insert or update or delete on public.client_billing for each row execute function app.audit();

create table public.contracts (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  client_id uuid not null references public.clients(id) on delete restrict,
  title text not null,
  start_date date not null,
  end_date date,
  billing_cycle text not null default 'monthly' check (billing_cycle in ('one_time','monthly','quarterly','yearly')),
  management_fee numeric(14,2) not null default 0 check (management_fee >= 0),  -- agency fee, separate from ad spend
  auto_renew boolean not null default false,
  renewal_reminder_days smallint not null default 30 check (renewal_reminder_days between 0 and 365),
  status text not null default 'active' check (status in ('draft','active','expired','terminated')),
  notes text,
  created_at timestamptz not null default now(),
  check (end_date is null or end_date >= start_date)
);
create index on public.contracts(client_id);
create index on public.contracts(org_id, end_date) where status = 'active';
create trigger trg_audit after insert or update or delete on public.contracts for each row execute function app.audit();

create table public.client_notes (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  client_id uuid not null references public.clients(id) on delete cascade,
  author_id uuid not null references public.profiles(id) on delete restrict,
  channel text not null default 'note' check (channel in ('note','call','meeting','email','whatsapp')),
  body text not null check (length(trim(body)) > 0),
  created_at timestamptz not null default now()
);
create index on public.client_notes(client_id, created_at desc);

create table public.client_onboarding_items (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  client_id uuid not null references public.clients(id) on delete cascade,
  title text not null,
  position smallint not null default 0,
  done_at timestamptz,
  done_by uuid references public.profiles(id) on delete set null,
  unique (client_id, title)
);

-- client-portal user invitations / employee invitations
create table public.invitations (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  email text not null check (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  role_id uuid not null references public.roles(id) on delete cascade,
  client_id uuid references public.clients(id) on delete cascade,
  employee_id uuid references public.employee_profiles(id) on delete cascade,
  invited_by uuid references public.profiles(id) on delete set null,
  expires_at timestamptz not null default now() + interval '14 days',
  accepted_at timestamptz,
  created_at timestamptz not null default now(),
  check (client_id is null or employee_id is null)
);
create unique index invitations_one_open on public.invitations(org_id, lower(email)) where accepted_at is null;

-- ---------- visibility helpers ----------
create or replace function app.can_view_client(p_client uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.clients c where c.id = p_client and c.org_id = app.org_id()
    and ((app.is_internal() and (app.has_perm('clients.view') or c.account_manager_id = app.my_employee_id()))
         or c.id = app.client_id()))
$$;

-- ---------- projects ----------
create type public.project_status as enum ('planning','active','on_hold','completed','cancelled');
create type public.priority as enum ('low','medium','high','urgent');

create table public.projects (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete restrict,
  client_id uuid references public.clients(id) on delete restrict,
  parent_project_id uuid references public.projects(id) on delete restrict,
  name text not null check (length(trim(name)) between 2 and 160),
  description text,
  service public.service_type,
  owner_id uuid references public.profiles(id) on delete set null,
  status public.project_status not null default 'planning',
  priority public.priority not null default 'medium',
  start_date date,
  due_date date,
  budget_amount numeric(14,2) check (budget_amount is null or budget_amount >= 0),
  client_visible boolean not null default false,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (due_date is null or start_date is null or due_date >= start_date),
  check (parent_project_id is null or parent_project_id <> id)
);
create index on public.projects(org_id, status);
create index on public.projects(client_id);
create index on public.projects(owner_id);
create trigger trg_projects_touch before update on public.projects for each row execute function app.touch_updated_at();
create trigger trg_audit after insert or update or delete on public.projects for each row execute function app.audit();

create type public.project_role as enum ('manager','member','viewer');
create table public.project_members (
  project_id uuid not null references public.projects(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  org_id uuid not null references public.organizations(id) on delete cascade,
  project_role public.project_role not null default 'member',
  added_at timestamptz not null default now(),
  primary key (project_id, profile_id)
);
create index on public.project_members(profile_id);

create table public.project_milestones (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  project_id uuid not null references public.projects(id) on delete cascade,
  title text not null,
  due_date date,
  completed_at timestamptz,
  client_visible boolean not null default true,
  position smallint not null default 0
);
create index on public.project_milestones(project_id);

create or replace function app.project_role_of_me(p_project uuid) returns public.project_role
language sql stable security definer set search_path = '' as $$
  select case when p.owner_id = auth.uid() then 'manager'::public.project_role else pm.project_role end
  from public.projects p left join public.project_members pm on pm.project_id = p.id and pm.profile_id = auth.uid()
  where p.id = p_project and p.org_id = app.org_id() and app.is_internal()
$$;

create or replace function app.is_project_member(p_project uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.project_members where project_id = p_project and profile_id = auth.uid())
$$;

create or replace function app.project_client_visible(p_project uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select client_visible from public.projects where id = p_project), false)
$$;

create or replace function app.can_view_project(p_project uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.projects p where p.id = p_project and p.org_id = app.org_id()
    and ((app.is_internal() and (app.has_perm('projects.view_all') or app.project_role_of_me(p.id) is not null))
         or (p.client_visible and p.client_id is not null and p.client_id = app.client_id())))
$$;

create or replace function app.can_manage_project(p_project uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select app.is_internal() and (app.has_perm('projects.edit') or app.project_role_of_me(p_project) = 'manager')
$$;

create or replace function app.project_before_write() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.client_id is not null and not exists (select 1 from public.clients where id = new.client_id and org_id = new.org_id) then
    raise exception 'Client must belong to the same organization' using errcode='23514'; end if;
  if new.parent_project_id is not null and not exists
     (select 1 from public.projects where id = new.parent_project_id and org_id = new.org_id and parent_project_id is null) then
    raise exception 'Parent project must be a top-level project of the same organization' using errcode='23514'; end if;
  if new.owner_id is not null and not exists
     (select 1 from public.profiles where id = new.owner_id and org_id = new.org_id and client_id is null) then
    raise exception 'Owner must be an internal user' using errcode='23514'; end if;
  return new;
end $$;
create trigger trg_project_before before insert or update on public.projects for each row execute function app.project_before_write();

create or replace function app.member_before_write() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  new.org_id := (select org_id from public.projects where id = new.project_id);
  if not exists (select 1 from public.profiles where id = new.profile_id and org_id = new.org_id and client_id is null) then
    raise exception 'Project members must be internal users of the same organization' using errcode='23514'; end if;
  return new;
end $$;
create trigger trg_member_before before insert or update on public.project_members for each row execute function app.member_before_write();

-- ---------- tasks ----------
create type public.status_category as enum ('todo','in_progress','review','changes_requested','done','cancelled');

create table public.task_statuses (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  key text not null check (key ~ '^[a-z_]{2,30}$'),
  name text not null,
  category public.status_category not null,
  position smallint not null default 0,
  color text not null default '#64748b',
  is_default boolean not null default false,
  unique (org_id, key)
);
create unique index task_status_one_default on public.task_statuses(org_id) where is_default;

create table public.tasks (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete restrict,
  project_id uuid not null references public.projects(id) on delete cascade,
  client_id uuid references public.clients(id) on delete restrict,   -- denormalised from project, maintained by trigger
  parent_task_id uuid references public.tasks(id) on delete cascade,
  title text not null check (length(trim(title)) between 2 and 200),
  description text,
  status_id uuid not null references public.task_statuses(id) on delete restrict,
  priority public.priority not null default 'medium',
  reviewer_id uuid references public.profiles(id) on delete set null,
  start_date date,
  due_date date,
  estimated_minutes integer check (estimated_minutes is null or estimated_minutes between 0 and 100000),
  position double precision not null default 0,
  client_visible boolean not null default false,
  created_by uuid references public.profiles(id) on delete set null,
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (due_date is null or start_date is null or due_date >= start_date),
  check (parent_task_id is null or parent_task_id <> id)
);
create index on public.tasks(org_id, due_date);
create index on public.tasks(project_id, status_id);
create index on public.tasks(parent_task_id);
create index on public.tasks(reviewer_id);
create index on public.tasks(client_id);
create trigger trg_tasks_touch before update on public.tasks for each row execute function app.touch_updated_at();
create trigger trg_audit after insert or update or delete on public.tasks for each row execute function app.audit();

create table public.task_assignees (
  task_id uuid not null references public.tasks(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  org_id uuid not null references public.organizations(id) on delete cascade,
  assigned_by uuid references public.profiles(id) on delete set null,
  assigned_at timestamptz not null default now(),
  primary key (task_id, profile_id)
);
create index on public.task_assignees(profile_id);
create trigger trg_audit after insert or delete on public.task_assignees for each row execute function app.audit();

create table public.task_dependencies (
  task_id uuid not null references public.tasks(id) on delete cascade,
  depends_on_task_id uuid not null references public.tasks(id) on delete cascade,
  org_id uuid not null references public.organizations(id) on delete cascade,
  primary key (task_id, depends_on_task_id),
  check (task_id <> depends_on_task_id)
);

create table public.task_comments (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  task_id uuid not null references public.tasks(id) on delete cascade,
  author_id uuid not null references public.profiles(id) on delete restrict,
  body text not null check (length(trim(body)) between 1 and 10000),
  is_internal boolean not null default true,
  created_at timestamptz not null default now(),
  edited_at timestamptz
);
create index on public.task_comments(task_id, created_at);

create table public.task_comment_mentions (
  comment_id uuid not null references public.task_comments(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  org_id uuid not null references public.organizations(id) on delete cascade,
  primary key (comment_id, profile_id)
);

create table public.task_attachments (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  task_id uuid not null references public.tasks(id) on delete cascade,
  file_name text not null,
  storage_path text not null unique,       -- {org_id}/tasks/{task_id}/{uuid}-{file}
  size_bytes bigint check (size_bytes between 0 and 52428800),
  mime_type text,
  is_internal boolean not null default true,
  uploaded_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
create index on public.task_attachments(task_id);

-- helpers (security definer -> no RLS recursion between tasks and task_assignees)
create or replace function app.is_task_assignee(p_task uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.task_assignees where task_id = p_task and profile_id = auth.uid())
$$;

create or replace function app.can_view_task(p_task uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.tasks t where t.id = p_task and t.org_id = app.org_id() and (
     (app.is_internal() and (app.has_perm('tasks.view_all') or app.project_role_of_me(t.project_id) is not null
        or t.reviewer_id = auth.uid() or t.created_by = auth.uid() or app.is_task_assignee(t.id)))
     or (t.client_visible and t.client_id is not null and t.client_id = app.client_id()
         and exists (select 1 from public.projects p where p.id = t.project_id and p.client_visible))))
$$;

create or replace function app.can_edit_task(p_task uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.tasks t where t.id = p_task and t.org_id = app.org_id() and app.is_internal() and (
    app.has_perm('tasks.edit_all') or app.project_role_of_me(t.project_id) = 'manager'
    or t.reviewer_id = auth.uid() or app.is_task_assignee(t.id) or t.created_by = auth.uid()))
$$;

create or replace function app.status_category(p_status uuid) returns public.status_category
language sql stable security definer set search_path = '' as $$ select category from public.task_statuses where id = p_status $$;

create or replace function app.task_before_write() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_proj public.projects; v_old_cat public.status_category; v_new_cat public.status_category;
begin
  select * into v_proj from public.projects where id = new.project_id;
  if v_proj.org_id is distinct from new.org_id then raise exception 'Project must belong to the same organization' using errcode='23514'; end if;
  new.client_id := v_proj.client_id;
  if tg_op = 'UPDATE' and new.project_id <> old.project_id and auth.uid() is not null
     and not (app.can_manage_project(old.project_id) and app.can_manage_project(new.project_id)) then
    raise exception 'Only project managers can move tasks between projects' using errcode='42501'; end if;
  if new.status_id is null then
    select id into new.status_id from public.task_statuses where org_id = new.org_id and is_default;
  end if;
  if not exists (select 1 from public.task_statuses where id = new.status_id and org_id = new.org_id) then
    raise exception 'Invalid status' using errcode='23514'; end if;
  if new.parent_task_id is not null and not exists
     (select 1 from public.tasks where id = new.parent_task_id and project_id = new.project_id and parent_task_id is null) then
    raise exception 'Subtasks must belong to a top-level task in the same project' using errcode='23514'; end if;
  if new.reviewer_id is not null and not exists
     (select 1 from public.profiles where id = new.reviewer_id and org_id = new.org_id and client_id is null) then
    raise exception 'Reviewer must be an internal user' using errcode='23514'; end if;

  v_new_cat := app.status_category(new.status_id);
  v_old_cat := case when tg_op = 'UPDATE' then app.status_category(old.status_id) end;

  if tg_op = 'UPDATE' and new.status_id <> old.status_id and auth.uid() is not null then
    if v_new_cat in ('done','changes_requested') and old.reviewer_id is not null
       and old.reviewer_id <> auth.uid() and not app.has_perm('tasks.edit_all') then
      raise exception 'Only the reviewer can approve or request changes on this task' using errcode='42501'; end if;
    if v_new_cat = 'done' and old.reviewer_id is not null and v_old_cat <> 'review' then
      raise exception 'This task must be reviewed before it can be completed' using errcode='22023'; end if;
    if v_new_cat = 'changes_requested' and v_old_cat <> 'review' then
      raise exception 'Changes can only be requested on a task in review' using errcode='22023'; end if;
  end if;

  if v_new_cat = 'done' and (tg_op = 'INSERT' or v_old_cat <> 'done') then
    if exists (select 1 from public.task_dependencies d join public.tasks dt on dt.id = d.depends_on_task_id
               where d.task_id = new.id and app.status_category(dt.status_id) not in ('done','cancelled')) then
      raise exception 'Complete the tasks this one depends on first' using errcode='22023'; end if;
    if exists (select 1 from public.tasks s where s.parent_task_id = new.id
               and app.status_category(s.status_id) not in ('done','cancelled')) then
      raise exception 'Complete or cancel all subtasks first' using errcode='22023'; end if;
    new.completed_at := now();
  elsif v_new_cat <> 'done' then
    new.completed_at := null;
  end if;
  return new;
end $$;
create trigger trg_task_before before insert or update on public.tasks for each row execute function app.task_before_write();

create or replace function app.task_child_before_write() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  new.org_id := (select org_id from public.tasks where id = new.task_id);
  return new;
end $$;
create trigger trg_assignee_org before insert on public.task_assignees for each row execute function app.task_child_before_write();
create trigger trg_dep_org before insert on public.task_dependencies for each row execute function app.task_child_before_write();
create trigger trg_comment_org before insert on public.task_comments for each row execute function app.task_child_before_write();
create trigger trg_attach_org before insert on public.task_attachments for each row execute function app.task_child_before_write();

create or replace function app.assignee_validate() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.profiles where id = new.profile_id and org_id = new.org_id and client_id is null and is_active) then
    raise exception 'Assignee must be an active internal user of the same organization' using errcode='23514'; end if;
  return new;
end $$;
create trigger trg_assignee_validate before insert on public.task_assignees for each row execute function app.assignee_validate();

create or replace function app.dependency_validate() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.tasks where id = new.depends_on_task_id and org_id = new.org_id) then
    raise exception 'Dependency must be in the same organization' using errcode='23514'; end if;
  if exists (with recursive chain(id) as (
                select new.depends_on_task_id
                union
                select d.depends_on_task_id from public.task_dependencies d join chain c on d.task_id = c.id)
             select 1 from chain where id = new.task_id) then
    raise exception 'This dependency would create a cycle' using errcode='23514'; end if;
  return new;
end $$;
create trigger trg_dep_validate before insert on public.task_dependencies for each row execute function app.dependency_validate();

-- client users can only post client-visible comments
create or replace function app.comment_before_write() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if not app.is_internal() and auth.uid() is not null then new.is_internal := false; end if;
  if tg_op = 'UPDATE' then
    if new.author_id <> old.author_id or new.task_id <> old.task_id then raise exception 'Immutable fields' using errcode='42501'; end if;
    new.edited_at := now();
  end if;
  return new;
end $$;
create trigger trg_comment_before before insert or update on public.task_comments for each row execute function app.comment_before_write();

-- ---------- project progress (rule documented in docs/PHASE1_PLAN.md §10.9) ----------
create or replace function app.project_progress(p_project uuid,
  out total_tasks int, out completed_tasks int, out progress_pct numeric)
language sql stable security definer set search_path = '' as $$
  with t as (
    select ts.category, t.estimated_minutes from public.tasks t join public.task_statuses ts on ts.id = t.status_id
    where t.project_id = p_project and t.parent_task_id is null and ts.category <> 'cancelled')
  select count(*)::int, count(*) filter (where category = 'done')::int,
    case when count(*) = 0 then 0
         when bool_and(estimated_minutes is not null and estimated_minutes > 0)
           then round(100.0 * coalesce(sum(estimated_minutes) filter (where category = 'done'),0) / sum(estimated_minutes), 1)
         else round(100.0 * count(*) filter (where category = 'done') / count(*), 1) end
  from t
$$;

create view public.project_overview with (security_invoker = true) as
  select p.*, pp.total_tasks, pp.completed_tasks, pp.progress_pct, c.name as client_name
  from public.projects p
  cross join lateral app.project_progress(p.id) pp
  left join public.clients c on c.id = p.client_id;

-- ---------- RLS ----------
alter table public.clients enable row level security;
alter table public.client_contacts enable row level security;
alter table public.client_services enable row level security;
alter table public.client_billing enable row level security;
alter table public.contracts enable row level security;
alter table public.client_notes enable row level security;
alter table public.client_onboarding_items enable row level security;
alter table public.invitations enable row level security;
alter table public.projects enable row level security;
alter table public.project_members enable row level security;
alter table public.project_milestones enable row level security;
alter table public.task_statuses enable row level security;
alter table public.tasks enable row level security;
alter table public.task_assignees enable row level security;
alter table public.task_dependencies enable row level security;
alter table public.task_comments enable row level security;
alter table public.task_comment_mentions enable row level security;
alter table public.task_attachments enable row level security;

-- NOTE: select policies on clients/projects/tasks use the row's own columns (never re-query the same
-- table by id) so INSERT ... RETURNING through the API can see the row it just created.
create policy clients_select on public.clients for select to authenticated using (
  org_id = (select app.org_id()) and (
    ((select app.is_internal()) and ((select app.has_perm('clients.view')) or account_manager_id = (select app.my_employee_id())
                                     or created_by = auth.uid()))
    or id = (select app.client_id())));
create policy clients_insert on public.clients for insert to authenticated
  with check (org_id = (select app.org_id()) and (select app.has_perm('clients.create')));
create policy clients_update on public.clients for update to authenticated
  using (org_id = (select app.org_id()) and (select app.has_perm('clients.edit')))
  with check (org_id = (select app.org_id()) and (select app.has_perm('clients.edit')));
create policy clients_delete on public.clients for delete to authenticated
  using (org_id = (select app.org_id()) and (select app.has_perm('clients.delete')));

-- contacts & services: visible to anyone who can see the client (incl. that client's portal users)
create policy cc_select on public.client_contacts for select to authenticated using (app.can_view_client(client_id));
create policy cc_write on public.client_contacts for all to authenticated
  using (org_id = (select app.org_id()) and (select app.has_perm('clients.edit')))
  with check (org_id = (select app.org_id()) and (select app.has_perm('clients.edit')) and app.can_view_client(client_id));
create policy cs_select on public.client_services for select to authenticated using (app.can_view_client(client_id));
create policy cs_write on public.client_services for all to authenticated
  using (org_id = (select app.org_id()) and (select app.has_perm('clients.edit')))
  with check (org_id = (select app.org_id()) and (select app.has_perm('clients.edit')) and app.can_view_client(client_id));

-- billing & contracts: billing permission only (never client users, never general staff)
create policy cb_all on public.client_billing for all to authenticated
  using (org_id = (select app.org_id()) and (select app.has_perm('clients.view_billing')))
  with check (org_id = (select app.org_id()) and (select app.has_perm('clients.view_billing'))
              and exists (select 1 from public.clients c where c.id = client_id and c.org_id = (select app.org_id())));
create policy contracts_all on public.contracts for all to authenticated
  using (org_id = (select app.org_id()) and (select app.has_perm('clients.view_billing')))
  with check (org_id = (select app.org_id()) and (select app.has_perm('clients.view_billing'))
              and exists (select 1 from public.clients c where c.id = client_id and c.org_id = (select app.org_id())));

-- internal notes & onboarding: internal users who can see the client
create policy cn_select on public.client_notes for select to authenticated
  using ((select app.is_internal()) and app.can_view_client(client_id));
create policy cn_insert on public.client_notes for insert to authenticated
  with check ((select app.is_internal()) and org_id = (select app.org_id()) and author_id = auth.uid() and app.can_view_client(client_id));
create policy cn_delete on public.client_notes for delete to authenticated
  using (org_id = (select app.org_id()) and (author_id = auth.uid() or (select app.has_perm('clients.delete'))));
create policy coi_select on public.client_onboarding_items for select to authenticated
  using ((select app.is_internal()) and app.can_view_client(client_id));
create policy coi_write on public.client_onboarding_items for all to authenticated
  using ((select app.is_internal()) and org_id = (select app.org_id()) and app.can_view_client(client_id))
  with check ((select app.is_internal()) and org_id = (select app.org_id()) and app.can_view_client(client_id));

create policy inv_all on public.invitations for all to authenticated
  using (org_id = (select app.org_id()) and (select app.has_perm('users.manage')))
  with check (org_id = (select app.org_id()) and (select app.has_perm('users.manage')) and invited_by = auth.uid());

create policy projects_select on public.projects for select to authenticated using (
  org_id = (select app.org_id()) and (
    ((select app.is_internal()) and ((select app.has_perm('projects.view_all')) or owner_id = auth.uid() or created_by = auth.uid()
                                     or app.is_project_member(id)))
    or (client_visible and client_id is not null and client_id = (select app.client_id()))));
create policy projects_insert on public.projects for insert to authenticated
  with check (org_id = (select app.org_id()) and (select app.has_perm('projects.create')) and created_by = auth.uid());
create policy projects_update on public.projects for update to authenticated
  using (org_id = (select app.org_id()) and app.can_manage_project(id))
  with check (org_id = (select app.org_id()) and app.can_manage_project(id));
create policy projects_delete on public.projects for delete to authenticated
  using (org_id = (select app.org_id()) and (select app.has_perm('projects.delete')));

create policy pm_select on public.project_members for select to authenticated
  using ((select app.is_internal()) and app.can_view_project(project_id));
create policy pm_write on public.project_members for all to authenticated
  using (app.can_manage_project(project_id)) with check (app.can_manage_project(project_id));

create policy ms_select on public.project_milestones for select to authenticated
  using (app.can_view_project(project_id) and ((select app.is_internal()) or client_visible));
create policy ms_write on public.project_milestones for all to authenticated
  using (org_id = (select app.org_id()) and app.can_manage_project(project_id))
  with check (org_id = (select app.org_id()) and app.can_manage_project(project_id));

create policy ts_select on public.task_statuses for select to authenticated using (org_id = (select app.org_id()));
create policy ts_write on public.task_statuses for all to authenticated
  using (org_id = (select app.org_id()) and (select app.has_perm('tasks.manage_statuses')))
  with check (org_id = (select app.org_id()) and (select app.has_perm('tasks.manage_statuses')));

create policy tasks_select on public.tasks for select to authenticated using (
  org_id = (select app.org_id()) and (
    ((select app.is_internal()) and ((select app.has_perm('tasks.view_all')) or app.project_role_of_me(project_id) is not null
       or reviewer_id = auth.uid() or created_by = auth.uid() or app.is_task_assignee(id)))
    or (client_visible and client_id is not null and client_id = (select app.client_id()) and app.project_client_visible(project_id))));
create policy tasks_insert on public.tasks for insert to authenticated
  with check (org_id = (select app.org_id()) and (select app.is_internal()) and created_by = auth.uid()
    and ((select app.has_perm('tasks.create')) or app.can_manage_project(project_id))
    and ((select app.has_perm('tasks.view_all')) or app.project_role_of_me(project_id) in ('manager','member')));
create policy tasks_update on public.tasks for update to authenticated
  using (app.can_edit_task(id))
  with check (org_id = (select app.org_id())
    and ((select app.has_perm('tasks.view_all')) or app.project_role_of_me(project_id) is not null
         or app.is_task_assignee(id) or reviewer_id = auth.uid()));
create policy tasks_delete on public.tasks for delete to authenticated
  using (org_id = (select app.org_id()) and ((select app.has_perm('tasks.delete')) or app.can_manage_project(project_id)));

create policy ta_select on public.task_assignees for select to authenticated using (app.can_view_task(task_id));
create policy ta_write on public.task_assignees for all to authenticated
  using (app.can_edit_task(task_id)) with check (app.can_edit_task(task_id));

create policy td_select on public.task_dependencies for select to authenticated using ((select app.is_internal()) and app.can_view_task(task_id));
create policy td_write on public.task_dependencies for all to authenticated
  using (app.can_edit_task(task_id)) with check (app.can_edit_task(task_id));

create policy tc_select on public.task_comments for select to authenticated
  using (app.can_view_task(task_id) and ((select app.is_internal()) or not is_internal));
create policy tc_insert on public.task_comments for insert to authenticated
  with check (author_id = auth.uid() and app.can_view_task(task_id));
create policy tc_update on public.task_comments for update to authenticated
  using (author_id = auth.uid()) with check (author_id = auth.uid());
create policy tc_delete on public.task_comments for delete to authenticated
  using (author_id = auth.uid() or (select app.has_perm('tasks.delete')));

create policy tcm_select on public.task_comment_mentions for select to authenticated
  using ((select app.is_internal()) and org_id = (select app.org_id()));
create policy tcm_insert on public.task_comment_mentions for insert to authenticated
  with check (task_comment_mentions.org_id = (select app.org_id())
    and exists (select 1 from public.task_comments c where c.id = comment_id and c.author_id = auth.uid()
                and c.org_id = task_comment_mentions.org_id)
    and exists (select 1 from public.profiles p where p.id = profile_id and p.org_id = task_comment_mentions.org_id));

create policy tatt_select on public.task_attachments for select to authenticated
  using (app.can_view_task(task_id) and ((select app.is_internal()) or not is_internal));
create policy tatt_insert on public.task_attachments for insert to authenticated
  with check (uploaded_by = auth.uid() and app.can_view_task(task_id)
              and ((select app.is_internal()) or not is_internal));
create policy tatt_delete on public.task_attachments for delete to authenticated
  using (uploaded_by = auth.uid() or app.can_edit_task(task_id));

-- ---------- grants ----------
grant select on public.clients, public.client_contacts, public.client_services, public.client_billing, public.contracts,
  public.client_notes, public.client_onboarding_items, public.invitations, public.projects, public.project_members,
  public.project_milestones, public.task_statuses, public.tasks, public.task_assignees, public.task_dependencies,
  public.task_comments, public.task_comment_mentions, public.task_attachments, public.project_overview to authenticated;
grant insert, update, delete on public.clients, public.client_contacts, public.client_services, public.client_billing,
  public.contracts, public.client_onboarding_items, public.invitations, public.projects, public.project_members,
  public.project_milestones, public.task_statuses, public.tasks, public.task_assignees, public.task_dependencies,
  public.task_attachments to authenticated;
grant insert, delete on public.client_notes, public.task_comment_mentions to authenticated;
grant insert, delete on public.task_comments to authenticated;
grant update (body) on public.task_comments to authenticated;

revoke execute on all functions in schema app from public, anon;
grant execute on all functions in schema app to authenticated, service_role;

-- ===== 20261026000004_notifications_dashboard_bootstrap.sql =====
-- =====================================================================
-- 0004 NOTIFICATIONS, ANNOUNCEMENTS, DASHBOARD, ORG BOOTSTRAP, INVITES
-- =====================================================================

-- guards may be bypassed only inside trusted bootstrap functions (transaction-local flag)
create or replace function app.guards_bypassed() returns boolean
language sql stable set search_path = '' as $$ select coalesce(current_setting('app.bypass_guards', true), '') = 'on' $$;

create or replace function app.guard_user_roles() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_role public.roles; v_prof public.profiles; v_remaining int;
begin
  if app.guards_bypassed() then return coalesce(new, old); end if;
  if tg_op = 'INSERT' then
    select * into v_role from public.roles where id = new.role_id;
    select * into v_prof from public.profiles where id = new.user_id;
    if v_prof.org_id is distinct from new.org_id or v_role.org_id is distinct from new.org_id then
      raise exception 'Role and user must belong to the same organization' using errcode = '42501'; end if;
    if v_role.is_client_role <> (v_prof.client_id is not null) then
      raise exception 'Client roles can only be given to client users and vice versa' using errcode = '42501'; end if;
    if auth.uid() is not null and new.user_id = auth.uid() and not app.has_perm('roles.manage') then
      raise exception 'You cannot change your own roles' using errcode = '42501'; end if;
    if v_role.key = 'super_admin' and auth.uid() is not null and not exists (
        select 1 from public.user_roles ur join public.roles r on r.id = ur.role_id
        where ur.user_id = auth.uid() and r.key = 'super_admin') then
      raise exception 'Only a Super Admin can grant Super Admin' using errcode = '42501'; end if;
    return new;
  else
    select * into v_role from public.roles where id = old.role_id;
    if v_role.key = 'super_admin' then
      select count(*) into v_remaining from public.user_roles ur
        join public.profiles p on p.id = ur.user_id and p.is_active
       where ur.role_id = old.role_id and ur.user_id <> old.user_id;
      if v_remaining = 0 and exists (select 1 from public.organizations where id = v_role.org_id) then
        raise exception 'Cannot remove the last Super Admin' using errcode = '42501'; end if;
    end if;
    return old;
  end if;
end $$;

create or replace function app.guard_role_permissions() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_key text; v_client boolean;
begin
  if app.guards_bypassed() then return coalesce(new, old); end if;
  select key, is_client_role into v_key, v_client from public.roles where id = coalesce(new.role_id, old.role_id);
  if v_key = 'super_admin' and auth.uid() is not null then
    raise exception 'Super Admin permissions are fixed' using errcode = '42501'; end if;
  if tg_op = 'INSERT' and v_client then
    raise exception 'Client roles cannot hold internal permissions' using errcode = '42501'; end if;
  return coalesce(new, old);
end $$;

-- ---------- notifications ----------
create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  recipient_id uuid not null references public.profiles(id) on delete cascade,
  type text not null,
  title text not null,
  body text,
  link text,
  entity_type text,
  entity_id uuid,
  dedupe_key text not null,
  read_at timestamptz,
  emailed_at timestamptz,
  created_at timestamptz not null default now(),
  unique (recipient_id, dedupe_key)
);
create index on public.notifications(recipient_id, created_at desc);
create index on public.notifications(recipient_id) where read_at is null;

create table public.notification_preferences (
  profile_id uuid not null references public.profiles(id) on delete cascade,
  type text not null,
  in_app boolean not null default true,
  email boolean not null default true,
  primary key (profile_id, type)
);

create or replace function app.notify(p_recipient uuid, p_type text, p_title text, p_body text, p_link text,
  p_entity_type text, p_entity_id uuid, p_dedupe text) returns void
language plpgsql security definer set search_path = '' as $$
declare v_org uuid;
begin
  if p_recipient is null or p_recipient = auth.uid() then return; end if;
  select org_id into v_org from public.profiles where id = p_recipient and is_active;
  if v_org is null then return; end if;
  if exists (select 1 from public.notification_preferences where profile_id = p_recipient and type = p_type and not in_app) then
    return; end if;
  insert into public.notifications(org_id, recipient_id, type, title, body, link, entity_type, entity_id, dedupe_key)
  values (v_org, p_recipient, p_type, p_title, p_body, p_link, p_entity_type, p_entity_id, p_dedupe)
  on conflict (recipient_id, dedupe_key) do nothing;
end $$;

create or replace function app.profiles_with_perm(p_org uuid, p_perm text) returns setof uuid
language sql stable security definer set search_path = '' as $$
  select distinct ur.user_id from public.user_roles ur
  join public.role_permissions rp on rp.role_id = ur.role_id and rp.permission_key = p_perm
  join public.profiles p on p.id = ur.user_id and p.is_active and p.client_id is null
  where ur.org_id = p_org
$$;

-- approvers = reporting manager's account, else everyone with the permission
create or replace function app.approvers_for(p_employee uuid, p_perm text) returns setof uuid
language sql stable security definer set search_path = '' as $$
  with mgr as (select m.profile_id from public.employee_profiles e
               join public.employee_profiles m on m.id = e.reporting_manager_id
               where e.id = p_employee and m.profile_id is not null and m.status <> 'exited')
  select profile_id from mgr
  union
  select x from public.employee_profiles e, app.profiles_with_perm(e.org_id, p_perm) x
   where e.id = p_employee and not exists (select 1 from mgr)
$$;

create or replace function app.trg_notify_task_assignee() returns trigger
language plpgsql security definer set search_path = '' as $$
declare t public.tasks;
begin
  select * into t from public.tasks where id = new.task_id;
  perform app.notify(new.profile_id, 'task_assigned', 'New task assigned: ' || t.title,
    case when t.due_date is not null then 'Due ' || to_char(t.due_date, 'DD Mon YYYY') end,
    '/tasks/' || t.id, 'task', t.id, 'task_assigned:' || t.id || ':' || extract(epoch from new.assigned_at)::bigint);
  return new;
end $$;
create trigger trg_notify_assignee after insert on public.task_assignees for each row execute function app.trg_notify_task_assignee();

create or replace function app.trg_notify_task_status() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_cat public.status_category; a uuid; v_stamp text := extract(epoch from now())::bigint::text;
begin
  if new.status_id = old.status_id then return new; end if;
  v_cat := app.status_category(new.status_id);
  if v_cat = 'review' and new.reviewer_id is not null then
    perform app.notify(new.reviewer_id, 'review_requested', 'Review requested: ' || new.title, null,
      '/tasks/' || new.id, 'task', new.id, 'review:' || new.id || ':' || v_stamp);
  elsif v_cat in ('changes_requested','done') then
    for a in select profile_id from public.task_assignees where task_id = new.id loop
      perform app.notify(a, case when v_cat = 'done' then 'task_approved' else 'changes_requested' end,
        case when v_cat = 'done' then 'Task completed: ' else 'Changes requested: ' end || new.title, null,
        '/tasks/' || new.id, 'task', new.id, v_cat || ':' || new.id || ':' || v_stamp);
    end loop;
  end if;
  return new;
end $$;
create trigger trg_notify_task_status after update of status_id on public.tasks for each row execute function app.trg_notify_task_status();

create or replace function app.trg_notify_mention() returns trigger
language plpgsql security definer set search_path = '' as $$
declare c public.task_comments; t public.tasks;
begin
  select * into c from public.task_comments where id = new.comment_id;
  select * into t from public.tasks where id = c.task_id;
  perform app.notify(new.profile_id, 'mention', 'You were mentioned on: ' || t.title, left(c.body, 200),
    '/tasks/' || t.id, 'task', t.id, 'mention:' || new.comment_id);
  return new;
end $$;
create trigger trg_notify_mention after insert on public.task_comment_mentions for each row execute function app.trg_notify_mention();

create or replace function app.trg_notify_client_comment() returns trigger
language plpgsql security definer set search_path = '' as $$
declare t public.tasks; p public.projects;
begin
  if new.is_internal then return new; end if;
  if exists (select 1 from public.profiles where id = new.author_id and client_id is not null) then
    select * into t from public.tasks where id = new.task_id;
    select * into p from public.projects where id = t.project_id;
    perform app.notify(p.owner_id, 'client_feedback', 'Client feedback on: ' || t.title, left(new.body, 200),
      '/tasks/' || t.id, 'task', t.id, 'client_comment:' || new.id);
  end if;
  return new;
end $$;
create trigger trg_notify_client_comment after insert on public.task_comments for each row execute function app.trg_notify_client_comment();

create or replace function app.trg_notify_leave() returns trigger
language plpgsql security definer set search_path = '' as $$
declare e public.employee_profiles; a uuid;
begin
  select * into e from public.employee_profiles where id = new.employee_id;
  if tg_op = 'INSERT' then
    for a in select app.approvers_for(new.employee_id, 'leave.approve') loop
      perform app.notify(a, 'leave_request', 'Leave request from ' || e.full_name,
        new.days || ' day(s) from ' || to_char(new.start_date, 'DD Mon'), '/leave?tab=approvals', 'leave_request', new.id,
        'leave_req:' || new.id || ':1');
    end loop;
  elsif new.status <> old.status and new.status in ('approved','rejected') then
    perform app.notify(e.profile_id, 'leave_decision', 'Your leave was ' || new.status,
      to_char(new.start_date, 'DD Mon') || ' – ' || to_char(new.end_date, 'DD Mon'), '/leave', 'leave_request', new.id,
      'leave_dec:' || new.id);
  elsif new.current_level > old.current_level then
    for a in select app.profiles_with_perm(new.org_id, 'leave.approve') loop
      perform app.notify(a, 'leave_request', 'Level ' || new.current_level || ' approval: ' || e.full_name,
        null, '/leave?tab=approvals', 'leave_request', new.id, 'leave_req:' || new.id || ':' || new.current_level);
    end loop;
  end if;
  return new;
end $$;
create trigger trg_notify_leave after insert or update on public.leave_requests for each row execute function app.trg_notify_leave();

create or replace function app.trg_notify_correction() returns trigger
language plpgsql security definer set search_path = '' as $$
declare e public.employee_profiles; a uuid;
begin
  select * into e from public.employee_profiles where id = new.employee_id;
  if tg_op = 'INSERT' then
    for a in select app.approvers_for(new.employee_id, 'attendance.approve') loop
      perform app.notify(a, 'attendance_correction', 'Attendance correction from ' || e.full_name,
        to_char(new.work_date, 'DD Mon YYYY'), '/attendance?tab=approvals', 'attendance_correction', new.id, 'att_corr:' || new.id);
    end loop;
  elsif new.status <> old.status then
    perform app.notify(e.profile_id, 'attendance_correction_decision', 'Attendance correction ' || new.status,
      to_char(new.work_date, 'DD Mon YYYY'), '/attendance', 'attendance_correction', new.id, 'att_corr_dec:' || new.id);
  end if;
  return new;
end $$;
create trigger trg_notify_correction after insert or update on public.attendance_corrections for each row execute function app.trg_notify_correction();

-- Scheduled job: idempotent (dedupe keys), safe to run many times a day. Service role / pg_cron only.
create or replace function public.generate_due_notifications() returns integer
language plpgsql security definer set search_path = '' as $$
declare v_before int; v_after int; r record; a uuid;
begin
  select count(*) into v_before from public.notifications;
  for r in
    select t.id, t.title, t.due_date, p.owner_id, (now() at time zone o.timezone)::date as today
    from public.tasks t
    join public.projects p on p.id = t.project_id
    join public.organizations o on o.id = t.org_id
    join public.task_statuses s on s.id = t.status_id
    where s.category not in ('done','cancelled') and t.due_date is not null
      and t.due_date <= (now() at time zone o.timezone)::date + 1
  loop
    if r.due_date >= r.today then
      for a in select profile_id from public.task_assignees where task_id = r.id loop
        perform app.notify(a, 'task_due_soon', 'Due ' || case when r.due_date = r.today then 'today' else 'tomorrow' end || ': ' || r.title,
          null, '/tasks/' || r.id, 'task', r.id, 'due:' || r.id || ':' || r.due_date || ':' || r.today);
      end loop;
    else
      for a in select profile_id from public.task_assignees where task_id = r.id
               union select r.owner_id where r.owner_id is not null loop
        perform app.notify(a, 'task_overdue', 'Overdue: ' || r.title, 'Was due ' || to_char(r.due_date, 'DD Mon'),
          '/tasks/' || r.id, 'task', r.id, 'overdue:' || r.id || ':' || r.today);
      end loop;
    end if;
  end loop;

  for r in
    select k.id, k.title, k.end_date, k.org_id, c.name client_name, m.profile_id as am
    from public.contracts k join public.clients c on c.id = k.client_id
    join public.organizations o on o.id = k.org_id
    left join public.employee_profiles m on m.id = c.account_manager_id
    where k.status = 'active' and k.end_date is not null
      and k.end_date between (now() at time zone o.timezone)::date
                         and (now() at time zone o.timezone)::date + k.renewal_reminder_days
  loop
    for a in select r.am where r.am is not null
             union select app.profiles_with_perm(r.org_id, 'clients.view_billing') loop
      perform app.notify(a, 'contract_renewal', 'Contract renewal: ' || r.client_name,
        r.title || ' ends ' || to_char(r.end_date, 'DD Mon YYYY'), '/clients', 'contract', r.id, 'renewal:' || r.id || ':' || r.end_date);
    end loop;
  end loop;

  select count(*) into v_after from public.notifications;
  return v_after - v_before;
end $$;
revoke execute on function public.generate_due_notifications() from public, anon, authenticated;
grant execute on function public.generate_due_notifications() to service_role;

do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('agency-os-due-notifications', '*/30 * * * *', 'select public.generate_due_notifications()');
  end if;
end $$;

create table public.announcements (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  title text not null check (length(trim(title)) between 2 and 160),
  body text not null,
  pinned boolean not null default false,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
create index on public.announcements(org_id, created_at desc);

alter table public.notifications enable row level security;
alter table public.notification_preferences enable row level security;
alter table public.announcements enable row level security;

create policy notif_select on public.notifications for select to authenticated using (recipient_id = auth.uid());
create policy notif_update on public.notifications for update to authenticated
  using (recipient_id = auth.uid()) with check (recipient_id = auth.uid());
create policy notif_delete on public.notifications for delete to authenticated using (recipient_id = auth.uid());
create policy np_all on public.notification_preferences for all to authenticated
  using (profile_id = auth.uid()) with check (profile_id = auth.uid());
create policy ann_select on public.announcements for select to authenticated using (org_id = (select app.org_id()) and (select app.is_internal()));
create policy ann_write on public.announcements for all to authenticated
  using (org_id = (select app.org_id()) and (select app.has_perm('announcements.manage')))
  with check (org_id = (select app.org_id()) and (select app.has_perm('announcements.manage')) and created_by = auth.uid());

grant select, delete on public.notifications to authenticated;
grant update (read_at) on public.notifications to authenticated;
grant select, insert, update, delete on public.notification_preferences, public.announcements to authenticated;

-- ---------- dashboard metrics (SECURITY INVOKER: every number is RLS-scoped to the caller) ----------
create or replace function public.get_dashboard_metrics() returns jsonb
language plpgsql stable security invoker set search_path = '' as $$
declare v_today date; v_me uuid := auth.uid(); v_emp uuid := app.my_employee_id(); res jsonb;
begin
  select (now() at time zone timezone)::date into v_today from public.organizations where id = app.org_id();
  with open_tasks as (
    select t.*, s.category from public.tasks t join public.task_statuses s on s.id = t.status_id
    where s.category not in ('done','cancelled'))
  select jsonb_build_object(
    'today', v_today,
    'active_clients', (select count(*) from public.clients where status = 'active'),
    'active_projects', (select count(*) from public.projects where status in ('planning','active')),
    'overdue_tasks', (select count(*) from open_tasks where due_date < v_today),
    'projects_at_risk', (select count(*) from public.project_overview p where p.status = 'active' and (
        exists (select 1 from open_tasks o where o.project_id = p.id and o.due_date < v_today)
        or (p.due_date is not null and p.due_date <= v_today + 7 and p.progress_pct < 80))),
    'tasks_in_review', (select count(*) from open_tasks where category = 'review'),
    'my_open_tasks', (select count(*) from open_tasks o where exists (select 1 from public.task_assignees a where a.task_id = o.id and a.profile_id = v_me)),
    'my_due_today', (select count(*) from open_tasks o where o.due_date = v_today and exists (select 1 from public.task_assignees a where a.task_id = o.id and a.profile_id = v_me)),
    'my_overdue', (select count(*) from open_tasks o where o.due_date < v_today and exists (select 1 from public.task_assignees a where a.task_id = o.id and a.profile_id = v_me)),
    'my_reviews', (select count(*) from open_tasks where category = 'review' and reviewer_id = v_me),
    'active_employees', (select count(*) from public.employee_profiles where status <> 'exited'),
    'checked_in_today', (select count(*) from public.attendance_records where work_date = v_today),
    'late_today', (select count(*) from public.attendance_records where work_date = v_today and late_minutes > 0),
    'on_leave_today', (select count(*) from public.leave_requests where status = 'approved' and v_today between start_date and end_date),
    'pending_leave_approvals', (select count(*) from public.leave_requests where status = 'pending' and (employee_id <> v_emp or v_emp is null)),
    'pending_corrections', (select count(*) from public.attendance_corrections where status = 'pending' and (employee_id <> v_emp or v_emp is null)),
    'probation_reviews_due', (select count(*) from public.employee_profiles where status = 'probation' and probation_end_date <= v_today + 30),
    'upcoming_renewals', (select count(*) from public.contracts where status = 'active' and end_date between v_today and v_today + 45),
    'my_attendance_today', (select to_jsonb(r) from public.attendance_records r where r.employee_id = v_emp and r.work_date = v_today),
    'team_workload', coalesce((select jsonb_agg(w order by w.open_tasks desc) from (
        select p.full_name as name, count(*) as open_tasks,
               count(*) filter (where o.due_date < v_today) as overdue
        from open_tasks o join public.task_assignees a on a.task_id = o.id join public.profiles p on p.id = a.profile_id
        group by p.full_name order by count(*) desc limit 10) w), '[]'::jsonb),
    'tasks_by_status', coalesce((select jsonb_agg(x order by x.position) from (
        select s.name, s.color, s.position, count(t.id) as count from public.task_statuses s
        left join public.tasks t on t.status_id = s.id group by s.id) x), '[]'::jsonb)
  ) into res;
  return res;
end $$;
revoke execute on function public.get_dashboard_metrics() from public, anon;
grant execute on function public.get_dashboard_metrics() to authenticated;

-- ---------- organization bootstrap ----------
create or replace function app.seed_org_defaults(p_org uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare r record;
begin
  perform set_config('app.bypass_guards', 'on', true);
  for r in select * from (values
    ('super_admin','Super Admin', false, array(select key from public.permissions)),
    ('agency_owner','Agency Owner', false, array(select key from public.permissions)),
    ('hr_manager','HR Manager', false, array['users.manage','departments.manage','employees.view','employees.create','employees.edit',
      'employees.delete','employees.export','employees.view_sensitive','salary.view','salary.edit','attendance.view_all',
      'attendance.approve','attendance.manage_policy','attendance.export','leave.view_all','leave.approve','leave.manage_policy',
      'leave.export','holidays.manage','announcements.manage','reports.view']),
    ('project_manager','Project Manager', false, array['employees.view','clients.view','clients.create','clients.edit',
      'projects.view_all','projects.create','projects.edit','projects.delete','projects.export','tasks.view_all','tasks.create',
      'tasks.edit_all','tasks.delete','tasks.manage_statuses','reports.view']),
    ('team_leader','Team Leader', false, array['employees.view','clients.view','projects.view_all','tasks.view_all','tasks.create',
      'tasks.edit_all','tasks.delete','reports.view']),
    ('dm_executive','Digital Marketing Executive', false, array['employees.view','tasks.create']),
    ('seo_executive','SEO Executive', false, array['employees.view','tasks.create']),
    ('graphic_designer','Graphic Designer', false, array['employees.view','tasks.create']),
    ('video_editor','Video Editor', false, array['employees.view','tasks.create']),
    ('social_media_manager','Social Media Manager', false, array['employees.view','tasks.create']),
    ('accounts_manager','Accounts Manager', false, array['employees.view','salary.view','clients.view','clients.view_billing','reports.view']),
    ('client','Client', true, array[]::text[])
  ) as v(key, name, is_client, perms) loop
    insert into public.roles(org_id, key, name, is_system, is_client_role)
    values (p_org, r.key, r.name, true, r.is_client) on conflict (org_id, key) do nothing;
    insert into public.role_permissions(role_id, permission_key, org_id)
    select ro.id, unnest(r.perms), p_org from public.roles ro where ro.org_id = p_org and ro.key = r.key
    on conflict do nothing;
  end loop;

  insert into public.task_statuses(org_id, key, name, category, position, color, is_default) values
    (p_org,'todo','To Do','todo',1,'#64748b',true),
    (p_org,'in_progress','In Progress','in_progress',2,'#2563eb',false),
    (p_org,'in_review','In Review','review',3,'#d97706',false),
    (p_org,'changes_requested','Changes Requested','changes_requested',4,'#dc2626',false),
    (p_org,'completed','Completed','done',5,'#16a34a',false)
  on conflict do nothing;

  insert into public.work_schedules(org_id, name, is_default) values (p_org, 'General shift', true) on conflict do nothing;

  insert into public.leave_types(org_id, code, name, annual_quota, is_paid, allow_half_day, color) values
    (p_org,'CL','Casual Leave',12,true,true,'#0ea5e9'),
    (p_org,'SL','Sick Leave',6,true,true,'#f97316'),
    (p_org,'EL','Earned Leave',15,true,false,'#22c55e'),
    (p_org,'LWP','Leave Without Pay',null,false,true,'#94a3b8')
  on conflict do nothing;

  insert into public.salary_components(org_id, code, name, kind) values
    (p_org,'BASIC','Basic','earning'),(p_org,'HRA','House Rent Allowance','earning'),
    (p_org,'SPECIAL','Special Allowance','earning'),(p_org,'PF_EMP','Employee PF','deduction'),
    (p_org,'PT','Professional Tax','deduction')
  on conflict do nothing;

  insert into public.departments(org_id, name)
  select p_org, d from unnest(array['Management','Performance Marketing','SEO','Creative','Social Media','Web Development','HR & Admin','Accounts']) d
  on conflict do nothing;
  perform set_config('app.bypass_guards', '', true);
end $$;

create or replace function public.create_organization(p_name text, p_slug text, p_full_name text default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_org uuid; v_prof public.profiles; v_role uuid;
begin
  select * into v_prof from public.profiles where id = auth.uid();
  if v_prof.id is null then raise exception 'Not signed in' using errcode='42501'; end if;
  if v_prof.org_id is not null or v_prof.client_id is not null then
    raise exception 'Your account already belongs to an organization' using errcode='42501'; end if;
  insert into public.organizations(name, slug) values (trim(p_name), lower(trim(p_slug))) returning id into v_org;
  perform app.seed_org_defaults(v_org);
  perform set_config('app.bypass_guards', 'on', true);
  update public.profiles set org_id = v_org, full_name = coalesce(nullif(trim(p_full_name),''), full_name) where id = auth.uid();
  select id into v_role from public.roles where org_id = v_org and key = 'super_admin';
  insert into public.user_roles(user_id, role_id, org_id) values (auth.uid(), v_role, v_org);
  insert into public.employee_profiles(org_id, profile_id, employee_code, full_name, work_email, designation, status, joining_date,
      department_id)
  select v_org, auth.uid(), '', coalesce(nullif(trim(p_full_name),''), nullif(v_prof.full_name,''), split_part(v_prof.email,'@',1)),
         v_prof.email, 'Founder', 'active', current_date, (select id from public.departments where org_id = v_org and name = 'Management');
  perform set_config('app.bypass_guards', '', true);
  return v_org;
end $$;
revoke execute on function public.create_organization(text,text,text) from public, anon;
grant execute on function public.create_organization(text,text,text) to authenticated;

-- guard_profiles must also honour the bypass flag
create or replace function app.guard_profiles() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null or app.guards_bypassed() then return new; end if;
  if new.org_id is distinct from old.org_id or new.client_id is distinct from old.client_id
     or new.email is distinct from old.email then
    raise exception 'Organization, client and email cannot be changed here' using errcode='42501'; end if;
  if new.is_active is distinct from old.is_active then
    if not app.has_perm('users.manage') or old.id = auth.uid() then
      raise exception 'Not allowed to change account status' using errcode='42501'; end if;
  end if;
  return new;
end $$;

-- ---------- invitations ----------
create or replace function app.invitation_validate() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_role public.roles;
begin
  new.email := lower(trim(new.email));
  select * into v_role from public.roles where id = new.role_id;
  if v_role.org_id is distinct from new.org_id then raise exception 'Role must belong to the organization' using errcode='23514'; end if;
  if v_role.is_client_role <> (new.client_id is not null) then
    raise exception 'Client invitations need a client role and a client; staff invitations need a staff role' using errcode='23514'; end if;
  if v_role.key = 'super_admin' and not exists (select 1 from public.user_roles ur join public.roles r on r.id = ur.role_id
      where ur.user_id = auth.uid() and r.key = 'super_admin') then
    raise exception 'Only a Super Admin can invite a Super Admin' using errcode='42501'; end if;
  if new.client_id is not null and not exists (select 1 from public.clients where id = new.client_id and org_id = new.org_id) then
    raise exception 'Client must belong to the organization' using errcode='23514'; end if;
  if new.employee_id is not null and not exists (select 1 from public.employee_profiles where id = new.employee_id and org_id = new.org_id and profile_id is null) then
    raise exception 'Employee must belong to the organization and not already have an account' using errcode='23514'; end if;
  if exists (select 1 from public.profiles where lower(email) = new.email and org_id is not null) then
    raise exception 'A user with this e-mail already belongs to an organization' using errcode='23505'; end if;
  return new;
end $$;
create trigger trg_invitation_validate before insert on public.invitations for each row execute function app.invitation_validate();

create or replace function app.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
declare inv public.invitations;
begin
  select * into inv from public.invitations
   where lower(email) = lower(new.email) and accepted_at is null and expires_at > now()
   order by created_at desc limit 1;
  insert into public.profiles(id, email, full_name, org_id, client_id)
  values (new.id, lower(new.email), coalesce(new.raw_user_meta_data->>'full_name', ''), inv.org_id, inv.client_id);
  if inv.id is not null then
    perform set_config('app.bypass_guards', 'on', true);
    insert into public.user_roles(user_id, role_id, org_id, assigned_by) values (new.id, inv.role_id, inv.org_id, inv.invited_by);
    if inv.employee_id is not null then
      update public.employee_profiles set profile_id = new.id where id = inv.employee_id and profile_id is null;
    end if;
    update public.invitations set accepted_at = now() where id = inv.id;
    perform set_config('app.bypass_guards', '', true);
  end if;
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users for each row execute function app.handle_new_user();

revoke execute on all functions in schema app from public, anon;
grant execute on all functions in schema app to authenticated, service_role;

-- ===== 20261026000005_storage.sql =====
-- =====================================================================
-- 0005 STORAGE: private bucket, path-based policies mirroring table RLS.
-- Path convention: {org_id}/{area}/{entity_id}/{uuid}-{filename}
--   area = tasks | employees | clients
-- Skipped automatically on plain Postgres (no storage schema).
-- =====================================================================
create or replace function app.can_read_object(p_name text) returns boolean
language plpgsql stable security definer set search_path = '' as $$
declare parts text[] := string_to_array(p_name, '/');
begin
  if array_length(parts, 1) < 4 or parts[1] <> app.org_id()::text then return false; end if;
  return case parts[2]
    when 'tasks' then exists (select 1 from public.task_attachments a where a.storage_path = p_name
                              and app.can_view_task(a.task_id) and (app.is_internal() or not a.is_internal))
    when 'employees' then app.is_internal() and (parts[3] = app.my_employee_id()::text or app.has_perm('employees.view_sensitive'))
    when 'clients' then app.can_view_client(parts[3]::uuid)
    else false end;
exception when invalid_text_representation then return false;
end $$;

create or replace function app.can_write_object(p_name text) returns boolean
language plpgsql stable security definer set search_path = '' as $$
declare parts text[] := string_to_array(p_name, '/');
begin
  if array_length(parts, 1) < 4 or parts[1] <> app.org_id()::text then return false; end if;
  return case parts[2]
    when 'tasks' then app.can_view_task(parts[3]::uuid)
    when 'employees' then app.has_perm('employees.view_sensitive') and app.has_perm('employees.edit')
    when 'clients' then app.can_view_client(parts[3]::uuid) and (app.has_perm('clients.edit') or parts[3]::uuid = app.client_id())
    else false end;
exception when invalid_text_representation then return false;
end $$;
grant execute on function app.can_read_object(text), app.can_write_object(text) to authenticated;

do $$ begin
  if exists (select 1 from information_schema.schemata where schema_name = 'storage') then
    insert into storage.buckets (id, name, public, file_size_limit)
    values ('agency-files', 'agency-files', false, 52428800) on conflict (id) do nothing;
    execute $p$create policy agency_files_read on storage.objects for select to authenticated
      using (bucket_id = 'agency-files' and app.can_read_object(name))$p$;
    execute $p$create policy agency_files_insert on storage.objects for insert to authenticated
      with check (bucket_id = 'agency-files' and app.can_write_object(name))$p$;
    execute $p$create policy agency_files_delete on storage.objects for delete to authenticated
      using (bucket_id = 'agency-files' and app.can_write_object(name))$p$;
  end if;
end $$;

-- ===== 20261026000006_automation.sql =====
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

-- ===== 20261026000007_no_privilege_escalation.sql =====
-- =====================================================================
-- 0007 NO PRIVILEGE ESCALATION
-- Assigning a role / inviting into a role: the caller must hold every SENSITIVE permission of
-- that role (admin, audit, HR-private, salary, billing, exports, policies). Operational permissions
-- (e.g. tasks.create) may be granted by anyone with users.manage, so HR can onboard staff.
-- Editing role permissions: strict — you can only add permissions you hold yourself.
-- Super Admins are exempt. Bootstrap code paths use the bypass flag.
-- =====================================================================
alter table public.permissions add column is_sensitive boolean not null default false;
update public.permissions set is_sensitive = true where key in (
  'org.manage','roles.manage','users.manage','audit.view','employees.view_sensitive','employees.export',
  'salary.view','salary.edit','attendance.manage_policy','leave.manage_policy','clients.view_billing','clients.export');

create or replace function app.is_super_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.user_roles ur join public.roles r on r.id = ur.role_id
                 join public.profiles p on p.id = ur.user_id and p.is_active
                 where ur.user_id = auth.uid() and r.key = 'super_admin')
$$;

-- true if the caller holds every sensitive permission of the role
create or replace function app.can_grant_role(p_role uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select app.is_super_admin() or not exists (
    select 1 from public.role_permissions rp join public.permissions p on p.key = rp.permission_key
    where rp.role_id = p_role and p.is_sensitive and not app.has_perm(rp.permission_key))
$$;

create or replace function app.guard_escalation_user_roles() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if app.guards_bypassed() or auth.uid() is null then return new; end if;
  if not app.can_grant_role(new.role_id) then
    raise exception 'You can only assign roles whose sensitive permissions you already hold' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger trg_guard_escalation before insert on public.user_roles
  for each row execute function app.guard_escalation_user_roles();

create or replace function app.guard_escalation_invitations() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if app.guards_bypassed() or auth.uid() is null then return new; end if;
  if not app.can_grant_role(new.role_id) then
    raise exception 'You can only invite people into roles whose sensitive permissions you already hold' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger trg_guard_escalation before insert or update of role_id on public.invitations
  for each row execute function app.guard_escalation_invitations();

create or replace function app.guard_escalation_role_permissions() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if app.guards_bypassed() or auth.uid() is null then return new; end if;
  if not app.is_super_admin() and not app.has_perm(new.permission_key) then
    raise exception 'You can only add permissions you already hold' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger trg_guard_escalation before insert on public.role_permissions
  for each row execute function app.guard_escalation_role_permissions();

revoke execute on all functions in schema app from public, anon;
grant execute on all functions in schema app to authenticated, service_role;

-- ===== 20261027000008_templates_recurring.sql =====
-- =====================================================================
-- 0008 PHASE 4: new permissions, project templates, recurring tasks
-- =====================================================================

-- ---------- permission catalog (all Phase 4 keys) ----------
insert into public.permissions(key, module, description) values
 ('projects.manage_templates','projects','Create and edit project templates'),
 ('time.view_all','time','View everyone''s time entries and timesheets'),
 ('timesheets.approve','time','Approve or reject timesheets'),
 ('content.view_all','content','View every client''s content calendar'),
 ('content.manage','content','Create, edit and approve content on behalf of clients'),
 ('campaigns.view','campaigns','View ad campaigns and performance'),
 ('campaigns.manage','campaigns','Create campaigns and import performance data')
on conflict (key) do nothing;

-- ---------- project templates ----------
create table public.project_templates (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  name text not null check (length(trim(name)) between 2 and 120),
  service public.service_type,
  description text,
  default_duration_days smallint not null default 30 check (default_duration_days between 1 and 730),
  is_active boolean not null default true,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (org_id, name)
);
create trigger trg_pt_touch before update on public.project_templates for each row execute function app.touch_updated_at();
create trigger trg_audit after insert or update or delete on public.project_templates for each row execute function app.audit();

create table public.template_tasks (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  template_id uuid not null references public.project_templates(id) on delete cascade,
  title text not null check (length(trim(title)) between 2 and 200),
  description text,
  priority public.priority not null default 'medium',
  start_offset_days smallint not null default 0 check (start_offset_days between 0 and 730),
  duration_days smallint not null default 3 check (duration_days between 0 and 365),
  estimated_minutes integer check (estimated_minutes is null or estimated_minutes between 0 and 100000),
  client_visible boolean not null default false,
  position smallint not null default 0
);
create index on public.template_tasks(template_id, position);

create or replace function app.template_child_before_write() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  new.org_id := (select org_id from public.project_templates where id = new.template_id);
  return new;
end $$;
create trigger trg_tt_org before insert or update on public.template_tasks
  for each row execute function app.template_child_before_write();

alter table public.project_templates enable row level security;
alter table public.template_tasks enable row level security;
create policy pt_select on public.project_templates for select to authenticated
  using (org_id = (select app.org_id()) and (select app.is_internal()));
create policy pt_write on public.project_templates for all to authenticated
  using (org_id = (select app.org_id()) and (select app.has_perm('projects.manage_templates')))
  with check (org_id = (select app.org_id()) and (select app.has_perm('projects.manage_templates')));
create policy tt_select on public.template_tasks for select to authenticated
  using (org_id = (select app.org_id()) and (select app.is_internal()));
create policy tt_write on public.template_tasks for all to authenticated
  using (org_id = (select app.org_id()) and (select app.has_perm('projects.manage_templates')))
  with check (org_id = (select app.org_id()) and (select app.has_perm('projects.manage_templates')));
grant select, insert, update, delete on public.project_templates, public.template_tasks to authenticated;

-- Create a project (and its tasks) from a template. SECURITY INVOKER: the caller's
-- own RLS rights on projects/tasks apply, so no privilege is gained by using a template.
create or replace function public.create_project_from_template(
  p_template uuid, p_name text, p_client uuid default null, p_start date default null, p_client_visible boolean default false)
returns uuid language plpgsql security invoker set search_path = '' as $$
declare v_t public.project_templates; v_proj uuid; v_start date; v_org uuid := app.org_id();
begin
  select * into v_t from public.project_templates where id = p_template and is_active;
  if v_t.id is null then raise exception 'Template not found' using errcode = 'P0002'; end if;
  v_start := coalesce(p_start, (select (now() at time zone timezone)::date from public.organizations where id = v_org));
  insert into public.projects(org_id, client_id, name, description, service, owner_id, status, start_date, due_date,
                              client_visible, created_by)
  values (v_org, p_client, coalesce(nullif(trim(p_name), ''), v_t.name), v_t.description, v_t.service, auth.uid(), 'planning',
          v_start, v_start + v_t.default_duration_days, coalesce(p_client_visible, false), auth.uid())
  returning id into v_proj;
  insert into public.tasks(org_id, project_id, title, description, priority, start_date, due_date, estimated_minutes,
                           client_visible, position, created_by)
  select v_org, v_proj, tt.title, tt.description, tt.priority, v_start + tt.start_offset_days,
         v_start + tt.start_offset_days + tt.duration_days, tt.estimated_minutes, tt.client_visible, tt.position, auth.uid()
  from public.template_tasks tt where tt.template_id = p_template order by tt.position;
  return v_proj;
end $$;
revoke execute on function public.create_project_from_template(uuid, text, uuid, date, boolean) from public, anon;
grant execute on function public.create_project_from_template(uuid, text, uuid, date, boolean) to authenticated;

-- ---------- recurring tasks ----------
create table public.recurring_task_rules (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  project_id uuid not null references public.projects(id) on delete cascade,
  title text not null check (length(trim(title)) between 2 and 200),
  description text,
  frequency text not null check (frequency in ('weekly','monthly')),
  weekday smallint check (weekday between 1 and 7),          -- ISO: 1 = Monday (weekly rules)
  day_of_month smallint check (day_of_month between 1 and 28), -- monthly rules (1-28 so every month has it)
  due_after_days smallint not null default 2 check (due_after_days between 0 and 60),
  assignee_id uuid references public.profiles(id) on delete set null,
  reviewer_id uuid references public.profiles(id) on delete set null,
  priority public.priority not null default 'medium',
  estimated_minutes integer check (estimated_minutes is null or estimated_minutes between 0 and 100000),
  client_visible boolean not null default false,
  start_date date not null default current_date,
  end_date date,
  is_active boolean not null default true,
  created_by uuid not null references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  check ((frequency = 'weekly' and weekday is not null and day_of_month is null)
      or (frequency = 'monthly' and day_of_month is not null and weekday is null)),
  check (end_date is null or end_date >= start_date)
);
create index on public.recurring_task_rules(project_id);
create index on public.recurring_task_rules(org_id) where is_active;
create trigger trg_audit after insert or update or delete on public.recurring_task_rules for each row execute function app.audit();

-- one row per rule per period: this unique key is what makes generation idempotent
create table public.recurring_task_runs (
  rule_id uuid not null references public.recurring_task_rules(id) on delete cascade,
  period_key text not null,
  org_id uuid not null references public.organizations(id) on delete cascade,
  task_id uuid references public.tasks(id) on delete set null,
  generated_at timestamptz not null default now(),
  primary key (rule_id, period_key)
);

create or replace function app.recurring_rule_before_write() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  new.org_id := (select org_id from public.projects where id = new.project_id);
  if new.assignee_id is not null and not exists (select 1 from public.profiles
      where id = new.assignee_id and org_id = new.org_id and client_id is null and is_active) then
    raise exception 'Assignee must be an active internal user of the same organization' using errcode = '23514'; end if;
  if new.reviewer_id is not null and not exists (select 1 from public.profiles
      where id = new.reviewer_id and org_id = new.org_id and client_id is null) then
    raise exception 'Reviewer must be an internal user' using errcode = '23514'; end if;
  return new;
end $$;
create trigger trg_rtr_before before insert or update on public.recurring_task_rules
  for each row execute function app.recurring_rule_before_write();

alter table public.recurring_task_rules enable row level security;
alter table public.recurring_task_runs enable row level security;
create policy rtr_select on public.recurring_task_rules for select to authenticated
  using ((select app.is_internal()) and app.can_view_project(project_id));
create policy rtr_write on public.recurring_task_rules for all to authenticated
  using (org_id = (select app.org_id()) and app.can_manage_project(project_id))
  with check (org_id = (select app.org_id()) and app.can_manage_project(project_id) and created_by = auth.uid());
create policy rtrun_select on public.recurring_task_runs for select to authenticated
  using ((select app.is_internal()) and org_id = (select app.org_id()));
grant select, insert, update, delete on public.recurring_task_rules to authenticated;
grant select on public.recurring_task_runs to authenticated;

-- The scheduled occurrence of a rule in the period containing p_day (or null if none / outside the rule's dates)
create or replace function app.rule_occurrence(r public.recurring_task_rules, p_day date) returns date
language sql immutable set search_path = '' as $$
  select case when d < r.start_date or (r.end_date is not null and d > r.end_date) or d > p_day then null else d end
  from (select case r.frequency
                 when 'weekly' then (date_trunc('week', p_day)::date + (r.weekday - 1))
                 else (date_trunc('month', p_day)::date + (r.day_of_month - 1)) end as d) x
$$;

-- Generates this period's task for every active rule whose day has arrived. Safe to run any number of times.
create or replace function public.generate_recurring_tasks(p_today date default null) returns integer
language plpgsql security definer set search_path = '' as $$
declare r public.recurring_task_rules; v_today date; v_occ date; v_key text; v_task uuid; v_n int := 0; v_run_new boolean;
begin
  for r in select rr.* from public.recurring_task_rules rr join public.projects p on p.id = rr.project_id
           where rr.is_active and p.status in ('planning','active') loop
    select coalesce(p_today, (now() at time zone o.timezone)::date) into v_today from public.organizations o where o.id = r.org_id;
    v_occ := app.rule_occurrence(r, v_today);
    continue when v_occ is null;
    v_key := case r.frequency when 'weekly' then to_char(v_occ, 'IYYY-"W"IW') else to_char(v_occ, 'YYYY-MM') end;
    insert into public.recurring_task_runs(rule_id, period_key, org_id) values (r.id, v_key, r.org_id)
    on conflict do nothing returning true into v_run_new;
    continue when v_run_new is null;
    insert into public.tasks(org_id, project_id, title, description, priority, reviewer_id, start_date, due_date,
                             estimated_minutes, client_visible, created_by)
    values (r.org_id, r.project_id, r.title || ' (' || to_char(v_occ, 'DD Mon') || ')', r.description, r.priority, r.reviewer_id,
            v_occ, v_occ + r.due_after_days, r.estimated_minutes, r.client_visible, r.created_by)
    returning id into v_task;
    if r.assignee_id is not null and exists (select 1 from public.profiles where id = r.assignee_id and is_active) then
      insert into public.task_assignees(task_id, profile_id, org_id, assigned_by) values (v_task, r.assignee_id, r.org_id, r.created_by);
    end if;
    update public.recurring_task_runs set task_id = v_task where rule_id = r.id and period_key = v_key;
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;
revoke execute on function public.generate_recurring_tasks(date) from public, anon, authenticated;
grant execute on function public.generate_recurring_tasks(date) to service_role;

do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('agency-os-recurring-tasks', '15 * * * *', 'select public.generate_recurring_tasks()');
  end if;
end $$;

-- ---------- default role permissions + starter templates for Phase 4 ----------
create or replace function app.seed_phase4_defaults(p_org uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_tpl uuid; r record;
begin
  perform set_config('app.bypass_guards', 'on', true);
  insert into public.role_permissions(role_id, permission_key, org_id)
  select ro.id, x.perm, p_org
  from (values
    ('super_admin', array['projects.manage_templates','time.view_all','timesheets.approve','content.view_all','content.manage','campaigns.view','campaigns.manage']),
    ('agency_owner', array['projects.manage_templates','time.view_all','timesheets.approve','content.view_all','content.manage','campaigns.view','campaigns.manage']),
    ('project_manager', array['projects.manage_templates','time.view_all','timesheets.approve','content.view_all','content.manage','campaigns.view','campaigns.manage']),
    ('team_leader', array['time.view_all','timesheets.approve','content.view_all','campaigns.view']),
    ('hr_manager', array['time.view_all','timesheets.approve']),
    ('social_media_manager', array['content.view_all','content.manage']),
    ('dm_executive', array['campaigns.view','campaigns.manage']),
    ('accounts_manager', array['time.view_all','campaigns.view'])
  ) as v(role_key, perms)
  cross join lateral unnest(v.perms) as x(perm)
  join public.roles ro on ro.org_id = p_org and ro.key = v.role_key
  on conflict do nothing;

  for r in select * from (values
    ('SEO Monthly Retainer','seo',30, 'Monthly SEO deliverables'),
    ('Google Ads Campaign Setup','google_ads',21,'Account audit to launch and first optimisation'),
    ('Meta Ads Campaign Setup','meta_ads',21,'Pixel, audiences, creatives and launch'),
    ('Social Media Monthly Plan','social_media',30,'Content calendar, creatives and publishing'),
    ('Website Development','website_development',45,'Discovery to launch'),
    ('Local SEO / Google Business Profile','local_seo',30,'GBP optimisation, citations and reviews'),
    ('YouTube Channel Management','youtube',30,'Scripts, editing, SEO and publishing'),
    ('Email Marketing Campaign','email_marketing',14,'List, template, copy and send')
  ) as t(name, service, days, descr) loop
    insert into public.project_templates(org_id, name, service, description, default_duration_days)
    values (p_org, r.name, r.service::public.service_type, r.descr, r.days)
    on conflict (org_id, name) do nothing returning id into v_tpl;
    continue when v_tpl is null;
    insert into public.template_tasks(template_id, org_id, title, priority, start_offset_days, duration_days, estimated_minutes, client_visible, position)
    select v_tpl, p_org, x.title, x.prio::public.priority, x.off, x.dur, x.mins, x.cv, x.pos
    from (values
      ('seo','Keyword research & mapping','high',0,3,240,true,1),('seo','Technical SEO audit','high',0,5,360,true,2),
      ('seo','On-page optimisation','medium',5,7,480,false,3),('seo','Content brief & 4 blog posts','medium',7,14,720,true,4),
      ('seo','Backlink outreach','medium',7,18,480,false,5),('seo','Monthly SEO report','high',27,3,120,true,6),
      ('google_ads','Account & conversion tracking audit','high',0,2,180,false,1),('google_ads','Keyword & competitor research','high',1,3,240,false,2),
      ('google_ads','Campaign structure & ad copy','high',3,4,360,true,3),('google_ads','Client approval of ads','high',7,2,30,true,4),
      ('google_ads','Launch campaigns','urgent',9,1,90,true,5),('google_ads','First-week optimisation','medium',10,7,180,false,6),
      ('google_ads','Performance report','high',18,3,120,true,7),
      ('meta_ads','Pixel & Conversions API check','high',0,2,120,false,1),('meta_ads','Audience research','high',1,3,180,false,2),
      ('meta_ads','Creatives (static + video)','high',3,5,480,true,3),('meta_ads','Client approval of creatives','high',8,2,30,true,4),
      ('meta_ads','Launch campaigns','urgent',10,1,90,true,5),('meta_ads','Optimisation & report','medium',11,10,240,true,6),
      ('social_media','Monthly content calendar','high',0,3,240,true,1),('social_media','Design creatives','high',3,7,900,false,2),
      ('social_media','Client approval of posts','high',10,3,30,true,3),('social_media','Schedule & publish','medium',13,15,240,false,4),
      ('social_media','Community management','low',0,30,300,false,5),('social_media','Monthly social report','medium',28,2,90,true,6),
      ('website_development','Discovery & sitemap','high',0,4,240,true,1),('website_development','Wireframes & design','high',4,10,960,true,2),
      ('website_development','Client design approval','high',14,3,30,true,3),('website_development','Development','high',17,18,2400,false,4),
      ('website_development','Content upload & SEO basics','medium',30,7,480,false,5),('website_development','QA & client UAT','high',37,5,360,true,6),
      ('website_development','Launch & handover','urgent',42,3,180,true,7),
      ('local_seo','GBP audit & optimisation','high',0,4,180,true,1),('local_seo','Citations & NAP consistency','medium',4,10,360,false,2),
      ('local_seo','Review generation plan','medium',4,5,120,true,3),('local_seo','GBP posts (weekly)','low',7,21,240,false,4),
      ('local_seo','Local SEO report','medium',27,3,90,true,5),
      ('youtube','Topic & keyword plan','high',0,3,180,true,1),('youtube','Scripts','high',3,5,480,true,2),
      ('youtube','Video editing','high',8,10,1200,false,3),('youtube','Thumbnails & SEO metadata','medium',15,5,240,false,4),
      ('youtube','Client approval','high',20,3,30,true,5),('youtube','Publish & promote','medium',23,5,120,false,6),
      ('email_marketing','List cleanup & segmentation','medium',0,3,180,false,1),('email_marketing','Template design','high',2,4,360,true,2),
      ('email_marketing','Copywriting','high',3,4,240,true,3),('email_marketing','Client approval','high',7,2,30,true,4),
      ('email_marketing','Test & send','urgent',9,2,90,false,5),('email_marketing','Campaign report','medium',12,2,60,true,6)
    ) as x(service, title, prio, off, dur, mins, cv, pos)
    where x.service = r.service;
  end loop;
  perform set_config('app.bypass_guards', '', true);
end $$;

-- new organizations get Phase 4 defaults too (same body as 0004 plus the last perform)
create or replace function app.seed_org_defaults(p_org uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare r record;
begin
  perform set_config('app.bypass_guards', 'on', true);
  for r in select * from (values
    ('super_admin','Super Admin', false, array(select key from public.permissions)),
    ('agency_owner','Agency Owner', false, array(select key from public.permissions)),
    ('hr_manager','HR Manager', false, array['users.manage','departments.manage','employees.view','employees.create','employees.edit',
      'employees.delete','employees.export','employees.view_sensitive','salary.view','salary.edit','attendance.view_all',
      'attendance.approve','attendance.manage_policy','attendance.export','leave.view_all','leave.approve','leave.manage_policy',
      'leave.export','holidays.manage','announcements.manage','reports.view']),
    ('project_manager','Project Manager', false, array['employees.view','clients.view','clients.create','clients.edit',
      'projects.view_all','projects.create','projects.edit','projects.delete','projects.export','tasks.view_all','tasks.create',
      'tasks.edit_all','tasks.delete','tasks.manage_statuses','reports.view']),
    ('team_leader','Team Leader', false, array['employees.view','clients.view','projects.view_all','tasks.view_all','tasks.create',
      'tasks.edit_all','tasks.delete','reports.view']),
    ('dm_executive','Digital Marketing Executive', false, array['employees.view','tasks.create']),
    ('seo_executive','SEO Executive', false, array['employees.view','tasks.create']),
    ('graphic_designer','Graphic Designer', false, array['employees.view','tasks.create']),
    ('video_editor','Video Editor', false, array['employees.view','tasks.create']),
    ('social_media_manager','Social Media Manager', false, array['employees.view','tasks.create']),
    ('accounts_manager','Accounts Manager', false, array['employees.view','salary.view','clients.view','clients.view_billing','reports.view']),
    ('client','Client', true, array[]::text[])
  ) as v(key, name, is_client, perms) loop
    insert into public.roles(org_id, key, name, is_system, is_client_role)
    values (p_org, r.key, r.name, true, r.is_client) on conflict (org_id, key) do nothing;
    insert into public.role_permissions(role_id, permission_key, org_id)
    select ro.id, unnest(r.perms), p_org from public.roles ro where ro.org_id = p_org and ro.key = r.key
    on conflict do nothing;
  end loop;

  insert into public.task_statuses(org_id, key, name, category, position, color, is_default) values
    (p_org,'todo','To Do','todo',1,'#64748b',true),
    (p_org,'in_progress','In Progress','in_progress',2,'#2563eb',false),
    (p_org,'in_review','In Review','review',3,'#d97706',false),
    (p_org,'changes_requested','Changes Requested','changes_requested',4,'#dc2626',false),
    (p_org,'completed','Completed','done',5,'#16a34a',false)
  on conflict do nothing;

  insert into public.work_schedules(org_id, name, is_default) values (p_org, 'General shift', true) on conflict do nothing;

  insert into public.leave_types(org_id, code, name, annual_quota, is_paid, allow_half_day, color) values
    (p_org,'CL','Casual Leave',12,true,true,'#0ea5e9'),
    (p_org,'SL','Sick Leave',6,true,true,'#f97316'),
    (p_org,'EL','Earned Leave',15,true,false,'#22c55e'),
    (p_org,'LWP','Leave Without Pay',null,false,true,'#94a3b8')
  on conflict do nothing;

  insert into public.salary_components(org_id, code, name, kind) values
    (p_org,'BASIC','Basic','earning'),(p_org,'HRA','House Rent Allowance','earning'),
    (p_org,'SPECIAL','Special Allowance','earning'),(p_org,'PF_EMP','Employee PF','deduction'),
    (p_org,'PT','Professional Tax','deduction')
  on conflict do nothing;

  insert into public.departments(org_id, name)
  select p_org, d from unnest(array['Management','Performance Marketing','SEO','Creative','Social Media','Web Development','HR & Admin','Accounts']) d
  on conflict do nothing;
  perform app.seed_phase4_defaults(p_org);
  perform set_config('app.bypass_guards', '', true);
end $$;

-- existing organizations (e.g. the live one) get the same Phase 4 defaults
do $$ declare o record; begin
  for o in select id from public.organizations loop perform app.seed_phase4_defaults(o.id); end loop;
end $$;

revoke execute on all functions in schema app from public, anon;
grant execute on all functions in schema app to authenticated, service_role;

-- ===== 20261027000009_time_tracking.sql =====
-- =====================================================================
-- 0009 PHASE 4: time tracking and weekly timesheets
-- Timer start/stop use server time. Entries in a submitted/approved
-- timesheet are locked; a rejected timesheet unlocks them again.
-- =====================================================================
create type public.timesheet_status as enum ('submitted','approved','rejected');

create table public.timesheets (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  week_start date not null check (extract(isodow from week_start) = 1),
  status public.timesheet_status not null default 'submitted',
  total_minutes integer not null default 0,
  submitted_at timestamptz not null default now(),
  decided_by uuid references public.profiles(id) on delete set null,
  decided_at timestamptz,
  decision_note text,
  unique (profile_id, week_start)
);
create index on public.timesheets(org_id, status);
create trigger trg_audit after insert or update or delete on public.timesheets for each row execute function app.audit();

create table public.time_entries (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  task_id uuid not null references public.tasks(id) on delete cascade,
  project_id uuid not null references public.projects(id) on delete cascade,   -- denormalised from task
  entry_date date not null,
  started_at timestamptz,
  ended_at timestamptz,
  minutes integer check (minutes is null or minutes between 1 and 1440),
  source text not null default 'manual' check (source in ('timer','manual')),
  note text check (note is null or length(note) <= 1000),
  billable boolean not null default true,
  timesheet_id uuid references public.timesheets(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check ((source = 'timer' and started_at is not null) or (source = 'manual' and minutes is not null)),
  check (ended_at is null or started_at is null or ended_at >= started_at)
);
create index on public.time_entries(profile_id, entry_date);
create index on public.time_entries(task_id);
create index on public.time_entries(project_id);
create unique index time_entries_one_running on public.time_entries(profile_id) where source = 'timer' and ended_at is null;
create trigger trg_te_touch before update on public.time_entries for each row execute function app.touch_updated_at();

create or replace function app.org_today(p_org uuid) returns date
language sql stable security definer set search_path = '' as $$
  select (now() at time zone timezone)::date from public.organizations where id = p_org
$$;

-- who may see someone's time: themselves, time.view_all, their reporting manager, or the project's manager
create or replace function app.can_see_time_of(p_profile uuid, p_project uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select app.is_internal() and (p_profile = auth.uid() or app.has_perm('time.view_all')
    or (p_project is not null and app.can_manage_project(p_project))
    or exists (select 1 from public.employee_profiles e where e.profile_id = p_profile and app.is_manager_of(e.id)))
$$;

alter table public.time_entries enable row level security;
alter table public.timesheets enable row level security;
create policy te_select on public.time_entries for select to authenticated
  using (org_id = (select app.org_id()) and app.can_see_time_of(profile_id, project_id));
create policy te_insert on public.time_entries for insert to authenticated
  with check (org_id = (select app.org_id()) and profile_id = auth.uid() and (select app.is_internal()) and app.can_view_task(task_id));
create policy te_update on public.time_entries for update to authenticated
  using (profile_id = auth.uid()) with check (profile_id = auth.uid() and app.can_view_task(task_id));
create policy te_delete on public.time_entries for delete to authenticated using (profile_id = auth.uid());
create policy tsh_select on public.timesheets for select to authenticated
  using (org_id = (select app.org_id()) and app.can_see_time_of(profile_id, null));
grant select, insert, delete on public.time_entries to authenticated;
grant update (task_id, entry_date, minutes, note, billable) on public.time_entries to authenticated;
grant select on public.timesheets to authenticated;

-- ---------- timer RPCs (server time) ----------
create or replace function public.stop_timer() returns public.time_entries
language plpgsql security definer set search_path = '' as $$
declare e public.time_entries; v_min int;
begin
  select * into e from public.time_entries where profile_id = auth.uid() and source = 'timer' and ended_at is null;
  if e.id is null then return null; end if;
  v_min := greatest(1, least(1440, round(extract(epoch from (now() - e.started_at)) / 60.0)::int));
  perform set_config('app.bypass_guards', 'on', true);
  update public.time_entries set ended_at = now(), minutes = v_min where id = e.id returning * into e;
  perform set_config('app.bypass_guards', '', true);
  return e;
end $$;

-- RPCs below set the bypass flag so they (and only they) may write timer rows
create or replace function app.time_entry_before_write() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_task public.tasks; v_locked boolean; v_day_total int; v_user boolean := auth.uid() is not null and not app.guards_bypassed();
begin
  if tg_op in ('UPDATE','DELETE') and old.timesheet_id is not null and v_user then
    select status in ('submitted','approved') into v_locked from public.timesheets where id = old.timesheet_id;
    if v_locked then raise exception 'This time is in a submitted or approved timesheet and cannot be changed' using errcode = '42501'; end if;
  end if;
  if tg_op = 'DELETE' then return old; end if;

  select * into v_task from public.tasks where id = new.task_id;
  new.org_id := v_task.org_id;
  new.project_id := v_task.project_id;
  if tg_op = 'UPDATE' and v_user then
    if new.profile_id <> old.profile_id or new.source <> old.source or new.started_at is distinct from old.started_at
       or (old.source = 'timer' and (new.ended_at is distinct from old.ended_at or new.minutes is distinct from old.minutes
                                     or new.entry_date is distinct from old.entry_date)) then
      raise exception 'Timer times are recorded by the server and cannot be edited; add a manual entry instead' using errcode = '42501'; end if;
    if new.timesheet_id is distinct from old.timesheet_id then
      raise exception 'Use Submit timesheet to attach time to a timesheet' using errcode = '42501'; end if;
  end if;
  if tg_op = 'INSERT' and v_user then
    if new.source = 'timer' then raise exception 'Use the timer controls to start a timer' using errcode = '42501'; end if;
    new.timesheet_id := null;
  end if;
  if not exists (select 1 from public.profiles where id = new.profile_id and org_id = new.org_id and client_id is null) then
    raise exception 'Time can only be logged by internal users of the same organization' using errcode = '23514'; end if;
  if new.source = 'manual' then
    new.started_at := null; new.ended_at := null;
    if new.entry_date > app.org_today(new.org_id) then
      raise exception 'Time cannot be logged for a future date' using errcode = '22023'; end if;
    if new.entry_date < app.org_today(new.org_id) - 60 then
      raise exception 'Time older than 60 days cannot be logged' using errcode = '22023'; end if;
  end if;
  if new.minutes is not null then
    select coalesce(sum(minutes), 0) into v_day_total from public.time_entries
     where profile_id = new.profile_id and entry_date = new.entry_date and id <> new.id;
    if v_day_total + new.minutes > 1440 then
      raise exception 'More than 24 hours logged on one day' using errcode = '22023'; end if;
  end if;
  if v_user and exists (select 1 from public.timesheets ts where ts.profile_id = new.profile_id
       and ts.week_start = date_trunc('week', new.entry_date)::date and ts.status in ('submitted','approved')) then
    raise exception 'That week''s timesheet is already submitted' using errcode = '42501'; end if;
  return new;
end $$;

create trigger trg_te_before before insert or update or delete on public.time_entries
  for each row execute function app.time_entry_before_write();

create or replace function public.start_timer(p_task uuid, p_note text default null) returns public.time_entries
language plpgsql security definer set search_path = '' as $$
declare e public.time_entries; v_org uuid := app.org_id();
begin
  if not app.is_internal() then raise exception 'Only staff can track time' using errcode = '42501'; end if;
  if not app.can_view_task(p_task) then raise exception 'Task not found' using errcode = '42501'; end if;
  perform public.stop_timer();
  if exists (select 1 from public.timesheets where profile_id = auth.uid()
             and week_start = date_trunc('week', app.org_today(v_org))::date and status in ('submitted','approved')) then
    raise exception 'This week''s timesheet is already submitted' using errcode = '42501'; end if;
  perform set_config('app.bypass_guards', 'on', true);
  insert into public.time_entries(org_id, profile_id, task_id, project_id, entry_date, started_at, source, note)
  select v_org, auth.uid(), t.id, t.project_id, app.org_today(v_org), now(), 'timer', nullif(trim(p_note), '')
  from public.tasks t where t.id = p_task
  returning * into e;
  perform set_config('app.bypass_guards', '', true);
  return e;
end $$;

-- ---------- timesheets ----------
create or replace function public.submit_timesheet(p_week_start date) returns public.timesheets
language plpgsql security definer set search_path = '' as $$
declare v_ts public.timesheets; v_org uuid := app.org_id(); v_week date := date_trunc('week', p_week_start)::date;
        v_total int; v_emp uuid := app.my_employee_id(); a uuid;
begin
  if not app.is_internal() then raise exception 'Only staff have timesheets' using errcode = '42501'; end if;
  if v_week > app.org_today(v_org) then raise exception 'You cannot submit a future week' using errcode = '22023'; end if;
  if exists (select 1 from public.time_entries where profile_id = auth.uid() and source = 'timer' and ended_at is null
             and entry_date between v_week and v_week + 6) then
    raise exception 'Stop your running timer first' using errcode = '22023'; end if;
  select * into v_ts from public.timesheets where profile_id = auth.uid() and week_start = v_week;
  if v_ts.status in ('submitted','approved') then raise exception 'This timesheet is already %', v_ts.status using errcode = '22023'; end if;
  select coalesce(sum(minutes), 0) into v_total from public.time_entries
   where profile_id = auth.uid() and entry_date between v_week and v_week + 6;
  if v_total = 0 then raise exception 'There is no time logged in this week' using errcode = '22023'; end if;
  perform set_config('app.bypass_guards', 'on', true);
  insert into public.timesheets(org_id, profile_id, week_start, status, total_minutes, submitted_at)
  values (v_org, auth.uid(), v_week, 'submitted', v_total, now())
  on conflict (profile_id, week_start) do update
    set status = 'submitted', total_minutes = excluded.total_minutes, submitted_at = now(),
        decided_by = null, decided_at = null, decision_note = null
  returning * into v_ts;
  update public.time_entries set timesheet_id = v_ts.id
   where profile_id = auth.uid() and entry_date between v_week and v_week + 6;
  perform set_config('app.bypass_guards', '', true);
  for a in select x from app.approvers_for(v_emp, 'timesheets.approve') x where x <> auth.uid() loop
    perform app.notify(a, 'timesheet_submitted', 'Timesheet to approve',
      (select full_name from public.profiles where id = auth.uid()) || ' — week of ' || to_char(v_week, 'DD Mon'),
      '/time?tab=approvals', 'timesheet', v_ts.id, 'ts:' || v_ts.id || ':' || (extract(epoch from v_ts.submitted_at) * 1000000)::bigint);
  end loop;
  return v_ts;
end $$;

create or replace function public.decide_timesheet(p_timesheet uuid, p_approve boolean, p_note text default null)
returns public.timesheets language plpgsql security definer set search_path = '' as $$
declare v_ts public.timesheets; v_emp uuid;
begin
  select * into v_ts from public.timesheets where id = p_timesheet and org_id = app.org_id() for update;
  if v_ts.id is null then raise exception 'Timesheet not found' using errcode = 'P0002'; end if;
  if v_ts.profile_id = auth.uid() then raise exception 'You cannot approve your own timesheet' using errcode = '42501'; end if;
  select id into v_emp from public.employee_profiles where profile_id = v_ts.profile_id;
  if not (app.has_perm('timesheets.approve') or (v_emp is not null and app.is_manager_of(v_emp))) then
    raise exception 'Not allowed to approve timesheets' using errcode = '42501'; end if;
  if v_ts.status <> 'submitted' then raise exception 'Only submitted timesheets can be decided' using errcode = '22023'; end if;
  if not p_approve and coalesce(trim(p_note), '') = '' then
    raise exception 'Please give a reason when rejecting' using errcode = '22023'; end if;
  update public.timesheets set status = case when p_approve then 'approved' else 'rejected' end::public.timesheet_status,
    decided_by = auth.uid(), decided_at = now(), decision_note = nullif(trim(p_note), '')
  where id = p_timesheet returning * into v_ts;
  perform app.notify(v_ts.profile_id, 'timesheet_decided',
    'Timesheet ' || v_ts.status::text || ': week of ' || to_char(v_ts.week_start, 'DD Mon'), v_ts.decision_note,
    '/time', 'timesheet', v_ts.id, 'tsd:' || v_ts.id || ':' || (extract(epoch from v_ts.decided_at) * 1000000)::bigint);
  return v_ts;
end $$;

-- actual vs estimated per task, visible to anyone who can see the task (internal)
create or replace function public.task_time_summary(p_task uuid)
returns table (logged_minutes bigint, estimated_minutes integer, running boolean)
language sql stable security definer set search_path = '' as $$
  select coalesce(sum(e.minutes), 0), t.estimated_minutes,
         exists (select 1 from public.time_entries r where r.task_id = t.id and r.source = 'timer' and r.ended_at is null)
  from public.tasks t left join public.time_entries e on e.task_id = t.id
  where t.id = p_task and app.is_internal() and app.can_view_task(t.id)
  group by t.id, t.estimated_minutes
$$;

-- per-project actual vs estimated (internal, project visible)
create or replace function public.project_time_summary(p_project uuid)
returns table (task_id uuid, title text, estimated_minutes integer, logged_minutes bigint)
language sql stable security definer set search_path = '' as $$
  select t.id, t.title, t.estimated_minutes, coalesce(sum(e.minutes), 0)
  from public.tasks t left join public.time_entries e on e.task_id = t.id
  where t.project_id = p_project and app.is_internal() and app.can_view_project(p_project)
  group by t.id, t.title, t.estimated_minutes
  order by coalesce(sum(e.minutes), 0) desc
$$;

revoke execute on function public.start_timer(uuid, text), public.stop_timer(), public.submit_timesheet(date),
  public.decide_timesheet(uuid, boolean, text), public.task_time_summary(uuid), public.project_time_summary(uuid) from public, anon;
grant execute on function public.start_timer(uuid, text), public.stop_timer(), public.submit_timesheet(date),
  public.decide_timesheet(uuid, boolean, text), public.task_time_summary(uuid), public.project_time_summary(uuid) to authenticated;
revoke execute on all functions in schema app from public, anon;
grant execute on all functions in schema app to authenticated, service_role;

-- ===== 20261027000010_content_calendar.sql =====
-- =====================================================================
-- 0010 PHASE 4: content calendar with client approval
-- Pipeline: idea -> in_progress -> internal_review -> client_review
--           -> (changes_requested -> in_progress ...) -> approved -> scheduled -> published
-- Client portal users see items once they reach client_review, and can only
-- approve / request changes through review_content().
-- =====================================================================
create type public.content_status as enum
  ('idea','in_progress','internal_review','client_review','changes_requested','approved','scheduled','published','cancelled');

create table public.content_items (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  client_id uuid not null references public.clients(id) on delete cascade,
  project_id uuid references public.projects(id) on delete set null,
  title text not null check (length(trim(title)) between 2 and 200),
  platform text not null check (platform in ('instagram','facebook','linkedin','youtube','x','google_business','blog','email','other')),
  content_type text not null default 'post' check (content_type in ('post','reel','story','carousel','video','short','blog','email','ad')),
  caption text check (caption is null or length(caption) <= 5000),
  creative_url text check (creative_url is null or creative_url ~* '^https?://'),
  scheduled_at timestamptz,
  status public.content_status not null default 'idea',
  assignee_id uuid references public.profiles(id) on delete set null,
  client_feedback text,
  reviewed_by uuid references public.profiles(id) on delete set null,
  reviewed_at timestamptz,
  published_url text check (published_url is null or published_url ~* '^https?://'),
  published_at timestamptz,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index on public.content_items(org_id, scheduled_at);
create index on public.content_items(client_id, status);
create index on public.content_items(assignee_id);
create trigger trg_ci_touch before update on public.content_items for each row execute function app.touch_updated_at();
create trigger trg_audit after insert or update or delete on public.content_items for each row execute function app.audit();

create or replace function app.can_view_content(c public.content_items) returns boolean
language sql stable security definer set search_path = '' as $$
  select c.org_id = app.org_id() and (
    (app.is_internal() and (app.has_perm('content.view_all') or app.has_perm('content.manage')
       or c.assignee_id = auth.uid() or c.created_by = auth.uid() or app.can_view_client(c.client_id)
       or (c.project_id is not null and app.can_view_project(c.project_id))))
    or (c.client_id = app.client_id() and c.status in ('client_review','changes_requested','approved','scheduled','published')))
$$;

create or replace function app.can_edit_content(c public.content_items) returns boolean
language sql stable security definer set search_path = '' as $$
  select c.org_id = app.org_id() and app.is_internal()
    and (app.has_perm('content.manage') or c.assignee_id = auth.uid() or c.created_by = auth.uid())
$$;

create or replace function app.content_before_write() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_old public.content_status := case when tg_op = 'UPDATE' then old.status end; a uuid;
begin
  if not exists (select 1 from public.clients where id = new.client_id and org_id = new.org_id) then
    raise exception 'Client must belong to the same organization' using errcode = '23514'; end if;
  if new.project_id is not null and not exists (select 1 from public.projects where id = new.project_id
       and org_id = new.org_id and client_id = new.client_id) then
    raise exception 'Project must belong to the same client' using errcode = '23514'; end if;
  if new.assignee_id is not null and not exists (select 1 from public.profiles where id = new.assignee_id
       and org_id = new.org_id and client_id is null) then
    raise exception 'Assignee must be an internal user' using errcode = '23514'; end if;

  if auth.uid() is not null and not app.guards_bypassed() then
    -- approval is the client's decision; internal staff need content.manage to record it on their behalf
    if new.status = 'approved' and v_old is distinct from 'approved' and not app.has_perm('content.manage') then
      raise exception 'Only the client (or a content manager on their behalf) can approve content' using errcode = '42501'; end if;
    if new.status in ('scheduled','published') and v_old is distinct from new.status
       and coalesce(v_old::text, '') not in ('approved','scheduled','published') then
      raise exception 'Content must be approved before it is scheduled or published' using errcode = '22023'; end if;
    if new.status = 'scheduled' and new.scheduled_at is null then
      raise exception 'Set a date and time before scheduling' using errcode = '22023'; end if;
    if tg_op = 'UPDATE' and (new.client_feedback is distinct from old.client_feedback
                             or new.reviewed_by is distinct from old.reviewed_by) then
      raise exception 'Client feedback is recorded through the review action' using errcode = '42501'; end if;
    if tg_op = 'UPDATE' and v_old in ('approved','scheduled','published') and new.status = v_old
       and (new.caption is distinct from old.caption or new.creative_url is distinct from old.creative_url) then
      raise exception 'Approved content is locked; send it back for review to change it' using errcode = '22023'; end if;
  end if;
  if new.status = 'published' and new.published_at is null then new.published_at := now(); end if;
  if new.status = 'approved' and v_old is distinct from 'approved' and new.reviewed_at is null then
    new.reviewed_by := auth.uid(); new.reviewed_at := now(); end if;

  if new.status = 'client_review' and v_old is distinct from 'client_review' then
    for a in select p.id from public.profiles p where p.client_id = new.client_id and p.is_active loop
      perform app.notify(a, 'content_review', 'Please review: ' || new.title,
        initcap(new.platform) || coalesce(' · ' || to_char(new.scheduled_at at time zone (select timezone from public.organizations where id = new.org_id), 'DD Mon HH24:MI'), ''),
        '/content', 'content', new.id, 'cr:' || new.id || ':' || (extract(epoch from now()) * 1000000)::bigint);
    end loop;
  end if;
  return new;
end $$;
create trigger trg_ci_before before insert or update on public.content_items
  for each row execute function app.content_before_write();

alter table public.content_items enable row level security;
create policy ci_select on public.content_items for select to authenticated using (app.can_view_content(content_items));
create policy ci_insert on public.content_items for insert to authenticated
  with check (org_id = (select app.org_id()) and (select app.is_internal()) and created_by = auth.uid()
    and ((select app.has_perm('content.manage')) or app.can_view_client(client_id)));
create policy ci_update on public.content_items for update to authenticated
  using (app.can_edit_content(content_items)) with check (app.can_edit_content(content_items));
create policy ci_delete on public.content_items for delete to authenticated
  using (org_id = (select app.org_id()) and ((select app.has_perm('content.manage')) or (created_by = auth.uid() and status = 'idea')));
grant select, insert, delete on public.content_items to authenticated;
grant update (title, platform, content_type, caption, creative_url, scheduled_at, status, assignee_id, project_id,
              published_url, published_at) on public.content_items to authenticated;

-- the client's decision (also usable by internal content managers on the client's behalf)
create or replace function public.review_content(p_item uuid, p_approve boolean, p_feedback text default null)
returns public.content_items language plpgsql security definer set search_path = '' as $$
declare c public.content_items; a uuid;
begin
  select * into c from public.content_items where id = p_item for update;
  if c.id is null or not app.can_view_content(c) then raise exception 'Content not found' using errcode = 'P0002'; end if;
  if not (c.client_id = app.client_id() or (app.is_internal() and app.has_perm('content.manage'))) then
    raise exception 'Only the client can review this content' using errcode = '42501'; end if;
  if c.status <> 'client_review' then raise exception 'This item is not waiting for review' using errcode = '22023'; end if;
  if not p_approve and coalesce(trim(p_feedback), '') = '' then
    raise exception 'Please describe the changes you need' using errcode = '22023'; end if;
  perform set_config('app.bypass_guards', 'on', true);
  update public.content_items set status = case when p_approve then 'approved' else 'changes_requested' end::public.content_status,
    client_feedback = nullif(trim(p_feedback), ''), reviewed_by = auth.uid(), reviewed_at = now()
  where id = p_item returning * into c;
  perform set_config('app.bypass_guards', '', true);
  for a in select x from (values (c.assignee_id), (c.created_by)) v(x) where x is not null loop
    perform app.notify(a, 'content_reviewed', case when p_approve then 'Approved: ' else 'Changes requested: ' end || c.title,
      c.client_feedback, '/content', 'content', c.id, 'crd:' || c.id || ':' || (extract(epoch from c.reviewed_at) * 1000000)::bigint);
  end loop;
  return c;
end $$;
revoke execute on function public.review_content(uuid, boolean, text) from public, anon;
grant execute on function public.review_content(uuid, boolean, text) to authenticated;
revoke execute on all functions in schema app from public, anon;
grant execute on all functions in schema app to authenticated, service_role;

-- ===== 20261027000011_campaigns.sql =====
-- =====================================================================
-- 0011 PHASE 4: ad campaign tracking (Google / Meta) with CSV import
-- Ad spend lives here and is never mixed with the agency's management
-- fee (contracts.management_fee, billing permission only).
-- Duplicate protection: one metrics row per campaign per day, and the
-- same file (SHA-256) cannot be imported twice.
-- =====================================================================
create table public.campaigns (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  client_id uuid not null references public.clients(id) on delete cascade,
  project_id uuid references public.projects(id) on delete set null,
  platform text not null check (platform in ('google_ads','meta_ads','other')),
  name text not null check (length(trim(name)) between 2 and 200),
  external_id text check (external_id is null or length(external_id) between 1 and 64),
  objective text,
  status text not null default 'active' check (status in ('draft','active','paused','ended')),
  start_date date,
  end_date date,
  monthly_budget numeric(14,2) check (monthly_budget is null or monthly_budget >= 0),  -- ad spend budget (client's money)
  currency char(3) not null default 'INR',
  client_visible boolean not null default true,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (end_date is null or start_date is null or end_date >= start_date)
);
create unique index campaigns_external on public.campaigns(org_id, platform, external_id) where external_id is not null;
create unique index campaigns_client_name on public.campaigns(client_id, platform, lower(name));
create index on public.campaigns(client_id);
create trigger trg_camp_touch before update on public.campaigns for each row execute function app.touch_updated_at();
create trigger trg_audit after insert or update or delete on public.campaigns for each row execute function app.audit();

create table public.campaign_imports (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  client_id uuid not null references public.clients(id) on delete cascade,
  platform text not null,
  file_name text not null,
  file_sha256 text not null check (file_sha256 ~ '^[0-9a-f]{64}$'),
  rows_total integer not null default 0,
  rows_inserted integer not null default 0,
  rows_updated integer not null default 0,
  rows_skipped integer not null default 0,
  campaigns_created integer not null default 0,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (org_id, file_sha256)
);

create table public.campaign_metrics_daily (
  campaign_id uuid not null references public.campaigns(id) on delete cascade,
  metric_date date not null,
  org_id uuid not null references public.organizations(id) on delete cascade,
  impressions bigint not null default 0 check (impressions >= 0),
  clicks bigint not null default 0 check (clicks >= 0),
  spend numeric(14,2) not null default 0 check (spend >= 0),
  conversions numeric(12,2) not null default 0 check (conversions >= 0),
  conversion_value numeric(14,2) not null default 0 check (conversion_value >= 0),
  import_id uuid references public.campaign_imports(id) on delete set null,
  updated_at timestamptz not null default now(),
  primary key (campaign_id, metric_date),
  check (clicks <= impressions or impressions = 0)
);
create index on public.campaign_metrics_daily(org_id, metric_date);

create or replace function app.campaign_before_write() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.clients where id = new.client_id and org_id = new.org_id) then
    raise exception 'Client must belong to the same organization' using errcode = '23514'; end if;
  if new.project_id is not null and not exists (select 1 from public.projects where id = new.project_id
       and org_id = new.org_id and client_id = new.client_id) then
    raise exception 'Project must belong to the same client' using errcode = '23514'; end if;
  return new;
end $$;
create trigger trg_camp_before before insert or update on public.campaigns
  for each row execute function app.campaign_before_write();

create or replace function app.metric_before_write() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  new.org_id := (select org_id from public.campaigns where id = new.campaign_id);
  new.updated_at := now();
  return new;
end $$;
create trigger trg_metric_before before insert or update on public.campaign_metrics_daily
  for each row execute function app.metric_before_write();

create or replace function app.can_view_campaign(p_campaign uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.campaigns c where c.id = p_campaign and c.org_id = app.org_id() and (
    (app.is_internal() and (app.has_perm('campaigns.view') or app.has_perm('campaigns.manage') or app.can_view_client(c.client_id)))
    or (c.client_visible and c.client_id = app.client_id())))
$$;

alter table public.campaigns enable row level security;
alter table public.campaign_imports enable row level security;
alter table public.campaign_metrics_daily enable row level security;
create policy camp_select on public.campaigns for select to authenticated using (app.can_view_campaign(id));
create policy camp_write on public.campaigns for all to authenticated
  using (org_id = (select app.org_id()) and (select app.has_perm('campaigns.manage')))
  with check (org_id = (select app.org_id()) and (select app.has_perm('campaigns.manage')));
create policy cimp_select on public.campaign_imports for select to authenticated
  using (org_id = (select app.org_id()) and (select app.is_internal())
         and ((select app.has_perm('campaigns.view')) or (select app.has_perm('campaigns.manage'))));
create policy cm_select on public.campaign_metrics_daily for select to authenticated using (app.can_view_campaign(campaign_id));
create policy cm_write on public.campaign_metrics_daily for all to authenticated
  using (org_id = (select app.org_id()) and (select app.has_perm('campaigns.manage')))
  with check ((select app.has_perm('campaigns.manage')) and app.can_view_campaign(campaign_id));
grant select, insert, update, delete on public.campaigns, public.campaign_metrics_daily to authenticated;
grant select on public.campaign_imports to authenticated;

-- campaign totals (SECURITY INVOKER view: RLS of the caller applies)
create view public.campaign_summary with (security_invoker = true) as
select c.id as campaign_id, c.client_id, c.platform, c.name, c.status, c.monthly_budget, c.currency,
       coalesce(sum(m.impressions), 0) as impressions, coalesce(sum(m.clicks), 0) as clicks,
       coalesce(sum(m.spend), 0) as spend, coalesce(sum(m.conversions), 0) as conversions,
       coalesce(sum(m.conversion_value), 0) as conversion_value,
       case when sum(m.impressions) > 0 then round(100.0 * sum(m.clicks) / sum(m.impressions), 2) end as ctr_pct,
       case when sum(m.clicks) > 0 then round(sum(m.spend) / sum(m.clicks), 2) end as cpc,
       case when sum(m.conversions) > 0 then round(sum(m.spend) / sum(m.conversions), 2) end as cpa,
       case when sum(m.spend) > 0 then round(sum(m.conversion_value) / sum(m.spend), 2) end as roas,
       min(m.metric_date) as first_date, max(m.metric_date) as last_date
from public.campaigns c left join public.campaign_metrics_daily m on m.campaign_id = c.id
group by c.id;
grant select on public.campaign_summary to authenticated;

-- Import parsed CSV rows for one client + platform.
-- p_rows: [{"campaign": "Name", "campaign_id": "123" (optional), "date": "2026-10-01", "impressions": 1, "clicks": 1,
--           "spend": 1.5, "conversions": 0, "conversion_value": 0}, ...]
-- p_mode: 'skip' keeps existing days untouched, 'overwrite' replaces them.
create or replace function public.import_campaign_metrics(p_client uuid, p_platform text, p_file_name text,
  p_file_sha256 text, p_rows jsonb, p_mode text default 'skip') returns public.campaign_imports
language plpgsql security definer set search_path = '' as $$
declare v_org uuid := app.org_id(); v_imp public.campaign_imports; r jsonb; v_camp uuid; v_date date; v_name text; v_ext text;
        v_ins int := 0; v_upd int := 0; v_skip int := 0; v_new_camps int := 0; v_existed boolean; v_n int := 0; v_today date;
begin
  if not (app.is_internal() and app.has_perm('campaigns.manage')) then
    raise exception 'Not allowed to import campaign data' using errcode = '42501'; end if;
  if not exists (select 1 from public.clients where id = p_client and org_id = v_org) then
    raise exception 'Client not found' using errcode = 'P0002'; end if;
  if p_platform not in ('google_ads','meta_ads','other') then raise exception 'Unknown platform' using errcode = '22023'; end if;
  if p_mode not in ('skip','overwrite') then raise exception 'Mode must be skip or overwrite' using errcode = '22023'; end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    raise exception 'The file has no data rows' using errcode = '22023'; end if;
  if jsonb_array_length(p_rows) > 20000 then raise exception 'Too many rows (max 20,000 per file)' using errcode = '22023'; end if;
  if exists (select 1 from public.campaign_imports where org_id = v_org and file_sha256 = lower(p_file_sha256)) then
    raise exception 'This exact file was already imported' using errcode = '23505'; end if;
  v_today := app.org_today(v_org);

  insert into public.campaign_imports(org_id, client_id, platform, file_name, file_sha256, created_by)
  values (v_org, p_client, p_platform, left(p_file_name, 255), lower(p_file_sha256), auth.uid()) returning * into v_imp;

  for r in select * from jsonb_array_elements(p_rows) loop
    v_n := v_n + 1;
    v_name := nullif(trim(r->>'campaign'), '');
    v_ext := nullif(trim(r->>'campaign_id'), '');
    begin
      v_date := (r->>'date')::date;
    exception when others then
      raise exception 'Row %: invalid date "%"', v_n, r->>'date' using errcode = '22023';
    end;
    if v_name is null and v_ext is null then raise exception 'Row %: campaign name is missing', v_n using errcode = '22023'; end if;
    if v_date is null or v_date > v_today then raise exception 'Row %: date is missing or in the future', v_n using errcode = '22023'; end if;

    v_camp := null;
    if v_ext is not null then
      select id into v_camp from public.campaigns where org_id = v_org and platform = p_platform and external_id = v_ext;
      if v_camp is not null and not exists (select 1 from public.campaigns where id = v_camp and client_id = p_client) then
        raise exception 'Row %: campaign ID % belongs to another client', v_n, v_ext using errcode = '23514'; end if;
    end if;
    if v_camp is null and v_name is not null then
      select id into v_camp from public.campaigns where client_id = p_client and platform = p_platform and lower(name) = lower(v_name);
    end if;
    if v_camp is null then
      insert into public.campaigns(org_id, client_id, platform, name, external_id, created_by)
      values (v_org, p_client, p_platform, coalesce(v_name, 'Campaign ' || v_ext), v_ext, auth.uid()) returning id into v_camp;
      v_new_camps := v_new_camps + 1;
    end if;

    v_existed := exists (select 1 from public.campaign_metrics_daily where campaign_id = v_camp and metric_date = v_date);
    if v_existed and p_mode = 'skip' then v_skip := v_skip + 1; continue; end if;
    begin
      insert into public.campaign_metrics_daily(campaign_id, metric_date, org_id, impressions, clicks, spend, conversions, conversion_value, import_id)
      values (v_camp, v_date, v_org, coalesce((r->>'impressions')::bigint, 0), coalesce((r->>'clicks')::bigint, 0),
              coalesce((r->>'spend')::numeric, 0), coalesce((r->>'conversions')::numeric, 0),
              coalesce((r->>'conversion_value')::numeric, 0), v_imp.id)
      on conflict (campaign_id, metric_date) do update set impressions = excluded.impressions, clicks = excluded.clicks,
        spend = excluded.spend, conversions = excluded.conversions, conversion_value = excluded.conversion_value,
        import_id = excluded.import_id;
    exception when check_violation or invalid_text_representation or numeric_value_out_of_range then
      raise exception 'Row %: numbers must be valid and not negative (clicks cannot exceed impressions)', v_n using errcode = '22023';
    end;
    if v_existed then v_upd := v_upd + 1; else v_ins := v_ins + 1; end if;
  end loop;

  update public.campaign_imports set rows_total = v_n, rows_inserted = v_ins, rows_updated = v_upd, rows_skipped = v_skip,
    campaigns_created = v_new_camps where id = v_imp.id returning * into v_imp;
  return v_imp;
end $$;
revoke execute on function public.import_campaign_metrics(uuid, text, text, text, jsonb, text) from public, anon;
grant execute on function public.import_campaign_metrics(uuid, text, text, text, jsonb, text) to authenticated;
revoke execute on all functions in schema app from public, anon;
grant execute on all functions in schema app to authenticated, service_role;

-- ===== 20261028000012_email_outbox.sql =====
-- =====================================================================
-- 0012 PHASE 5: permissions for Phase 5 + e-mail delivery (outbox)
-- E-mails are queued in public.email_outbox by database code and sent by
-- the `send-emails` Edge Function (Resend). Nothing is queued until an
-- admin turns e-mail on in Settings, so the queue never grows unattended.
-- =====================================================================

-- ---------- permission catalog (all Phase 5 keys) ----------
insert into public.permissions(key, module, description, is_sensitive) values
 ('invoices.view','finance','View invoices, payments and collections', true),
 ('invoices.manage','finance','Create, issue and cancel invoices, record payments, edit billing settings', true),
 ('payroll.view','payroll','View payroll runs and everyone''s payslips', true),
 ('payroll.run','payroll','Prepare, finalize and mark payroll as paid', true),
 ('recruitment.view','recruitment','View job openings and candidates', true),
 ('recruitment.manage','recruitment','Manage openings, candidates, interviews and offers', true)
on conflict (key) do nothing;

-- ---------- e-mail settings (one row per organization) ----------
create table public.email_settings (
  org_id uuid primary key references public.organizations(id) on delete cascade,
  enabled boolean not null default false,
  app_url text check (app_url is null or app_url ~ '^https?://[^\s]+$'),
  from_name text check (from_name is null or length(from_name) <= 80),
  reply_to text check (reply_to is null or reply_to ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  send_notifications boolean not null default true,
  send_invoices boolean not null default true,
  updated_at timestamptz not null default now()
);
create trigger trg_es_touch before update on public.email_settings for each row execute function app.touch_updated_at();
create trigger trg_audit after insert or update or delete on public.email_settings for each row execute function app.audit();

create table public.email_outbox (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  to_email text not null check (to_email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  to_name text,
  subject text not null check (length(subject) between 1 and 250),
  body_text text not null,
  category text not null check (category in ('notification','invoice','invoice_reminder','offer','test')),
  entity_type text,
  entity_id uuid,
  dedupe_key text not null,
  status text not null default 'queued' check (status in ('queued','sending','sent','failed')),
  attempts smallint not null default 0,
  last_error text,
  provider_id text,
  scheduled_at timestamptz not null default now(),
  locked_at timestamptz,
  sent_at timestamptz,
  created_at timestamptz not null default now(),
  unique (org_id, dedupe_key)
);
create index email_outbox_due on public.email_outbox(scheduled_at) where status in ('queued','sending');
create index on public.email_outbox(org_id, created_at desc);

alter table public.email_settings enable row level security;
alter table public.email_outbox enable row level security;
create policy es_select on public.email_settings for select to authenticated
  using (org_id = (select app.org_id()) and (select app.has_perm('org.manage')));
create policy es_write on public.email_settings for all to authenticated
  using (org_id = (select app.org_id()) and (select app.has_perm('org.manage')))
  with check (org_id = (select app.org_id()) and (select app.has_perm('org.manage')));
create policy eo_select on public.email_outbox for select to authenticated
  using (org_id = (select app.org_id()) and (select app.has_perm('org.manage')));
grant select, insert, update on public.email_settings to authenticated;
grant select on public.email_outbox to authenticated;

-- Queue one e-mail if the organization has e-mail turned on for this category. Idempotent per dedupe key.
create or replace function app.queue_email(p_org uuid, p_to text, p_name text, p_subject text, p_body text,
  p_category text, p_entity_type text, p_entity_id uuid, p_dedupe text) returns boolean
language plpgsql security definer set search_path = '' as $$
declare s public.email_settings; v_id uuid;
begin
  select * into s from public.email_settings where org_id = p_org;
  if s.org_id is null or not s.enabled then return false; end if;
  if p_to is null or p_to !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then return false; end if;
  if (p_category = 'notification' and not s.send_notifications)
     or (p_category in ('invoice','invoice_reminder') and not s.send_invoices) then return false; end if;
  insert into public.email_outbox(org_id, to_email, to_name, subject, body_text, category, entity_type, entity_id, dedupe_key)
  values (p_org, lower(trim(p_to)), p_name, left(p_subject, 250), p_body, p_category, p_entity_type, p_entity_id, p_dedupe)
  on conflict (org_id, dedupe_key) do nothing returning id into v_id;
  return v_id is not null;
end $$;

-- Absolute link into the app for e-mails ('' when no app URL is configured)
create or replace function app.app_link(p_org uuid, p_path text) returns text
language sql stable security definer set search_path = '' as $$
  select case when s.app_url is null or p_path is null then '' else rtrim(s.app_url, '/') || p_path end
  from (select (select app_url from public.email_settings where org_id = p_org) as app_url) s
$$;

-- Every new in-app notification is also e-mailed, unless the person turned e-mail off for that type.
create or replace function app.trg_email_notification() returns trigger
language plpgsql security definer set search_path = '' as $$
declare p public.profiles; v_link text; v_org_name text;
begin
  if exists (select 1 from public.notification_preferences where profile_id = new.recipient_id and type = new.type and not email) then
    return new; end if;
  select * into p from public.profiles where id = new.recipient_id and is_active;
  if p.id is null then return new; end if;
  select name into v_org_name from public.organizations where id = new.org_id;
  v_link := app.app_link(new.org_id, new.link);
  perform app.queue_email(new.org_id, p.email, nullif(p.full_name, ''), new.title,
    concat_ws(E'\n\n', 'Hi ' || coalesce(nullif(split_part(p.full_name, ' ', 1), ''), 'there') || ',', new.title, new.body,
      case when v_link <> '' then 'Open: ' || v_link end,
      '— ' || v_org_name || E' Agency OS\nYou can turn these e-mails off in Settings → Notifications.'),
    'notification', 'notification', new.id, 'notif:' || new.id);
  return new;
exception when others then
  return new;  -- e-mail is best effort: never block the in-app notification
end $$;
create trigger trg_email_notification after insert on public.notifications
  for each row execute function app.trg_email_notification();

-- ---------- worker API (service role only: the send-emails Edge Function) ----------
create or replace function public.claim_emails(p_limit integer default 20)
returns table (id uuid, org_id uuid, to_email text, to_name text, subject text, body_text text, from_name text, reply_to text)
language plpgsql security definer set search_path = '' as $$
begin
  return query
  with picked as (
    select o.id from public.email_outbox o
    where o.scheduled_at <= now() and o.attempts < 5
      and (o.status = 'queued' or (o.status = 'sending' and o.locked_at < now() - interval '10 minutes'))
    order by o.scheduled_at limit greatest(1, least(coalesce(p_limit, 20), 100))
    for update skip locked),
  upd as (
    update public.email_outbox o set status = 'sending', locked_at = now(), attempts = o.attempts + 1
    from picked where o.id = picked.id returning o.*)
  select u.id, u.org_id, u.to_email, u.to_name, u.subject, u.body_text,
         coalesce(s.from_name, org.name), s.reply_to
  from upd u join public.organizations org on org.id = u.org_id
  left join public.email_settings s on s.org_id = u.org_id;
end $$;

create or replace function public.complete_email(p_id uuid, p_ok boolean, p_error text default null, p_provider_id text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare e public.email_outbox;
begin
  update public.email_outbox set
    status = case when p_ok then 'sent' when attempts >= 5 then 'failed' else 'queued' end,
    sent_at = case when p_ok then now() end,
    provider_id = coalesce(p_provider_id, provider_id),
    last_error = case when p_ok then null else left(p_error, 1000) end,
    scheduled_at = case when p_ok then scheduled_at else now() + (interval '2 minutes' * power(2, attempts)) end,
    locked_at = null
  where id = p_id and status = 'sending' returning * into e;
  if p_ok and e.entity_type = 'notification' then
    update public.notifications set emailed_at = now() where id = e.entity_id;
  end if;
end $$;
revoke execute on function public.claim_emails(integer) from public, anon, authenticated;
revoke execute on function public.complete_email(uuid, boolean, text, text) from public, anon, authenticated;
grant execute on function public.claim_emails(integer), public.complete_email(uuid, boolean, text, text) to service_role;

-- Admin: queue a test e-mail to yourself
create or replace function public.send_test_email() returns boolean
language plpgsql security definer set search_path = '' as $$
declare p public.profiles;
begin
  if not app.has_perm('org.manage') then raise exception 'Not allowed' using errcode = '42501'; end if;
  select * into p from public.profiles where id = auth.uid();
  if not exists (select 1 from public.email_settings where org_id = p.org_id and enabled) then
    raise exception 'Turn e-mail on first' using errcode = '22023'; end if;
  return app.queue_email(p.org_id, p.email, p.full_name, 'Test e-mail from Agency OS',
    'This is a test. If you can read it, e-mail delivery from Agency OS works.', 'test', null, null,
    'test:' || auth.uid() || ':' || extract(epoch from clock_timestamp())::bigint);
end $$;

create or replace function public.email_queue_stats() returns jsonb
language sql stable security definer set search_path = '' as $$
  select case when app.has_perm('org.manage') then jsonb_build_object(
    'queued', count(*) filter (where status in ('queued','sending')),
    'sent_7d', count(*) filter (where status = 'sent' and sent_at > now() - interval '7 days'),
    'failed', count(*) filter (where status = 'failed'),
    'last_sent_at', max(sent_at)) end
  from public.email_outbox where org_id = app.org_id()
$$;
revoke execute on function public.send_test_email(), public.email_queue_stats() from public, anon;
grant execute on function public.send_test_email(), public.email_queue_stats() to authenticated;

-- keep the outbox small: sent mail older than 90 days is removed by the scheduled job
create or replace function public.purge_old_emails() returns integer
language sql security definer set search_path = '' as $$
  with d as (delete from public.email_outbox where status in ('sent','failed') and created_at < now() - interval '90 days' returning 1)
  select count(*)::int from d
$$;
revoke execute on function public.purge_old_emails() from public, anon, authenticated;
grant execute on function public.purge_old_emails() to service_role;
do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('agency-os-purge-emails', '40 3 * * *', 'select public.purge_old_emails()');
  end if;
end $$;

revoke execute on all functions in schema app from public, anon;
grant execute on all functions in schema app to authenticated, service_role;

-- ===== 20261028000013_invoices.sql =====
-- =====================================================================
-- 0013 PHASE 5: GST invoices, payments, reminders, collections summary
-- * Management fee and ad spend are separate line kinds with separate
--   subtotals; ad spend defaults to 0% GST (pure-agent reimbursement),
--   configurable in billing settings.
-- * Invoice numbers are assigned only when an invoice is issued, per
--   Indian financial year (Apr–Mar), consecutive and never reused:
--   PREFIX/2026-27/0001. Cancelled invoices keep their number.
-- * Issued invoices are immutable; only issue/cancel/payment functions
--   change them. Clients see their own issued invoices in the portal.
-- =====================================================================

-- ---------- billing settings (the agency's own details) ----------
create table public.billing_settings (
  org_id uuid primary key references public.organizations(id) on delete cascade,
  legal_name text check (legal_name is null or length(legal_name) <= 160),
  gstin text check (gstin is null or gstin ~ '^[0-9]{2}[0-9A-Z]{13}$'),
  pan text check (pan is null or pan ~ '^[A-Z]{5}[0-9]{4}[A-Z]$'),
  state_code char(2) check (state_code is null or state_code ~ '^[0-9]{2}$'),
  address text,
  email text check (email is null or email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  phone text,
  invoice_prefix text not null default 'INV' check (invoice_prefix ~ '^[A-Z0-9-]{1,10}$'),
  default_sac text not null default '998361' check (default_sac ~ '^[0-9]{4,8}$'),
  default_gst_rate numeric(5,2) not null default 18 check (default_gst_rate in (0,5,12,18,28)),
  ad_spend_gst_rate numeric(5,2) not null default 0 check (ad_spend_gst_rate in (0,5,12,18,28)),
  bank_details text,
  terms text,
  updated_at timestamptz not null default now()
);
create trigger trg_bs_touch before update on public.billing_settings for each row execute function app.touch_updated_at();
create trigger trg_audit after insert or update or delete on public.billing_settings for each row execute function app.audit();

create or replace function app.billing_settings_before() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.gstin := nullif(upper(trim(new.gstin)), '');
  new.pan := nullif(upper(trim(new.pan)), '');
  if new.gstin is not null then new.state_code := left(new.gstin, 2); end if;
  return new;
end $$;
create trigger trg_bs_before before insert or update on public.billing_settings
  for each row execute function app.billing_settings_before();

-- client place of supply (state code); taken from the GSTIN when there is one
alter table public.client_billing add column state_code char(2) check (state_code is null or state_code ~ '^[0-9]{2}$');
create or replace function app.client_billing_before() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.gst_number := nullif(upper(trim(new.gst_number)), '');
  if new.gst_number is not null then new.state_code := left(new.gst_number, 2); end if;
  return new;
end $$;
create trigger trg_cb_before before insert or update on public.client_billing
  for each row execute function app.client_billing_before();
update public.client_billing set state_code = left(gst_number, 2) where gst_number is not null and state_code is null;

-- Indian financial year label for a date: 2026-10-27 -> '2026-27'
create or replace function app.fiscal_year(p_day date) returns text
language sql immutable set search_path = '' as $$
  select case when extract(month from p_day) >= 4
              then extract(year from p_day)::int || '-' || lpad(((extract(year from p_day)::int + 1) % 100)::text, 2, '0')
              else (extract(year from p_day)::int - 1) || '-' || lpad((extract(year from p_day)::int % 100)::text, 2, '0') end
$$;

create table public.invoice_sequences (
  org_id uuid not null references public.organizations(id) on delete cascade,
  fiscal_year text not null check (fiscal_year ~ '^[0-9]{4}-[0-9]{2}$'),
  last_number integer not null default 0,
  primary key (org_id, fiscal_year)
);

-- ---------- invoices ----------
create type public.invoice_status as enum ('draft','issued','partially_paid','paid','cancelled');

create table public.invoices (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  client_id uuid not null references public.clients(id) on delete restrict,
  contract_id uuid references public.contracts(id) on delete set null,
  billing_period text check (billing_period is null or billing_period ~ '^[0-9]{4}-(0[1-9]|1[0-2])$'),
  invoice_number text,
  fiscal_year text,
  status public.invoice_status not null default 'draft',
  issue_date date,
  due_date date,
  place_of_supply char(2) check (place_of_supply is null or place_of_supply ~ '^[0-9]{2}$'),
  tax_mode text not null default 'intra' check (tax_mode in ('intra','inter')),
  currency char(3) not null default 'INR',
  notes text check (notes is null or length(notes) <= 2000),
  seller jsonb,
  buyer jsonb,
  fee_subtotal numeric(14,2) not null default 0,
  ad_spend_subtotal numeric(14,2) not null default 0,
  other_subtotal numeric(14,2) not null default 0,
  taxable_total numeric(14,2) not null default 0,
  cgst numeric(14,2) not null default 0,
  sgst numeric(14,2) not null default 0,
  igst numeric(14,2) not null default 0,
  round_off numeric(6,2) not null default 0,
  total numeric(14,2) not null default 0,
  amount_received numeric(14,2) not null default 0,
  tds_deducted numeric(14,2) not null default 0,
  balance numeric(14,2) generated always as (total - amount_received - tds_deducted) stored,
  created_by uuid references public.profiles(id) on delete set null,
  issued_by uuid references public.profiles(id) on delete set null,
  issued_at timestamptz,
  cancelled_at timestamptz,
  cancel_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (org_id, invoice_number),
  check (status = 'draft' or (invoice_number is not null and issue_date is not null and due_date is not null)),
  check (due_date is null or issue_date is null or due_date >= issue_date),
  check (status <> 'cancelled' or cancel_reason is not null)
);
create index on public.invoices(org_id, status);
create index on public.invoices(client_id);
create index invoices_open_due on public.invoices(org_id, due_date) where status in ('issued','partially_paid');
create unique index invoices_contract_period on public.invoices(contract_id, billing_period)
  where status <> 'cancelled' and contract_id is not null and billing_period is not null;
create trigger trg_inv_touch before update on public.invoices for each row execute function app.touch_updated_at();
create trigger trg_audit after insert or update or delete on public.invoices for each row execute function app.audit();

create table public.invoice_items (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  invoice_id uuid not null references public.invoices(id) on delete cascade,
  kind text not null default 'management_fee' check (kind in ('management_fee','ad_spend','other')),
  description text not null check (length(trim(description)) between 2 and 500),
  sac text check (sac is null or sac ~ '^[0-9]{4,8}$'),
  quantity numeric(10,2) not null default 1 check (quantity > 0),
  unit_price numeric(14,2) not null check (unit_price >= 0),
  gst_rate numeric(5,2) not null default 18 check (gst_rate in (0,5,12,18,28)),
  amount numeric(14,2) generated always as (round(quantity * unit_price, 2)) stored,
  position smallint not null default 0
);
create index on public.invoice_items(invoice_id, position);

create table public.payments (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  invoice_id uuid not null references public.invoices(id) on delete restrict,
  amount numeric(14,2) not null check (amount >= 0),
  tds_amount numeric(14,2) not null default 0 check (tds_amount >= 0),
  paid_on date not null,
  method text not null default 'bank_transfer' check (method in ('bank_transfer','upi','cheque','cash','card','other')),
  reference text check (reference is null or length(reference) <= 100),
  note text,
  recorded_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  check (amount + tds_amount > 0)
);
create index on public.payments(invoice_id);
create index on public.payments(org_id, paid_on);
create unique index payments_no_duplicate_reference on public.payments(invoice_id, method, lower(reference)) where reference is not null;
create trigger trg_audit after insert or update or delete on public.payments for each row execute function app.audit();

-- ---------- visibility ----------
create or replace function app.can_view_invoice(p_invoice uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.invoices i where i.id = p_invoice and i.org_id = app.org_id() and (
    (app.is_internal() and (app.has_perm('invoices.view') or app.has_perm('invoices.manage')))
    or (i.status <> 'draft' and i.client_id = app.client_id())))
$$;

-- ---------- totals ----------
create or replace function app.recalc_invoice(p_invoice uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_fee numeric; v_ad numeric; v_other numeric; v_taxable numeric; v_tax numeric; v_mode text; v_raw numeric; v_total numeric;
begin
  select coalesce(sum(amount) filter (where kind = 'management_fee'), 0), coalesce(sum(amount) filter (where kind = 'ad_spend'), 0),
         coalesce(sum(amount) filter (where kind = 'other'), 0), coalesce(sum(amount), 0),
         coalesce(sum(round(amount * gst_rate / 100, 2)), 0)
    into v_fee, v_ad, v_other, v_taxable, v_tax
    from public.invoice_items where invoice_id = p_invoice;
  select tax_mode into v_mode from public.invoices where id = p_invoice;
  v_raw := v_taxable + v_tax;
  v_total := round(v_raw);
  update public.invoices set fee_subtotal = v_fee, ad_spend_subtotal = v_ad, other_subtotal = v_other, taxable_total = v_taxable,
    cgst = case when v_mode = 'intra' then round(v_tax / 2, 2) else 0 end,
    sgst = case when v_mode = 'intra' then v_tax - round(v_tax / 2, 2) else 0 end,
    igst = case when v_mode = 'inter' then v_tax else 0 end,
    round_off = v_total - v_raw, total = v_total
  where id = p_invoice;
end $$;

-- drafts: force safe defaults, derive place of supply and CGST/SGST vs IGST
create or replace function app.invoice_before_write() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_seller char(2); v_client_state char(2);
begin
  if app.guards_bypassed() then return new; end if;
  if tg_op = 'INSERT' then
    new.status := 'draft'; new.invoice_number := null; new.fiscal_year := null; new.issued_at := null; new.issued_by := null;
    new.seller := null; new.buyer := null; new.amount_received := 0; new.tds_deducted := 0;
    new.fee_subtotal := 0; new.ad_spend_subtotal := 0; new.other_subtotal := 0; new.taxable_total := 0;
    new.cgst := 0; new.sgst := 0; new.igst := 0; new.round_off := 0; new.total := 0;
    new.cancelled_at := null; new.cancel_reason := null;
    new.created_by := coalesce(auth.uid(), new.created_by);
  elsif old.status <> 'draft' then
    raise exception 'Issued invoices cannot be edited. Cancel it and create a new one if something is wrong.' using errcode = '42501';
  end if;
  if not exists (select 1 from public.clients where id = new.client_id and org_id = new.org_id) then
    raise exception 'Client must belong to the same organization' using errcode = '23514'; end if;
  if new.contract_id is not null and not exists (select 1 from public.contracts where id = new.contract_id and client_id = new.client_id) then
    raise exception 'Contract must belong to the same client' using errcode = '23514'; end if;
  select state_code into v_seller from public.billing_settings where org_id = new.org_id;
  select state_code into v_client_state from public.client_billing where client_id = new.client_id;
  new.place_of_supply := coalesce(new.place_of_supply, v_client_state);
  new.tax_mode := case when v_seller is not null and new.place_of_supply is not null and v_seller <> new.place_of_supply then 'inter' else 'intra' end;
  return new;
end $$;
create trigger trg_inv_before before insert or update on public.invoices
  for each row execute function app.invoice_before_write();

create or replace function app.invoice_after_update() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform app.recalc_invoice(new.id);
  return new;
end $$;
-- place of supply changed on a draft -> CGST/SGST vs IGST may flip -> recompute the tax split
create trigger trg_inv_after after update on public.invoices
  for each row when (new.status = 'draft' and new.tax_mode is distinct from old.tax_mode)
  execute function app.invoice_after_update();

create or replace function app.invoice_delete_guard() returns trigger
language plpgsql set search_path = '' as $$
begin
  if old.status <> 'draft' then raise exception 'Only draft invoices can be deleted' using errcode = '42501'; end if;
  return old;
end $$;
create trigger trg_inv_delete before delete on public.invoices for each row execute function app.invoice_delete_guard();

create or replace function app.invoice_item_before_write() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_status public.invoice_status; v_inv uuid := coalesce(new.invoice_id, old.invoice_id);
begin
  select status into v_status from public.invoices where id = v_inv;
  if v_status is distinct from 'draft' and v_status is not null then
    raise exception 'Items of an issued invoice cannot be changed' using errcode = '42501'; end if;
  if tg_op = 'UPDATE' and new.invoice_id <> old.invoice_id then
    raise exception 'Items cannot move between invoices' using errcode = '42501'; end if;
  if tg_op <> 'DELETE' then
    new.org_id := (select org_id from public.invoices where id = new.invoice_id);
    new.description := trim(new.description);
    return new;
  end if;
  return old;
end $$;
create trigger trg_ii_before before insert or update or delete on public.invoice_items
  for each row execute function app.invoice_item_before_write();

create or replace function app.invoice_item_after_write() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform app.recalc_invoice(coalesce(new.invoice_id, old.invoice_id));
  return null;
end $$;
create trigger trg_ii_after after insert or update or delete on public.invoice_items
  for each row execute function app.invoice_item_after_write();

-- ---------- RLS ----------
alter table public.billing_settings enable row level security;
alter table public.invoice_sequences enable row level security;
alter table public.invoices enable row level security;
alter table public.invoice_items enable row level security;
alter table public.payments enable row level security;

create policy bs_select on public.billing_settings for select to authenticated
  using (org_id = (select app.org_id()) and (select app.is_internal())
         and ((select app.has_perm('invoices.view')) or (select app.has_perm('invoices.manage'))));
create policy bs_write on public.billing_settings for all to authenticated
  using (org_id = (select app.org_id()) and (select app.has_perm('invoices.manage')))
  with check (org_id = (select app.org_id()) and (select app.has_perm('invoices.manage')));

create policy inv_select on public.invoices for select to authenticated using (app.can_view_invoice(id));
create policy inv_insert on public.invoices for insert to authenticated
  with check (org_id = (select app.org_id()) and (select app.has_perm('invoices.manage')));
create policy inv_update on public.invoices for update to authenticated
  using (org_id = (select app.org_id()) and (select app.has_perm('invoices.manage')) and status = 'draft')
  with check (org_id = (select app.org_id()) and (select app.has_perm('invoices.manage')));
create policy inv_delete on public.invoices for delete to authenticated
  using (org_id = (select app.org_id()) and (select app.has_perm('invoices.manage')) and status = 'draft');

create policy ii_select on public.invoice_items for select to authenticated using (app.can_view_invoice(invoice_id));
create policy ii_write on public.invoice_items for all to authenticated
  using (org_id = (select app.org_id()) and (select app.has_perm('invoices.manage')))
  with check ((select app.has_perm('invoices.manage'))
              and exists (select 1 from public.invoices i where i.id = invoice_id and i.org_id = (select app.org_id())));

create policy pay_select on public.payments for select to authenticated using (app.can_view_invoice(invoice_id));

grant select, insert on public.billing_settings to authenticated;
grant update (legal_name, gstin, pan, state_code, address, email, phone, invoice_prefix, default_sac, default_gst_rate,
  ad_spend_gst_rate, bank_details, terms) on public.billing_settings to authenticated;
grant select, insert, delete on public.invoices to authenticated;
grant update (client_id, contract_id, billing_period, due_date, place_of_supply, currency, notes) on public.invoices to authenticated;
grant select, insert, update, delete on public.invoice_items to authenticated;
grant select on public.payments to authenticated;

-- ---------- workflow functions ----------
create or replace function app.require_invoice_manager() returns void
language plpgsql stable security definer set search_path = '' as $$
begin
  if not (app.is_internal() and app.has_perm('invoices.manage')) then
    raise exception 'You need the invoices.manage permission' using errcode = '42501'; end if;
end $$;

create or replace function public.issue_invoice(p_invoice uuid, p_issue_date date default null) returns public.invoices
language plpgsql security definer set search_path = '' as $$
declare i public.invoices; s public.billing_settings; c public.clients; b public.client_billing; v_fy text; v_n int;
        v_today date; v_date date; v_org_name text;
begin
  perform app.require_invoice_manager();
  select * into i from public.invoices where id = p_invoice and org_id = app.org_id() for update;
  if i.id is null then raise exception 'Invoice not found' using errcode = 'P0002'; end if;
  if i.status <> 'draft' then raise exception 'Only draft invoices can be issued' using errcode = '22023'; end if;
  if not exists (select 1 from public.invoice_items where invoice_id = i.id) then
    raise exception 'Add at least one line before issuing' using errcode = '22023'; end if;
  perform app.recalc_invoice(i.id);
  select * into i from public.invoices where id = p_invoice;
  if i.total <= 0 then raise exception 'Invoice total must be more than zero' using errcode = '22023'; end if;
  v_today := app.org_today(i.org_id);
  v_date := coalesce(p_issue_date, v_today);
  if v_date > v_today then raise exception 'Issue date cannot be in the future' using errcode = '22023'; end if;
  if v_date < v_today - 30 then raise exception 'Issue date can be at most 30 days in the past' using errcode = '22023'; end if;

  insert into public.billing_settings(org_id) values (i.org_id) on conflict do nothing;
  select * into s from public.billing_settings where org_id = i.org_id;
  select * into c from public.clients where id = i.client_id;
  select * into b from public.client_billing where client_id = i.client_id;
  select name into v_org_name from public.organizations where id = i.org_id;

  v_fy := app.fiscal_year(v_date);
  insert into public.invoice_sequences(org_id, fiscal_year) values (i.org_id, v_fy) on conflict do nothing;
  update public.invoice_sequences set last_number = last_number + 1
   where org_id = i.org_id and fiscal_year = v_fy returning last_number into v_n;

  perform set_config('app.bypass_guards', 'on', true);
  update public.invoices set status = 'issued', fiscal_year = v_fy,
    invoice_number = s.invoice_prefix || '/' || v_fy || '/' || lpad(v_n::text, 4, '0'),
    issue_date = v_date,
    due_date = case when i.due_date is not null and i.due_date >= v_date then i.due_date
                    else v_date + coalesce(b.payment_terms_days, 15) end,
    issued_by = auth.uid(), issued_at = now(),
    seller = jsonb_strip_nulls(jsonb_build_object('name', coalesce(s.legal_name, v_org_name), 'gstin', s.gstin, 'pan', s.pan,
      'state_code', s.state_code, 'address', s.address, 'email', s.email, 'phone', s.phone, 'bank_details', s.bank_details, 'terms', s.terms)),
    buyer = jsonb_strip_nulls(jsonb_build_object('name', coalesce(nullif(b.billing_name, ''), c.legal_name, c.name), 'gstin', b.gst_number,
      'state_code', i.place_of_supply, 'address', b.billing_address, 'email', b.billing_email))
  where id = i.id returning * into i;
  perform set_config('app.bypass_guards', '', true);

  if b.billing_email is not null then
    perform app.queue_email(i.org_id, b.billing_email, coalesce(b.billing_name, c.name),
      'Invoice ' || i.invoice_number || ' from ' || coalesce(s.legal_name, v_org_name),
      concat_ws(E'\n\n', 'Hello,',
        'Please find invoice ' || i.invoice_number || ' dated ' || to_char(i.issue_date, 'DD Mon YYYY') || ' for ' || i.currency || ' '
          || to_char(i.total, 'FM99,99,99,99,990.00') || ', due on ' || to_char(i.due_date, 'DD Mon YYYY') || '.',
        case when app.app_link(i.org_id, '/invoices/' || i.id) <> '' then 'View it in your client portal: ' || app.app_link(i.org_id, '/invoices/' || i.id) end,
        nullif(s.bank_details, ''),
        'Thank you,' || E'\n' || coalesce(s.legal_name, v_org_name)),
      'invoice', 'invoice', i.id, 'invoice_issued:' || i.id);
  end if;
  return i;
end $$;

create or replace function public.cancel_invoice(p_invoice uuid, p_reason text) returns public.invoices
language plpgsql security definer set search_path = '' as $$
declare i public.invoices;
begin
  perform app.require_invoice_manager();
  select * into i from public.invoices where id = p_invoice and org_id = app.org_id() for update;
  if i.id is null then raise exception 'Invoice not found' using errcode = 'P0002'; end if;
  if i.status = 'draft' then raise exception 'Delete a draft instead of cancelling it' using errcode = '22023'; end if;
  if i.status = 'cancelled' then raise exception 'Invoice is already cancelled' using errcode = '22023'; end if;
  if exists (select 1 from public.payments where invoice_id = i.id) then
    raise exception 'Remove the recorded payments before cancelling this invoice' using errcode = '22023'; end if;
  if coalesce(length(trim(p_reason)), 0) < 5 then raise exception 'Give a reason (at least 5 characters)' using errcode = '22023'; end if;
  perform set_config('app.bypass_guards', 'on', true);
  update public.invoices set status = 'cancelled', cancelled_at = now(), cancel_reason = trim(p_reason) where id = i.id returning * into i;
  perform set_config('app.bypass_guards', '', true);
  return i;
end $$;

create or replace function app.refresh_invoice_payments(p_invoice uuid) returns public.invoices
language plpgsql security definer set search_path = '' as $$
declare i public.invoices; v_amt numeric; v_tds numeric;
begin
  select coalesce(sum(amount), 0), coalesce(sum(tds_amount), 0) into v_amt, v_tds from public.payments where invoice_id = p_invoice;
  perform set_config('app.bypass_guards', 'on', true);
  update public.invoices set amount_received = v_amt, tds_deducted = v_tds,
    status = case when total - v_amt - v_tds <= 0 then 'paid'::public.invoice_status
                  when v_amt + v_tds > 0 then 'partially_paid'::public.invoice_status
                  else 'issued'::public.invoice_status end
  where id = p_invoice returning * into i;
  perform set_config('app.bypass_guards', '', true);
  return i;
end $$;

create or replace function public.record_payment(p_invoice uuid, p_amount numeric, p_paid_on date, p_method text default 'bank_transfer',
  p_reference text default null, p_tds numeric default 0, p_note text default null) returns public.payments
language plpgsql security definer set search_path = '' as $$
declare i public.invoices; p public.payments;
begin
  perform app.require_invoice_manager();
  select * into i from public.invoices where id = p_invoice and org_id = app.org_id() for update;
  if i.id is null then raise exception 'Invoice not found' using errcode = 'P0002'; end if;
  if i.status not in ('issued','partially_paid') then raise exception 'Payments can only be recorded on issued, unpaid invoices' using errcode = '22023'; end if;
  if coalesce(p_amount, 0) < 0 or coalesce(p_tds, 0) < 0 or coalesce(p_amount, 0) + coalesce(p_tds, 0) <= 0 then
    raise exception 'Enter an amount received (and TDS, if any) greater than zero' using errcode = '22023'; end if;
  if round(coalesce(p_amount, 0) + coalesce(p_tds, 0), 2) > i.balance then
    raise exception 'This is more than the balance due (%)', i.balance using errcode = '22023'; end if;
  if p_paid_on is null or p_paid_on > app.org_today(i.org_id) then raise exception 'Payment date cannot be in the future' using errcode = '22023'; end if;
  if p_paid_on < i.issue_date - 90 then raise exception 'Payment date is too far before the invoice date' using errcode = '22023'; end if;
  begin
    insert into public.payments(org_id, invoice_id, amount, tds_amount, paid_on, method, reference, note, recorded_by)
    values (i.org_id, i.id, round(coalesce(p_amount, 0), 2), round(coalesce(p_tds, 0), 2), p_paid_on, coalesce(p_method, 'bank_transfer'),
            nullif(trim(p_reference), ''), nullif(trim(p_note), ''), auth.uid()) returning * into p;
  exception when unique_violation then
    raise exception 'A payment with this reference is already recorded on this invoice' using errcode = '23505';
  end;
  perform app.refresh_invoice_payments(i.id);
  return p;
end $$;

create or replace function public.delete_payment(p_payment uuid) returns public.invoices
language plpgsql security definer set search_path = '' as $$
declare p public.payments;
begin
  perform app.require_invoice_manager();
  select * into p from public.payments where id = p_payment and org_id = app.org_id();
  if p.id is null then raise exception 'Payment not found' using errcode = 'P0002'; end if;
  perform 1 from public.invoices where id = p.invoice_id for update;
  delete from public.payments where id = p.id;
  return app.refresh_invoice_payments(p.invoice_id);
end $$;

-- Draft invoice for a contract and month: the management fee line, plus (optionally) one ad-spend line
-- per platform from imported campaign data for that month. One invoice per contract per month.
create or replace function public.create_invoice_from_contract(p_contract uuid, p_period text, p_include_ad_spend boolean default false)
returns uuid language plpgsql security definer set search_path = '' as $$
declare k public.contracts; c public.clients; s public.billing_settings; v_inv uuid; v_start date; v_label text; r record; v_pos int := 1;
begin
  perform app.require_invoice_manager();
  select * into k from public.contracts where id = p_contract and org_id = app.org_id();
  if k.id is null then raise exception 'Contract not found' using errcode = 'P0002'; end if;
  if p_period !~ '^[0-9]{4}-(0[1-9]|1[0-2])$' then raise exception 'Period must look like 2026-11' using errcode = '22023'; end if;
  v_start := (p_period || '-01')::date;
  v_label := to_char(v_start, 'FMMonth YYYY');
  select * into c from public.clients where id = k.client_id;
  insert into public.billing_settings(org_id) values (k.org_id) on conflict do nothing;
  select * into s from public.billing_settings where org_id = k.org_id;
  begin
    insert into public.invoices(org_id, client_id, contract_id, billing_period, created_by)
    values (k.org_id, k.client_id, k.id, p_period, auth.uid()) returning id into v_inv;
  exception when unique_violation then
    raise exception 'An invoice for this contract and month already exists' using errcode = '23505';
  end;
  if k.management_fee > 0 then
    insert into public.invoice_items(org_id, invoice_id, kind, description, sac, quantity, unit_price, gst_rate, position)
    values (k.org_id, v_inv, 'management_fee', k.title || ' — ' || v_label, s.default_sac, 1, k.management_fee, s.default_gst_rate, v_pos);
    v_pos := v_pos + 1;
  end if;
  if p_include_ad_spend then
    for r in select cp.platform, sum(m.spend) as spend
             from public.campaign_metrics_daily m join public.campaigns cp on cp.id = m.campaign_id
             where cp.client_id = k.client_id and m.metric_date >= v_start and m.metric_date < (v_start + interval '1 month')::date
             group by cp.platform having sum(m.spend) > 0 order by cp.platform loop
      insert into public.invoice_items(org_id, invoice_id, kind, description, sac, quantity, unit_price, gst_rate, position)
      values (k.org_id, v_inv, 'ad_spend',
        'Ad spend — ' || case r.platform when 'google_ads' then 'Google Ads' when 'meta_ads' then 'Meta Ads' else 'Other platforms' end || ' — ' || v_label,
        s.default_sac, 1, round(r.spend, 2), s.ad_spend_gst_rate, v_pos);
      v_pos := v_pos + 1;
    end loop;
  end if;
  return v_inv;
end $$;

-- ---------- collections summary (SECURITY INVOKER: RLS applies, so clients see only their own) ----------
create or replace function public.get_finance_summary() returns jsonb
language plpgsql stable security invoker set search_path = '' as $$
declare v_today date := app.org_today(app.org_id()); v_month date; res jsonb;
begin
  v_month := date_trunc('month', v_today)::date;
  with open_inv as (select * from public.invoices where status in ('issued','partially_paid'))
  select jsonb_build_object(
    'today', v_today,
    'outstanding', coalesce((select sum(balance) from open_inv), 0),
    'overdue', coalesce((select sum(balance) from open_inv where due_date < v_today), 0),
    'overdue_count', (select count(*) from open_inv where due_date < v_today),
    'open_count', (select count(*) from open_inv),
    'draft_count', (select count(*) from public.invoices where status = 'draft'),
    'invoiced_this_month', coalesce((select sum(total) from public.invoices where status <> 'cancelled' and status <> 'draft' and issue_date >= v_month), 0),
    'fees_this_month', coalesce((select sum(fee_subtotal) from public.invoices where status not in ('cancelled','draft') and issue_date >= v_month), 0),
    'ad_spend_this_month', coalesce((select sum(ad_spend_subtotal) from public.invoices where status not in ('cancelled','draft') and issue_date >= v_month), 0),
    'collected_this_month', coalesce((select sum(amount) from public.payments where paid_on >= v_month), 0),
    'aging', jsonb_build_object(
      'current', coalesce((select sum(balance) from open_inv where due_date >= v_today), 0),
      'd1_30', coalesce((select sum(balance) from open_inv where v_today - due_date between 1 and 30), 0),
      'd31_60', coalesce((select sum(balance) from open_inv where v_today - due_date between 31 and 60), 0),
      'd61_90', coalesce((select sum(balance) from open_inv where v_today - due_date between 61 and 90), 0),
      'd90_plus', coalesce((select sum(balance) from open_inv where v_today - due_date > 90), 0)),
    'by_client', coalesce((select jsonb_agg(x order by x.balance desc) from (
        select o.client_id, cl.name, sum(o.balance) as balance, count(*) as invoices, min(o.due_date) as oldest_due
        from open_inv o join public.clients cl on cl.id = o.client_id group by o.client_id, cl.name
        order by sum(o.balance) desc limit 10) x), '[]'::jsonb)
  ) into res;
  return res;
end $$;

-- ---------- reminders (scheduled; idempotent through dedupe keys) ----------
-- Staff (account manager + invoices.manage) get in-app reminders; the client's billing e-mail gets
-- a reminder 3 days before the due date, on it, and 7 / 14 / 30 days after it.
create or replace function public.generate_invoice_reminders() returns integer
language plpgsql security definer set search_path = '' as $$
declare r record; a uuid; v_stage text; v_days int; v_n int := 0; v_link text; v_amt text;
begin
  for r in
    select i.*, c.name as client_name, m.profile_id as am, b.billing_email, b.billing_name, o.name as org_name,
           app.org_today(i.org_id) as today, coalesce(s.legal_name, o.name) as seller_name
    from public.invoices i join public.clients c on c.id = i.client_id
    join public.organizations o on o.id = i.org_id
    left join public.employee_profiles m on m.id = c.account_manager_id
    left join public.client_billing b on b.client_id = i.client_id
    left join public.billing_settings s on s.org_id = i.org_id
    where i.status in ('issued','partially_paid') and i.balance > 0
  loop
    v_days := r.today - r.due_date;
    v_stage := case when v_days = -3 then 'due_in_3' when v_days = 0 then 'due_today' when v_days = 7 then 'overdue_7'
                    when v_days = 14 then 'overdue_14' when v_days = 30 then 'overdue_30' end;
    continue when v_stage is null;
    v_amt := r.currency || ' ' || to_char(r.balance, 'FM99,99,99,99,990.00');
    for a in select r.am where r.am is not null union select app.profiles_with_perm(r.org_id, 'invoices.manage') loop
      perform app.notify(a, 'invoice_reminder',
        case when v_days > 0 then 'Overdue ' || v_days || ' days: ' else 'Payment due' || case when v_days = 0 then ' today: ' else ' in 3 days: ' end end
          || r.invoice_number || ' (' || r.client_name || ')',
        v_amt || ' outstanding', '/invoices/' || r.id, 'invoice', r.id, 'inv_rem:' || r.id || ':' || v_stage);
    end loop;
    if r.billing_email is not null then
      v_link := app.app_link(r.org_id, '/invoices/' || r.id);
      if app.queue_email(r.org_id, r.billing_email, coalesce(r.billing_name, r.client_name),
        case when v_days > 0 then 'Reminder: invoice ' || r.invoice_number || ' is overdue'
             else 'Reminder: invoice ' || r.invoice_number || ' is due ' || case when v_days = 0 then 'today' else 'on ' || to_char(r.due_date, 'DD Mon') end end,
        concat_ws(E'\n\n', 'Hello,',
          'This is a friendly reminder that ' || v_amt || ' is outstanding on invoice ' || r.invoice_number
            || ' dated ' || to_char(r.issue_date, 'DD Mon YYYY') || ', due on ' || to_char(r.due_date, 'DD Mon YYYY') || '.',
          case when v_link <> '' then 'View the invoice: ' || v_link end,
          'If you have already paid, please ignore this e-mail or reply with the payment reference.',
          'Thank you,' || E'\n' || r.seller_name),
        'invoice_reminder', 'invoice', r.id, 'inv_rem_mail:' || r.id || ':' || v_stage) then v_n := v_n + 1; end if;
    end if;
  end loop;
  return v_n;
end $$;
revoke execute on function public.generate_invoice_reminders() from public, anon, authenticated;
grant execute on function public.generate_invoice_reminders() to service_role;
do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('agency-os-invoice-reminders', '5 4 * * *', 'select public.generate_invoice_reminders()');
  end if;
end $$;

do $$ declare f text; begin
  foreach f in array array['issue_invoice(uuid,date)','cancel_invoice(uuid,text)',
    'record_payment(uuid,numeric,date,text,text,numeric,text)','delete_payment(uuid)',
    'create_invoice_from_contract(uuid,text,boolean)','get_finance_summary()'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop; end $$;

revoke execute on all functions in schema app from public, anon;
grant execute on all functions in schema app to authenticated, service_role;

-- ===== 20261028000014_payroll.sql =====
-- =====================================================================
-- 0014 PHASE 5: payroll runs and payslips
-- Monthly run from each employee's salary structure (latest revision
-- effective by month end), joining/exit dates, unpaid leave and,
-- optionally, unexplained absences. Calendar-day proration:
--   component × payable days ÷ days in month (rounded to the rupee).
-- Statutory rules (PF/ESI/PT/TDS) are not computed: they are entered as
-- salary components or per-payslip adjustments and must be checked by
-- your accountant.
-- Lifecycle: draft (editable, recalculable) → finalized (employees can
-- see their payslip) → paid. A finalized run can be reopened until paid.
-- =====================================================================

-- payslip details kept with the employee's private record (self + HR only)
alter table public.employee_private
  add column pan_number text check (pan_number is null or pan_number ~ '^[A-Z]{5}[0-9]{4}[A-Z]$'),
  add column uan_number text check (uan_number is null or uan_number ~ '^[0-9]{12}$'),
  add column bank_name text check (bank_name is null or length(bank_name) <= 80),
  add column bank_account_number text check (bank_account_number is null or bank_account_number ~ '^[0-9]{6,20}$'),
  add column bank_ifsc text check (bank_ifsc is null or bank_ifsc ~ '^[A-Z]{4}0[A-Z0-9]{6}$');

create table public.payroll_runs (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  period_month date not null check (extract(day from period_month) = 1),
  status text not null default 'draft' check (status in ('draft','finalized','paid')),
  absent_as_lop boolean not null default false,
  employees_count integer not null default 0,
  gross_total numeric(14,2) not null default 0,
  deductions_total numeric(14,2) not null default 0,
  net_total numeric(14,2) not null default 0,
  missing_salary jsonb not null default '[]'::jsonb,   -- employees skipped because they have no salary structure
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  finalized_by uuid references public.profiles(id) on delete set null,
  finalized_at timestamptz,
  paid_on date,
  paid_by uuid references public.profiles(id) on delete set null,
  unique (org_id, period_month)
);
create trigger trg_audit after insert or update or delete on public.payroll_runs for each row execute function app.audit();

create table public.payslips (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  run_id uuid not null references public.payroll_runs(id) on delete cascade,
  period_month date not null,
  employee_id uuid not null references public.employee_profiles(id) on delete restrict,
  employee_code text not null,
  employee_name text not null,
  designation text,
  department text,
  joining_date date,
  salary_revision_id uuid references public.salary_revisions(id) on delete set null,
  annual_ctc numeric(14,2),
  days_in_month smallint not null,
  payable_days numeric(5,1) not null,
  lop_days numeric(5,1) not null default 0,
  unpaid_leave_days numeric(5,1) not null default 0,
  absent_days numeric(5,1) not null default 0,
  earnings jsonb not null default '[]'::jsonb,      -- [{code, name, full, amount}]
  deductions jsonb not null default '[]'::jsonb,    -- [{code, name, full, amount}]
  adjustments jsonb not null default '[]'::jsonb,   -- [{label, kind: earning|deduction, amount}]
  gross numeric(14,2) not null default 0,
  total_deductions numeric(14,2) not null default 0,
  net_pay numeric(14,2) not null default 0,
  bank jsonb not null default '{}'::jsonb,           -- PAN/UAN/bank snapshot for the payslip and transfer sheet
  updated_at timestamptz not null default now(),
  unique (run_id, employee_id)
);
create index on public.payslips(employee_id, period_month desc);
create trigger trg_audit after insert or update or delete on public.payslips for each row execute function app.audit();

create or replace function app.payroll_released(p_run uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.payroll_runs where id = p_run and status in ('finalized','paid'))
$$;

alter table public.payroll_runs enable row level security;
alter table public.payslips enable row level security;
create policy pr_select on public.payroll_runs for select to authenticated
  using (org_id = (select app.org_id()) and (select app.is_internal())
         and ((select app.has_perm('payroll.view')) or (select app.has_perm('payroll.run'))));
create policy ps_select on public.payslips for select to authenticated using (
  org_id = (select app.org_id()) and (select app.is_internal()) and (
    (select app.has_perm('payroll.view')) or (select app.has_perm('payroll.run'))
    or (employee_id = (select app.my_employee_id()) and app.payroll_released(run_id))));
grant select on public.payroll_runs, public.payslips to authenticated;

-- ---------- pure-ish calculation helpers ----------
-- Payable / unpaid days of one employee in one month.
create or replace function app.payroll_days(p_employee uuid, p_month date, p_absent_as_lop boolean,
  out days_in_month int, out employed_days int, out unpaid_leave_days numeric, out absent_days numeric, out payable_days numeric)
language plpgsql stable security definer set search_path = '' as $$
declare e public.employee_profiles; v_end date; v_from date; v_to date; v_today date; d date; v_cover numeric; a public.attendance_records;
begin
  select * into e from public.employee_profiles where id = p_employee;
  v_end := (p_month + interval '1 month' - interval '1 day')::date;
  days_in_month := v_end - p_month + 1;
  v_from := greatest(p_month, e.joining_date);
  v_to := least(v_end, coalesce(e.exit_date, v_end));
  employed_days := greatest(0, v_to - v_from + 1);
  unpaid_leave_days := 0; absent_days := 0;
  if employed_days = 0 then payable_days := 0; return; end if;

  -- approved leave without pay, on working days only (half days count 0.5)
  select coalesce(sum(case when lr.half_day <> 'none' then 0.5 else 1 end), 0) into unpaid_leave_days
  from public.leave_requests lr join public.leave_types lt on lt.id = lr.leave_type_id and not lt.is_paid
  cross join lateral generate_series(greatest(lr.start_date, v_from), least(lr.end_date, v_to), interval '1 day') g(day)
  where lr.employee_id = p_employee and lr.status = 'approved' and app.is_working_day(p_employee, g.day::date);

  if p_absent_as_lop then
    v_today := app.org_today(e.org_id);
    d := v_from;
    while d <= least(v_to, v_today - 1) loop
      if app.is_working_day(p_employee, d) then
        select coalesce(max(case when lr.half_day <> 'none' then 0.5 else 1 end), 0) into v_cover
          from public.leave_requests lr where lr.employee_id = p_employee and lr.status = 'approved' and d between lr.start_date and lr.end_date;
        if v_cover < 1 then
          select * into a from public.attendance_records where employee_id = p_employee and work_date = d;
          if a.id is null or a.status = 'absent' then absent_days := absent_days + (1 - v_cover);
          elsif a.status = 'half_day' and v_cover = 0 then absent_days := absent_days + 0.5;
          end if;
        end if;
      end if;
      d := d + 1;
    end loop;
  end if;
  payable_days := greatest(0, employed_days - unpaid_leave_days - absent_days);
end $$;

-- (Re)computes one payslip, keeping manual adjustments. Returns false if the employee has no salary structure.
create or replace function app.compute_payslip(p_run uuid, p_employee uuid) returns boolean
language plpgsql security definer set search_path = '' as $$
declare r public.payroll_runs; e public.employee_profiles; sr public.salary_revisions; pv public.employee_private; v_end date; dd record;
        v_earn jsonb; v_ded jsonb; v_adj jsonb; v_gross numeric; v_tded numeric; v_ratio numeric;
begin
  select * into r from public.payroll_runs where id = p_run;
  select * into e from public.employee_profiles where id = p_employee;
  v_end := (r.period_month + interval '1 month' - interval '1 day')::date;
  select * into sr from public.salary_revisions where employee_id = p_employee and effective_from <= v_end
   order by effective_from desc limit 1;
  if sr.id is null then return false; end if;
  dd := app.payroll_days(p_employee, r.period_month, r.absent_as_lop);
  v_ratio := case when dd.days_in_month > 0 then dd.payable_days / dd.days_in_month else 0 end;

  with comp as (
    select j.key as code, j.value::numeric as full_amount, coalesce(sc.name, j.key) as name, coalesce(sc.kind, 'earning') as kind
    from jsonb_each_text(sr.monthly_components) j
    left join public.salary_components sc on sc.org_id = e.org_id and sc.code = j.key
    where j.value ~ '^-?[0-9]+(\.[0-9]+)?$' and j.value::numeric > 0
    union all
    -- no component breakup: pay the CTC as one line
    select 'SALARY', round(sr.annual_ctc / 12, 2), 'Salary', 'earning'
    where not exists (select 1 from jsonb_each_text(sr.monthly_components) j where j.value ~ '^-?[0-9]+(\.[0-9]+)?$' and j.value::numeric > 0)
      and sr.annual_ctc > 0)
  select coalesce(jsonb_agg(jsonb_build_object('code', code, 'name', name, 'full', full_amount, 'amount', round(full_amount * v_ratio))
                            order by code) filter (where kind = 'earning'), '[]'::jsonb),
         coalesce(jsonb_agg(jsonb_build_object('code', code, 'name', name, 'full', full_amount, 'amount', round(full_amount * v_ratio))
                            order by code) filter (where kind = 'deduction'), '[]'::jsonb)
    into v_earn, v_ded from comp;

  select adjustments into v_adj from public.payslips where run_id = p_run and employee_id = p_employee;
  v_adj := coalesce(v_adj, '[]'::jsonb);
  v_gross := coalesce((select sum((x->>'amount')::numeric) from jsonb_array_elements(v_earn) x), 0)
           + coalesce((select sum((x->>'amount')::numeric) from jsonb_array_elements(v_adj) x where x->>'kind' = 'earning'), 0);
  v_tded := coalesce((select sum((x->>'amount')::numeric) from jsonb_array_elements(v_ded) x), 0)
          + coalesce((select sum((x->>'amount')::numeric) from jsonb_array_elements(v_adj) x where x->>'kind' = 'deduction'), 0);
  select * into pv from public.employee_private where employee_id = p_employee;

  insert into public.payslips(org_id, run_id, period_month, employee_id, employee_code, employee_name, designation, department, joining_date,
    salary_revision_id, annual_ctc, days_in_month, payable_days, lop_days, unpaid_leave_days, absent_days, earnings, deductions, adjustments,
    gross, total_deductions, net_pay, bank)
  values (r.org_id, r.id, r.period_month, e.id, e.employee_code, e.full_name, e.designation,
    (select name from public.departments where id = e.department_id), e.joining_date, sr.id, sr.annual_ctc, dd.days_in_month, dd.payable_days,
    dd.unpaid_leave_days + dd.absent_days, dd.unpaid_leave_days, dd.absent_days, v_earn, v_ded, v_adj, v_gross, v_tded, v_gross - v_tded,
    jsonb_strip_nulls(jsonb_build_object('pan', pv.pan_number, 'uan', pv.uan_number, 'bank_name', pv.bank_name,
      'account_number', pv.bank_account_number, 'ifsc', pv.bank_ifsc)))
  on conflict (run_id, employee_id) do update set employee_code = excluded.employee_code, employee_name = excluded.employee_name,
    designation = excluded.designation, department = excluded.department, joining_date = excluded.joining_date,
    salary_revision_id = excluded.salary_revision_id, annual_ctc = excluded.annual_ctc, days_in_month = excluded.days_in_month,
    payable_days = excluded.payable_days, lop_days = excluded.lop_days, unpaid_leave_days = excluded.unpaid_leave_days,
    absent_days = excluded.absent_days, earnings = excluded.earnings, deductions = excluded.deductions,
    gross = excluded.gross, total_deductions = excluded.total_deductions, net_pay = excluded.net_pay, bank = excluded.bank, updated_at = now();
  return true;
end $$;

create or replace function app.refresh_payroll_totals(p_run uuid) returns void
language sql security definer set search_path = '' as $$
  update public.payroll_runs r set employees_count = x.n, gross_total = x.g, deductions_total = x.d, net_total = x.net
  from (select count(*) n, coalesce(sum(gross), 0) g, coalesce(sum(total_deductions), 0) d, coalesce(sum(net_pay), 0) net
        from public.payslips where run_id = p_run) x
  where r.id = p_run
$$;

-- Computes every eligible employee (employed during the month). Keeps adjustments; drops people no longer eligible.
create or replace function app.compute_payroll_run(p_run uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare r public.payroll_runs; emp record; v_end date; v_missing jsonb := '[]'::jsonb;
begin
  select * into r from public.payroll_runs where id = p_run;
  v_end := (r.period_month + interval '1 month' - interval '1 day')::date;
  delete from public.payslips p where p.run_id = r.id and not exists (
    select 1 from public.employee_profiles e where e.id = p.employee_id and e.joining_date <= v_end
      and (e.exit_date is null or e.exit_date >= r.period_month));
  for emp in select * from public.employee_profiles where org_id = r.org_id and joining_date <= v_end
           and (exit_date is null or exit_date >= r.period_month) order by employee_code loop
    if not app.compute_payslip(r.id, emp.id) then
      delete from public.payslips where run_id = r.id and employee_id = emp.id;
      v_missing := v_missing || jsonb_build_object('employee_id', emp.id, 'name', emp.full_name, 'code', emp.employee_code);
    end if;
  end loop;
  update public.payroll_runs set missing_salary = v_missing where id = r.id;
  perform app.refresh_payroll_totals(r.id);
end $$;

create or replace function app.require_payroll_runner() returns void
language plpgsql stable security definer set search_path = '' as $$
begin
  if not (app.is_internal() and app.has_perm('payroll.run')) then
    raise exception 'You need the payroll.run permission' using errcode = '42501'; end if;
end $$;

create or replace function app.lock_run(p_run uuid, p_status text) returns public.payroll_runs
language plpgsql security definer set search_path = '' as $$
declare r public.payroll_runs;
begin
  select * into r from public.payroll_runs where id = p_run and org_id = app.org_id() for update;
  if r.id is null then raise exception 'Payroll run not found' using errcode = 'P0002'; end if;
  if p_status is not null and r.status <> p_status then
    raise exception 'This payroll run is %', r.status using errcode = '22023'; end if;
  return r;
end $$;

-- ---------- public API ----------
create or replace function public.create_payroll_run(p_month date, p_absent_as_lop boolean default false) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_org uuid := app.org_id(); v_id uuid; v_month date := date_trunc('month', p_month)::date;
begin
  perform app.require_payroll_runner();
  if v_month > date_trunc('month', app.org_today(v_org))::date then
    raise exception 'Payroll can''t be run for a future month' using errcode = '22023'; end if;
  begin
    insert into public.payroll_runs(org_id, period_month, absent_as_lop, created_by)
    values (v_org, v_month, coalesce(p_absent_as_lop, false), auth.uid()) returning id into v_id;
  exception when unique_violation then
    raise exception 'A payroll run for % already exists', to_char(v_month, 'FMMonth YYYY') using errcode = '23505';
  end;
  perform app.compute_payroll_run(v_id);
  return v_id;
end $$;

create or replace function public.recalculate_payroll_run(p_run uuid, p_absent_as_lop boolean default null) returns public.payroll_runs
language plpgsql security definer set search_path = '' as $$
declare r public.payroll_runs;
begin
  perform app.require_payroll_runner();
  r := app.lock_run(p_run, 'draft');
  if p_absent_as_lop is not null then update public.payroll_runs set absent_as_lop = p_absent_as_lop where id = r.id; end if;
  perform app.compute_payroll_run(r.id);
  select * into r from public.payroll_runs where id = p_run;
  return r;
end $$;

create or replace function public.set_payslip_adjustments(p_payslip uuid, p_adjustments jsonb) returns public.payslips
language plpgsql security definer set search_path = '' as $$
declare p public.payslips; v_item jsonb;
begin
  perform app.require_payroll_runner();
  select * into p from public.payslips where id = p_payslip and org_id = app.org_id();
  if p.id is null then raise exception 'Payslip not found' using errcode = 'P0002'; end if;
  perform app.lock_run(p.run_id, 'draft');
  if jsonb_typeof(p_adjustments) <> 'array' or jsonb_array_length(p_adjustments) > 20 then
    raise exception 'Adjustments must be a list of at most 20 items' using errcode = '22023'; end if;
  for v_item in select * from jsonb_array_elements(p_adjustments) loop
    if coalesce(length(trim(v_item->>'label')), 0) not between 2 and 80 then raise exception 'Each adjustment needs a label' using errcode = '22023'; end if;
    if coalesce(v_item->>'kind', '') not in ('earning','deduction') then raise exception 'Adjustment kind must be earning or deduction' using errcode = '22023'; end if;
    if coalesce(v_item->>'amount', '') !~ '^[0-9]+(\.[0-9]{1,2})?$' or (v_item->>'amount')::numeric <= 0 or (v_item->>'amount')::numeric > 10000000 then
      raise exception 'Adjustment amounts must be positive numbers' using errcode = '22023'; end if;
  end loop;
  update public.payslips set adjustments = (select coalesce(jsonb_agg(jsonb_build_object('label', trim(x->>'label'), 'kind', x->>'kind',
      'amount', round((x->>'amount')::numeric, 2))), '[]'::jsonb) from jsonb_array_elements(p_adjustments) a(x))
   where id = p.id;
  perform app.compute_payslip(p.run_id, p.employee_id);
  perform app.refresh_payroll_totals(p.run_id);
  select * into p from public.payslips where id = p_payslip;
  return p;
end $$;

create or replace function public.finalize_payroll_run(p_run uuid) returns public.payroll_runs
language plpgsql security definer set search_path = '' as $$
declare r public.payroll_runs; s record;
begin
  perform app.require_payroll_runner();
  r := app.lock_run(p_run, 'draft');
  if not exists (select 1 from public.payslips where run_id = r.id) then
    raise exception 'There are no payslips in this run' using errcode = '22023'; end if;
  if exists (select 1 from public.payslips where run_id = r.id and net_pay < 0) then
    raise exception 'Some payslips have a negative net pay. Fix their adjustments first.' using errcode = '22023'; end if;
  update public.payroll_runs set status = 'finalized', finalized_by = auth.uid(), finalized_at = now() where id = r.id returning * into r;
  for s in select p.id, e.profile_id from public.payslips p join public.employee_profiles e on e.id = p.employee_id
           where p.run_id = r.id and e.profile_id is not null loop
    perform app.notify(s.profile_id, 'payslip_ready', 'Your payslip for ' || to_char(r.period_month, 'FMMonth YYYY') || ' is ready',
      null, '/payroll/payslips/' || s.id, 'payslip', s.id, 'payslip:' || s.id || ':' || extract(epoch from r.finalized_at)::bigint);
  end loop;
  return r;
end $$;

create or replace function public.reopen_payroll_run(p_run uuid) returns public.payroll_runs
language plpgsql security definer set search_path = '' as $$
declare r public.payroll_runs;
begin
  perform app.require_payroll_runner();
  r := app.lock_run(p_run, 'finalized');
  update public.payroll_runs set status = 'draft', finalized_by = null, finalized_at = null where id = r.id returning * into r;
  return r;
end $$;

create or replace function public.mark_payroll_paid(p_run uuid, p_paid_on date) returns public.payroll_runs
language plpgsql security definer set search_path = '' as $$
declare r public.payroll_runs;
begin
  perform app.require_payroll_runner();
  r := app.lock_run(p_run, 'finalized');
  if p_paid_on is null or p_paid_on > app.org_today(r.org_id) then raise exception 'Payment date cannot be in the future' using errcode = '22023'; end if;
  if p_paid_on < r.period_month then raise exception 'Payment date is before the payroll month' using errcode = '22023'; end if;
  update public.payroll_runs set status = 'paid', paid_on = p_paid_on, paid_by = auth.uid() where id = r.id returning * into r;
  return r;
end $$;

create or replace function public.delete_payroll_run(p_run uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare r public.payroll_runs;
begin
  perform app.require_payroll_runner();
  r := app.lock_run(p_run, 'draft');
  delete from public.payroll_runs where id = r.id;
end $$;

do $$ declare f text; begin
  foreach f in array array['create_payroll_run(date,boolean)','recalculate_payroll_run(uuid,boolean)',
    'set_payslip_adjustments(uuid,jsonb)','finalize_payroll_run(uuid)','reopen_payroll_run(uuid)',
    'mark_payroll_paid(uuid,date)','delete_payroll_run(uuid)'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop; end $$;

revoke execute on all functions in schema app from public, anon;
grant execute on all functions in schema app to authenticated, service_role;

-- ===== 20261028000015_recruitment.sql =====
-- =====================================================================
-- 0015 PHASE 5: recruitment — openings, candidates, interviews, offers,
-- and "hire" which turns an accepted offer into an employee record.
-- Visibility: recruitment.view / recruitment.manage see everything; an
-- opening's hiring manager sees its candidates; an interviewer sees the
-- candidates they interview. Offers (CTC) need a recruitment permission.
-- =====================================================================
create table public.job_openings (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  title text not null check (length(trim(title)) between 2 and 120),
  department_id uuid references public.departments(id) on delete set null,
  employment_type public.employment_type not null default 'full_time',
  location text check (location is null or length(location) <= 120),
  positions smallint not null default 1 check (positions between 1 and 100),
  description text,
  requirements text,
  salary_min numeric(14,2) check (salary_min is null or salary_min >= 0),
  salary_max numeric(14,2) check (salary_max is null or salary_max >= 0),
  status text not null default 'open' check (status in ('draft','open','on_hold','closed','filled')),
  hiring_manager_id uuid references public.employee_profiles(id) on delete set null,
  target_date date,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (salary_min is null or salary_max is null or salary_max >= salary_min)
);
create index on public.job_openings(org_id, status);
create trigger trg_jo_touch before update on public.job_openings for each row execute function app.touch_updated_at();
create trigger trg_audit after insert or update or delete on public.job_openings for each row execute function app.audit();

create table public.candidates (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  opening_id uuid not null references public.job_openings(id) on delete restrict,
  full_name text not null check (length(trim(full_name)) between 2 and 120),
  email text check (email is null or email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  phone text check (phone is null or length(phone) <= 30),
  source text not null default 'other' check (source in ('referral','linkedin','naukri','indeed','website','walk_in','agency','other')),
  referred_by uuid references public.employee_profiles(id) on delete set null,
  current_company text,
  experience_years numeric(4,1) check (experience_years is null or experience_years between 0 and 60),
  current_ctc numeric(14,2) check (current_ctc is null or current_ctc >= 0),
  expected_ctc numeric(14,2) check (expected_ctc is null or expected_ctc >= 0),
  notice_period_days smallint check (notice_period_days is null or notice_period_days between 0 and 365),
  location text,
  portfolio_url text check (portfolio_url is null or portfolio_url ~* '^https?://'),
  resume_path text unique,
  resume_name text,
  stage text not null default 'applied' check (stage in ('applied','screening','interview','offer','hired','rejected','withdrawn')),
  rejection_reason text,
  rating smallint check (rating is null or rating between 1 and 5),
  notes text,
  employee_id uuid references public.employee_profiles(id) on delete set null,
  stage_changed_at timestamptz not null default now(),
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index on public.candidates(opening_id, stage);
create index on public.candidates(org_id, created_at desc);
create unique index candidates_one_per_opening on public.candidates(opening_id, lower(email)) where email is not null;
create trigger trg_cand_touch before update on public.candidates for each row execute function app.touch_updated_at();
create trigger trg_audit after insert or update or delete on public.candidates for each row execute function app.audit();

create table public.interviews (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  candidate_id uuid not null references public.candidates(id) on delete cascade,
  round_name text not null check (length(trim(round_name)) between 2 and 80),
  scheduled_at timestamptz not null,
  duration_minutes smallint not null default 45 check (duration_minutes between 15 and 480),
  mode text not null default 'video' check (mode in ('in_person','video','phone')),
  location text check (location is null or length(location) <= 300),
  interviewer_id uuid not null references public.profiles(id) on delete restrict,
  status text not null default 'scheduled' check (status in ('scheduled','completed','cancelled','no_show')),
  rating smallint check (rating is null or rating between 1 and 5),
  recommendation text check (recommendation is null or recommendation in ('strong_yes','yes','no','strong_no')),
  feedback text,
  feedback_at timestamptz,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
create index on public.interviews(candidate_id);
create index on public.interviews(interviewer_id, scheduled_at);
create trigger trg_audit after insert or update or delete on public.interviews for each row execute function app.audit();

create table public.offers (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  candidate_id uuid not null references public.candidates(id) on delete cascade,
  designation text not null check (length(trim(designation)) between 2 and 120),
  department_id uuid references public.departments(id) on delete set null,
  annual_ctc numeric(14,2) not null check (annual_ctc > 0),
  joining_date date not null,
  offer_date date not null default current_date,
  valid_until date,
  status text not null default 'draft' check (status in ('draft','sent','accepted','declined','withdrawn')),
  letter_text text check (letter_text is null or length(letter_text) <= 20000),
  decided_at timestamptz,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (valid_until is null or valid_until >= offer_date)
);
create unique index offers_one_open_per_candidate on public.offers(candidate_id) where status in ('draft','sent','accepted');
create trigger trg_offer_touch before update on public.offers for each row execute function app.touch_updated_at();
create trigger trg_audit after insert or update or delete on public.offers for each row execute function app.audit();

-- ---------- visibility helpers ----------
create or replace function app.can_view_opening(p_opening uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select app.is_internal() and exists (select 1 from public.job_openings o where o.id = p_opening and o.org_id = app.org_id()
    and (app.has_perm('recruitment.view') or app.has_perm('recruitment.manage')
         or (o.hiring_manager_id is not null and o.hiring_manager_id = app.my_employee_id())))
$$;

create or replace function app.can_view_candidate(p_candidate uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select app.is_internal() and exists (select 1 from public.candidates c where c.id = p_candidate and c.org_id = app.org_id()
    and (app.can_view_opening(c.opening_id)
         or exists (select 1 from public.interviews i where i.candidate_id = c.id and i.interviewer_id = auth.uid())))
$$;

create or replace function app.recruiter() returns boolean
language sql stable security definer set search_path = '' as $$
  select app.is_internal() and app.has_perm('recruitment.manage')
$$;

-- ---------- integrity triggers ----------
create or replace function app.opening_before_write() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.department_id is not null and not exists (select 1 from public.departments where id = new.department_id and org_id = new.org_id) then
    raise exception 'Department must belong to the same organization' using errcode = '23514'; end if;
  if new.hiring_manager_id is not null and not exists (select 1 from public.employee_profiles where id = new.hiring_manager_id
      and org_id = new.org_id and status <> 'exited') then
    raise exception 'Hiring manager must be a current employee' using errcode = '23514'; end if;
  return new;
end $$;
create trigger trg_jo_before before insert or update on public.job_openings for each row execute function app.opening_before_write();

create or replace function app.candidate_before_write() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  new.email := nullif(lower(trim(new.email)), '');
  if not exists (select 1 from public.job_openings where id = new.opening_id and org_id = new.org_id) then
    raise exception 'Opening must belong to the same organization' using errcode = '23514'; end if;
  if tg_op = 'INSERT' then
    if new.stage not in ('applied','screening') then new.stage := 'applied'; end if;
    new.employee_id := null;
    new.created_by := coalesce(auth.uid(), new.created_by);
  elsif new.stage is distinct from old.stage then
    if old.stage = 'hired' then raise exception 'A hired candidate can''t be moved to another stage' using errcode = '22023'; end if;
    if new.stage = 'hired' and not app.guards_bypassed() then
      raise exception 'Use "Hire" on an accepted offer to mark someone as hired' using errcode = '22023'; end if;
    new.stage_changed_at := now();
  end if;
  if tg_op = 'UPDATE' and new.employee_id is distinct from old.employee_id and not app.guards_bypassed() then
    raise exception 'The employee link is set by hiring' using errcode = '42501'; end if;
  if new.stage = 'rejected' and coalesce(length(trim(new.rejection_reason)), 0) < 3 then
    raise exception 'Give a rejection reason' using errcode = '22023'; end if;
  if new.referred_by is not null and not exists (select 1 from public.employee_profiles where id = new.referred_by and org_id = new.org_id) then
    raise exception 'Referrer must be an employee of the same organization' using errcode = '23514'; end if;
  if new.resume_path is not null
     and (split_part(new.resume_path, '/', 1) <> new.org_id::text or split_part(new.resume_path, '/', 2) <> 'recruitment') then
    raise exception 'Invalid resume path' using errcode = '42501'; end if;
  return new;
end $$;
create trigger trg_cand_before before insert or update on public.candidates for each row execute function app.candidate_before_write();

create or replace function app.interview_before_write() returns trigger
language plpgsql security definer set search_path = '' as $$
declare c public.candidates;
begin
  select * into c from public.candidates where id = new.candidate_id;
  new.org_id := c.org_id;
  if c.stage in ('hired','rejected','withdrawn') and (tg_op = 'INSERT' or new.scheduled_at is distinct from old.scheduled_at) then
    raise exception 'This candidate is no longer in the pipeline' using errcode = '22023'; end if;
  if not exists (select 1 from public.profiles where id = new.interviewer_id and org_id = c.org_id and client_id is null and is_active) then
    raise exception 'Interviewer must be an active team member' using errcode = '23514'; end if;
  if tg_op = 'INSERT' then new.created_by := coalesce(auth.uid(), new.created_by); new.status := 'scheduled'; end if;
  if tg_op = 'UPDATE' and not app.guards_bypassed() and (new.rating is distinct from old.rating or new.recommendation is distinct from old.recommendation
      or new.feedback is distinct from old.feedback or new.feedback_at is distinct from old.feedback_at) then
    raise exception 'Feedback is submitted by the interviewer' using errcode = '42501'; end if;
  return new;
end $$;
create trigger trg_iv_before before insert or update on public.interviews for each row execute function app.interview_before_write();

create or replace function app.interview_after_write() returns trigger
language plpgsql security definer set search_path = '' as $$
declare c public.candidates; v_tz text;
begin
  select * into c from public.candidates where id = new.candidate_id;
  select timezone into v_tz from public.organizations where id = new.org_id;
  if tg_op = 'INSERT' and c.stage in ('applied','screening') then
    update public.candidates set stage = 'interview' where id = c.id;
  end if;
  if new.status = 'scheduled' and (tg_op = 'INSERT' or new.scheduled_at is distinct from old.scheduled_at or new.interviewer_id is distinct from old.interviewer_id) then
    perform app.notify(new.interviewer_id, 'interview_scheduled', 'Interview: ' || c.full_name || ' (' || new.round_name || ')',
      to_char(new.scheduled_at at time zone v_tz, 'Dy DD Mon, HH12:MI AM') || ' · ' || replace(new.mode, '_', ' ')
        || coalesce(' · ' || new.location, ''),
      '/recruitment/candidates/' || c.id, 'interview', new.id, 'interview:' || new.id || ':' || extract(epoch from new.scheduled_at)::bigint
        || ':' || new.interviewer_id);
  end if;
  return new;
end $$;
create trigger trg_iv_after after insert or update on public.interviews for each row execute function app.interview_after_write();

create or replace function app.offer_before_write() returns trigger
language plpgsql security definer set search_path = '' as $$
declare c public.candidates;
begin
  select * into c from public.candidates where id = new.candidate_id;
  new.org_id := c.org_id;
  if new.department_id is not null and not exists (select 1 from public.departments where id = new.department_id and org_id = new.org_id) then
    raise exception 'Department must belong to the same organization' using errcode = '23514'; end if;
  if tg_op = 'INSERT' then
    if c.stage in ('hired','rejected','withdrawn') then raise exception 'This candidate is no longer in the pipeline' using errcode = '22023'; end if;
    new.status := 'draft'; new.decided_at := null; new.created_by := coalesce(auth.uid(), new.created_by);
  elsif not app.guards_bypassed() then
    if new.status is distinct from old.status then
      raise exception 'Use the offer actions to change its status' using errcode = '42501'; end if;
    if old.status <> 'draft' then raise exception 'Only draft offers can be edited' using errcode = '42501'; end if;
  end if;
  return new;
end $$;
create trigger trg_offer_before before insert or update on public.offers for each row execute function app.offer_before_write();

-- ---------- RLS ----------
alter table public.job_openings enable row level security;
alter table public.candidates enable row level security;
alter table public.interviews enable row level security;
alter table public.offers enable row level security;

create policy jo_select on public.job_openings for select to authenticated using (app.can_view_opening(id));
create policy jo_write on public.job_openings for all to authenticated
  using (org_id = (select app.org_id()) and (select app.recruiter()))
  with check (org_id = (select app.org_id()) and (select app.recruiter()));
create policy cand_select on public.candidates for select to authenticated using (app.can_view_candidate(id));
create policy cand_write on public.candidates for all to authenticated
  using (org_id = (select app.org_id()) and (select app.recruiter()))
  with check (org_id = (select app.org_id()) and (select app.recruiter()));
create policy iv_select on public.interviews for select to authenticated
  using (interviewer_id = auth.uid() or app.can_view_candidate(candidate_id));
create policy iv_write on public.interviews for all to authenticated
  using (org_id = (select app.org_id()) and (select app.recruiter()))
  with check (org_id = (select app.org_id()) and (select app.recruiter()));
create policy offer_select on public.offers for select to authenticated
  using (org_id = (select app.org_id()) and (select app.is_internal())
         and ((select app.has_perm('recruitment.view')) or (select app.has_perm('recruitment.manage'))));
create policy offer_write on public.offers for all to authenticated
  using (org_id = (select app.org_id()) and (select app.recruiter()))
  with check (org_id = (select app.org_id()) and (select app.recruiter()));

grant select, insert, update, delete on public.job_openings, public.candidates, public.offers to authenticated;
grant select, insert, delete on public.interviews to authenticated;
grant update (round_name, scheduled_at, duration_minutes, mode, location, interviewer_id, status) on public.interviews to authenticated;

-- openings with pipeline counts (SECURITY INVOKER: callers only see what RLS allows)
create view public.opening_pipeline with (security_invoker = true) as
select o.id, o.org_id, o.title, o.department_id, o.employment_type, o.location, o.positions, o.status, o.hiring_manager_id,
       o.target_date, o.created_at,
       count(c.id) filter (where c.stage not in ('rejected','withdrawn','hired')) as active,
       count(c.id) filter (where c.stage = 'applied') as applied,
       count(c.id) filter (where c.stage = 'screening') as screening,
       count(c.id) filter (where c.stage = 'interview') as interview,
       count(c.id) filter (where c.stage = 'offer') as offer,
       count(c.id) filter (where c.stage = 'hired') as hired,
       count(c.id) filter (where c.stage in ('rejected','withdrawn')) as closed
from public.job_openings o left join public.candidates c on c.opening_id = o.id
group by o.id;
grant select on public.opening_pipeline to authenticated;

-- ---------- actions ----------
create or replace function public.submit_interview_feedback(p_interview uuid, p_rating smallint, p_recommendation text,
  p_feedback text, p_status text default 'completed') returns public.interviews
language plpgsql security definer set search_path = '' as $$
declare iv public.interviews; v_to uuid;
begin
  select * into iv from public.interviews where id = p_interview and org_id = app.org_id() for update;
  if iv.id is null then raise exception 'Interview not found' using errcode = 'P0002'; end if;
  if not (iv.interviewer_id = auth.uid() or app.recruiter()) then
    raise exception 'Only the interviewer or a recruiter can submit feedback' using errcode = '42501'; end if;
  if p_status not in ('completed','no_show') then raise exception 'Status must be completed or no-show' using errcode = '22023'; end if;
  if p_status = 'completed' then
    if p_rating is null or p_rating not between 1 and 5 then raise exception 'Rate the candidate from 1 to 5' using errcode = '22023'; end if;
    if p_recommendation not in ('strong_yes','yes','no','strong_no') then raise exception 'Choose a recommendation' using errcode = '22023'; end if;
    if coalesce(length(trim(p_feedback)), 0) < 10 then raise exception 'Write at least a sentence of feedback' using errcode = '22023'; end if;
  end if;
  if iv.scheduled_at > now() + interval '1 hour' then raise exception 'Feedback can be submitted once the interview has happened' using errcode = '22023'; end if;
  perform set_config('app.bypass_guards', 'on', true);
  update public.interviews set status = p_status, rating = case when p_status = 'completed' then p_rating end,
    recommendation = case when p_status = 'completed' then p_recommendation end,
    feedback = nullif(trim(p_feedback), ''), feedback_at = now()
  where id = iv.id returning * into iv;
  perform set_config('app.bypass_guards', '', true);
  for v_to in select x from app.profiles_with_perm(iv.org_id, 'recruitment.manage') x loop
    perform app.notify(v_to, 'interview_feedback', 'Interview feedback submitted', iv.round_name,
      '/recruitment/candidates/' || iv.candidate_id, 'interview', iv.id, 'iv_feedback:' || iv.id);
  end loop;
  return iv;
end $$;

-- draft -> sent -> accepted | declined; anything open -> withdrawn
create or replace function public.set_offer_status(p_offer uuid, p_status text) returns public.offers
language plpgsql security definer set search_path = '' as $$
declare o public.offers; c public.candidates; v_ok boolean;
begin
  if not app.recruiter() then raise exception 'You need the recruitment.manage permission' using errcode = '42501'; end if;
  select * into o from public.offers where id = p_offer and org_id = app.org_id() for update;
  if o.id is null then raise exception 'Offer not found' using errcode = 'P0002'; end if;
  select * into c from public.candidates where id = o.candidate_id;
  v_ok := (o.status = 'draft' and p_status in ('sent','withdrawn'))
       or (o.status = 'sent' and p_status in ('accepted','declined','withdrawn'))
       or (o.status = 'accepted' and p_status = 'withdrawn' and c.stage <> 'hired');
  if not v_ok then raise exception 'An offer that is % can''t be marked %', o.status, p_status using errcode = '22023'; end if;
  perform set_config('app.bypass_guards', 'on', true);
  update public.offers set status = p_status,
    offer_date = case when p_status = 'sent' then app.org_today(o.org_id) else offer_date end,
    decided_at = case when p_status in ('accepted','declined','withdrawn') then now() end
  where id = o.id returning * into o;
  if p_status = 'sent' then
    update public.candidates set stage = 'offer' where id = c.id and stage not in ('offer','hired');
    if c.email is not null and o.letter_text is not null then
      perform app.queue_email(o.org_id, c.email, c.full_name, 'Offer of employment — ' || o.designation,
        o.letter_text, 'offer', 'offer', o.id, 'offer_sent:' || o.id);
    end if;
  elsif p_status = 'declined' then
    update public.candidates set stage = 'withdrawn', rejection_reason = coalesce(rejection_reason, 'Declined the offer') where id = c.id;
  end if;
  perform set_config('app.bypass_guards', '', true);
  return o;
end $$;

-- Accepted offer -> employee record (onboarding), first salary revision, candidate marked hired.
create or replace function public.hire_candidate(p_candidate uuid, p_work_email text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare c public.candidates; o public.offers; j public.job_openings; v_emp uuid; v_month numeric; v_basic numeric; v_hra numeric;
begin
  if not (app.recruiter() and app.has_perm('employees.create')) then
    raise exception 'You need recruitment.manage and employees.create to hire' using errcode = '42501'; end if;
  select * into c from public.candidates where id = p_candidate and org_id = app.org_id() for update;
  if c.id is null then raise exception 'Candidate not found' using errcode = 'P0002'; end if;
  if c.stage = 'hired' then raise exception 'Already hired' using errcode = '22023'; end if;
  select * into o from public.offers where candidate_id = c.id and status = 'accepted';
  if o.id is null then raise exception 'The candidate needs an accepted offer first' using errcode = '22023'; end if;
  select * into j from public.job_openings where id = c.opening_id;
  if coalesce(trim(p_work_email), '') !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter a valid work e-mail' using errcode = '22023'; end if;
  if exists (select 1 from public.employee_profiles where org_id = c.org_id and lower(work_email) = lower(trim(p_work_email))) then
    raise exception 'An employee with this work e-mail already exists' using errcode = '23505'; end if;

  insert into public.employee_profiles(org_id, employee_code, full_name, work_email, work_phone, department_id, designation,
    reporting_manager_id, employment_type, status, joining_date)
  values (c.org_id, '', c.full_name, lower(trim(p_work_email)), c.phone, coalesce(o.department_id, j.department_id), o.designation,
    j.hiring_manager_id, j.employment_type, 'onboarding', o.joining_date)
  returning id into v_emp;

  if app.has_perm('salary.edit') then
    v_month := round(o.annual_ctc / 12, 2);
    v_basic := round(v_month * 0.5); v_hra := round(v_month * 0.2);
    insert into public.salary_revisions(org_id, employee_id, effective_from, annual_ctc, monthly_components, reason, created_by)
    values (c.org_id, v_emp, o.joining_date, o.annual_ctc,
      jsonb_build_object('BASIC', v_basic, 'HRA', v_hra, 'SPECIAL', v_month - v_basic - v_hra), 'Offer accepted', auth.uid());
  end if;

  perform set_config('app.bypass_guards', 'on', true);
  update public.candidates set stage = 'hired', employee_id = v_emp where id = c.id;
  if (select count(*) from public.candidates where opening_id = j.id and stage = 'hired') >= j.positions then
    update public.job_openings set status = 'filled' where id = j.id;
  end if;
  perform set_config('app.bypass_guards', '', true);
  return v_emp;
end $$;

do $$ declare f text; begin
  foreach f in array array['submit_interview_feedback(uuid,smallint,text,text,text)','set_offer_status(uuid,text)',
    'hire_candidate(uuid,text)'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop; end $$;

revoke execute on all functions in schema app from public, anon;
grant execute on all functions in schema app to authenticated, service_role;

-- ===== 20261028000016_phase5_defaults.sql =====
-- =====================================================================
-- 0016 PHASE 5: default role permissions, storage area for résumés,
-- and backfill for organizations created before this release.
-- =====================================================================

create or replace function app.seed_phase5_defaults(p_org uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform set_config('app.bypass_guards', 'on', true);
  insert into public.role_permissions(role_id, permission_key, org_id)
  select ro.id, x.perm, p_org
  from (values
    ('super_admin', array['invoices.view','invoices.manage','payroll.view','payroll.run','recruitment.view','recruitment.manage']),
    ('agency_owner', array['invoices.view','invoices.manage','payroll.view','payroll.run','recruitment.view','recruitment.manage']),
    ('hr_manager', array['payroll.view','payroll.run','recruitment.view','recruitment.manage']),
    ('accounts_manager', array['invoices.view','invoices.manage','payroll.view'])
  ) as v(role_key, perms)
  cross join lateral unnest(v.perms) as x(perm)
  join public.roles ro on ro.org_id = p_org and ro.key = v.role_key
  on conflict do nothing;
  insert into public.billing_settings(org_id, legal_name)
  select id, name from public.organizations where id = p_org on conflict do nothing;
  insert into public.email_settings(org_id) values (p_org) on conflict do nothing;
  perform set_config('app.bypass_guards', '', true);
end $$;

-- new organizations: same body as 0008 plus Phase 5 defaults
create or replace function app.seed_org_defaults(p_org uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare r record;
begin
  perform set_config('app.bypass_guards', 'on', true);
  for r in select * from (values
    ('super_admin','Super Admin', false, array(select key from public.permissions)),
    ('agency_owner','Agency Owner', false, array(select key from public.permissions)),
    ('hr_manager','HR Manager', false, array['users.manage','departments.manage','employees.view','employees.create','employees.edit',
      'employees.delete','employees.export','employees.view_sensitive','salary.view','salary.edit','attendance.view_all',
      'attendance.approve','attendance.manage_policy','attendance.export','leave.view_all','leave.approve','leave.manage_policy',
      'leave.export','holidays.manage','announcements.manage','reports.view']),
    ('project_manager','Project Manager', false, array['employees.view','clients.view','clients.create','clients.edit',
      'projects.view_all','projects.create','projects.edit','projects.delete','projects.export','tasks.view_all','tasks.create',
      'tasks.edit_all','tasks.delete','tasks.manage_statuses','reports.view']),
    ('team_leader','Team Leader', false, array['employees.view','clients.view','projects.view_all','tasks.view_all','tasks.create',
      'tasks.edit_all','tasks.delete','reports.view']),
    ('dm_executive','Digital Marketing Executive', false, array['employees.view','tasks.create']),
    ('seo_executive','SEO Executive', false, array['employees.view','tasks.create']),
    ('graphic_designer','Graphic Designer', false, array['employees.view','tasks.create']),
    ('video_editor','Video Editor', false, array['employees.view','tasks.create']),
    ('social_media_manager','Social Media Manager', false, array['employees.view','tasks.create']),
    ('accounts_manager','Accounts Manager', false, array['employees.view','salary.view','clients.view','clients.view_billing','reports.view']),
    ('client','Client', true, array[]::text[])
  ) as v(key, name, is_client, perms) loop
    insert into public.roles(org_id, key, name, is_system, is_client_role)
    values (p_org, r.key, r.name, true, r.is_client) on conflict (org_id, key) do nothing;
    insert into public.role_permissions(role_id, permission_key, org_id)
    select ro.id, unnest(r.perms), p_org from public.roles ro where ro.org_id = p_org and ro.key = r.key
    on conflict do nothing;
  end loop;

  insert into public.task_statuses(org_id, key, name, category, position, color, is_default) values
    (p_org,'todo','To Do','todo',1,'#64748b',true),
    (p_org,'in_progress','In Progress','in_progress',2,'#2563eb',false),
    (p_org,'in_review','In Review','review',3,'#d97706',false),
    (p_org,'changes_requested','Changes Requested','changes_requested',4,'#dc2626',false),
    (p_org,'completed','Completed','done',5,'#16a34a',false)
  on conflict do nothing;

  insert into public.work_schedules(org_id, name, is_default) values (p_org, 'General shift', true) on conflict do nothing;

  insert into public.leave_types(org_id, code, name, annual_quota, is_paid, allow_half_day, color) values
    (p_org,'CL','Casual Leave',12,true,true,'#0ea5e9'),
    (p_org,'SL','Sick Leave',6,true,true,'#f97316'),
    (p_org,'EL','Earned Leave',15,true,false,'#22c55e'),
    (p_org,'LWP','Leave Without Pay',null,false,true,'#94a3b8')
  on conflict do nothing;

  insert into public.salary_components(org_id, code, name, kind) values
    (p_org,'BASIC','Basic','earning'),(p_org,'HRA','House Rent Allowance','earning'),
    (p_org,'SPECIAL','Special Allowance','earning'),(p_org,'PF_EMP','Employee PF','deduction'),
    (p_org,'PT','Professional Tax','deduction')
  on conflict do nothing;

  insert into public.departments(org_id, name)
  select p_org, d from unnest(array['Management','Performance Marketing','SEO','Creative','Social Media','Web Development','HR & Admin','Accounts']) d
  on conflict do nothing;
  perform app.seed_phase4_defaults(p_org);
  perform app.seed_phase5_defaults(p_org);
  perform set_config('app.bypass_guards', '', true);
end $$;

-- ---------- storage: résumés under {org_id}/recruitment/{candidate_id}/... ----------
create or replace function app.can_read_object(p_name text) returns boolean
language plpgsql stable security definer set search_path = '' as $$
declare parts text[] := string_to_array(p_name, '/');
begin
  if array_length(parts, 1) < 4 or parts[1] <> app.org_id()::text then return false; end if;
  return case parts[2]
    when 'tasks' then exists (select 1 from public.task_attachments a where a.storage_path = p_name
                              and app.can_view_task(a.task_id) and (app.is_internal() or not a.is_internal))
    when 'employees' then app.is_internal() and (parts[3] = app.my_employee_id()::text or app.has_perm('employees.view_sensitive'))
    when 'clients' then app.can_view_client(parts[3]::uuid)
    when 'recruitment' then app.can_view_candidate(parts[3]::uuid)
    else false end;
exception when invalid_text_representation then return false;
end $$;

create or replace function app.can_write_object(p_name text) returns boolean
language plpgsql stable security definer set search_path = '' as $$
declare parts text[] := string_to_array(p_name, '/');
begin
  if array_length(parts, 1) < 4 or parts[1] <> app.org_id()::text then return false; end if;
  return case parts[2]
    when 'tasks' then app.can_view_task(parts[3]::uuid)
    when 'employees' then app.has_perm('employees.view_sensitive') and app.has_perm('employees.edit')
    when 'clients' then app.can_view_client(parts[3]::uuid) and (app.has_perm('clients.edit') or parts[3]::uuid = app.client_id())
    when 'recruitment' then app.recruiter() and exists (select 1 from public.candidates c where c.id = parts[3]::uuid and c.org_id = app.org_id())
    else false end;
exception when invalid_text_representation then return false;
end $$;

-- existing organizations (e.g. the live one) get the same Phase 5 defaults
do $$ declare o record; begin
  for o in select id from public.organizations loop perform app.seed_phase5_defaults(o.id); end loop;
end $$;

revoke execute on all functions in schema app from public, anon;
grant execute on all functions in schema app to authenticated, service_role;
