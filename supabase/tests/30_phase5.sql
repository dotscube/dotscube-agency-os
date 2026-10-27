-- =====================================================================
-- Phase 5 tests: e-mail outbox, GST invoices & payments, payroll,
-- recruitment. Runs after 10_ and 20_ and reuses their fixtures.
-- =====================================================================
\set ON_ERROR_STOP 1
\o /dev/null

-- =================== DEFAULTS ===================
select tst.ok(exists (select 1 from public.role_permissions rp join public.roles r on r.id = rp.role_id
  where r.org_id = tst.id('orgA') and r.key = 'accounts_manager' and rp.permission_key = 'invoices.manage'), 'Accounts gets invoices.manage');
select tst.ok(exists (select 1 from public.role_permissions rp join public.roles r on r.id = rp.role_id
  where r.org_id = tst.id('orgA') and r.key = 'hr_manager' and rp.permission_key = 'payroll.run'), 'HR gets payroll.run');
select tst.ok(exists (select 1 from public.role_permissions rp join public.roles r on r.id = rp.role_id
  where r.org_id = tst.id('orgA') and r.key = 'super_admin' and rp.permission_key = 'recruitment.manage'), 'Super Admin gets Phase 5 permissions');
select tst.ok(not exists (select 1 from public.role_permissions rp join public.roles r on r.id = rp.role_id
  where r.org_id = tst.id('orgA') and r.key = 'project_manager' and rp.permission_key like 'invoices.%'), 'PM gets no invoice permissions');
select tst.ok((select bool_and(is_sensitive) from public.permissions where key in ('invoices.view','invoices.manage','payroll.view','payroll.run')),
  'finance and payroll permissions are sensitive');
select tst.ok(exists (select 1 from public.email_settings where org_id = tst.id('orgA') and not enabled), 'org has e-mail settings, off by default');
select tst.ok(exists (select 1 from public.billing_settings where org_id = tst.id('orgA')), 'org has billing settings');
delete from public.role_permissions where permission_key = 'payroll.view'
  and role_id = (select id from public.roles where org_id = tst.id('orgA') and key = 'accounts_manager');
select app.seed_phase5_defaults(tst.id('orgA'));
select tst.ok(exists (select 1 from public.role_permissions rp join public.roles r on r.id = rp.role_id
  where r.org_id = tst.id('orgA') and r.key = 'accounts_manager' and rp.permission_key = 'payroll.view'), 'backfill restores missing Phase 5 permissions');

-- =================== E-MAIL OUTBOX ===================
select tst.eq((select count(*) from public.email_outbox)::int, 0, 'nothing is queued while e-mail is off');
select tst.login('des@a.test'); set role authenticated;
select tst.eq((select count(*) from public.email_settings)::int, 0, 'staff cannot read e-mail settings');
update public.email_settings set enabled = true;
select tst.throws($$select public.send_test_email()$$, 'staff cannot send test e-mails', '42501');
select tst.throws($$select * from public.claim_emails(5)$$, 'users cannot claim the e-mail queue', '42501');
reset role;
select tst.ok((select not enabled from public.email_settings where org_id = tst.id('orgA')), 'staff update of e-mail settings had no effect');

select tst.login('owner@a.test'); set role authenticated;
update public.email_settings set enabled = true, app_url = 'https://app.dotscube.test' where org_id = tst.id('orgA');
select tst.ok((select enabled from public.email_settings where org_id = tst.id('orgA')), 'admin turns e-mail on');
select tst.throws($$update public.email_settings set app_url = 'javascript:alert(1)' where org_id = tst.id('orgA')$$, 'app URL must be http(s)', '23514');
select tst.ok(public.send_test_email(), 'admin queues a test e-mail');
select tst.ok((public.email_queue_stats()->>'queued')::int >= 1, 'queue stats visible to admin');
reset role;

select app.notify(tst.id('des@a.test'), 'task_assigned', 'New task assigned: Banner set', 'Due 01 Nov 2026', '/tasks/' || tst.id('t2'), 'task', tst.id('t2'), 'p5-test-1');
select tst.put('mail1', (select id from public.email_outbox where to_email = 'des@a.test' and category = 'notification'));
select tst.ok(tst.id('mail1') is not null, 'notification is e-mailed when e-mail is on');
select tst.ok((select body_text like '%https://app.dotscube.test/tasks/%' from public.email_outbox where id = tst.id('mail1')), 'e-mail links into the app');
insert into public.notification_preferences(profile_id, type, in_app, email) values (tst.id('seo@a.test'), 'task_assigned', true, false);
select app.notify(tst.id('seo@a.test'), 'task_assigned', 'New task assigned: Audit', null, '/tasks/x', 'task', null, 'p5-test-2');
select tst.ok(exists (select 1 from public.notifications where dedupe_key = 'p5-test-2'), 'in-app notification still created');
select tst.eq((select count(*) from public.email_outbox where to_email = 'seo@a.test')::int, 0, 'e-mail opt-out respected');

