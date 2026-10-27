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
