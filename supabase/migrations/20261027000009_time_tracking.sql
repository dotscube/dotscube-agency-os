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