select set_config('request.jwt.claims', '{}', false);
select tst.ok((select count(*) >= 2 from public.claim_emails(50)), 'worker claims queued e-mails');
select tst.eq((select count(*) from public.claim_emails(50))::int, 0, 'claimed e-mails are not handed out twice');
select public.complete_email(tst.id('mail1'), true, null, 'resend-123');
select tst.eq((select status from public.email_outbox where id = tst.id('mail1')), 'sent', 'sent e-mail marked sent');
select tst.ok((select emailed_at is not null from public.notifications where dedupe_key = 'p5-test-1'), 'notification marked as e-mailed');
select public.complete_email((select id from public.email_outbox where category = 'test'), false, 'Domain not verified');
select tst.ok((select status = 'queued' and scheduled_at > now() and last_error is not null from public.email_outbox where category = 'test'),
  'failed e-mail retried later with the error kept');

-- =================== BILLING SETTINGS & INVOICES ===================
select tst.login('acc@a.test'); set role authenticated;
update public.billing_settings set gstin = '08aaacd1234f1z2', legal_name = 'Dotscube Digital Pvt Ltd', bank_details = 'HDFC 0000 IFSC HDFC0000001'
 where org_id = tst.id('orgA');
select tst.eq((select state_code::text from public.billing_settings where org_id = tst.id('orgA')), '08', 'seller state taken from GSTIN');
select tst.throws($$update public.billing_settings set gstin = 'BAD' where org_id = tst.id('orgA')$$, 'GSTIN format checked', '23514');
reset role;
select tst.eq((select state_code::text from public.client_billing where client_id = tst.id('client1')), '08', 'client state taken from GSTIN');
-- client2 is in another state (Maharashtra) -> IGST
insert into public.client_billing(client_id, org_id, billing_email, billing_name, state_code) values
  (tst.id('client2'), tst.id('orgA'), 'accounts@second.test', 'Second Client LLP', '27');
-- known ad spend for September (client1)
insert into public.campaigns(org_id, client_id, platform, name) values (tst.id('orgA'), tst.id('client1'), 'other', 'P5 Sept test');
insert into public.campaign_metrics_daily(campaign_id, metric_date, org_id, impressions, clicks, spend)
select id, '2026-09-10', org_id, 1000, 50, 10000 from public.campaigns where name = 'P5 Sept test';
select tst.put('contract1', (select id from public.contracts where client_id = tst.id('client1') and title = 'SEO retainer'));

select tst.login('acc@a.test'); set role authenticated;
select tst.put('inv1', public.create_invoice_from_contract(tst.id('contract1'), '2026-09', true));
select tst.eq((select status::text from public.invoices where id = tst.id('inv1')), 'draft', 'contract invoice starts as draft');
select tst.eq((select fee_subtotal from public.invoices where id = tst.id('inv1')), 25000.00, 'management fee line from contract');
select tst.eq((select unit_price from public.invoice_items where invoice_id = tst.id('inv1') and description like 'Ad spend — Other platforms%'), 10000.00,
  'ad spend line from imported campaign data');
select tst.eq((select gst_rate from public.invoice_items where invoice_id = tst.id('inv1') and kind = 'ad_spend' limit 1), 0.00, 'ad spend defaults to 0% GST');
select tst.eq((select ad_spend_subtotal >= 10000 from public.invoices where id = tst.id('inv1')), true, 'ad spend kept in its own subtotal');
select tst.eq((select tax_mode from public.invoices where id = tst.id('inv1')), 'intra', 'same state -> CGST + SGST');
select tst.eq((select (cgst, sgst, igst)::text from public.invoices where id = tst.id('inv1')), '(2250.00,2250.00,0.00)', '9% + 9% on the fee only');
select tst.eq((select total = round(taxable_total + cgst + sgst) from public.invoices where id = tst.id('inv1')), true, 'total rounded to the rupee');
select tst.throws($$select public.create_invoice_from_contract(tst.id('contract1'), '2026-09')$$, 'one invoice per contract per month', '23505');
select tst.throws($$select public.create_invoice_from_contract(tst.id('contract1'), '2026-13')$$, 'period format checked', '22023');
insert into public.invoice_items(org_id, invoice_id, kind, description, quantity, unit_price, gst_rate)
values (tst.id('orgA'), tst.id('inv1'), 'other', 'Landing page design', 1, 5000, 18);
select tst.eq((select other_subtotal from public.invoices where id = tst.id('inv1')), 5000.00, 'draft lines can be added');
select tst.eq((select cgst from public.invoices where id = tst.id('inv1')), 2700.00, 'totals recalculated on every line change');
delete from public.invoice_items where invoice_id = tst.id('inv1') and description = 'Landing page design';
select tst.eq((select cgst from public.invoices where id = tst.id('inv1')), 2250.00, 'totals recalculated after removing a line');
select tst.throws($$insert into public.invoice_items(org_id, invoice_id, description, unit_price, gst_rate) values (tst.id('orgA'), tst.id('inv1'), 'Odd rate', 100, 7)$$,
  'only valid GST rates', '23514');
