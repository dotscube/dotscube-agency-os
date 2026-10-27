-- =====================================================================
-- Phase 4 tests: templates, recurring tasks, time tracking/timesheets,
-- content calendar with client approval, campaigns + CSV import.
-- Runs after 10_security_and_rules.sql and reuses its fixtures.
-- =====================================================================
\set ON_ERROR_STOP 1
\o /dev/null

-- =================== TEMPLATES ===================
select tst.eq((select count(*) from public.project_templates where org_id = tst.id('orgA'))::int, 8, 'org gets 8 service templates');
select tst.ok((select bool_and(n >= 5) from (select count(*) n from public.template_tasks tt join public.project_templates t on t.id = tt.template_id
                where t.org_id = tst.id('orgA') group by t.id) x), 'every template has at least 5 tasks');
select tst.ok(exists (select 1 from public.role_permissions rp join public.roles r on r.id = rp.role_id
  where r.org_id = tst.id('orgA') and r.key = 'project_manager' and rp.permission_key = 'timesheets.approve'), 'PM role gets Phase 4 permissions');
select tst.ok(exists (select 1 from public.role_permissions rp join public.roles r on r.id = rp.role_id
  where r.org_id = tst.id('orgA') and r.key = 'super_admin' and rp.permission_key = 'campaigns.manage'), 'Super Admin gets Phase 4 permissions');

-- backfill for organizations that existed before this release is idempotent
delete from public.role_permissions where permission_key = 'content.manage'
  and role_id = (select id from public.roles where org_id = tst.id('orgA') and key = 'project_manager');
select app.seed_phase4_defaults(tst.id('orgA'));
select tst.ok(exists (select 1 from public.role_permissions rp join public.roles r on r.id = rp.role_id
  where r.org_id = tst.id('orgA') and r.key = 'project_manager' and rp.permission_key = 'content.manage'), 'backfill restores missing permissions');
select tst.eq((select count(*) from public.project_templates where org_id = tst.id('orgA'))::int, 8, 'backfill does not duplicate templates');

select tst.login('pm@a.test'); set role authenticated;
select tst.put('tpl_seo', (select id from public.project_templates where name = 'SEO Monthly Retainer'));
select tst.put('proj_tpl', public.create_project_from_template(tst.id('tpl_seo'), 'Maahaul SEO November', tst.id('client1'), '2026-11-01', true));
select tst.eq((select count(*) from public.tasks where project_id = tst.id('proj_tpl'))::int, 6, 'project from template gets template tasks');
select tst.eq((select due_date from public.projects where id = tst.id('proj_tpl')), '2026-12-01'::date, 'project due date from template duration');
select tst.eq((select due_date from public.tasks where project_id = tst.id('proj_tpl') and title = 'Monthly SEO report'), '2026-12-01'::date,
  'task dates offset from project start');
select tst.eq((select owner_id from public.projects where id = tst.id('proj_tpl')), tst.id('pm@a.test'), 'creator owns templated project');
insert into public.project_templates(org_id, name, service) values (tst.id('orgA'), 'PM custom template', 'other');
select tst.lives($$insert into public.template_tasks(template_id, org_id, title) select id, tst.id('orgA'), 'Kickoff call' from public.project_templates where name = 'PM custom template'$$,
  'PM can build custom templates');
reset role;

select tst.login('des@a.test'); set role authenticated;
select tst.ok((select count(*) from public.project_templates) = 9, 'staff can read templates');
select tst.throws($$insert into public.project_templates(org_id, name) values (tst.id('orgA'), 'Designer template')$$,
  'designer cannot create templates', '42501');
select tst.throws($$select public.create_project_from_template(tst.id('tpl_seo'), 'Sneaky project')$$,
  'designer cannot create projects via template', '42501');
reset role;
select tst.login('owner@b.test'); set role authenticated;
select tst.eq((select count(*) from public.project_templates where org_id = tst.id('orgA'))::int, 0, 'other org cannot see templates');
select tst.throws($$select public.create_project_from_template(tst.id('tpl_seo'), 'Cross org')$$, 'other org cannot use template', 'P0002');
reset role;
select tst.login('cli@maahaul.test'); set role authenticated;
select tst.eq((select count(*) from public.project_templates)::int, 0, 'client users cannot see templates');
reset role;

