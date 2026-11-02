-- =====================================================================
-- Deleting an agency (platform admin). Runs last: it deletes agencies.
-- =====================================================================
\set ON_ERROR_STOP 1
\o /dev/null

-- rows an agency holds across every table that points at organizations
create or replace function tst.org_rows(p_org uuid) returns bigint language plpgsql as $$
declare t record; v bigint; total bigint := 0;
begin
  for t in select c.conrelid::regclass::text tbl, a.attname::text col from pg_constraint c
             join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
            where c.contype = 'f' and c.confrelid = 'public.organizations'::regclass loop
    execute format('select count(*) from %s where %I = $1', t.tbl, t.col) into v using p_org;
    total := total + v;
  end loop;
  return total + (select count(*) from public.organizations where id = p_org);
end $$;

create temp table snap as select tst.org_rows(tst.id('orgA')) a_rows,
  (select array_agg(id) from public.profiles where org_id = tst.id('orgB')) b_users,
  (select array_agg(id) from public.profiles where org_id = tst.id('orgA')) a_users;
grant select on snap to authenticated;
select tst.ok((select a_rows from snap) > 100 and tst.org_rows(tst.id('orgB')) > 20, 'test agencies hold data before deletion');

-- ---------- who may delete, and the safety checks ----------
select tst.login('owner@b.test'); set role authenticated;
select tst.throws($$select public.platform_delete_agency(tst.id('orgA'), 'x')$$, 'an agency''s Super Admin cannot delete agencies', '42501');
reset role;
select tst.login('owner@a.test'); set role authenticated;
select tst.throws($$select public.platform_delete_agency(tst.id('orgA'), (select name from public.organizations where id = tst.id('orgA')))$$,
  'cannot delete the platform''s own agency', '22023');
select tst.throws($$select public.platform_delete_agency(tst.id('orgB'), (select x->>'name' from jsonb_array_elements(public.platform_agencies()) x where x->>'id' = tst.id('orgB')::text))$$,
  'an active agency must be suspended before it can be deleted', '22023');
select public.platform_set_agency_status(tst.id('orgB'), 'suspended', 'Closing account');
select tst.throws($$select public.platform_delete_agency(tst.id('orgB'), 'wrong name')$$, 'the agency name must be typed to confirm', '22023');
select tst.ok(exists (select 1 from jsonb_array_elements(public.platform_agencies()) x where x->>'id' = tst.id('orgB')::text), 'failed attempts change nothing');

-- ---------- delete agency B ----------
select tst.lives($$select public.platform_delete_agency(tst.id('orgB'),
  upper((select x->>'name' from jsonb_array_elements(public.platform_agencies()) x where x->>'id' = tst.id('orgB')::text)))$$,
  'platform admin deletes a suspended agency (name match ignores case)');
select tst.ok(not exists (select 1 from jsonb_array_elements(public.platform_agencies()) x where x->>'id' = tst.id('orgB')::text), 'deleted agency gone from the platform list');
reset role;
select tst.eq(tst.org_rows(tst.id('orgB')), 0::bigint, 'none of the deleted agency''s data is left in any table');
select tst.eq((select count(*) from auth.users where id in (select unnest(b_users) from snap))::int, 0, 'its members'' logins are deleted');
select tst.eq(tst.org_rows(tst.id('orgA')), (select a_rows from snap), 'other agencies are untouched');
select tst.ok(exists (select 1 from public.audit_logs where org_id is null and record_id = tst.id('orgB')::text and new_data->>'platform' = 'deleted'
  and actor_id = tst.id('owner@a.test') and (new_data->>'logins_deleted')::int > 0), 'deletion recorded in the platform audit log');
select tst.ok(not exists (select 1 from public.audit_logs where org_id = tst.id('orgB')), 'the deleted agency''s own audit trail is removed');
select tst.eq(current_setting('app.purge_org', true), '', 'purge flag not left behind');

-- the guards are back in force after a deletion
select tst.login('owner@a.test'); set role authenticated;
select tst.throws($$delete from public.roles where org_id = tst.id('orgA') and is_system$$, 'system roles still protected afterwards', '42501');
reset role;

-- ---------- a full agency (issued invoices, payroll, timesheets, ...) deletes cleanly ----------
delete from public.platform_admins;
insert into public.platform_admins(user_id) values (tst.id('invited@x.test'));
select tst.login('invited@x.test'); set role authenticated;
select public.platform_set_agency_status(tst.id('orgA'), 'suspended', 'Test of a full delete');
select tst.lives($$select public.platform_delete_agency(tst.id('orgA'), (select x->>'name' from jsonb_array_elements(public.platform_agencies()) x where x->>'id' = tst.id('orgA')::text))$$,
  'agency with issued invoices, payroll and history can be deleted');
reset role;
select tst.eq(tst.org_rows(tst.id('orgA')), 0::bigint, 'every row of the full agency is gone');
select tst.eq((select count(*) from auth.users where id in (select unnest(a_users) from snap))::int, 0, 'all of the full agency''s logins are deleted');
select tst.ok(exists (select 1 from public.organizations where id = tst.id('orgC')), 'the platform admin''s own agency remains');