select tst.throws($$update public.invoices set total = 1, status = 'paid' where id = tst.id('inv1')$$, 'status and totals are not directly writable', '42501');
reset role;

select tst.login('acc@a.test'); set role authenticated;
select tst.put('inv1', (select id from public.issue_invoice(tst.id('inv1'))));
select tst.eq((select invoice_number from public.invoices where id = tst.id('inv1')),
  'INV/' || app.fiscal_year(app.org_today(tst.id('orgA'))) || '/0001', 'number assigned on issue, per financial year');
select tst.eq((select due_date - issue_date from public.invoices where id = tst.id('inv1')), 15, 'due date from client payment terms');
select tst.eq((select seller->>'gstin' from public.invoices where id = tst.id('inv1')), '08AAACD1234F1Z2', 'seller details snapshotted');
select tst.eq((select buyer->>'gstin' from public.invoices where id = tst.id('inv1')), '08ABCDE1234F1Z5', 'buyer details snapshotted');
select tst.throws($$insert into public.invoice_items(org_id, invoice_id, description, unit_price) values (tst.id('orgA'), tst.id('inv1'), 'Late add', 100)$$,
  'issued invoice lines are locked', '42501');
update public.invoices set notes = 'changed after issue' where id = tst.id('inv1');
select tst.ok((select notes is null from public.invoices where id = tst.id('inv1')), 'issued invoice cannot be edited');
delete from public.invoices where id = tst.id('inv1');
select tst.ok(exists (select 1 from public.invoices where id = tst.id('inv1')), 'issued invoice cannot be deleted');
select tst.throws($$select public.issue_invoice(tst.id('inv1'))$$, 'cannot issue twice', '22023');

-- inter-state invoice -> IGST
insert into public.invoices(org_id, client_id, notes) values (tst.id('orgA'), tst.id('client2'), 'Website build milestone 1');
select tst.put('inv2', (select id from public.invoices where client_id = tst.id('client2') and status = 'draft'));
select tst.throws($$select public.issue_invoice(tst.id('inv2'))$$, 'empty invoice cannot be issued', '22023');
insert into public.invoice_items(org_id, invoice_id, description, sac, unit_price, gst_rate)
values (tst.id('orgA'), tst.id('inv2'), 'Website development — milestone 1', '998314', 10000, 18);
select tst.eq((select (tax_mode, igst, cgst, total)::text from public.invoices where id = tst.id('inv2')), '(inter,1800.00,0.00,11800.00)', 'different state -> IGST');
select tst.throws($$select public.issue_invoice(tst.id('inv2'), app.org_today(tst.id('orgA')) + 1)$$, 'issue date cannot be in the future', '22023');
select public.issue_invoice(tst.id('inv2'));
select tst.ok((select invoice_number like '%/0002' from public.invoices where id = tst.id('inv2')), 'numbers are consecutive');
select tst.eq((select count(*) from public.email_outbox)::int, 0, 'accounts cannot read the e-mail outbox');
reset role;
select tst.ok(exists (select 1 from public.email_outbox where category = 'invoice' and to_email = 'accounts@second.test'), 'issued invoice e-mailed to client billing e-mail');
select tst.login('acc@a.test'); set role authenticated;

-- cancelled invoices keep their number
insert into public.invoices(org_id, client_id) values (tst.id('orgA'), tst.id('client2'));
select tst.put('inv3', (select id from public.invoices where client_id = tst.id('client2') and status = 'draft'));
insert into public.invoice_items(org_id, invoice_id, description, unit_price) values (tst.id('orgA'), tst.id('inv3'), 'Wrong invoice', 500);
select public.issue_invoice(tst.id('inv3'));
select tst.throws($$select public.cancel_invoice(tst.id('inv3'), 'no')$$, 'cancel needs a reason', '22023');
select public.cancel_invoice(tst.id('inv3'), 'Raised on the wrong client');
select tst.ok((select status = 'cancelled' and invoice_number like '%/0003' from public.invoices where id = tst.id('inv3')), 'cancelled invoice keeps its number');
insert into public.invoices(org_id, client_id) values (tst.id('orgA'), tst.id('client2'));
select tst.put('inv4', (select id from public.invoices where client_id = tst.id('client2') and status = 'draft'));
insert into public.invoice_items(org_id, invoice_id, description, unit_price) values (tst.id('orgA'), tst.id('inv4'), 'Correct invoice', 500);
select public.issue_invoice(tst.id('inv4'));
select tst.ok((select invoice_number like '%/0004' from public.invoices where id = tst.id('inv4')), 'numbers are never reused');