-- =================== RECURRING TASKS ===================
select tst.login('pm@a.test'); set role authenticated;
insert into public.recurring_task_rules(org_id, project_id, title, frequency, weekday, due_after_days, assignee_id, start_date, created_by, estimated_minutes)
values (tst.id('orgA'), tst.id('proj_tpl'), 'Weekly GBP post', 'weekly', 3, 2, tst.id('des@a.test'), '2026-11-01', auth.uid(), 60);
insert into public.recurring_task_rules(org_id, project_id, title, frequency, day_of_month, start_date, created_by)
values (tst.id('orgA'), tst.id('proj_tpl'), 'Monthly ranking report', 'monthly', 5, '2026-11-01', auth.uid());
insert into public.recurring_task_rules(org_id, project_id, title, frequency, weekday, start_date, end_date, created_by)
values (tst.id('orgA'), tst.id('proj_tpl'), 'Ended rule', 'weekly', 3, '2026-11-01', '2026-11-02', auth.uid()),
       (tst.id('orgA'), tst.id('proj_tpl'), 'Paused rule', 'weekly', 3, '2026-11-01', null, auth.uid());
update public.recurring_task_rules set is_active = false where title = 'Paused rule';
select tst.throws($$insert into public.recurring_task_rules(org_id, project_id, title, frequency, weekday, assignee_id, created_by)
  values (tst.id('orgA'), tst.id('proj_tpl'), 'Client assignee', 'weekly', 1, tst.id('cli@maahaul.test'), auth.uid())$$,
  'recurring rule cannot assign a client user', '23514');
select tst.throws($$insert into public.recurring_task_rules(org_id, project_id, title, frequency, weekday, day_of_month, created_by)
  values (tst.id('orgA'), tst.id('proj_tpl'), 'Bad schedule', 'weekly', 1, 3, auth.uid())$$, 'weekly rule needs only a weekday', '23514');
select tst.throws($$select public.generate_recurring_tasks('2026-11-04')$$, 'users cannot run the recurring job', '42501');
reset role;
select tst.login('des@a.test'); set role authenticated;
select tst.throws($$insert into public.recurring_task_rules(org_id, project_id, title, frequency, weekday, created_by)
  values (tst.id('orgA'), tst.id('proj1'), 'Designer rule', 'weekly', 1, auth.uid())$$, 'non-manager cannot create recurring rules', '42501');
reset role;

-- job runs as the scheduler (no user)
select set_config('request.jwt.claims', '{}', false);
select tst.eq(public.generate_recurring_tasks('2026-11-03'), 0, 'nothing generated before the weekday arrives');
select tst.eq(public.generate_recurring_tasks('2026-11-04'), 1, 'weekly task generated on its day');
select tst.eq(public.generate_recurring_tasks('2026-11-04'), 0, 'running again the same day is idempotent');
select tst.eq(public.generate_recurring_tasks('2026-11-06'), 1, 'monthly task caught up later in its month');
select tst.eq(public.generate_recurring_tasks('2026-11-07'), 0, 'nothing new later in the same week/month');
select tst.eq(public.generate_recurring_tasks('2026-11-11'), 1, 'next week generates the next occurrence');
select tst.eq((select count(*) from public.tasks where title like 'Weekly GBP post%')::int, 2, 'exactly one weekly task per week');
select tst.eq((select count(*) from public.tasks where title like 'Ended rule%' or title like 'Paused rule%')::int, 0, 'ended and paused rules generate nothing');
select tst.eq((select due_date from public.tasks where title = 'Weekly GBP post (04 Nov)'), '2026-11-06'::date, 'due date = occurrence + due_after_days');
select tst.ok(exists (select 1 from public.task_assignees ta join public.tasks t on t.id = ta.task_id
  where t.title = 'Weekly GBP post (04 Nov)' and ta.profile_id = tst.id('des@a.test')), 'generated task assigned');
select tst.ok(exists (select 1 from public.notifications where recipient_id = tst.id('des@a.test') and type = 'task_assigned'
  and title like '%Weekly GBP post%'), 'assignee notified of generated task');
select tst.eq((select count(*) from public.recurring_task_runs)::int, 3, 'one run row per rule per period');

-- =================== TIME TRACKING ===================
select tst.login('des@a.test'); set role authenticated;
select tst.lives($$select public.start_timer(tst.id('t2'), 'Audit crawl')$$, 'designer starts a timer');
select tst.lives($$select public.start_timer(tst.id('t2'))$$, 'starting another timer stops the first');
select tst.eq((select count(*) from public.time_entries where profile_id = auth.uid() and ended_at is null and source = 'timer')::int, 1,
  'only one running timer per person');
