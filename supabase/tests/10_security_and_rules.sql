-- =====================================================================
-- Agency OS database tests: tenancy, RBAC, HR rules, task workflow,
-- client isolation, notifications, dashboard, audit.
-- Run: scripts/test-db.sh
-- =====================================================================
\set ON_ERROR_STOP 1
\o /dev/null

-- ---------- bootstrap two organizations ----------
select tst.new_user('owner@a.test', 'Manjeet Owner');
select tst.new_user('owner@b.test', 'Other Owner');
select tst.new_user('stranger@x.test', 'No Org');

select tst.login('owner@a.test'); set role authenticated;
select tst.put('orgA', public.create_organization('Dotscube Digital', 'dotscube', 'Manjeet Owner'));
select tst.throws($$select public.create_organization('Again','again')$$, 'cannot create a second org', '42501');
reset role;

select tst.login('owner@b.test'); set role authenticated;
select tst.put('orgB', public.create_organization('Other Agency', 'other-agency'));
reset role;

select tst.ok((select count(*) = 12 from public.roles where org_id = tst.id('orgA')), 'seeded 12 roles');
select tst.ok((select count(*) = 5 from public.task_statuses where org_id = tst.id('orgA')), 'seeded 5 task statuses');
select tst.eq((select employee_code from public.employee_profiles where profile_id = tst.id('owner@a.test')), 'EMP0001', 'founder employee code auto-generated');

-- ---------- owner A creates employees and invitations ----------
select tst.login('owner@a.test'); set role authenticated;
select tst.put('dept_creative', (select id from public.departments where name = 'Creative'));
insert into public.employee_profiles(org_id, employee_code, full_name, work_email, designation, status, joining_date, department_id)
values (tst.id('orgA'), '', 'Priya HR', 'hr@a.test', 'HR Manager', 'active', '2024-01-01', null),
       (tst.id('orgA'), '', 'Rahul PM', 'pm@a.test', 'Project Manager', 'active', '2024-01-01', null),
       (tst.id('orgA'), '', 'Asha Accounts', 'acc@a.test', 'Accountant', 'active', '2024-01-01', null);
select tst.put('emp_hr', (select id from public.employee_profiles where work_email = 'hr@a.test'));
select tst.put('emp_pm', (select id from public.employee_profiles where work_email = 'pm@a.test'));
select tst.put('emp_acc', (select id from public.employee_profiles where work_email = 'acc@a.test'));
insert into public.employee_profiles(org_id, employee_code, full_name, work_email, designation, status, joining_date,
  reporting_manager_id, department_id, probation_end_date)
values (tst.id('orgA'), '', 'Dev Designer', 'des@a.test', 'Graphic Designer', 'probation', '2026-06-01', tst.id('emp_pm'), tst.id('dept_creative'), current_date + 10),
       (tst.id('orgA'), '', 'Sana SEO', 'seo@a.test', 'SEO Executive', 'active', '2025-01-01', tst.id('emp_pm'), null, null);
select tst.put('emp_des', (select id from public.employee_profiles where work_email = 'des@a.test'));
select tst.put('emp_seo', (select id from public.employee_profiles where work_email = 'seo@a.test'));
select tst.throws($$update public.employee_profiles set reporting_manager_id = tst.id('emp_des') where id = tst.id('emp_pm')$$,
  'reporting-line cycle rejected', 'cycle');

insert into public.invitations(org_id, email, role_id, employee_id, invited_by)
select tst.id('orgA'), x.email, r.id, x.emp, auth.uid()
from (values ('hr@a.test','hr_manager',tst.id('emp_hr')), ('pm@a.test','project_manager',tst.id('emp_pm')),
             ('acc@a.test','accounts_manager',tst.id('emp_acc')), ('des@a.test','graphic_designer',tst.id('emp_des')),
             ('seo@a.test','seo_executive',tst.id('emp_seo'))) x(email, rk, emp)
join public.roles r on r.org_id = tst.id('orgA') and r.key = x.rk;

-- client
insert into public.clients(org_id, name, status, account_manager_id, created_by)
values (tst.id('orgA'), 'Maahaul India', 'active', tst.id('emp_pm'), auth.uid()),
       (tst.id('orgA'), 'Second Client', 'active', null, auth.uid());
