-- =====================================================================
-- 0007 NO PRIVILEGE ESCALATION
-- Assigning a role / inviting into a role: the caller must hold every SENSITIVE permission of
-- that role (admin, audit, HR-private, salary, billing, exports, policies). Operational permissions
-- (e.g. tasks.create) may be granted by anyone with users.manage, so HR can onboard staff.
-- Editing role permissions: strict — you can only add permissions you hold yourself.
-- Super Admins are exempt. Bootstrap code paths use the bypass flag.
-- =====================================================================
alter table public.permissions add column is_sensitive boolean not null default false;
update public.permissions set is_sensitive = true where key in (
  'org.manage','roles.manage','users.manage','audit.view','employees.view_sensitive','employees.export',
  'salary.view','salary.edit','attendance.manage_policy','leave.manage_policy','clients.view_billing','clients.export');

create or replace function app.is_super_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.user_roles ur join public.roles r on r.id = ur.role_id
                 join public.profiles p on p.id = ur.user_id and p.is_active
                 where ur.user_id = auth.uid() and r.key = 'super_admin')
$$;

-- true if the caller holds every sensitive permission of the role
create or replace function app.can_grant_role(p_role uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select app.is_super_admin() or not exists (
    select 1 from public.role_permissions rp join public.permissions p on p.key = rp.permission_key
    where rp.role_id = p_role and p.is_sensitive and not app.has_perm(rp.permission_key))
$$;

create or replace function app.guard_escalation_user_roles() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if app.guards_bypassed() or auth.uid() is null then return new; end if;
  if not app.can_grant_role(new.role_id) then
    raise exception 'You can only assign roles whose sensitive permissions you already hold' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger trg_guard_escalation before insert on public.user_roles
  for each row execute function app.guard_escalation_user_roles();

create or replace function app.guard_escalation_invitations() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if app.guards_bypassed() or auth.uid() is null then return new; end if;
  if not app.can_grant_role(new.role_id) then
    raise exception 'You can only invite people into roles whose sensitive permissions you already hold' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger trg_guard_escalation before insert or update of role_id on public.invitations
  for each row execute function app.guard_escalation_invitations();

create or replace function app.guard_escalation_role_permissions() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if app.guards_bypassed() or auth.uid() is null then return new; end if;
  if not app.is_super_admin() and not app.has_perm(new.permission_key) then
    raise exception 'You can only add permissions you already hold' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger trg_guard_escalation before insert on public.role_permissions
  for each row execute function app.guard_escalation_role_permissions();

revoke execute on all functions in schema app from public, anon;
grant execute on all functions in schema app to authenticated, service_role;