select tst.ok((select bool_and(minutes >= 1) from public.time_entries where profile_id = auth.uid() and ended_at is not null), 'stopped timer has minutes');
select tst.throws($$insert into public.time_entries(org_id, profile_id, task_id, project_id, entry_date, started_at, source)
  values (tst.id('orgA'), auth.uid(), tst.id('t2'), tst.id('proj1'), current_date, now() - interval '5 hours', 'timer')$$,
  'cannot insert a fake timer row', '42501');
select tst.throws($$update public.time_entries set minutes = 600 where source = 'timer' and profile_id = auth.uid() and ended_at is not null$$,
  'cannot edit timer minutes', '42501');
select public.stop_timer();
update public.tasks set estimated_minutes = 240 where id = tst.id('t2');
insert into public.time_entries(org_id, profile_id, task_id, project_id, entry_date, minutes, note)
values (tst.id('orgA'), auth.uid(), tst.id('t2'), tst.id('proj1'), app.org_today(tst.id('orgA')), 90, 'Manual audit work');
select tst.throws($$insert into public.time_entries(org_id, profile_id, task_id, project_id, entry_date, minutes)
  values (tst.id('orgA'), auth.uid(), tst.id('t2'), tst.id('proj1'), app.org_today(tst.id('orgA')) + 1, 30)$$, 'no time on future dates', '22023');
select tst.throws($$insert into public.time_entries(org_id, profile_id, task_id, project_id, entry_date, minutes)
  values (tst.id('orgA'), auth.uid(), tst.id('t2'), tst.id('proj1'), app.org_today(tst.id('orgA')), 1400)$$, 'no more than 24h per day', '22023');
select tst.throws($$insert into public.time_entries(org_id, profile_id, task_id, project_id, entry_date, minutes)
  values (tst.id('orgA'), tst.id('seo@a.test'), tst.id('t2'), tst.id('proj1'), app.org_today(tst.id('orgA')), 30)$$,
  'cannot log time for someone else', '42501');
select tst.eq((select logged_minutes >= 92 from public.task_time_summary(tst.id('t2'))), true, 'task summary shows logged time');
select tst.eq((select estimated_minutes from public.task_time_summary(tst.id('t2'))), 240, 'task summary shows estimate');
reset role;

select tst.login('seo@a.test'); set role authenticated;
select tst.eq((select count(*) from public.time_entries where profile_id = tst.id('des@a.test'))::int, 0, 'colleagues cannot see each other''s time');
select tst.throws($$select public.start_timer(tst.id('t2'))$$, 'cannot track time on a task you cannot see', '42501');
reset role;
select tst.login('cli@maahaul.test'); set role authenticated;
select tst.throws($$select public.start_timer(tst.id('t1'))$$, 'client users cannot track time', '42501');
select tst.eq((select count(*) from public.time_entries)::int, 0, 'client users see no time entries');
select tst.eq((select count(*) from public.task_time_summary(tst.id('t1')))::int, 0, 'client users get no time summary');
reset role;
select tst.login('pm@a.test'); set role authenticated;
select tst.ok((select count(*) >= 3 from public.time_entries where profile_id = tst.id('des@a.test')), 'PM sees team time');
reset role;

-- timesheet workflow
select tst.login('des@a.test'); set role authenticated;
select tst.put('ts1', (select id from public.submit_timesheet(app.org_today(tst.id('orgA')))));
select tst.eq((select status::text from public.timesheets where id = tst.id('ts1')), 'submitted', 'timesheet submitted');
select tst.ok((select total_minutes >= 92 from public.timesheets where id = tst.id('ts1')), 'timesheet total computed');
select tst.throws($$update public.time_entries set note = 'edit after submit' where profile_id = auth.uid()$$, 'submitted time is locked', '42501');
select tst.throws($$insert into public.time_entries(org_id, profile_id, task_id, project_id, entry_date, minutes)
  values (tst.id('orgA'), auth.uid(), tst.id('t2'), tst.id('proj1'), app.org_today(tst.id('orgA')), 15)$$, 'no new time in a submitted week', '42501');