select tst.put('client1', (select id from public.clients where name = 'Maahaul India'));
select tst.put('client2', (select id from public.clients where name = 'Second Client'));
select tst.eq((select count(*) from public.client_onboarding_items where client_id = tst.id('client1'))::int, 7, 'new client gets onboarding checklist automatically');
insert into public.client_billing(client_id, org_id, billing_email, gst_number) values (tst.id('client1'), tst.id('orgA'), 'billing@maahaul.test', '08ABCDE1234F1Z5');
insert into public.contracts(org_id, client_id, title, start_date, end_date, management_fee, renewal_reminder_days)
values (tst.id('orgA'), tst.id('client1'), 'SEO retainer', '2026-01-01', current_date + 20, 25000, 30);
insert into public.client_notes(org_id, client_id, author_id, body) values (tst.id('orgA'), tst.id('client1'), auth.uid(), 'Internal: client is price sensitive');
insert into public.invitations(org_id, email, role_id, client_id, invited_by)
select tst.id('orgA'), 'cli@maahaul.test', id, tst.id('client1'), auth.uid() from public.roles where org_id = tst.id('orgA') and key = 'client';
select tst.throws($$insert into public.invitations(org_id, email, role_id, invited_by)
  select tst.id('orgA'), 'bad@a.test', id, auth.uid() from public.roles where org_id = tst.id('orgA') and key = 'client'$$,
  'client role invitation without client rejected', '23514');
insert into public.holidays(org_id, holiday_date, name) values (tst.id('orgA'), '2027-03-03', 'Test Holiday');
reset role;

-- invited users sign up -> linked automatically
select tst.new_user('hr@a.test','Priya HR'), tst.new_user('pm@a.test','Rahul PM'), tst.new_user('acc@a.test','Asha'),
       tst.new_user('des@a.test','Dev Designer'), tst.new_user('seo@a.test','Sana SEO'), tst.new_user('cli@maahaul.test','Client User');
select tst.eq((select org_id from public.profiles where email = 'des@a.test'), tst.id('orgA'), 'invitation links user to org');
select tst.eq((select profile_id from public.employee_profiles where id = tst.id('emp_des')), tst.id('des@a.test'), 'invitation links employee record');
select tst.eq((select client_id from public.profiles where email = 'cli@maahaul.test'), tst.id('client1'), 'client invite sets client_id');
select tst.ok((select org_id is null from public.profiles where email = 'stranger@x.test'), 'uninvited user has no org');

-- =================== TENANCY ===================
select tst.login('owner@b.test'); set role authenticated;
select tst.eq((select count(*) from public.clients)::int, 0, 'org B cannot see org A clients');
select tst.eq((select count(*) from public.employee_profiles where org_id = tst.id('orgA'))::int, 0, 'org B cannot see org A employees');
select tst.eq((select count(*) from public.organizations)::int, 1, 'org B sees only its own organization');
select tst.throws($$insert into public.clients(org_id, name, created_by) values (tst.id('orgA'), 'Injected', auth.uid())$$,
  'org B cannot insert into org A', '42501');
select tst.eq((select count(*) from public.audit_logs where org_id = tst.id('orgA'))::int, 0, 'org B cannot read org A audit log');
reset role;

select tst.login('stranger@x.test'); set role authenticated;
select tst.eq((select count(*) from public.roles)::int, 0, 'user without org sees no roles');
select tst.eq((select count(*) from public.my_permissions())::int, 0, 'user without org has no permissions');
reset role;

-- =================== RBAC & HR PRIVACY ===================
select tst.login('hr@a.test'); set role authenticated;
insert into public.salary_revisions(org_id, employee_id, effective_from, annual_ctc, monthly_components, created_by)
values (tst.id('orgA'), tst.id('emp_seo'), '2026-04-01', 480000, '{"BASIC":20000,"HRA":8000}', auth.uid()),
       (tst.id('orgA'), tst.id('emp_des'), '2026-06-01', 360000, '{"BASIC":15000}', auth.uid());
insert into public.employee_private(employee_id, org_id, personal_phone, emergency_contact_name)
values (tst.id('emp_seo'), tst.id('orgA'), '9999999999', 'Parent');
select tst.eq((select count(*) from public.employee_private where employee_id = tst.id('emp_seo'))::int, 1, 'HR reads private details');
select tst.throws($$update public.salary_revisions set annual_ctc = 1 where employee_id = tst.id('emp_seo')$$,
  'salary revisions are append-only', '42501');