-- payments
select tst.put('pay1', (select id from public.record_payment(tst.id('inv1'), 20000, app.org_today(tst.id('orgA')), 'upi', 'UTR001', 2500)));
select tst.eq((select status::text from public.invoices where id = tst.id('inv1')), 'partially_paid', 'part payment -> partially paid');
select tst.eq((select balance from public.invoices where id = tst.id('inv1')), (select total - 22500 from public.invoices where id = tst.id('inv1')),
  'balance = total - received - TDS');
select tst.throws($$select public.record_payment(tst.id('inv1'), 999999, app.org_today(tst.id('orgA')))$$, 'cannot record more than the balance', '22023');
select tst.throws($$select public.record_payment(tst.id('inv1'), 10, app.org_today(tst.id('orgA')), 'upi', 'UTR001')$$, 'duplicate payment reference rejected', '23505');
select tst.throws($$select public.record_payment(tst.id('inv1'), 10, app.org_today(tst.id('orgA')) + 1)$$, 'payment date cannot be in the future', '22023');
select tst.throws($$select public.record_payment(tst.id('inv1'), 0, app.org_today(tst.id('orgA')))$$, 'zero payment rejected', '22023');
select tst.throws($$select public.record_payment(tst.id('inv3'), 10, app.org_today(tst.id('orgA')))$$, 'no payments on cancelled invoices', '22023');
select public.record_payment(tst.id('inv1'), (select balance from public.invoices where id = tst.id('inv1')), app.org_today(tst.id('orgA')), 'bank_transfer', 'NEFT77');
select tst.eq((select (status::text, balance)::text from public.invoices where id = tst.id('inv1')), '(paid,0.00)', 'fully paid -> paid');
select tst.throws($$select public.cancel_invoice(tst.id('inv1'), 'Trying to cancel a paid invoice')$$, 'cannot cancel an invoice with payments', '22023');
select public.delete_payment(tst.id('pay1'));
select tst.eq((select status::text from public.invoices where id = tst.id('inv1')), 'partially_paid', 'removing a payment reopens the balance');
select tst.ok((public.get_finance_summary()->>'outstanding')::numeric =
  (select sum(balance) from public.invoices where status in ('issued','partially_paid')), 'finance summary outstanding');
reset role;

-- who can see what
select tst.login('des@a.test'); set role authenticated;
select tst.eq((select count(*) from public.invoices)::int, 0, 'staff without permission see no invoices');
select tst.eq((select count(*) from public.payments)::int, 0, 'staff without permission see no payments');
select tst.throws($$insert into public.invoices(org_id, client_id) values (tst.id('orgA'), tst.id('client1'))$$, 'staff cannot create invoices', '42501');
select tst.throws($$select public.record_payment(tst.id('inv2'), 10, current_date)$$, 'staff cannot record payments', '42501');
select tst.throws($$select public.issue_invoice(tst.id('inv2'))$$, 'staff cannot issue invoices', '42501');
reset role;
select tst.login('pm@a.test'); set role authenticated;
select tst.eq((select count(*) from public.billing_settings)::int, 0, 'PM cannot see billing settings');
reset role;
select tst.login('cli@maahaul.test'); set role authenticated;
select tst.eq((select count(*) from public.invoices)::int, 1, 'client sees only its own issued invoices');
select tst.ok((select count(*) >= 1 from public.invoice_items where invoice_id = tst.id('inv1')), 'client sees its invoice lines');
select tst.ok((select count(*) >= 1 from public.payments), 'client sees payments on its invoices');
select tst.throws($$select public.record_payment(tst.id('inv1'), 10, current_date)$$, 'client cannot record payments', '42501');
reset role;
select tst.login('acc@a.test'); set role authenticated;
select public.create_invoice_from_contract(tst.id('contract1'), '2026-08');
reset role;
select tst.login('cli@maahaul.test'); set role authenticated;
select tst.eq((select count(*) from public.invoices where status = 'draft')::int, 0, 'client never sees drafts');
reset role;
select tst.login('owner@b.test'); set role authenticated;
select tst.eq((select count(*) from public.invoices)::int, 0, 'other org sees no invoices');
select tst.throws($$select public.issue_invoice(tst.id('inv2'))$$, 'other org cannot touch invoices', 'P0002');
reset role;

