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