select tst.throws($$insert into public.user_roles(user_id, role_id, org_id)
  select tst.id('seo@a.test'), id, org_id from public.roles where org_id = tst.id('orgA') and key = 'super_admin'$$,
  'HR cannot grant Super Admin', '42501');
reset role;

select tst.login('des@a.test'); set role authenticated;
select tst.eq((select count(*) from public.salary_revisions)::int, 1, 'designer sees only own salary');
select tst.eq((select count(*) from public.employee_private where employee_id = tst.id('emp_seo'))::int, 0, 'designer cannot read colleague private details');
select tst.ok((select count(*) >= 5 from public.employee_profiles), 'designer can see directory');
select tst.throws($$insert into public.employee_profiles(org_id, employee_code, full_name, work_email, joining_date)
  values (tst.id('orgA'), '', 'Fake', 'fake@a.test', current_date)$$, 'designer cannot create employees', '42501');
select tst.throws($$insert into public.user_roles(user_id, role_id, org_id)
  select auth.uid(), id, org_id from public.roles where org_id = tst.id('orgA') and key = 'agency_owner'$$,
  'designer cannot grant himself a role', '42501');
select tst.eq((select count(*) from public.client_billing)::int, 0, 'designer cannot see client billing');
select tst.eq((select count(*) from public.contracts)::int, 0, 'designer cannot see contracts');
select tst.eq((select count(*) from public.clients)::int, 0, 'designer without clients.view sees no clients');
select tst.eq((select count(*) from public.audit_logs)::int, 0, 'designer cannot read audit log');
update public.profiles set is_active = false where id = tst.id('seo@a.test');
select tst.ok((select is_active from public.profiles where id = tst.id('seo@a.test')), 'designer cannot deactivate users');
reset role;

select tst.login('pm@a.test'); set role authenticated;
select tst.eq((select count(*) from public.contracts)::int, 0, 'PM cannot see contracts');
select tst.eq((select count(*) from public.clients)::int, 2, 'PM sees clients');
select tst.eq((select count(*) from public.salary_revisions)::int, 0, 'PM cannot see salaries (has none of own)');
reset role;

select tst.login('acc@a.test'); set role authenticated;
select tst.eq((select count(*) from public.contracts)::int, 1, 'accounts sees contracts');
select tst.eq((select count(*) from public.salary_revisions)::int, 2, 'accounts sees salaries');
reset role;

select tst.login('owner@a.test'); set role authenticated;
select tst.throws($$delete from public.user_roles where user_id = auth.uid()$$, 'cannot remove last Super Admin', '42501');
select tst.throws($$insert into public.role_permissions(role_id, permission_key, org_id)
  select id, 'salary.view', org_id from public.roles where org_id = tst.id('orgA') and key = 'client'$$,
  'client role cannot receive internal permissions', '42501');
select tst.throws($$delete from public.roles where org_id = tst.id('orgA') and key = 'hr_manager'$$, 'system roles cannot be deleted', '42501');
select tst.ok((select count(*) > 0 from public.audit_logs), 'owner reads audit log');
reset role;

-- =================== PRIVILEGE ESCALATION ===================
select tst.login('hr@a.test'); set role authenticated;
select tst.throws($$insert into public.invitations(org_id, email, role_id, invited_by)
  select tst.id('orgA'), 'accomplice@x.test', id, auth.uid() from public.roles where org_id = tst.id('orgA') and key = 'agency_owner'$$,
  'HR cannot invite into a more powerful role', '42501');
select tst.throws($$insert into public.user_roles(user_id, role_id, org_id)
  select tst.id('seo@a.test'), id, org_id from public.roles where org_id = tst.id('orgA') and key = 'agency_owner'$$,
  'HR cannot assign a more powerful role', '42501');
select tst.throws($$insert into public.invitations(org_id, email, role_id, invited_by)
  select tst.id('orgA'), 'accounts2@x.test', id, auth.uid() from public.roles where org_id = tst.id('orgA') and key = 'accounts_manager'$$,
  'HR cannot invite into a role with billing access', '42501');