-- reminders
select set_config('app.bypass_guards', 'on', false);
update public.invoices set issue_date = app.org_today(org_id) - 30, due_date = app.org_today(org_id) - 7 where id = tst.id('inv2');
select set_config('app.bypass_guards', '', false);
select set_config('request.jwt.claims', '{}', false);
select tst.ok(public.generate_invoice_reminders() >= 1, 'overdue invoice reminder e-mailed to the client');
select tst.ok(exists (select 1 from public.notifications where recipient_id = tst.id('acc@a.test') and type = 'invoice_reminder'
  and title like 'Overdue 7 days%'), 'accounts notified of overdue invoice');
select tst.eq(public.generate_invoice_reminders(), 0, 'reminders are not repeated the same day');
select tst.login('acc@a.test'); set role authenticated;
select tst.throws($$select public.generate_invoice_reminders()$$, 'users cannot run the reminder job', '42501');
select tst.ok((public.get_finance_summary()->>'overdue_count')::int >= 1, 'finance summary counts overdue invoices');
reset role;

-- =================== PAYROLL ===================
-- 2 days of leave without pay for Sana in September (Tue 15, Wed 16)
insert into public.leave_requests(org_id, employee_id, leave_type_id, start_date, end_date, days, status)
select tst.id('orgA'), tst.id('emp_seo'), id, '2026-09-15', '2026-09-16', 2, 'approved' from public.leave_types where org_id = tst.id('orgA') and code = 'LWP';

select tst.login('hr@a.test'); set role authenticated;
insert into public.employee_profiles(org_id, employee_code, full_name, work_email, designation, status, joining_date)
values (tst.id('orgA'), '', 'Mid Month Joiner', 'mid@a.test', 'Intern', 'active', '2026-09-16');
select tst.put('emp_mid', (select id from public.employee_profiles where work_email = 'mid@a.test'));
insert into public.salary_revisions(org_id, employee_id, effective_from, annual_ctc, monthly_components, created_by)
values (tst.id('orgA'), tst.id('emp_mid'), '2026-09-16', 120000, '{"BASIC":10000}', auth.uid());
insert into public.employee_private(employee_id, org_id) values (tst.id('emp_mid'), tst.id('orgA'));
select tst.throws($$update public.employee_private set bank_ifsc = 'BADIFSC' where employee_id = tst.id('emp_mid')$$, 'IFSC format checked', '23514');
update public.employee_private set pan_number = 'ABCDE1234F', bank_name = 'HDFC Bank', bank_account_number = '50100123456789', bank_ifsc = 'HDFC0001234'
 where employee_id = tst.id('emp_mid');

select tst.put('run1', public.create_payroll_run('2026-09-01'));
select tst.throws($$select public.create_payroll_run('2026-09-15')$$, 'one payroll run per month', '23505');
select tst.throws($$select public.create_payroll_run((date_trunc('month', current_date) + interval '2 months')::date)$$, 'no payroll for future months', '22023');
select tst.put('slip_seo', (select id from public.payslips where run_id = tst.id('run1') and employee_id = tst.id('emp_seo')));
select tst.eq((select (days_in_month, payable_days, unpaid_leave_days)::text from public.payslips where id = tst.id('slip_seo')), '(30,28.0,2.0)',
  'leave without pay reduces payable days');
select tst.eq((select (earnings->0->>'amount')::numeric from public.payslips where id = tst.id('slip_seo')), 18667::numeric,
  'Basic prorated 20000 × 28/30, rounded');
select tst.eq((select gross from public.payslips where id = tst.id('slip_seo')), 26134.00, 'gross = sum of prorated components');
select tst.eq((select (payable_days, gross)::text from public.payslips where run_id = tst.id('run1') and employee_id = tst.id('emp_mid')), '(15.0,5000.00)',
  'mid-month joiner paid from joining date');
select tst.eq((select bank->>'ifsc' from public.payslips where run_id = tst.id('run1') and employee_id = tst.id('emp_mid')), 'HDFC0001234',
  'bank details snapshotted for the transfer sheet');
select tst.eq((select gross from public.payslips where run_id = tst.id('run1') and employee_id = tst.id('emp_des')), 15000.00, 'full month paid in full');
select tst.ok((select jsonb_array_length(missing_salary) = 3 and missing_salary @> '[{"name":"Rahul PM"}]' from public.payroll_runs where id = tst.id('run1')),
  'employees without a salary structure listed (and not paid)');
select tst.ok((select employees_count = (select count(*) from public.payslips where run_id = tst.id('run1')) from public.payroll_runs where id = tst.id('run1')),
  'run totals kept in sync');

