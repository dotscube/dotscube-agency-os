-- =====================================================================
-- 0012 PHASE 5: permissions for Phase 5 + e-mail delivery (outbox)
-- E-mails are queued in public.email_outbox by database code and sent by
-- the `send-emails` Edge Function (Resend). Nothing is queued until an
-- admin turns e-mail on in Settings, so the queue never grows unattended.
-- =====================================================================

-- ---------- permission catalog (all Phase 5 keys) ----------
insert into public.permissions(key, module, description, is_sensitive) values
 ('invoices.view','finance','View invoices, payments and collections', true),
 ('invoices.manage','finance','Create, issue and cancel invoices, record payments, edit billing settings', true),
 ('payroll.view','payroll','View payroll runs and everyone''s payslips', true),
 ('payroll.run','payroll','Prepare, finalize and mark payroll as paid', true),
 ('recruitment.view','recruitment','View job openings and candidates', true),
 ('recruitment.manage','recruitment','Manage openings, candidates, interviews and offers', true)
on conflict (key) do nothing;

-- ---------- e-mail settings (one row per organization) ----------
create table public.email_settings (
  org_id uuid primary key references public.organizations(id) on delete cascade,
  enabled boolean not null default false,
  app_url text check (app_url is null or app_url ~ '^https?://[^\s]+$'),
  from_name text check (from_name is null or length(from_name) <= 80),
  reply_to text check (reply_to is null or reply_to ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  send_notifications boolean not null default true,
  send_invoices boolean not null default true,
  updated_at timestamptz not null default now()
);
create trigger trg_es_touch before update on public.email_settings for each row execute function app.touch_updated_at();
create trigger trg_audit after insert or update or delete on public.email_settings for each row execute function app.audit();

create table public.email_outbox (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  to_email text not null check (to_email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  to_name text,
  subject text not null check (length(subject) between 1 and 250),
  body_text text not null,
  category text not null check (category in ('notification','invoice','invoice_reminder','offer','test')),
  entity_type text,
  entity_id uuid,
  dedupe_key text not null,
  status text not null default 'queued' check (status in ('queued','sending','sent','failed')),
  attempts smallint not null default 0,
  last_error text,
  provider_id text,
  scheduled_at timestamptz not null default now(),
  locked_at timestamptz,
  sent_at timestamptz,
  created_at timestamptz not null default now(),
  unique (org_id, dedupe_key)
);
create index email_outbox_due on public.email_outbox(scheduled_at) where status in ('queued','sending');
create index on public.email_outbox(org_id, created_at desc);

alter table public.email_settings enable row level security;
alter table public.email_outbox enable row level security;
create policy es_select on public.email_settings for select to authenticated
  using (org_id = (select app.org_id()) and (select app.has_perm('org.manage')));
create policy es_write on public.email_settings for all to authenticated
  using (org_id = (select app.org_id()) and (select app.has_perm('org.manage')))
  with check (org_id = (select app.org_id()) and (select app.has_perm('org.manage')));
create policy eo_select on public.email_outbox for select to authenticated
  using (org_id = (select app.org_id()) and (select app.has_perm('org.manage')));
grant select, insert, update on public.email_settings to authenticated;
grant select on public.email_outbox to authenticated;

-- Queue one e-mail if the organization has e-mail turned on for this category. Idempotent per dedupe key.
create or replace function app.queue_email(p_org uuid, p_to text, p_name text, p_subject text, p_body text,
  p_category text, p_entity_type text, p_entity_id uuid, p_dedupe text) returns boolean
language plpgsql security definer set search_path = '' as $$
declare s public.email_settings; v_id uuid;
begin
  select * into s from public.email_settings where org_id = p_org;
  if s.org_id is null or not s.enabled then return false; end if;
  if p_to is null or p_to !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then return false; end if;
  if (p_category = 'notification' and not s.send_notifications)
     or (p_category in ('invoice','invoice_reminder') and not s.send_invoices) then return false; end if;
  insert into public.email_outbox(org_id, to_email, to_name, subject, body_text, category, entity_type, entity_id, dedupe_key)
  values (p_org, lower(trim(p_to)), p_name, left(p_subject, 250), p_body, p_category, p_entity_type, p_entity_id, p_dedupe)
  on conflict (org_id, dedupe_key) do nothing returning id into v_id;
  return v_id is not null;
end $$;

-- Absolute link into the app for e-mails ('' when no app URL is configured)
create or replace function app.app_link(p_org uuid, p_path text) returns text
language sql stable security definer set search_path = '' as $$
  select case when s.app_url is null or p_path is null then '' else rtrim(s.app_url, '/') || p_path end
  from (select (select app_url from public.email_settings where org_id = p_org) as app_url) s
$$;

-- Every new in-app notification is also e-mailed, unless the person turned e-mail off for that type.
create or replace function app.trg_email_notification() returns trigger
language plpgsql security definer set search_path = '' as $$
declare p public.profiles; v_link text; v_org_name text;
begin
  if exists (select 1 from public.notification_preferences where profile_id = new.recipient_id and type = new.type and not email) then
    return new; end if;
  select * into p from public.profiles where id = new.recipient_id and is_active;
  if p.id is null then return new; end if;
  select name into v_org_name from public.organizations where id = new.org_id;
  v_link := app.app_link(new.org_id, new.link);
  perform app.queue_email(new.org_id, p.email, nullif(p.full_name, ''), new.title,
    concat_ws(E'\n\n', 'Hi ' || coalesce(nullif(split_part(p.full_name, ' ', 1), ''), 'there') || ',', new.title, new.body,
      case when v_link <> '' then 'Open: ' || v_link end,
      '— ' || v_org_name || E' Agency OS\nYou can turn these e-mails off in Settings → Notifications.'),
    'notification', 'notification', new.id, 'notif:' || new.id);
  return new;
exception when others then
  return new;  -- e-mail is best effort: never block the in-app notification
end $$;
create trigger trg_email_notification after insert on public.notifications
  for each row execute function app.trg_email_notification();

-- ---------- worker API (service role only: the send-emails Edge Function) ----------
create or replace function public.claim_emails(p_limit integer default 20)
returns table (id uuid, org_id uuid, to_email text, to_name text, subject text, body_text text, from_name text, reply_to text)
language plpgsql security definer set search_path = '' as $$
begin
  return query
  with picked as (
    select o.id from public.email_outbox o
    where o.scheduled_at <= now() and o.attempts < 5
      and (o.status = 'queued' or (o.status = 'sending' and o.locked_at < now() - interval '10 minutes'))
    order by o.scheduled_at limit greatest(1, least(coalesce(p_limit, 20), 100))
    for update skip locked),
  upd as (
    update public.email_outbox o set status = 'sending', locked_at = now(), attempts = o.attempts + 1
    from picked where o.id = picked.id returning o.*)
  select u.id, u.org_id, u.to_email, u.to_name, u.subject, u.body_text,
         coalesce(s.from_name, org.name), s.reply_to
  from upd u join public.organizations org on org.id = u.org_id
  left join public.email_settings s on s.org_id = u.org_id;
end $$;

create or replace function public.complete_email(p_id uuid, p_ok boolean, p_error text default null, p_provider_id text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare e public.email_outbox;
begin
  update public.email_outbox set
    status = case when p_ok then 'sent' when attempts >= 5 then 'failed' else 'queued' end,
    sent_at = case when p_ok then now() end,
    provider_id = coalesce(p_provider_id, provider_id),
    last_error = case when p_ok then null else left(p_error, 1000) end,
    scheduled_at = case when p_ok then scheduled_at else now() + (interval '2 minutes' * power(2, attempts)) end,
    locked_at = null
  where id = p_id and status = 'sending' returning * into e;
  if p_ok and e.entity_type = 'notification' then
    update public.notifications set emailed_at = now() where id = e.entity_id;
  end if;
end $$;
revoke execute on function public.claim_emails(integer) from public, anon, authenticated;
revoke execute on function public.complete_email(uuid, boolean, text, text) from public, anon, authenticated;
grant execute on function public.claim_emails(integer), public.complete_email(uuid, boolean, text, text) to service_role;

-- Admin: queue a test e-mail to yourself
create or replace function public.send_test_email() returns boolean
language plpgsql security definer set search_path = '' as $$
declare p public.profiles;
begin
  if not app.has_perm('org.manage') then raise exception 'Not allowed' using errcode = '42501'; end if;
  select * into p from public.profiles where id = auth.uid();
  if not exists (select 1 from public.email_settings where org_id = p.org_id and enabled) then
    raise exception 'Turn e-mail on first' using errcode = '22023'; end if;
  return app.queue_email(p.org_id, p.email, p.full_name, 'Test e-mail from Agency OS',
    'This is a test. If you can read it, e-mail delivery from Agency OS works.', 'test', null, null,
    'test:' || auth.uid() || ':' || extract(epoch from clock_timestamp())::bigint);
end $$;

create or replace function public.email_queue_stats() returns jsonb
language sql stable security definer set search_path = '' as $$
  select case when app.has_perm('org.manage') then jsonb_build_object(
    'queued', count(*) filter (where status in ('queued','sending')),
    'sent_7d', count(*) filter (where status = 'sent' and sent_at > now() - interval '7 days'),
    'failed', count(*) filter (where status = 'failed'),
    'last_sent_at', max(sent_at)) end
  from public.email_outbox where org_id = app.org_id()
$$;
revoke execute on function public.send_test_email(), public.email_queue_stats() from public, anon;
grant execute on function public.send_test_email(), public.email_queue_stats() to authenticated;

-- keep the outbox small: sent mail older than 90 days is removed by the scheduled job
create or replace function public.purge_old_emails() returns integer
language sql security definer set search_path = '' as $$
  with d as (delete from public.email_outbox where status in ('sent','failed') and created_at < now() - interval '90 days' returning 1)
  select count(*)::int from d
$$;
revoke execute on function public.purge_old_emails() from public, anon, authenticated;
grant execute on function public.purge_old_emails() to service_role;
do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('agency-os-purge-emails', '40 3 * * *', 'select public.purge_old_emails()');
  end if;
end $$;

revoke execute on all functions in schema app from public, anon;
grant execute on all functions in schema app to authenticated, service_role;