select tst.lives($$insert into public.invitations(org_id, email, role_id, invited_by)
  select tst.id('orgA'), 'editor@a.test', id, auth.uid() from public.roles where org_id = tst.id('orgA') and key = 'video_editor'$$,
  'HR can invite staff into operational roles');
select tst.lives($$insert into public.invitations(org_id, email, role_id, invited_by)
  select tst.id('orgA'), 'pm2@a.test', id, auth.uid() from public.roles where org_id = tst.id('orgA') and key = 'project_manager'$$,
  'HR can invite a project manager');
reset role;
-- a custom role holder with roles.manage cannot add permissions they lack
select tst.login('owner@a.test'); set role authenticated;
insert into public.roles(org_id, key, name) values (tst.id('orgA'), 'role_admin', 'Role admin');
insert into public.role_permissions(role_id, permission_key, org_id)
  select id, 'roles.manage', org_id from public.roles where org_id = tst.id('orgA') and key = 'role_admin';
insert into public.user_roles(user_id, role_id, org_id)
  select tst.id('seo@a.test'), id, org_id from public.roles where org_id = tst.id('orgA') and key = 'role_admin';
reset role;
select tst.login('seo@a.test'); set role authenticated;
select tst.throws($$insert into public.role_permissions(role_id, permission_key, org_id)
  select id, 'salary.view', org_id from public.roles where org_id = tst.id('orgA') and key = 'role_admin'$$,
  'roles.manage holder cannot grant themselves new permissions', '42501');
reset role;
select tst.login('owner@a.test'); set role authenticated;
delete from public.user_roles where user_id = tst.id('seo@a.test') and role_id = (select id from public.roles where key = 'role_admin' and org_id = tst.id('orgA'));
reset role;

-- =================== ATTENDANCE ===================
select tst.eq((select row(worked_minutes, late_minutes, status)::text from app.compute_attendance(
  '2026-10-26 04:50+00', '2026-10-26 13:30+00', 30, 'Asia/Kolkata', '10:00', 15, 240, 480)),
  '(490,20,present)', 'compute: 10:20 IST in, 19:00 out, 30m break -> late 20, present');
select tst.eq((select row(worked_minutes, late_minutes, status)::text from app.compute_attendance(
  '2026-10-26 04:40+00', '2026-10-26 09:40+00', 0, 'Asia/Kolkata', '10:00', 15, 240, 480)),
  '(300,0,half_day)', 'compute: within grace, 5h -> half day');
select tst.eq((select row(worked_minutes, late_minutes, status)::text from app.compute_attendance(
  '2026-10-26 04:30+00', '2026-10-26 06:30+00', 0, 'Asia/Kolkata', '10:00', 15, 240, 480)),
  '(120,0,absent)', 'compute: 2h -> absent');
select tst.eq((select status::text from app.compute_attendance(now(), null, 0, 'Asia/Kolkata', '10:00', 15, 240, 480)),
  'in_progress', 'compute: open record -> in progress');

select tst.login('des@a.test'); set role authenticated;
select tst.lives($$select public.attendance_check_in()$$, 'designer checks in');
select tst.throws($$select public.attendance_check_in()$$, 'second check-in same day rejected', 'already checked in');
select tst.lives($$select public.attendance_break_start()$$, 'break starts');
select tst.throws($$select public.attendance_break_start()$$, 'cannot start two breaks', 'already in progress');
select tst.lives($$select public.attendance_break_end()$$, 'break ends');
select tst.throws($$insert into public.attendance_records(org_id, employee_id, work_date, check_in_at)
  values (tst.id('orgA'), tst.id('emp_des'), current_date - 5, now() - interval '5 days')$$, 'direct attendance insert denied', '42501');
select tst.throws($$update public.attendance_records set check_in_at = now() - interval '3 hours'$$, 'direct attendance edit denied', '42501');
select tst.lives($$select public.attendance_check_out()$$, 'designer checks out');
select tst.ok((select check_out_at is not null and worked_minutes is not null from public.attendance_records where employee_id = tst.id('emp_des')),
  'check-out recorded with server time');
select tst.lives($$select public.request_attendance_correction(
   ((now() at time zone 'Asia/Kolkata')::date - 2),
   (((now() at time zone 'Asia/Kolkata')::date - 2) + time '10:05') at time zone 'Asia/Kolkata',
   (((now() at time zone 'Asia/Kolkata')::date - 2) + time '19:10') at time zone 'Asia/Kolkata', 'Forgot to check in - client visit')$$,
  'designer requests correction');