select tst.throws($$select public.start_timer(tst.id('t2'))$$, 'no timer in a submitted week', '42501');
select tst.throws($$select public.submit_timesheet(app.org_today(tst.id('orgA')))$$, 'cannot submit twice', '22023');
select tst.throws($$select public.decide_timesheet(tst.id('ts1'), true)$$, 'cannot approve own timesheet', '42501');
reset role;
select tst.ok(exists (select 1 from public.notifications where recipient_id = tst.id('pm@a.test') and type = 'timesheet_submitted'),
  'reporting manager notified of timesheet');
select tst.login('seo@a.test'); set role authenticated;
select tst.throws($$select public.decide_timesheet(tst.id('ts1'), true)$$, 'unrelated staff cannot approve', '42501');
reset role;
select tst.login('pm@a.test'); set role authenticated;
select tst.throws($$select public.decide_timesheet(tst.id('ts1'), false)$$, 'rejection needs a reason', '22023');
select public.decide_timesheet(tst.id('ts1'), false, 'Add notes to the audit entries');
reset role;
select tst.login('des@a.test'); set role authenticated;
select tst.lives($$update public.time_entries set note = 'Crawl + report' where profile_id = auth.uid() and source = 'manual'$$,
  'rejected timesheet unlocks time');
select public.submit_timesheet(app.org_today(tst.id('orgA')));
reset role;
select tst.login('pm@a.test'); set role authenticated;
select public.decide_timesheet(tst.id('ts1'), true);
select tst.eq((select status::text from public.timesheets where id = tst.id('ts1')), 'approved', 'manager approves resubmitted timesheet');
select tst.throws($$select public.decide_timesheet(tst.id('ts1'), true)$$, 'cannot decide twice', '22023');
reset role;
select tst.ok(exists (select 1 from public.notifications where recipient_id = tst.id('des@a.test') and type = 'timesheet_decided'
  and title like 'Timesheet approved%'), 'employee notified of approval');
select tst.login('des@a.test'); set role authenticated;
select tst.throws($$delete from public.time_entries where profile_id = auth.uid()$$, 'approved time cannot be deleted', '42501');
reset role;

-- =================== CONTENT CALENDAR ===================
select tst.login('pm@a.test'); set role authenticated;
insert into public.content_items(org_id, client_id, project_id, title, platform, content_type, caption, created_by)
values (tst.id('orgA'), tst.id('client1'), tst.id('proj_tpl'), 'Diwali offer reel', 'instagram', 'reel', 'Celebrate with Maahaul', auth.uid()),
       (tst.id('orgA'), tst.id('client1'), null, 'Unapproved post', 'facebook', 'post', 'Draft', auth.uid());
select tst.put('c1', (select id from public.content_items where title = 'Diwali offer reel'));
select tst.put('c2', (select id from public.content_items where title = 'Unapproved post'));
update public.content_items set assignee_id = tst.id('des@a.test') where id = tst.id('c1');
select tst.throws($$update public.content_items set status = 'scheduled', scheduled_at = now() + interval '2 days' where id = tst.id('c2')$$,
  'cannot schedule before approval', '22023');
select tst.throws($$insert into public.content_items(org_id, client_id, project_id, title, platform, created_by)
  values (tst.id('orgA'), tst.id('client2'), tst.id('proj_tpl'), 'Wrong client project', 'blog', auth.uid())$$,
  'content project must match client', '23514');
reset role;

select tst.login('cli@maahaul.test'); set role authenticated;
select tst.eq((select count(*) from public.content_items)::int, 0, 'client cannot see drafts');
reset role;
select tst.login('seo@a.test'); set role authenticated;
select tst.eq((select count(*) from public.content_items where id = tst.id('c1'))::int, 0, 'unrelated staff cannot see client content');
reset role;
select tst.login('des@a.test'); set role authenticated;
select tst.eq((select count(*) from public.content_items where id = tst.id('c1'))::int, 1, 'assignee sees content');
select tst.throws($$update public.content_items set status = 'approved' where id = tst.id('c1')$$, 'assignee cannot approve for the client', '42501');
update public.content_items set status = 'client_review', scheduled_at = '2026-11-08 18:30+05:30',
  creative_url = 'https://drive.example/reel.mp4' where id = tst.id('c1');
reset role;
select tst.ok(exists (select 1 from public.notifications where recipient_id = tst.id('cli@maahaul.test') and type = 'content_review'),
  'client notified when content needs review');

