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