select tst.put('corr1', (select id from public.attendance_corrections where employee_id = tst.id('emp_des')));
select tst.throws($$select public.decide_attendance_correction(tst.id('corr1'), true)$$, 'cannot approve own correction', '42501');
select tst.throws($$select public.request_attendance_correction(current_date + 3, now(), now() + interval '1 hour', 'future date test')$$,
  'future correction rejected', '22023');
reset role;

select tst.login('seo@a.test'); set role authenticated;
select tst.eq((select count(*) from public.attendance_records where employee_id = tst.id('emp_des'))::int, 0, 'peer cannot see colleague attendance');
select tst.throws($$select public.decide_attendance_correction(tst.id('corr1'), true)$$, 'peer cannot approve correction', '42501');
reset role;

select tst.login('pm@a.test'); set role authenticated;
select tst.eq((select count(*) from public.attendance_records where employee_id = tst.id('emp_des'))::int, 1, 'manager sees report attendance');
select tst.lives($$select public.decide_attendance_correction(tst.id('corr1'), true, 'ok')$$, 'manager approves correction');
select tst.throws($$select public.decide_attendance_correction(tst.id('corr1'), true)$$, 'correction cannot be decided twice', 'already decided');
select tst.eq((select row(source, status, late_minutes)::text from public.attendance_records
  where employee_id = tst.id('emp_des') and work_date = (now() at time zone 'Asia/Kolkata')::date - 2), '(correction,present,0)',
  'approved correction creates computed record (10:05 within grace, 9h05m)');
reset role;
select tst.ok((select count(*) > 0 from public.audit_logs where table_name = 'attendance_records' and org_id = tst.id('orgA')),
  'attendance changes are audited');

-- =================== LEAVE ===================
-- 2027-03-01 Mon .. 2027-03-07 Sun; 2027-03-03 holiday; Sunday weekly off -> 5 working days
select tst.login('des@a.test'); set role authenticated;
select tst.eq(public.preview_leave_days('2027-03-01','2027-03-07'), 5.0, 'leave days exclude Sunday and holiday');
select tst.eq(public.preview_leave_days('2027-03-03','2027-03-03','first_half'), 0.0, 'half day on holiday counts 0');
select tst.put('cl', (select id from public.leave_types where org_id = tst.id('orgA') and code = 'CL'));
select tst.put('el', (select id from public.leave_types where org_id = tst.id('orgA') and code = 'EL'));
select tst.put('sl', (select id from public.leave_types where org_id = tst.id('orgA') and code = 'SL'));
select tst.lives($$select public.apply_leave(tst.id('cl'), '2027-03-01', '2027-03-07', 'none', 'Family function')$$, 'apply 5-day CL');
select tst.put('lr1', (select id from public.leave_requests where employee_id = tst.id('emp_des') and start_date = '2027-03-01'));
select tst.throws($$select public.apply_leave(tst.id('cl'), '2027-03-05', '2027-03-05')$$, 'overlapping leave rejected', '23P01');
select tst.throws($$select public.apply_leave(tst.id('cl'), '2027-04-05', '2027-04-14')$$, 'insufficient balance (5 pending of 12)', 'Insufficient balance');
select tst.throws($$select public.apply_leave(tst.id('el'), '2027-05-03', '2027-05-03', 'first_half')$$, 'half day not allowed on EL', '22023');
select tst.throws($$select public.apply_leave(tst.id('cl'), '2026-12-30', '2027-01-02')$$, 'cross-year leave rejected', '22023');
select tst.lives($$select public.apply_leave(tst.id('cl'), '2027-03-10', '2027-03-10', 'first_half')$$, 'apply half-day CL');
select tst.throws($$select public.decide_leave(tst.id('lr1'), true)$$, 'cannot approve own leave', '42501');
select tst.throws($$update public.leave_balances set used = 0$$, 'employee cannot edit balances', '42501');
reset role;

