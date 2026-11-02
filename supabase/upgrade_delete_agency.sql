-- Dotscube Agency OS: delete an agency (platform admin).
-- For a project that already ran upgrade_platform.sql. Paste into Supabase > SQL Editor > New query > Run, ONCE.
-- Generated from supabase/migrations (the source of truth).
begin;

-- ===== 20261102000018_platform_delete_agency.sql =====
-- =====================================================================
-- 0018 DELETE AN AGENCY: a platform admin can permanently delete an agency,
-- with all of its data and the login accounts of everyone in it.
-- * Only platform admins; never the agency platform admins belong to.
-- * The agency must be suspended first, and the caller must type its name.
-- * While an agency is being deleted (app.purge_org is set for the
--   transaction), the guards that protect issued invoices, system roles and
--   the audit trail step aside for that delete only.
-- * One record survives in the platform audit log (org_id null): who deleted
--   which agency, when, and how much it held.
-- =====================================================================

create or replace function app.purging() returns boolean
language sql stable set search_path = '' as $$
  select coalesce(current_setting('app.purge_org', true), '') <> ''
$$;

-- ---------- guards that step aside while an agency is being deleted ----------
create or replace function app.audit() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_old jsonb; v_new jsonb; v_row jsonb;
begin
  if app.purging() then return coalesce(new, old); end if;
  if tg_op in ('UPDATE','DELETE') then v_old := to_jsonb(old); end if;
  if tg_op in ('INSERT','UPDATE') then v_new := to_jsonb(new); end if;
  if tg_op = 'UPDATE' and v_old - 'updated_at' = v_new - 'updated_at' then return new; end if;
  v_row := coalesce(v_new, v_old);
  insert into public.audit_logs(org_id, actor_id, action, table_name, record_id, old_data, new_data)
  values (nullif(v_row->>'org_id','')::uuid, auth.uid(), tg_op, tg_table_name,
          coalesce(v_row->>'id', v_row->>'user_id'), v_old, v_new);
  return coalesce(new, old);
end $$;

create or replace function app.guard_roles() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'DELETE' and app.purging() then return old; end if;
  if tg_op = 'DELETE' and old.is_system then raise exception 'System roles cannot be deleted' using errcode='42501'; end if;
  if tg_op = 'UPDATE' and (new.key <> old.key or new.is_system <> old.is_system or new.org_id <> old.org_id
                           or new.is_client_role <> old.is_client_role) then
    raise exception 'Role key/system flags are immutable' using errcode='42501';
  end if;
  return coalesce(new, old);
end $$;

create or replace function app.invoice_delete_guard() returns trigger
language plpgsql set search_path = '' as $$
begin
  if app.purging() then return old; end if;
  if old.status <> 'draft' then raise exception 'Only draft invoices can be deleted' using errcode = '42501'; end if;
  return old;
end $$;

create or replace function app.invoice_item_before_write() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_status public.invoice_status; v_inv uuid := coalesce(new.invoice_id, old.invoice_id);
begin
  if tg_op = 'DELETE' and app.purging() then return old; end if;
  select status into v_status from public.invoices where id = v_inv;
  if v_status is distinct from 'draft' and v_status is not null then
    raise exception 'Items of an issued invoice cannot be changed' using errcode = '42501'; end if;
  if tg_op = 'UPDATE' and new.invoice_id <> old.invoice_id then
    raise exception 'Items cannot move between invoices' using errcode = '42501'; end if;
  if tg_op <> 'DELETE' then
    new.org_id := (select org_id from public.invoices where id = new.invoice_id);
    new.description := trim(new.description);
    return new;
  end if;
  return old;
end $$;

create or replace function app.invoice_item_after_write() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if app.purging() then return null; end if;
  perform app.recalc_invoice(coalesce(new.invoice_id, old.invoice_id));
  return null;
end $$;

-- ---------- the delete itself ----------
create or replace function public.platform_delete_agency(p_org uuid, p_confirm text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  o public.organizations; t record; v_summary jsonb; v_users uuid[];
  v_pass int := 0; v_failed int; v_deleted bigint; v_n bigint; v_last text;
begin
  perform app.require_platform_admin();
  select * into o from public.organizations where id = p_org for update;
  if o.id is null then raise exception 'Agency not found' using errcode = 'P0002'; end if;
  if exists (select 1 from public.platform_admins pa join public.profiles p on p.id = pa.user_id where p.org_id = p_org) then
    raise exception 'You can''t delete the agency that platform admins belong to' using errcode = '22023'; end if;
  if o.status <> 'suspended' then
    raise exception 'Suspend the agency first, then delete it' using errcode = '22023'; end if;
  if lower(trim(coalesce(p_confirm, ''))) <> lower(trim(o.name)) then
    raise exception 'Type the agency''s name exactly to confirm' using errcode = '22023'; end if;

  select x into v_summary from jsonb_array_elements(public.platform_agencies()) x where x->>'id' = p_org::text;
  select coalesce(array_agg(id), '{}') into v_users from public.profiles where org_id = p_org;

  perform set_config('app.purge_org', p_org::text, true);
  perform set_config('app.bypass_guards', 'on', true);

  -- Every table that points at the agency, plus its members' logins. Tables point at each
  -- other with ON DELETE RESTRICT, so delete what can go and repeat until nothing is left.
  loop
    v_pass := v_pass + 1; v_failed := 0; v_deleted := 0;
    for t in
      select c.conrelid::regclass::text as tbl, a.attname::text as col
        from pg_constraint c join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
       where c.contype = 'f' and c.confrelid = 'public.organizations'::regclass and c.confdeltype <> 'n'
         and c.conrelid not in ('public.profiles'::regclass, 'public.audit_logs'::regclass)
      union all select 'auth.users', 'id'
    loop
      begin
        if t.tbl = 'auth.users' then
          delete from auth.users where id = any(v_users);
        else
          execute format('delete from %s where %I = $1', t.tbl, t.col) using p_org;
        end if;
        get diagnostics v_n = row_count; v_deleted := v_deleted + v_n;
      exception when foreign_key_violation then
        v_failed := v_failed + 1; v_last := t.tbl || ': ' || sqlerrm;
      end;
    end loop;
    exit when v_failed = 0;
    if v_deleted = 0 or v_pass >= 50 then
      raise exception 'The agency could not be deleted (%). Nothing was changed.', v_last using errcode = '23503'; end if;
  end loop;

  delete from public.profiles where org_id = p_org;
  delete from public.audit_logs where org_id = p_org;
  delete from public.organizations where id = p_org;

  perform set_config('app.purge_org', '', true);
  perform set_config('app.bypass_guards', '', true);
  perform app.audit_event(null, 'organizations', p_org::text, jsonb_build_object('platform', 'deleted', 'name', o.name, 'slug', o.slug,
    'founder', v_summary->'founder', 'logins_deleted', cardinality(v_users),
    'clients', v_summary->'clients', 'projects', v_summary->'projects', 'invoices', v_summary->'invoices'));
end $$;

revoke execute on function public.platform_delete_agency(uuid, text) from public, anon;
grant execute on function public.platform_delete_agency(uuid, text) to authenticated;
revoke execute on function app.purging() from public, anon;
grant execute on function app.purging() to authenticated, service_role;

commit;