select public.set_payslip_adjustments(tst.id('slip_seo'), '[{"label":"Performance bonus","kind":"earning","amount":2000},{"label":"Advance recovery","kind":"deduction","amount":500}]');
select tst.eq((select (gross, total_deductions, net_pay)::text from public.payslips where id = tst.id('slip_seo')), '(28134.00,500.00,27634.00)',
  'adjustments added to gross and deductions');
select tst.throws($$select public.set_payslip_adjustments(tst.id('slip_seo'), '[{"label":"x","kind":"earning","amount":10}]')$$, 'adjustment needs a label', '22023');
select tst.throws($$select public.set_payslip_adjustments(tst.id('slip_seo'), '[{"label":"Bonus","kind":"gift","amount":10}]')$$, 'adjustment kind checked', '22023');
select tst.throws($$select public.set_payslip_adjustments(tst.id('slip_seo'), '[{"label":"Bonus","kind":"earning","amount":-10}]')$$, 'adjustment amount must be positive', '22023');
select public.recalculate_payroll_run(tst.id('run1'), true);
select tst.ok((select absent_days > 0 from public.payslips where id = tst.id('slip_seo')), 'optional: days without attendance count as unpaid');
select public.recalculate_payroll_run(tst.id('run1'), false);
select tst.eq((select (net_pay, absent_days)::text from public.payslips where id = tst.id('slip_seo')), '(27634.00,0.0)', 'recalculation keeps adjustments');
reset role;

select tst.login('seo@a.test'); set role authenticated;
select tst.eq((select count(*) from public.payslips)::int, 0, 'employees cannot see a draft payslip');
select tst.throws($$select public.create_payroll_run('2026-08-01')$$, 'staff cannot run payroll', '42501');
reset role;
select tst.login('hr@a.test'); set role authenticated;
select public.finalize_payroll_run(tst.id('run1'));
select tst.throws($$select public.set_payslip_adjustments(tst.id('slip_seo'), '[]')$$, 'finalized payslips are locked', '22023');
reset role;
select tst.ok(exists (select 1 from public.notifications where recipient_id = tst.id('seo@a.test') and type = 'payslip_ready'), 'employee notified when payslip is ready');
select tst.login('seo@a.test'); set role authenticated;
select tst.eq((select count(*) from public.payslips)::int, 1, 'employee sees only their own payslip');
select tst.eq((select count(*) from public.payroll_runs)::int, 0, 'employee cannot see payroll runs');
reset role;
select tst.login('acc@a.test'); set role authenticated;
select tst.ok((select count(*) >= 3 from public.payslips where run_id = tst.id('run1')), 'payroll.view sees all payslips');
select tst.throws($$select public.finalize_payroll_run(tst.id('run1'))$$, 'payroll.view cannot change payroll', '42501');
reset role;
select tst.login('pm@a.test'); set role authenticated;
select tst.eq((select count(*) from public.payslips where employee_id <> tst.id('emp_pm'))::int, 0, 'managers cannot see team payslips');
reset role;
select tst.login('hr@a.test'); set role authenticated;
select public.reopen_payroll_run(tst.id('run1'));
select tst.eq((select status from public.payroll_runs where id = tst.id('run1')), 'draft', 'finalized run can be reopened');
select public.finalize_payroll_run(tst.id('run1'));
select tst.throws($$select public.mark_payroll_paid(tst.id('run1'), current_date + 5)$$, 'paid date cannot be in the future', '22023');
select public.mark_payroll_paid(tst.id('run1'), '2026-10-01');
select tst.eq((select status from public.payroll_runs where id = tst.id('run1')), 'paid', 'run marked paid');
select tst.throws($$select public.reopen_payroll_run(tst.id('run1'))$$, 'paid run cannot be reopened', '22023');
select tst.throws($$select public.delete_payroll_run(tst.id('run1'))$$, 'paid run cannot be deleted', '22023');
select tst.put('run2', public.create_payroll_run('2026-08-01'));
select public.delete_payroll_run(tst.id('run2'));
select tst.eq((select count(*) from public.payroll_runs where id = tst.id('run2'))::int, 0, 'draft run can be deleted');
reset role;
select tst.login('owner@b.test'); set role authenticated;
select tst.eq((select count(*) from public.payslips)::int, 0, 'other org sees no payslips');
reset role;

