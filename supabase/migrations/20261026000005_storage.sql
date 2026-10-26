-- =====================================================================
-- 0005 STORAGE: private bucket, path-based policies mirroring table RLS.
-- Path convention: {org_id}/{area}/{entity_id}/{uuid}-{filename}
--   area = tasks | employees | clients
-- Skipped automatically on plain Postgres (no storage schema).
-- =====================================================================
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
    else false end;
exception when invalid_text_representation then return false;
end $$;
grant execute on function app.can_read_object(text), app.can_write_object(text) to authenticated;

do $$ begin
  if exists (select 1 from information_schema.schemata where schema_name = 'storage') then
    insert into storage.buckets (id, name, public, file_size_limit)
    values ('agency-files', 'agency-files', false, 52428800) on conflict (id) do nothing;
    execute $p$create policy agency_files_read on storage.objects for select to authenticated
      using (bucket_id = 'agency-files' and app.can_read_object(name))$p$;
    execute $p$create policy agency_files_insert on storage.objects for insert to authenticated
      with check (bucket_id = 'agency-files' and app.can_write_object(name))$p$;
    execute $p$create policy agency_files_delete on storage.objects for delete to authenticated
      using (bucket_id = 'agency-files' and app.can_write_object(name))$p$;
  end if;
end $$;