select tst.login('cli@maahaul.test'); set role authenticated;
select tst.eq((select count(*) from public.content_items)::int, 1, 'client sees only content in review');
update public.content_items set caption = 'client edit';
select tst.ok((select caption <> 'client edit' from public.content_items where id = tst.id('c1')), 'client cannot edit content directly');
select tst.throws($$select public.review_content(tst.id('c1'), false)$$, 'change request needs feedback', '22023');
select public.review_content(tst.id('c1'), false, 'Use the new logo please');
select tst.eq((select status::text from public.content_items where id = tst.id('c1')), 'changes_requested', 'client requests changes');
select tst.throws($$select public.review_content(tst.id('c1'), true)$$, 'cannot review twice', '22023');
select tst.throws($$select public.review_content(tst.id('c2'), true)$$, 'cannot review a draft', 'P0002');
reset role;
select tst.ok(exists (select 1 from public.notifications where recipient_id = tst.id('des@a.test') and type = 'content_reviewed'
  and body = 'Use the new logo please'), 'assignee gets client feedback');

select tst.login('des@a.test'); set role authenticated;
select tst.throws($$update public.content_items set client_feedback = 'all good' where id = tst.id('c1')$$, 'staff cannot fake client feedback', '42501');
update public.content_items set status = 'in_progress' where id = tst.id('c1');
update public.content_items set status = 'client_review', caption = 'Celebrate with Maahaul - new logo' where id = tst.id('c1');
reset role;
select tst.login('cli@maahaul.test'); set role authenticated;
select public.review_content(tst.id('c1'), true);
reset role;
select tst.login('des@a.test'); set role authenticated;
select tst.eq((select status::text from public.content_items where id = tst.id('c1')), 'approved', 'client approves');
select tst.eq((select reviewed_by from public.content_items where id = tst.id('c1')), tst.id('cli@maahaul.test'), 'approval records the client');
select tst.throws($$update public.content_items set caption = 'sneaky change' where id = tst.id('c1')$$, 'approved content is locked', '22023');
select tst.lives($$update public.content_items set status = 'scheduled' where id = tst.id('c1')$$, 'approved content can be scheduled');
update public.content_items set status = 'published', published_url = 'https://instagram.example/p/1' where id = tst.id('c1');
select tst.ok((select published_at is not null from public.content_items where id = tst.id('c1')), 'publish time recorded');
reset role;
select tst.login('owner@b.test'); set role authenticated;
select tst.eq((select count(*) from public.content_items)::int, 0, 'other org cannot see content');
reset role;

