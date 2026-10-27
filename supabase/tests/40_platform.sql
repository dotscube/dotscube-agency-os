-- =====================================================================
-- Platform admin tests: platform owner, agency list, suspension,
-- who may create agencies, user limits. Runs after 10_/20_/30_.
-- =====================================================================
\set ON_ERROR_STOP 1
\o /dev/null

select tst.ok(exists (select 1 from public.platform_admins where user_id = tst.id('owner@a.test')), 'first agency founder owns the platform');
select tst.eq((select count(*) from public.platform_admins)::int, 1, 'later founders are not platform admins');
select tst.eq((select created_by from public.organizations where id = tst.id('orgB')), tst.id('owner@b.test'), 'founder recorded on the agency');

-- ---------- console access ----------
select tst.login('owner@b.test'); set role authenticated;
select tst.throws($$select public.platform_agencies()$$, 'other agency''s Super Admin cannot open the platform console', '42501');
select tst.throws($$select public.platform_set_agency_status(tst.id('orgA'), 'suspended', 'hostile')$$, 'other agency cannot suspend anyone', '42501');
select tst.throws($$insert into public.platform_admins(user_id) values (auth.uid())$$, 'nobody can make themselves platform admin', '42501');
select tst.throws($$select count(*) from public.platform_admins$$, 'platform admin list is not readable', '42501');
select tst.throws($$update public.organizations set status = 'active', plan = 'unlimited', max_users = null where id = tst.id('orgB')$$,
  'agencies cannot change their own plan or status', '42501');
select tst.ok(not (public.my_account_state()->>'platform_admin')::boolean, 'account state: not a platform admin');
reset role;
select tst.login('hr@a.test'); set role authenticated;
select tst.throws($$select public.platform_agencies()$$, 'staff of the platform''s own agency are not platform admins', '42501');
reset role;

select tst.login('owner@a.test'); set role authenticated;
select tst.ok((public.my_account_state()->>'platform_admin')::boolean, 'account state: platform admin');
select tst.eq(jsonb_array_length(public.platform_agencies()), 2, 'platform admin sees every agency');
select tst.ok((select (x->>'staff_users')::int >= 6 and (x->>'clients')::int >= 2 and (x->>'is_platform_home')::boolean
  from jsonb_array_elements(public.platform_agencies()) x where x->>'id' = tst.id('orgA')::text), 'agency summary counts');
select tst.eq((select x->'founder'->>'email' from jsonb_array_elements(public.platform_agencies()) x where x->>'id' = tst.id('orgB')::text),
  'owner@b.test', 'founder shown for each agency');
select tst.ok(jsonb_array_length(public.platform_agency_members(tst.id('orgA'))) >= 7, 'members of an agency listed with roles');
select tst.eq((select count(*) from public.clients where org_id = tst.id('orgB'))::int, 0, 'platform admin still cannot read another agency''s data directly');

-- ---------- suspension ----------
select tst.throws($$select public.platform_set_agency_status(tst.id('orgA'), 'suspended', 'test')$$, 'cannot suspend the platform''s own agency', '22023');
select tst.throws($$select public.platform_set_agency_status(tst.id('orgB'), 'suspended', '')$$, 'suspension needs a reason', '22023');
select public.platform_set_agency_status(tst.id('orgB'), 'suspended', 'Unpaid subscription');
reset role;
select tst.login('owner@b.test'); set role authenticated;
select tst.eq((select count(*) from public.organizations)::int, 0, 'suspended agency loses access to its organization');
select tst.eq((select count(*) from public.my_permissions())::int, 0, 'suspended agency has no permissions');
select tst.eq(public.my_account_state()->>'org_status', 'suspended', 'suspended user is told why');
select tst.throws($$insert into public.clients(org_id, name, created_by) values (tst.id('orgB'), 'While suspended', auth.uid())$$,
  'suspended agency cannot write data', '42501');
reset role;
select tst.login('owner@a.test'); set role authenticated;
select public.platform_set_agency_status(tst.id('orgB'), 'active');
reset role;
select tst.login('owner@b.test'); set role authenticated;
select tst.eq((select count(*) from public.organizations)::int, 1, 'reactivated agency regains access');
reset role;
select tst.ok(exists (select 1 from public.audit_logs where org_id = tst.id('orgB') and new_data->>'platform' = 'suspended'), 'suspension recorded in the audit log');