select tst.login('pm@a.test'); set role authenticated;
select tst.ok((select count(*) >= 1 from public.notifications where type = 'leave_request'), 'manager notified of leave request');
select tst.lives($$select public.decide_leave(tst.id('lr1'), true, 'Enjoy')$$, 'manager approves leave');
select tst.throws($$select public.decide_leave(tst.id('lr1'), true)$$, 'leave cannot be decided twice', 'already decided');
reset role;
select tst.eq((select used from public.leave_balances where employee_id = tst.id('emp_des') and leave_type_id = tst.id('cl') and year = 2027),
  5.0, 'approval deducts balance');

select tst.login('des@a.test'); set role authenticated;
select tst.ok((select count(*) = 1 from public.notifications where type = 'leave_decision'), 'employee notified of decision');
select tst.lives($$select public.cancel_leave(tst.id('lr1'))$$, 'employee cancels future approved leave');
reset role;
select tst.eq((select used from public.leave_balances where employee_id = tst.id('emp_des') and leave_type_id = tst.id('cl') and year = 2027),
  0.0, 'cancellation restores balance');

-- two-level approval
update public.leave_types set approval_levels = 2 where id = tst.id('sl');
select tst.login('des@a.test'); set role authenticated;
select tst.put('lr2', (public.apply_leave(tst.id('sl'), '2027-06-07', '2027-06-08')).id);
reset role;
select tst.login('pm@a.test'); set role authenticated;
select tst.lives($$select public.decide_leave(tst.id('lr2'), true)$$, 'level 1 approval by manager');
select tst.throws($$select public.decide_leave(tst.id('lr2'), true)$$, 'manager without leave.approve cannot do level 2', '42501');
reset role;
select tst.login('hr@a.test'); set role authenticated;
select tst.lives($$select public.decide_leave(tst.id('lr2'), true)$$, 'HR approves level 2');
select tst.eq((select status from public.leave_requests where id = tst.id('lr2')), 'approved', 'two-level leave fully approved');
select tst.eq((select count(*) from public.leave_approvals where request_id = tst.id('lr2'))::int, 2, 'approval history kept per level');
reset role;

-- =================== PROJECTS & TASKS ===================
select tst.login('pm@a.test'); set role authenticated;
insert into public.projects(org_id, client_id, name, service, owner_id, status, start_date, due_date, client_visible, created_by)
values (tst.id('orgA'), tst.id('client1'), 'Maahaul SEO Q4', 'seo', auth.uid(), 'active', '2026-10-01', '2026-12-31', true, auth.uid());
select tst.put('proj1', (select id from public.projects where name = 'Maahaul SEO Q4'));
insert into public.project_members(project_id, profile_id, org_id, project_role) values (tst.id('proj1'), tst.id('des@a.test'), tst.id('orgA'), 'member');
select tst.throws($$insert into public.project_members(project_id, profile_id, org_id) values (tst.id('proj1'), tst.id('cli@maahaul.test'), tst.id('orgA'))$$,
  'client user cannot be project member', '23514');
insert into public.tasks(org_id, project_id, title, reviewer_id, due_date, created_by, client_visible, estimated_minutes)
values (tst.id('orgA'), tst.id('proj1'), 'Keyword research', auth.uid(), current_date - 1, auth.uid(), true, 120),
       (tst.id('orgA'), tst.id('proj1'), 'Technical audit', null, current_date + 1, auth.uid(), false, 360);
select tst.put('t1', (select id from public.tasks where title = 'Keyword research'));
select tst.put('t2', (select id from public.tasks where title = 'Technical audit'));
insert into public.task_assignees(task_id, profile_id, org_id) values (tst.id('t1'), tst.id('des@a.test'), tst.id('orgA')),
  (tst.id('t2'), tst.id('des@a.test'), tst.id('orgA'));
insert into public.task_comments(org_id, task_id, author_id, body, is_internal) values
  (tst.id('orgA'), tst.id('t1'), auth.uid(), 'Internal: use the paid tool', true),
  (tst.id('orgA'), tst.id('t1'), auth.uid(), 'Research is under way', false);
select tst.eq((select client_id from public.tasks where id = tst.id('t1')), tst.id('client1'), 'task inherits client from project');
reset role;

select tst.login('des@a.test'); set role authenticated;
select tst.eq((select count(*) from public.tasks)::int, 2, 'member sees project tasks');
select tst.ok((select count(*) = 2 from public.notifications where type = 'task_assigned'), 'assignee notified');
select tst.throws($$update public.tasks set status_id = (select id from public.task_statuses where key='completed' and org_id = tst.id('orgA')) where id = tst.id('t1')$$,
  'reviewed task cannot skip review', '42501');