-- =================== CAMPAIGNS ===================
select tst.login('pm@a.test'); set role authenticated;
select tst.put('imp1', (select id from public.import_campaign_metrics(tst.id('client1'), 'google_ads', 'oct.csv', repeat('a', 64),
  '[{"campaign":"Brand Search","campaign_id":"111","date":"2026-10-01","impressions":1000,"clicks":100,"spend":2500,"conversions":10,"conversion_value":50000},
    {"campaign":"Brand Search","campaign_id":"111","date":"2026-10-02","impressions":1000,"clicks":50,"spend":1500,"conversions":5,"conversion_value":20000},
    {"campaign":"Generic Search","date":"2026-10-01","impressions":500,"clicks":10,"spend":1000,"conversions":0,"conversion_value":0}]'::jsonb)));
select tst.eq((select rows_inserted from public.campaign_imports where id = tst.id('imp1')), 3, 'import inserts rows');
select tst.eq((select campaigns_created from public.campaign_imports where id = tst.id('imp1')), 2, 'import creates missing campaigns');
select tst.throws($$select public.import_campaign_metrics(tst.id('client1'), 'google_ads', 'oct-copy.csv', repeat('a', 64),
  '[{"campaign":"Brand Search","date":"2026-10-03","impressions":1,"clicks":1,"spend":1}]'::jsonb)$$, 'same file cannot be imported twice', '23505');
select tst.put('imp2', (select id from public.import_campaign_metrics(tst.id('client1'), 'google_ads', 'oct-v2.csv', repeat('b', 64),
  '[{"campaign":"Brand Search","campaign_id":"111","date":"2026-10-02","impressions":9999,"clicks":1,"spend":1},
    {"campaign":"Brand Search","campaign_id":"111","date":"2026-10-03","impressions":800,"clicks":40,"spend":1000,"conversions":4}]'::jsonb, 'skip')));
select tst.eq((select rows_skipped || '/' || rows_inserted from public.campaign_imports where id = tst.id('imp2')), '1/1', 'skip mode keeps existing days');
select tst.eq((select impressions from public.campaign_metrics_daily m join public.campaigns c on c.id = m.campaign_id
  where c.external_id = '111' and metric_date = '2026-10-02'), 1000::bigint, 'skipped day unchanged');
select public.import_campaign_metrics(tst.id('client1'), 'google_ads', 'oct-fix.csv', repeat('c', 64),
  '[{"campaign":"Brand Search","campaign_id":"111","date":"2026-10-02","impressions":1200,"clicks":60,"spend":1800,"conversions":6,"conversion_value":24000}]'::jsonb, 'overwrite');
select tst.eq((select spend from public.campaign_metrics_daily m join public.campaigns c on c.id = m.campaign_id
  where c.external_id = '111' and metric_date = '2026-10-02'), 1800.00::numeric, 'overwrite mode replaces the day');
select tst.eq((select count(*) from public.campaign_metrics_daily m join public.campaigns c on c.id = m.campaign_id where c.external_id = '111')::int, 3,
  'never duplicate days for a campaign');
select tst.throws($$select public.import_campaign_metrics(tst.id('client1'), 'google_ads', 'bad.csv', repeat('d', 64),
  '[{"campaign":"Brand Search","date":"2026-10-04","impressions":10,"clicks":1,"spend":5},
    {"campaign":"Brand Search","date":"2099-01-01","impressions":10,"clicks":1,"spend":5}]'::jsonb)$$, 'future dates rejected', 'future');
select tst.eq((select count(*) from public.campaign_imports where file_sha256 = repeat('d', 64))::int, 0, 'failed import saves nothing');
select tst.throws($$select public.import_campaign_metrics(tst.id('client1'), 'google_ads', 'neg.csv', repeat('e', 64),
  '[{"campaign":"Brand Search","date":"2026-10-05","impressions":10,"clicks":1,"spend":-5}]'::jsonb)$$, 'negative spend rejected', '22023');
select tst.throws($$select public.import_campaign_metrics(tst.id('client1'), 'google_ads', 'ctr.csv', repeat('f', 64),
  '[{"campaign":"Brand Search","date":"2026-10-05","impressions":10,"clicks":50,"spend":5}]'::jsonb)$$, 'clicks above impressions rejected', '22023');
select tst.throws($$select public.import_campaign_metrics(tst.id('client2'), 'google_ads', 'x.csv', repeat('9', 64),
  '[{"campaign":"Other","campaign_id":"111","date":"2026-10-05","impressions":10,"clicks":1,"spend":5}]'::jsonb)$$,
  'campaign ID of another client rejected', '23514');
select tst.eq((select spend from public.campaign_summary where name = 'Brand Search'), 5300.00::numeric, 'summary spend');
select tst.eq((select cpc from public.campaign_summary where name = 'Brand Search'), 26.50::numeric, 'summary CPC');
select tst.eq((select ctr_pct from public.campaign_summary where name = 'Brand Search'), 6.67::numeric, 'summary CTR');
select tst.eq((select roas from public.campaign_summary where name = 'Brand Search'), 13.96::numeric, 'summary ROAS');
reset role;

select tst.login('des@a.test'); set role authenticated;
select tst.throws($$select public.import_campaign_metrics(tst.id('client1'), 'meta_ads', 'm.csv', repeat('1', 64),
  '[{"campaign":"X","date":"2026-10-01","impressions":1,"clicks":1,"spend":1}]'::jsonb)$$, 'designer cannot import', '42501');
select tst.eq((select count(*) from public.campaigns)::int, 0, 'designer cannot see campaigns');
reset role;
select tst.login('cli@maahaul.test'); set role authenticated;
select tst.eq((select count(*) from public.campaign_summary)::int, 2, 'client sees own campaigns');
select tst.eq((select spend from public.campaign_summary where name = 'Brand Search'), 5300.00::numeric, 'client sees own ad spend');
select tst.eq((select count(*) from public.campaign_imports)::int, 0, 'client cannot see import history');
select tst.throws($$insert into public.campaign_metrics_daily(campaign_id, metric_date, org_id, spend)
  select campaign_id, '2026-10-09', tst.id('orgA'), 1 from public.campaign_summary limit 1$$, 'client cannot write metrics', '42501');
select tst.eq((select count(*) from public.contracts)::int, 0, 'client still cannot see management fees');
reset role;
select tst.login('owner@b.test'); set role authenticated;
select tst.eq((select count(*) from public.campaign_summary)::int, 0, 'other org cannot see campaigns');
reset role;