-- ---------- plans and user limits ----------
select tst.login('owner@a.test'); set role authenticated;
select public.platform_update_agency(tst.id('orgB'), 'starter', 1, 'Trial');
reset role;
select tst.login('owner@b.test'); set role authenticated;
select tst.throws($$insert into public.invitations(org_id, email, role_id, invited_by)
  select tst.id('orgB'), 'new@b.test', id, auth.uid() from public.roles where key = 'graphic_designer'$$, 'user limit enforced on invitations', '22023');
reset role;
select tst.login('owner@a.test'); set role authenticated;
select public.platform_update_agency(tst.id('orgB'), 'starter', 5, null);
reset role;
select tst.login('owner@b.test'); set role authenticated;
select tst.lives($$insert into public.invitations(org_id, email, role_id, invited_by)
  select tst.id('orgB'), 'new@b.test', id, auth.uid() from public.roles where key = 'graphic_designer'$$, 'raising the limit allows invitations');
reset role;

-- ---------- who may create an agency ----------
select tst.new_user('stranger2@x.test', 'Stranger Two');
select tst.new_user('invited@x.test', 'Invited Founder');
select tst.login('owner@a.test'); set role authenticated;
select public.platform_save_settings('closed', 'free', 10);
reset role;
select tst.login('stranger2@x.test'); set role authenticated;
select tst.eq(public.my_account_state()->>'org_creation', 'closed', 'sign-up mode visible before onboarding');
select tst.throws($$select public.create_organization('Spam Agency', 'spam-agency')$$, 'closed: nobody can create an agency', '42501');
reset role;
select tst.login('owner@a.test'); set role authenticated;
select public.platform_save_settings('invite_only', 'free', 10);
select public.platform_invite('Invited@X.test', 'growth', 25, 'Met at the Jaipur meetup');
select tst.throws($$select public.platform_invite('invited@x.test')$$, 'one open platform invitation per e-mail', '23505');
select tst.throws($$select public.platform_invite('owner@b.test')$$, 'cannot invite someone who already has an agency', '23505');
reset role;
select tst.login('stranger2@x.test'); set role authenticated;
select tst.throws($$select public.create_organization('Spam Agency', 'spam-agency')$$, 'invite-only: uninvited user blocked', '42501');
reset role;
select tst.login('invited@x.test'); set role authenticated;
select tst.put('orgC', public.create_organization('Invited Agency', 'invited-agency'));
reset role;
select tst.eq((select (plan, max_users)::text from public.organizations where id = tst.id('orgC')), '(growth,25)', 'invitation plan and limit applied');
select tst.ok(exists (select 1 from public.platform_invites where used_by_org = tst.id('orgC')), 'invitation marked used');
select tst.ok(not exists (select 1 from public.platform_admins where user_id = tst.id('invited@x.test')), 'invited founder is not a platform admin');
select tst.login('owner@a.test'); set role authenticated;
select public.platform_save_settings('open', 'free', null);
reset role;
select tst.login('stranger2@x.test'); set role authenticated;
select tst.lives($$select public.create_organization('Open Agency', 'open-agency')$$, 'open: anyone can create an agency');
select tst.eq((select max_users from public.organizations where slug = 'open-agency'), null::int, 'default limit applied (none)');
reset role;

-- ---------- more platform admins ----------
select tst.login('owner@a.test'); set role authenticated;
select public.platform_add_admin('hr@a.test');
select tst.throws($$select public.platform_remove_admin(auth.uid())$$, 'cannot remove yourself', '22023');
reset role;
select tst.login('hr@a.test'); set role authenticated;
select tst.ok(jsonb_array_length(public.platform_agencies()) >= 4, 'added platform admin can open the console');
reset role;
select tst.login('owner@a.test'); set role authenticated;
select public.platform_remove_admin(tst.id('hr@a.test'));
reset role;
select tst.login('hr@a.test'); set role authenticated;
select tst.throws($$select public.platform_agencies()$$, 'removed platform admin loses access', '42501');
reset role;
