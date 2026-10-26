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