-- =================== RECRUITMENT ===================
select tst.login('hr@a.test'); set role authenticated;
insert into public.job_openings(org_id, title, hiring_manager_id, positions, salary_min, salary_max, created_by)
values (tst.id('orgA'), 'SEO Executive', tst.id('emp_pm'), 1, 300000, 500000, auth.uid());
select tst.put('job1', (select id from public.job_openings where title = 'SEO Executive'));
select tst.throws($$insert into public.job_openings(org_id, title, salary_min, salary_max) values (tst.id('orgA'), 'Bad range', 5, 1)$$, 'salary range checked', '23514');
insert into public.candidates(org_id, opening_id, full_name, email, source, expected_ctc, stage)
values (tst.id('orgA'), tst.id('job1'), 'Ravi Kumar', 'Ravi@Cand.test', 'linkedin', 450000, 'hired');
select tst.put('cand1', (select id from public.candidates where email = 'ravi@cand.test'));
select tst.eq((select stage from public.candidates where id = tst.id('cand1')), 'applied', 'new candidates start at applied');
select tst.throws($$insert into public.candidates(org_id, opening_id, full_name, email) values (tst.id('orgA'), tst.id('job1'), 'Ravi Again', 'ravi@cand.test')$$,
  'same candidate cannot apply twice to one opening', '23505');
insert into public.candidates(org_id, opening_id, full_name, email) values (tst.id('orgA'), tst.id('job1'), 'Second Person', 'second@cand.test');
select tst.throws($$update public.candidates set stage = 'hired' where id = tst.id('cand1')$$, 'cannot mark hired by hand', '22023');
select tst.throws($$update public.candidates set stage = 'rejected' where email = 'second@cand.test'$$, 'rejection needs a reason', '22023');
update public.candidates set stage = 'rejected', rejection_reason = 'Not enough experience' where email = 'second@cand.test';
select tst.throws($$update public.candidates set resume_path = 'other-org/recruitment/x/cv.pdf' where id = tst.id('cand1')$$, 'resume path must be inside the org', '42501');
insert into public.interviews(org_id, candidate_id, round_name, scheduled_at, interviewer_id)
values (tst.id('orgA'), tst.id('cand1'), 'Technical round', now() - interval '1 day', tst.id('seo@a.test'));
select tst.put('iv1', (select id from public.interviews where candidate_id = tst.id('cand1')));
select tst.eq((select stage from public.candidates where id = tst.id('cand1')), 'interview', 'scheduling an interview moves the candidate on');
select tst.throws($$update public.interviews set rating = 5 where id = tst.id('iv1')$$, 'recruiters cannot write interviewer feedback', '42501');
select tst.throws($$insert into public.interviews(org_id, candidate_id, round_name, scheduled_at, interviewer_id)
  values (tst.id('orgA'), tst.id('cand1'), 'Client round', now(), tst.id('cli@maahaul.test'))$$, 'interviewer must be internal', '23514');
reset role;
select tst.ok(exists (select 1 from public.notifications where recipient_id = tst.id('seo@a.test') and type = 'interview_scheduled'), 'interviewer notified');

select tst.login('seo@a.test'); set role authenticated;
select tst.eq((select count(*) from public.candidates)::int, 1, 'interviewer sees only the candidates they interview');
select tst.eq((select count(*) from public.offers)::int, 0, 'interviewer cannot see offers');
select tst.throws($$insert into public.interviews(org_id, candidate_id, round_name, scheduled_at, interviewer_id)
  values (tst.id('orgA'), tst.id('cand1'), 'Self round', now(), auth.uid())$$, 'interviewer cannot schedule interviews', '42501');
select tst.throws($$select public.submit_interview_feedback(tst.id('iv1'), 4::smallint, 'yes', 'ok')$$, 'feedback needs a sentence', '22023');
select public.submit_interview_feedback(tst.id('iv1'), 4::smallint, 'yes', 'Strong on technical SEO and reporting.');
select tst.eq((select (status, rating)::text from public.interviews where id = tst.id('iv1')), '(completed,4)', 'interviewer submits feedback');
reset role;
select tst.login('des@a.test'); set role authenticated;
select tst.eq((select count(*) from public.candidates)::int, 0, 'other staff see no candidates');
select tst.eq((select count(*) from public.job_openings)::int, 0, 'other staff see no openings');
select tst.throws($$select public.submit_interview_feedback(tst.id('iv1'), 1::smallint, 'no', 'I am not the interviewer here.')$$, 'only the interviewer can give feedback', '42501');
reset role;
select tst.login('pm@a.test'); set role authenticated;
select tst.eq((select count(*) from public.candidates where opening_id = tst.id('job1'))::int, 2, 'hiring manager sees the opening''s candidates');
select tst.eq((select count(*) from public.offers)::int, 0, 'hiring manager cannot see offer CTC');
update public.candidates set notes = 'pm edit' where id = tst.id('cand1');
reset role;
select tst.ok((select notes is null from public.candidates where id = tst.id('cand1')), 'hiring manager cannot edit candidates');
select tst.login('cli@maahaul.test'); set role authenticated;
select tst.eq((select count(*) from public.candidates)::int, 0, 'clients see no candidates');
reset role;

