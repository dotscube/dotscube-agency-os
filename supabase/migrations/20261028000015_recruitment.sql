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
