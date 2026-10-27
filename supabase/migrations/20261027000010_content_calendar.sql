-- =====================================================================
-- 0010 PHASE 4: content calendar with client approval
-- Pipeline: idea -> in_progress -> internal_review -> client_review
--           -> (changes_requested -> in_progress ...) -> approved -> scheduled -> published
-- Client portal users see items once they reach client_review, and can only
-- approve / request changes through review_content().
-- =====================================================================
create type public.content_status as enum
  ('idea','in_progress','internal_review','client_review','changes_requested','approved','scheduled','published','cancelled');

create table public.content_items (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  client_id uuid not null references public.clients(id) on delete cascade,
  project_id uuid references public.projects(id) on delete set null,
  title text not null check (length(trim(title)) between 2 and 200),
  platform text not null check (platform in ('instagram','facebook','linkedin','youtube','x','google_business','blog','email','other')),
  content_type text not null default 'post' check (content_type in ('post','reel','story','carousel','video','short','blog','email','ad')),
  caption text check (caption is null or length(caption) <= 5000),
  creative_url text check (creative_url is null or creative_url ~* '^https?://'),
  scheduled_at timestamptz,
  status public.content_status not null default 'idea',
  assignee_id uuid references public.profiles(id) on delete set null,
  client_feedback text,
  reviewed_by uuid references public.profiles(id) on delete set null,
  reviewed_at timestamptz,
  published_url text check (published_url is null or published_url ~* '^https?://'),
  published_at timestamptz,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index on public.content_items(org_id, scheduled_at);
create index on public.content_items(client_id, status);
create index on public.content_items(assignee_id);
create trigger trg_ci_touch before update on public.content_items for each row execute function app.touch_updated_at();
create trigger trg_audit after insert or update or delete on public.content_items for each row execute function app.audit();

create or replace function app.can_view_content(c public.content_items) returns boolean
language sql stable security definer set search_path = '' as $$
  select c.org_id = app.org_id() and (
    (app.is_internal() and (app.has_perm('content.view_all') or app.has_perm('content.manage')
       or c.assignee_id = auth.uid() or c.created_by = auth.uid() or app.can_view_client(c.client_id)
       or (c.project_id is not null and app.can_view_project(c.project_id))))
    or (c.client_id = app.client_id() and c.status in ('client_review','changes_requested','approved','scheduled','published')))
$$;

create or replace function app.can_edit_content(c public.content_items) returns boolean
language sql stable security definer set search_path = '' as $$
  select c.org_id = app.org_id() and app.is_internal()
    and (app.has_perm('content.manage') or c.assignee_id = auth.uid() or c.created_by = auth.uid())
$$;

create or replace function app.content_before_write() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_old public.content_status := case when tg_op = 'UPDATE' then old.status end; a uuid;
begin
  if not exists (select 1 from public.clients where id = new.client_id and org_id = new.org_id) then
    raise exception 'Client must belong to the same organization' using errcode = '23514'; end if;
  if new.project_id is not null and not exists (select 1 from public.projects where id = new.project_id
       and org_id = new.org_id and client_id = new.client_id) then
    raise exception 'Project must belong to the same client' using errcode = '23514'; end if;
  if new.assignee_id is not null and not exists (select 1 from public.profiles where id = new.assignee_id
       and org_id = new.org_id and client_id is null) then
    raise exception 'Assignee must be an internal user' using errcode = '23514'; end if;

  if auth.uid() is not null and not app.guards_bypassed() then
    -- approval is the client's decision; internal staff need content.manage to record it on their behalf
    if new.status = 'approved' and v_old is distinct from 'approved' and not app.has_perm('content.manage') then
      raise exception 'Only the client (or a content manager on their behalf) can approve content' using errcode = '42501'; end if;
    if new.status in ('scheduled','published') and v_old is distinct from new.status
       and coalesce(v_old::text, '') not in ('approved','scheduled','published') then
      raise exception 'Content must be approved before it is scheduled or published' using errcode = '22023'; end if;
    if new.status = 'scheduled' and new.scheduled_at is null then
      raise exception 'Set a date and time before scheduling' using errcode = '22023'; end if;
    if tg_op = 'UPDATE' and (new.client_feedback is distinct from old.client_feedback
                             or new.reviewed_by is distinct from old.reviewed_by) then
      raise exception 'Client feedback is recorded through the review action' using errcode = '42501'; end if;
    if tg_op = 'UPDATE' and v_old in ('approved','scheduled','published') and new.status = v_old
       and (new.caption is distinct from old.caption or new.creative_url is distinct from old.creative_url) then
      raise exception 'Approved content is locked; send it back for review to change it' using errcode = '22023'; end if;
  end if;
  if new.status = 'published' and new.published_at is null then new.published_at := now(); end if;
  if new.status = 'approved' and v_old is distinct from 'approved' and new.reviewed_at is null then
    new.reviewed_by := auth.uid(); new.reviewed_at := now(); end if;

  if new.status = 'client_review' and v_old is distinct from 'client_review' then
    for a in select p.id from public.profiles p where p.client_id = new.client_id and p.is_active loop
      perform app.notify(a, 'content_review', 'Please review: ' || new.title,
        initcap(new.platform) || coalesce(' · ' || to_char(new.scheduled_at at time zone (select timezone from public.organizations where id = new.org_id), 'DD Mon HH24:MI'), ''),
        '/content', 'content', new.id, 'cr:' || new.id || ':' || (extract(epoch from now()) * 1000000)::bigint);
    end loop;
  end if;
  return new;
end $$;
create trigger trg_ci_before before insert or update on public.content_items
  for each row execute function app.content_before_write();

alter table public.content_items enable row level security;
create policy ci_select on public.content_items for select to authenticated using (app.can_view_content(content_items));
create policy ci_insert on public.content_items for insert to authenticated
  with check (org_id = (select app.org_id()) and (select app.is_internal()) and created_by = auth.uid()
    and ((select app.has_perm('content.manage')) or app.can_view_client(client_id)));
create policy ci_update on public.content_items for update to authenticated
  using (app.can_edit_content(content_items)) with check (app.can_edit_content(content_items));
create policy ci_delete on public.content_items for delete to authenticated
  using (org_id = (select app.org_id()) and ((select app.has_perm('content.manage')) or (created_by = auth.uid() and status = 'idea')));
grant select, insert, delete on public.content_items to authenticated;
grant update (title, platform, content_type, caption, creative_url, scheduled_at, status, assignee_id, project_id,
              published_url, published_at) on public.content_items to authenticated;

-- the client's decision (also usable by internal content managers on the client's behalf)
create or replace function public.review_content(p_item uuid, p_approve boolean, p_feedback text default null)
returns public.content_items language plpgsql security definer set search_path = '' as $$
declare c public.content_items; a uuid;
begin
  select * into c from public.content_items where id = p_item for update;
  if c.id is null or not app.can_view_content(c) then raise exception 'Content not found' using errcode = 'P0002'; end if;
  if not (c.client_id = app.client_id() or (app.is_internal() and app.has_perm('content.manage'))) then
    raise exception 'Only the client can review this content' using errcode = '42501'; end if;
  if c.status <> 'client_review' then raise exception 'This item is not waiting for review' using errcode = '22023'; end if;
  if not p_approve and coalesce(trim(p_feedback), '') = '' then
    raise exception 'Please describe the changes you need' using errcode = '22023'; end if;
  perform set_config('app.bypass_guards', 'on', true);
  update public.content_items set status = case when p_approve then 'approved' else 'changes_requested' end::public.content_status,
    client_feedback = nullif(trim(p_feedback), ''), reviewed_by = auth.uid(), reviewed_at = now()
  where id = p_item returning * into c;
  perform set_config('app.bypass_guards', '', true);
  for a in select x from (values (c.assignee_id), (c.created_by)) v(x) where x is not null loop
    perform app.notify(a, 'content_reviewed', case when p_approve then 'Approved: ' else 'Changes requested: ' end || c.title,
      c.client_feedback, '/content', 'content', c.id, 'crd:' || c.id || ':' || (extract(epoch from c.reviewed_at) * 1000000)::bigint);
  end loop;
  return c;
end $$;
revoke execute on function public.review_content(uuid, boolean, text) from public, anon;
grant execute on function public.review_content(uuid, boolean, text) to authenticated;
revoke execute on all functions in schema app from public, anon;
grant execute on all functions in schema app to authenticated, service_role;
