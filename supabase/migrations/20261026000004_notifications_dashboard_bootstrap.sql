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