select tst.login('hr@a.test'); set role authenticated;
insert into public.offers(org_id, candidate_id, designation, annual_ctc, joining_date, letter_text)
values (tst.id('orgA'), tst.id('cand1'), 'SEO Executive', 450000, '2026-11-16', 'Dear Ravi, we are pleased to offer you…');
select tst.put('offer1', (select id from public.offers where candidate_id = tst.id('cand1')));
select tst.throws($$insert into public.offers(org_id, candidate_id, designation, annual_ctc, joining_date) values (tst.id('orgA'), tst.id('cand1'), 'Dup', 1, '2026-12-01')$$,
  'one open offer per candidate', '23505');
select tst.throws($$update public.offers set status = 'accepted' where id = tst.id('offer1')$$, 'offer status only via actions', '42501');
select tst.throws($$select public.set_offer_status(tst.id('offer1'), 'accepted')$$, 'draft offer cannot jump to accepted', '22023');
select tst.throws($$select public.hire_candidate(tst.id('cand1'), 'ravi@a.test')$$, 'hiring needs an accepted offer', '22023');
select public.set_offer_status(tst.id('offer1'), 'sent');
select tst.eq((select stage from public.candidates where id = tst.id('cand1')), 'offer', 'sending an offer moves the candidate to offer');
reset role;
select tst.ok(exists (select 1 from public.email_outbox where category = 'offer' and to_email = 'ravi@cand.test'), 'offer letter e-mailed to the candidate');
select tst.login('hr@a.test'); set role authenticated;
select tst.throws($$update public.offers set annual_ctc = 1 where id = tst.id('offer1')$$, 'sent offer cannot be edited', '42501');
select public.set_offer_status(tst.id('offer1'), 'accepted');
select tst.throws($$select public.hire_candidate(tst.id('cand1'), 'not-an-email')$$, 'work e-mail validated', '22023');
select tst.put('emp_ravi', public.hire_candidate(tst.id('cand1'), 'ravi@a.test'));
select tst.eq((select (status::text, designation, joining_date::text) from public.employee_profiles where id = tst.id('emp_ravi'))::text,
  '(onboarding,"SEO Executive",2026-11-16)', 'hire creates the employee record');
select tst.eq((select reporting_manager_id from public.employee_profiles where id = tst.id('emp_ravi')), tst.id('emp_pm'), 'hiring manager becomes reporting manager');
select tst.eq((select monthly_components::text from public.salary_revisions where employee_id = tst.id('emp_ravi')),
  '{"HRA": 7500, "BASIC": 18750, "SPECIAL": 11250.00}', 'salary structure from offer CTC');
select tst.eq((select (stage, employee_id = tst.id('emp_ravi'))::text from public.candidates where id = tst.id('cand1')), '(hired,t)', 'candidate marked hired');
select tst.eq((select status from public.job_openings where id = tst.id('job1')), 'filled', 'opening filled when all positions are hired');
select tst.throws($$select public.hire_candidate(tst.id('cand1'), 'ravi2@a.test')$$, 'cannot hire twice', '22023');
select tst.eq((select (active, hired, closed)::text from public.opening_pipeline where id = tst.id('job1')), '(0,1,1)', 'pipeline counts per opening');
reset role;
select tst.login('des@a.test'); set role authenticated;
select tst.throws($$select public.hire_candidate(tst.id('cand1'), 'x@a.test')$$, 'staff cannot hire', '42501');
reset role;
select tst.login('owner@b.test'); set role authenticated;
select tst.eq((select count(*) from public.job_openings)::int, 0, 'other org sees no openings');
reset role;

-- résumé storage paths
select tst.login('seo@a.test'); set role authenticated;
select tst.ok(app.can_read_object(tst.id('orgA') || '/recruitment/' || tst.id('cand1') || '/cv.pdf'), 'interviewer can open the résumé');
select tst.ok(not app.can_write_object(tst.id('orgA') || '/recruitment/' || tst.id('cand1') || '/cv.pdf'), 'interviewer cannot upload résumés');
reset role;
select tst.login('des@a.test'); set role authenticated;
select tst.ok(not app.can_read_object(tst.id('orgA') || '/recruitment/' || tst.id('cand1') || '/cv.pdf'), 'other staff cannot open résumés');
reset role;
select tst.login('hr@a.test'); set role authenticated;
select tst.ok(app.can_write_object(tst.id('orgA') || '/recruitment/' || tst.id('cand1') || '/cv.pdf'), 'recruiter can upload résumés');
reset role;