update public.tasks set status_id = (select id from public.task_statuses where key='in_review' and org_id = tst.id('orgA')) where id = tst.id('t1');
select tst.throws($$update public.tasks set status_id = (select id from public.task_statuses where key='completed' and org_id = tst.id('orgA')) where id = tst.id('t1')$$,
  'assignee cannot approve own reviewed task', 'Only the reviewer');
insert into public.task_dependencies(task_id, depends_on_task_id, org_id) values (tst.id('t2'), tst.id('t1'), tst.id('orgA'));
select tst.throws($$insert into public.task_dependencies(task_id, depends_on_task_id, org_id) values (tst.id('t1'), tst.id('t2'), tst.id('orgA'))$$,
  'dependency cycle rejected', 'cycle');
select tst.throws($$update public.tasks set status_id = (select id from public.task_statuses where key='completed' and org_id = tst.id('orgA')) where id = tst.id('t2')$$,
  'blocked by incomplete dependency', 'depends on');
reset role;

select tst.login('pm@a.test'); set role authenticated;
select tst.ok((select count(*) = 1 from public.notifications where type = 'review_requested'), 'reviewer notified on review');
select tst.lives($$update public.tasks set status_id = (select id from public.task_statuses where key='completed' and org_id = tst.id('orgA')) where id = tst.id('t1')$$,
  'reviewer approves task');
select tst.ok((select completed_at is not null from public.tasks where id = tst.id('t1')), 'completed_at set');
select tst.eq((select progress_pct from public.project_overview where id = tst.id('proj1')), 25.0, 'progress weighted by estimates (120 of 480 min)');
update public.tasks set estimated_minutes = null where id = tst.id('t2');
select tst.eq((select progress_pct from public.project_overview where id = tst.id('proj1')), 50.0, 'progress by count when estimates missing');
reset role;

select tst.login('seo@a.test'); set role authenticated;
select tst.eq((select count(*) from public.tasks)::int, 0, 'non-member sees no tasks');
select tst.eq((select count(*) from public.projects)::int, 0, 'non-member sees no projects');
select tst.throws($$insert into public.tasks(org_id, project_id, title, created_by) values (tst.id('orgA'), tst.id('proj1'), 'Sneaky', auth.uid())$$,
  'non-member cannot create task in project', '42501');
reset role;

-- =================== API-STYLE WRITES (INSERT/UPDATE ... RETURNING, as PostgREST does) ===================
select tst.login('pm@a.test'); set role authenticated;
select tst.lives($$with x as (insert into public.clients(org_id, name, created_by) values (tst.id('orgA'), 'Returning Client', auth.uid()) returning id) select * from x$$,
  'insert client ... returning (API path)');
select tst.lives($$with x as (insert into public.projects(org_id, name, owner_id, created_by) values (tst.id('orgA'), 'Returning Project', auth.uid(), auth.uid()) returning id) select * from x$$,
  'insert project ... returning (API path)');
select tst.lives($$with x as (insert into public.tasks(org_id, project_id, title, created_by) values (tst.id('orgA'), tst.id('proj1'), 'Returning Task', auth.uid()) returning id) select * from x$$,
  'insert task ... returning (API path)');
select tst.lives($$with x as (update public.tasks set priority = 'high' where id = tst.id('t2') returning id) select * from x$$, 'update task ... returning (API path)');
reset role;
select tst.login('des@a.test'); set role authenticated;
select tst.lives($$with x as (insert into public.tasks(org_id, project_id, title, created_by) values (tst.id('orgA'), tst.id('proj1'), 'Designer Task', auth.uid()) returning id) select * from x$$,
  'project member inserts task ... returning');
reset role;
select tst.login('hr@a.test'); set role authenticated;
select tst.lives($$with x as (insert into public.employee_profiles(org_id, employee_code, full_name, work_email, joining_date) values (tst.id('orgA'), '', 'New Hire', 'new@a.test', current_date) returning id, employee_code) select * from x$$,
  'HR inserts employee ... returning');
reset role;
delete from public.tasks where title in ('Returning Task', 'Designer Task');

