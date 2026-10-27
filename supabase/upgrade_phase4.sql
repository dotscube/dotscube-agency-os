-- Dotscube Agency OS: Phase 4 upgrade (templates, recurring tasks, time tracking, content calendar, campaigns).
-- For a project that already ran setup.sql from Phase 1-3. Paste into Supabase > SQL Editor > New query > Run, ONCE.
-- Existing organizations get the new permissions and the 8 starter templates automatically.
-- Generated from supabase/migrations (the source of truth).
begin;

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

commit;
