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