-- =================== CLIENT PORTAL ISOLATION ===================
select tst.login('cli@maahaul.test'); set role authenticated;
select tst.eq((select count(*) from public.my_permissions())::int, 0, 'client has no internal permissions');
select tst.eq((select count(*) from public.clients)::int, 1, 'client sees only own client record');
select tst.eq((select count(*) from public.projects)::int, 1, 'client sees client-visible project');
select tst.eq((select count(*) from public.tasks)::int, 1, 'client sees only client-visible tasks');
select tst.eq((select count(*) from public.task_comments)::int, 1, 'client cannot see internal comments');
select tst.eq((select count(*) from public.employee_profiles)::int, 0, 'client cannot see employees');
select tst.eq((select count(*) from public.salary_revisions)::int, 0, 'client cannot see salaries');
select tst.eq((select count(*) from public.client_notes)::int, 0, 'client cannot see internal client notes');
select tst.eq((select count(*) from public.client_billing)::int, 0, 'client cannot see billing');
select tst.eq((select count(*) from public.project_members)::int, 0, 'client cannot see team membership');
select tst.eq((select count(*) from public.profiles)::int, 1, 'client sees only own profile');
insert into public.task_comments(org_id, task_id, author_id, body, is_internal) values (tst.id('orgA'), tst.id('t1'), auth.uid(), 'Looks good, approved', true);
select tst.eq((select is_internal from public.task_comments where author_id = auth.uid()), false, 'client comment forced to client-visible');
select tst.throws($$insert into public.task_comments(org_id, task_id, author_id, body) values (tst.id('orgA'), tst.id('t2'), auth.uid(), 'peek')$$,
  'client cannot comment on internal task', '42501');
update public.tasks set title = 'hacked' where id = tst.id('t1');
select tst.eq((select title from public.tasks where id = tst.id('t1')), 'Keyword research', 'task unchanged after client attempt');
select tst.eq((select count(*) from public.client_onboarding_items)::int, 0, 'client cannot see internal onboarding checklist');
reset role;
select tst.login('pm@a.test'); set role authenticated;
select tst.ok((select count(*) = 1 from public.notifications where type = 'client_feedback'), 'project owner notified of client feedback');
reset role;

-- =================== NOTIFICATIONS JOB ===================
select tst.ok(public.generate_due_notifications() > 0, 'due/overdue job creates notifications');
select tst.eq(public.generate_due_notifications(), 0, 'due/overdue job is idempotent');
select tst.ok((select count(*) > 0 from public.notifications where type = 'contract_renewal' and recipient_id = tst.id('acc@a.test')),
  'renewal reminder reaches accounts');
select tst.login('des@a.test'); set role authenticated;
select tst.throws($$select public.generate_due_notifications()$$, 'users cannot trigger scheduled job', '42501');
select tst.ok((select bool_and(recipient_id = auth.uid()) from public.notifications), 'users only see own notifications');
reset role;

-- =================== DASHBOARD ===================
select tst.login('owner@a.test'); set role authenticated;
select tst.eq((public.get_dashboard_metrics()->>'active_clients')::int, 2, 'owner dashboard: active clients');
select tst.eq((public.get_dashboard_metrics()->>'probation_reviews_due')::int, 1, 'owner dashboard: probation reviews');
select tst.eq((public.get_dashboard_metrics()->>'upcoming_renewals')::int, 1, 'owner dashboard: renewals');
reset role;
select tst.login('des@a.test'); set role authenticated;
select tst.eq((public.get_dashboard_metrics()->>'active_clients')::int, 0, 'designer dashboard is RLS-scoped (no clients)');
select tst.eq((public.get_dashboard_metrics()->>'my_open_tasks')::int, 1, 'designer dashboard: my open tasks');
select tst.eq((public.get_dashboard_metrics()->>'upcoming_renewals')::int, 0, 'designer dashboard: no contract data');
reset role;
select tst.login('cli@maahaul.test'); set role authenticated;
select tst.eq((public.get_dashboard_metrics()->>'active_employees')::int, 0, 'client dashboard leaks no HR data');
reset role;

-- =================== REPORT ===================
\o
\pset format aligned
select n, case when ok then 'ok' else 'FAIL' end as result, name, case when not ok then detail end as detail
from tst.results order by n;
select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed from tst.results;
do $$ begin
  if exists (select 1 from tst.results where not ok) then raise exception 'DATABASE TESTS FAILED'; end if;
end $$;
