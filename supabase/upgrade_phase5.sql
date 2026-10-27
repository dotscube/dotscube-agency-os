-- Dotscube Agency OS: Phase 5 upgrade (e-mail delivery, GST invoices & payments, payroll, recruitment).
-- For a project that already ran upgrade_phase4.sql. Paste into Supabase > SQL Editor > New query > Run, ONCE.
-- Existing organizations get the new permissions, billing settings and e-mail settings (off) automatically.
-- Generated from supabase/migrations (the source of truth).
begin;

-- ===== 20261028000012_email_outbox.sql =====
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

-- ===== 20261028000013_invoices.sql =====
-- =====================================================================
-- 0013 PHASE 5: GST invoices, payments, reminders, collections summary
-- * Management fee and ad spend are separate line kinds with separate
--   subtotals; ad spend defaults to 0% GST (pure-agent reimbursement),
--   configurable in billing settings.
-- * Invoice numbers are assigned only when an invoice is issued, per
--   Indian financial year (Apr–Mar), consecutive and never reused:
--   PREFIX/2026-27/0001. Cancelled invoices keep their number.
-- * Issued invoices are immutable; only issue/cancel/payment functions
--   change them. Clients see their own issued invoices in the portal.
-- =====================================================================

-- ---------- billing settings (the agency's own details) ----------
create table public.billing_settings (
  org_id uuid primary key references public.organizations(id) on delete cascade,
  legal_name text check (legal_name is null or length(legal_name) <= 160),
  gstin text check (gstin is null or gstin ~ '^[0-9]{2}[0-9A-Z]{13}$'),
  pan text check (pan is null or pan ~ '^[A-Z]{5}[0-9]{4}[A-Z]$'),
  state_code char(2) check (state_code is null or state_code ~ '^[0-9]{2}$'),
  address text,
  email text check (email is null or email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  phone text,
  invoice_prefix text not null default 'INV' check (invoice_prefix ~ '^[A-Z0-9-]{1,10}$'),
  default_sac text not null default '998361' check (default_sac ~ '^[0-9]{4,8}$'),
  default_gst_rate numeric(5,2) not null default 18 check (default_gst_rate in (0,5,12,18,28)),
  ad_spend_gst_rate numeric(5,2) not null default 0 check (ad_spend_gst_rate in (0,5,12,18,28)),
  bank_details text,
  terms text,
  updated_at timestamptz not null default now()
);
create trigger trg_bs_touch before update on public.billing_settings for each row execute function app.touch_updated_at();
create trigger trg_audit after insert or update or delete on public.billing_settings for each row execute function app.audit();

create or replace function app.billing_settings_before() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.gstin := nullif(upper(trim(new.gstin)), '');
  new.pan := nullif(upper(trim(new.pan)), '');
  if new.gstin is not null then new.state_code := left(new.gstin, 2); end if;
  return new;
end $$;
create trigger trg_bs_before before insert or update on public.billing_settings
  for each row execute function app.billing_settings_before();

-- client place of supply (state code); taken from the GSTIN when there is one
alter table public.client_billing add column state_code char(2) check (state_code is null or state_code ~ '^[0-9]{2}$');
create or replace function app.client_billing_before() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.gst_number := nullif(upper(trim(new.gst_number)), '');
  if new.gst_number is not null then new.state_code := left(new.gst_number, 2); end if;
  return new;
end $$;
create trigger trg_cb_before before insert or update on public.client_billing
  for each row execute function app.client_billing_before();
update public.client_billing set state_code = left(gst_number, 2) where gst_number is not null and state_code is null;

-- Indian financial year label for a date: 2026-10-27 -> '2026-27'
create or replace function app.fiscal_year(p_day date) returns text
language sql immutable set search_path = '' as $$
  select case when extract(month from p_day) >= 4
              then extract(year from p_day)::int || '-' || lpad(((extract(year from p_day)::int + 1) % 100)::text, 2, '0')
              else (extract(year from p_day)::int - 1) || '-' || lpad((extract(year from p_day)::int % 100)::text, 2, '0') end
$$;

create table public.invoice_sequences (
  org_id uuid not null references public.organizations(id) on delete cascade,
  fiscal_year text not null check (fiscal_year ~ '^[0-9]{4}-[0-9]{2}$'),
  last_number integer not null default 0,
  primary key (org_id, fiscal_year)
);

-- ---------- invoices ----------
create type public.invoice_status as enum ('draft','issued','partially_paid','paid','cancelled');

create table public.invoices (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  client_id uuid not null references public.clients(id) on delete restrict,
  contract_id uuid references public.contracts(id) on delete set null,
  billing_period text check (billing_period is null or billing_period ~ '^[0-9]{4}-(0[1-9]|1[0-2])$'),
  invoice_number text,
  fiscal_year text,
  status public.invoice_status not null default 'draft',
  issue_date date,
  due_date date,
  place_of_supply char(2) check (place_of_supply is null or place_of_supply ~ '^[0-9]{2}$'),
  tax_mode text not null default 'intra' check (tax_mode in ('intra','inter')),
  currency char(3) not null default 'INR',
  notes text check (notes is null or length(notes) <= 2000),
  seller jsonb,
  buyer jsonb,
  fee_subtotal numeric(14,2) not null default 0,
  ad_spend_subtotal numeric(14,2) not null default 0,
  other_subtotal numeric(14,2) not null default 0,
  taxable_total numeric(14,2) not null default 0,
  cgst numeric(14,2) not null default 0,
  sgst numeric(14,2) not null default 0,
  igst numeric(14,2) not null default 0,
  round_off numeric(6,2) not null default 0,
  total numeric(14,2) not null default 0,
  amount_received numeric(14,2) not null default 0,
  tds_deducted numeric(14,2) not null default 0,
  balance numeric(14,2) generated always as (total - amount_received - tds_deducted) stored,
  created_by uuid references public.profiles(id) on delete set null,
  issued_by uuid references public.profiles(id) on delete set null,
  issued_at timestamptz,
  cancelled_at timestamptz,
  cancel_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (org_id, invoice_number),
  check (status = 'draft' or (invoice_number is not null and issue_date is not null and due_date is not null)),
  check (due_date is null or issue_date is null or due_date >= issue_date),
  check (status <> 'cancelled' or cancel_reason is not null)
);
create index on public.invoices(org_id, status);
create index on public.invoices(client_id);
create index invoices_open_due on public.invoices(org_id, due_date) where status in ('issued','partially_paid');
create unique index invoices_contract_period on public.invoices(contract_id, billing_period)
  where status <> 'cancelled' and contract_id is not null and billing_period is not null;
create trigger trg_inv_touch before update on public.invoices for each row execute function app.touch_updated_at();
create trigger trg_audit after insert or update or delete on public.invoices for each row execute function app.audit();

create table public.invoice_items (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  invoice_id uuid not null references public.invoices(id) on delete cascade,
  kind text not null default 'management_fee' check (kind in ('management_fee','ad_spend','other')),
  description text not null check (length(trim(description)) between 2 and 500),
  sac text check (sac is null or sac ~ '^[0-9]{4,8}$'),
  quantity numeric(10,2) not null default 1 check (quantity > 0),
  unit_price numeric(14,2) not null check (unit_price >= 0),
  gst_rate numeric(5,2) not null default 18 check (gst_rate in (0,5,12,18,28)),
  amount numeric(14,2) generated always as (round(quantity * unit_price, 2)) stored,
  position smallint not null default 0
);
create index on public.invoice_items(invoice_id, position);

create table public.payments (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  invoice_id uuid not null references public.invoices(id) on delete restrict,
  amount numeric(14,2) not null check (amount >= 0),
  tds_amount numeric(14,2) not null default 0 check (tds_amount >= 0),
  paid_on date not null,
  method text not null default 'bank_transfer' check (method in ('bank_transfer','upi','cheque','cash','card','other')),
  reference text check (reference is null or length(reference) <= 100),
  note text,
  recorded_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  check (amount + tds_amount > 0)
);
create index on public.payments(invoice_id);
create index on public.payments(org_id, paid_on);
create unique index payments_no_duplicate_reference on public.payments(invoice_id, method, lower(reference)) where reference is not null;
create trigger trg_audit after insert or update or delete on public.payments for each row execute function app.audit();

-- ---------- visibility ----------
create or replace function app.can_view_invoice(p_invoice uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.invoices i where i.id = p_invoice and i.org_id = app.org_id() and (
    (app.is_internal() and (app.has_perm('invoices.view') or app.has_perm('invoices.manage')))
    or (i.status <> 'draft' and i.client_id = app.client_id())))
$$;

-- ---------- totals ----------
create or replace function app.recalc_invoice(p_invoice uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_fee numeric; v_ad numeric; v_other numeric; v_taxable numeric; v_tax numeric; v_mode text; v_raw numeric; v_total numeric;
begin
  select coalesce(sum(amount) filter (where kind = 'management_fee'), 0), coalesce(sum(amount) filter (where kind = 'ad_spend'), 0),
         coalesce(sum(amount) filter (where kind = 'other'), 0), coalesce(sum(amount), 0),
         coalesce(sum(round(amount * gst_rate / 100, 2)), 0)
    into v_fee, v_ad, v_other, v_taxable, v_tax
    from public.invoice_items where invoice_id = p_invoice;
  select tax_mode into v_mode from public.invoices where id = p_invoice;
  v_raw := v_taxable + v_tax;
  v_total := round(v_raw);
  update public.invoices set fee_subtotal = v_fee, ad_spend_subtotal = v_ad, other_subtotal = v_other, taxable_total = v_taxable,
    cgst = case when v_mode = 'intra' then round(v_tax / 2, 2) else 0 end,
    sgst = case when v_mode = 'intra' then v_tax - round(v_tax / 2, 2) else 0 end,
    igst = case when v_mode = 'inter' then v_tax else 0 end,
    round_off = v_total - v_raw, total = v_total
  where id = p_invoice;
end $$;

-- drafts: force safe defaults, derive place of supply and CGST/SGST vs IGST
create or replace function app.invoice_before_write() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_seller char(2); v_client_state char(2);
begin
  if app.guards_bypassed() then return new; end if;
  if tg_op = 'INSERT' then
    new.status := 'draft'; new.invoice_number := null; new.fiscal_year := null; new.issued_at := null; new.issued_by := null;
    new.seller := null; new.buyer := null; new.amount_received := 0; new.tds_deducted := 0;
    new.fee_subtotal := 0; new.ad_spend_subtotal := 0; new.other_subtotal := 0; new.taxable_total := 0;
    new.cgst := 0; new.sgst := 0; new.igst := 0; new.round_off := 0; new.total := 0;
    new.cancelled_at := null; new.cancel_reason := null;
    new.created_by := coalesce(auth.uid(), new.created_by);
  elsif old.status <> 'draft' then
    raise exception 'Issued invoices cannot be edited. Cancel it and create a new one if something is wrong.' using errcode = '42501';
  end if;
  if not exists (select 1 from public.clients where id = new.client_id and org_id = new.org_id) then
    raise exception 'Client must belong to the same organization' using errcode = '23514'; end if;
  if new.contract_id is not null and not exists (select 1 from public.contracts where id = new.contract_id and client_id = new.client_id) then
    raise exception 'Contract must belong to the same client' using errcode = '23514'; end if;
  select state_code into v_seller from public.billing_settings where org_id = new.org_id;
  select state_code into v_client_state from public.client_billing where client_id = new.client_id;
  new.place_of_supply := coalesce(new.place_of_supply, v_client_state);
  new.tax_mode := case when v_seller is not null and new.place_of_supply is not null and v_seller <> new.place_of_supply then 'inter' else 'intra' end;
  return new;
end $$;
create trigger trg_inv_before before insert or update on public.invoices
  for each row execute function app.invoice_before_write();

create or replace function app.invoice_after_update() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform app.recalc_invoice(new.id);
  return new;
end $$;
-- place of supply changed on a draft -> CGST/SGST vs IGST may flip -> recompute the tax split
create trigger trg_inv_after after update on public.invoices
  for each row when (new.status = 'draft' and new.tax_mode is distinct from old.tax_mode)
  execute function app.invoice_after_update();

create or replace function app.invoice_delete_guard() returns trigger
language plpgsql set search_path = '' as $$
begin
  if old.status <> 'draft' then raise exception 'Only draft invoices can be deleted' using errcode = '42501'; end if;
  return old;
end $$;
create trigger trg_inv_delete before delete on public.invoices for each row execute function app.invoice_delete_guard();

create or replace function app.invoice_item_before_write() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_status public.invoice_status; v_inv uuid := coalesce(new.invoice_id, old.invoice_id);
begin
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
create trigger trg_ii_before before insert or update or delete on public.invoice_items
  for each row execute function app.invoice_item_before_write();

create or replace function app.invoice_item_after_write() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform app.recalc_invoice(coalesce(new.invoice_id, old.invoice_id));
  return null;
end $$;
create trigger trg_ii_after after insert or update or delete on public.invoice_items
  for each row execute function app.invoice_item_after_write();

-- ---------- RLS ----------
alter table public.billing_settings enable row level security;
alter table public.invoice_sequences enable row level security;
alter table public.invoices enable row level security;
alter table public.invoice_items enable row level security;
alter table public.payments enable row level security;

create policy bs_select on public.billing_settings for select to authenticated
  using (org_id = (select app.org_id()) and (select app.is_internal())
         and ((select app.has_perm('invoices.view')) or (select app.has_perm('invoices.manage'))));
create policy bs_write on public.billing_settings for all to authenticated
  using (org_id = (select app.org_id()) and (select app.has_perm('invoices.manage')))
  with check (org_id = (select app.org_id()) and (select app.has_perm('invoices.manage')));

create policy inv_select on public.invoices for select to authenticated using (app.can_view_invoice(id));
create policy inv_insert on public.invoices for insert to authenticated
  with check (org_id = (select app.org_id()) and (select app.has_perm('invoices.manage')));
create policy inv_update on public.invoices for update to authenticated
  using (org_id = (select app.org_id()) and (select app.has_perm('invoices.manage')) and status = 'draft')
  with check (org_id = (select app.org_id()) and (select app.has_perm('invoices.manage')));
create policy inv_delete on public.invoices for delete to authenticated
  using (org_id = (select app.org_id()) and (select app.has_perm('invoices.manage')) and status = 'draft');

create policy ii_select on public.invoice_items for select to authenticated using (app.can_view_invoice(invoice_id));
create policy ii_write on public.invoice_items for all to authenticated
  using (org_id = (select app.org_id()) and (select app.has_perm('invoices.manage')))
  with check ((select app.has_perm('invoices.manage'))
              and exists (select 1 from public.invoices i where i.id = invoice_id and i.org_id = (select app.org_id())));

create policy pay_select on public.payments for select to authenticated using (app.can_view_invoice(invoice_id));

grant select, insert on public.billing_settings to authenticated;
grant update (legal_name, gstin, pan, state_code, address, email, phone, invoice_prefix, default_sac, default_gst_rate,
  ad_spend_gst_rate, bank_details, terms) on public.billing_settings to authenticated;
grant select, insert, delete on public.invoices to authenticated;
grant update (client_id, contract_id, billing_period, due_date, place_of_supply, currency, notes) on public.invoices to authenticated;
grant select, insert, update, delete on public.invoice_items to authenticated;
grant select on public.payments to authenticated;

-- ---------- workflow functions ----------
create or replace function app.require_invoice_manager() returns void
language plpgsql stable security definer set search_path = '' as $$
begin
  if not (app.is_internal() and app.has_perm('invoices.manage')) then
    raise exception 'You need the invoices.manage permission' using errcode = '42501'; end if;
end $$;

create or replace function public.issue_invoice(p_invoice uuid, p_issue_date date default null) returns public.invoices
language plpgsql security definer set search_path = '' as $$
declare i public.invoices; s public.billing_settings; c public.clients; b public.client_billing; v_fy text; v_n int;
        v_today date; v_date date; v_org_name text;
begin
  perform app.require_invoice_manager();
  select * into i from public.invoices where id = p_invoice and org_id = app.org_id() for update;
  if i.id is null then raise exception 'Invoice not found' using errcode = 'P0002'; end if;
  if i.status <> 'draft' then raise exception 'Only draft invoices can be issued' using errcode = '22023'; end if;
  if not exists (select 1 from public.invoice_items where invoice_id = i.id) then
    raise exception 'Add at least one line before issuing' using errcode = '22023'; end if;
  perform app.recalc_invoice(i.id);
  select * into i from public.invoices where id = p_invoice;
  if i.total <= 0 then raise exception 'Invoice total must be more than zero' using errcode = '22023'; end if;
  v_today := app.org_today(i.org_id);
  v_date := coalesce(p_issue_date, v_today);
  if v_date > v_today then raise exception 'Issue date cannot be in the future' using errcode = '22023'; end if;
  if v_date < v_today - 30 then raise exception 'Issue date can be at most 30 days in the past' using errcode = '22023'; end if;

  insert into public.billing_settings(org_id) values (i.org_id) on conflict do nothing;
  select * into s from public.billing_settings where org_id = i.org_id;
  select * into c from public.clients where id = i.client_id;
  select * into b from public.client_billing where client_id = i.client_id;
  select name into v_org_name from public.organizations where id = i.org_id;

  v_fy := app.fiscal_year(v_date);
  insert into public.invoice_sequences(org_id, fiscal_year) values (i.org_id, v_fy) on conflict do nothing;
  update public.invoice_sequences set last_number = last_number + 1
   where org_id = i.org_id and fiscal_year = v_fy returning last_number into v_n;

  perform set_config('app.bypass_guards', 'on', true);
  update public.invoices set status = 'issued', fiscal_year = v_fy,
    invoice_number = s.invoice_prefix || '/' || v_fy || '/' || lpad(v_n::text, 4, '0'),
    issue_date = v_date,
    due_date = case when i.due_date is not null and i.due_date >= v_date then i.due_date
                    else v_date + coalesce(b.payment_terms_days, 15) end,
    issued_by = auth.uid(), issued_at = now(),
    seller = jsonb_strip_nulls(jsonb_build_object('name', coalesce(s.legal_name, v_org_name), 'gstin', s.gstin, 'pan', s.pan,
      'state_code', s.state_code, 'address', s.address, 'email', s.email, 'phone', s.phone, 'bank_details', s.bank_details, 'terms', s.terms)),
    buyer = jsonb_strip_nulls(jsonb_build_object('name', coalesce(nullif(b.billing_name, ''), c.legal_name, c.name), 'gstin', b.gst_number,
      'state_code', i.place_of_supply, 'address', b.billing_address, 'email', b.billing_email))
  where id = i.id returning * into i;
  perform set_config('app.bypass_guards', '', true);

  if b.billing_email is not null then
    perform app.queue_email(i.org_id, b.billing_email, coalesce(b.billing_name, c.name),
      'Invoice ' || i.invoice_number || ' from ' || coalesce(s.legal_name, v_org_name),
      concat_ws(E'\n\n', 'Hello,',
        'Please find invoice ' || i.invoice_number || ' dated ' || to_char(i.issue_date, 'DD Mon YYYY') || ' for ' || i.currency || ' '
          || to_char(i.total, 'FM99,99,99,99,990.00') || ', due on ' || to_char(i.due_date, 'DD Mon YYYY') || '.',
        case when app.app_link(i.org_id, '/invoices/' || i.id) <> '' then 'View it in your client portal: ' || app.app_link(i.org_id, '/invoices/' || i.id) end,
        nullif(s.bank_details, ''),
        'Thank you,' || E'\n' || coalesce(s.legal_name, v_org_name)),
      'invoice', 'invoice', i.id, 'invoice_issued:' || i.id);
  end if;
  return i;
end $$;

create or replace function public.cancel_invoice(p_invoice uuid, p_reason text) returns public.invoices
language plpgsql security definer set search_path = '' as $$
declare i public.invoices;
begin
  perform app.require_invoice_manager();
  select * into i from public.invoices where id = p_invoice and org_id = app.org_id() for update;
  if i.id is null then raise exception 'Invoice not found' using errcode = 'P0002'; end if;
  if i.status = 'draft' then raise exception 'Delete a draft instead of cancelling it' using errcode = '22023'; end if;
  if i.status = 'cancelled' then raise exception 'Invoice is already cancelled' using errcode = '22023'; end if;
  if exists (select 1 from public.payments where invoice_id = i.id) then
    raise exception 'Remove the recorded payments before cancelling this invoice' using errcode = '22023'; end if;
  if coalesce(length(trim(p_reason)), 0) < 5 then raise exception 'Give a reason (at least 5 characters)' using errcode = '22023'; end if;
  perform set_config('app.bypass_guards', 'on', true);
  update public.invoices set status = 'cancelled', cancelled_at = now(), cancel_reason = trim(p_reason) where id = i.id returning * into i;
  perform set_config('app.bypass_guards', '', true);
  return i;
end $$;

create or replace function app.refresh_invoice_payments(p_invoice uuid) returns public.invoices
language plpgsql security definer set search_path = '' as $$
declare i public.invoices; v_amt numeric; v_tds numeric;
begin
  select coalesce(sum(amount), 0), coalesce(sum(tds_amount), 0) into v_amt, v_tds from public.payments where invoice_id = p_invoice;
  perform set_config('app.bypass_guards', 'on', true);
  update public.invoices set amount_received = v_amt, tds_deducted = v_tds,
    status = case when total - v_amt - v_tds <= 0 then 'paid'::public.invoice_status
                  when v_amt + v_tds > 0 then 'partially_paid'::public.invoice_status
                  else 'issued'::public.invoice_status end
  where id = p_invoice returning * into i;
  perform set_config('app.bypass_guards', '', true);
  return i;
end $$;

create or replace function public.record_payment(p_invoice uuid, p_amount numeric, p_paid_on date, p_method text default 'bank_transfer',
  p_reference text default null, p_tds numeric default 0, p_note text default null) returns public.payments
language plpgsql security definer set search_path = '' as $$
declare i public.invoices; p public.payments;
begin
  perform app.require_invoice_manager();
  select * into i from public.invoices where id = p_invoice and org_id = app.org_id() for update;
  if i.id is null then raise exception 'Invoice not found' using errcode = 'P0002'; end if;
  if i.status not in ('issued','partially_paid') then raise exception 'Payments can only be recorded on issued, unpaid invoices' using errcode = '22023'; end if;
  if coalesce(p_amount, 0) < 0 or coalesce(p_tds, 0) < 0 or coalesce(p_amount, 0) + coalesce(p_tds, 0) <= 0 then
    raise exception 'Enter an amount received (and TDS, if any) greater than zero' using errcode = '22023'; end if;
  if round(coalesce(p_amount, 0) + coalesce(p_tds, 0), 2) > i.balance then
    raise exception 'This is more than the balance due (%)', i.balance using errcode = '22023'; end if;
  if p_paid_on is null or p_paid_on > app.org_today(i.org_id) then raise exception 'Payment date cannot be in the future' using errcode = '22023'; end if;
  if p_paid_on < i.issue_date - 90 then raise exception 'Payment date is too far before the invoice date' using errcode = '22023'; end if;
  begin
    insert into public.payments(org_id, invoice_id, amount, tds_amount, paid_on, method, reference, note, recorded_by)
    values (i.org_id, i.id, round(coalesce(p_amount, 0), 2), round(coalesce(p_tds, 0), 2), p_paid_on, coalesce(p_method, 'bank_transfer'),
            nullif(trim(p_reference), ''), nullif(trim(p_note), ''), auth.uid()) returning * into p;
  exception when unique_violation then
    raise exception 'A payment with this reference is already recorded on this invoice' using errcode = '23505';
  end;
  perform app.refresh_invoice_payments(i.id);
  return p;
end $$;

create or replace function public.delete_payment(p_payment uuid) returns public.invoices
language plpgsql security definer set search_path = '' as $$
declare p public.payments;
begin
  perform app.require_invoice_manager();
  select * into p from public.payments where id = p_payment and org_id = app.org_id();
  if p.id is null then raise exception 'Payment not found' using errcode = 'P0002'; end if;
  perform 1 from public.invoices where id = p.invoice_id for update;
  delete from public.payments where id = p.id;
  return app.refresh_invoice_payments(p.invoice_id);
end $$;

-- Draft invoice for a contract and month: the management fee line, plus (optionally) one ad-spend line
-- per platform from imported campaign data for that month. One invoice per contract per month.
create or replace function public.create_invoice_from_contract(p_contract uuid, p_period text, p_include_ad_spend boolean default false)
returns uuid language plpgsql security definer set search_path = '' as $$
declare k public.contracts; c public.clients; s public.billing_settings; v_inv uuid; v_start date; v_label text; r record; v_pos int := 1;
begin
  perform app.require_invoice_manager();
  select * into k from public.contracts where id = p_contract and org_id = app.org_id();
  if k.id is null then raise exception 'Contract not found' using errcode = 'P0002'; end if;
  if p_period !~ '^[0-9]{4}-(0[1-9]|1[0-2])$' then raise exception 'Period must look like 2026-11' using errcode = '22023'; end if;
  v_start := (p_period || '-01')::date;
  v_label := to_char(v_start, 'FMMonth YYYY');
  select * into c from public.clients where id = k.client_id;
  insert into public.billing_settings(org_id) values (k.org_id) on conflict do nothing;
  select * into s from public.billing_settings where org_id = k.org_id;
  begin
    insert into public.invoices(org_id, client_id, contract_id, billing_period, created_by)
    values (k.org_id, k.client_id, k.id, p_period, auth.uid()) returning id into v_inv;
  exception when unique_violation then
    raise exception 'An invoice for this contract and month already exists' using errcode = '23505';
  end;
  if k.management_fee > 0 then
    insert into public.invoice_items(org_id, invoice_id, kind, description, sac, quantity, unit_price, gst_rate, position)
    values (k.org_id, v_inv, 'management_fee', k.title || ' — ' || v_label, s.default_sac, 1, k.management_fee, s.default_gst_rate, v_pos);
    v_pos := v_pos + 1;
  end if;
  if p_include_ad_spend then
    for r in select cp.platform, sum(m.spend) as spend
             from public.campaign_metrics_daily m join public.campaigns cp on cp.id = m.campaign_id
             where cp.client_id = k.client_id and m.metric_date >= v_start and m.metric_date < (v_start + interval '1 month')::date
             group by cp.platform having sum(m.spend) > 0 order by cp.platform loop
      insert into public.invoice_items(org_id, invoice_id, kind, description, sac, quantity, unit_price, gst_rate, position)
      values (k.org_id, v_inv, 'ad_spend',
        'Ad spend — ' || case r.platform when 'google_ads' then 'Google Ads' when 'meta_ads' then 'Meta Ads' else 'Other platforms' end || ' — ' || v_label,
        s.default_sac, 1, round(r.spend, 2), s.ad_spend_gst_rate, v_pos);
      v_pos := v_pos + 1;
    end loop;
  end if;
  return v_inv;
end $$;

-- ---------- collections summary (SECURITY INVOKER: RLS applies, so clients see only their own) ----------
create or replace function public.get_finance_summary() returns jsonb
language plpgsql stable security invoker set search_path = '' as $$
declare v_today date := app.org_today(app.org_id()); v_month date; res jsonb;
begin
  v_month := date_trunc('month', v_today)::date;
  with open_inv as (select * from public.invoices where status in ('issued','partially_paid'))
  select jsonb_build_object(
    'today', v_today,
    'outstanding', coalesce((select sum(balance) from open_inv), 0),
    'overdue', coalesce((select sum(balance) from open_inv where due_date < v_today), 0),
    'overdue_count', (select count(*) from open_inv where due_date < v_today),
    'open_count', (select count(*) from open_inv),
    'draft_count', (select count(*) from public.invoices where status = 'draft'),
    'invoiced_this_month', coalesce((select sum(total) from public.invoices where status <> 'cancelled' and status <> 'draft' and issue_date >= v_month), 0),
    'fees_this_month', coalesce((select sum(fee_subtotal) from public.invoices where status not in ('cancelled','draft') and issue_date >= v_month), 0),
    'ad_spend_this_month', coalesce((select sum(ad_spend_subtotal) from public.invoices where status not in ('cancelled','draft') and issue_date >= v_month), 0),
    'collected_this_month', coalesce((select sum(amount) from public.payments where paid_on >= v_month), 0),
    'aging', jsonb_build_object(
      'current', coalesce((select sum(balance) from open_inv where due_date >= v_today), 0),
      'd1_30', coalesce((select sum(balance) from open_inv where v_today - due_date between 1 and 30), 0),
      'd31_60', coalesce((select sum(balance) from open_inv where v_today - due_date between 31 and 60), 0),
      'd61_90', coalesce((select sum(balance) from open_inv where v_today - due_date between 61 and 90), 0),
      'd90_plus', coalesce((select sum(balance) from open_inv where v_today - due_date > 90), 0)),
    'by_client', coalesce((select jsonb_agg(x order by x.balance desc) from (
        select o.client_id, cl.name, sum(o.balance) as balance, count(*) as invoices, min(o.due_date) as oldest_due
        from open_inv o join public.clients cl on cl.id = o.client_id group by o.client_id, cl.name
        order by sum(o.balance) desc limit 10) x), '[]'::jsonb)
  ) into res;
  return res;
end $$;

-- ---------- reminders (scheduled; idempotent through dedupe keys) ----------
-- Staff (account manager + invoices.manage) get in-app reminders; the client's billing e-mail gets
-- a reminder 3 days before the due date, on it, and 7 / 14 / 30 days after it.
create or replace function public.generate_invoice_reminders() returns integer
language plpgsql security definer set search_path = '' as $$
declare r record; a uuid; v_stage text; v_days int; v_n int := 0; v_link text; v_amt text;
begin
  for r in
    select i.*, c.name as client_name, m.profile_id as am, b.billing_email, b.billing_name, o.name as org_name,
           app.org_today(i.org_id) as today, coalesce(s.legal_name, o.name) as seller_name
    from public.invoices i join public.clients c on c.id = i.client_id
    join public.organizations o on o.id = i.org_id
    left join public.employee_profiles m on m.id = c.account_manager_id
    left join public.client_billing b on b.client_id = i.client_id
    left join public.billing_settings s on s.org_id = i.org_id
    where i.status in ('issued','partially_paid') and i.balance > 0
  loop
    v_days := r.today - r.due_date;
    v_stage := case when v_days = -3 then 'due_in_3' when v_days = 0 then 'due_today' when v_days = 7 then 'overdue_7'
                    when v_days = 14 then 'overdue_14' when v_days = 30 then 'overdue_30' end;
    continue when v_stage is null;
    v_amt := r.currency || ' ' || to_char(r.balance, 'FM99,99,99,99,990.00');
    for a in select r.am where r.am is not null union select app.profiles_with_perm(r.org_id, 'invoices.manage') loop
      perform app.notify(a, 'invoice_reminder',
        case when v_days > 0 then 'Overdue ' || v_days || ' days: ' else 'Payment due' || case when v_days = 0 then ' today: ' else ' in 3 days: ' end end
          || r.invoice_number || ' (' || r.client_name || ')',
        v_amt || ' outstanding', '/invoices/' || r.id, 'invoice', r.id, 'inv_rem:' || r.id || ':' || v_stage);
    end loop;
    if r.billing_email is not null then
      v_link := app.app_link(r.org_id, '/invoices/' || r.id);
      if app.queue_email(r.org_id, r.billing_email, coalesce(r.billing_name, r.client_name),
        case when v_days > 0 then 'Reminder: invoice ' || r.invoice_number || ' is overdue'
             else 'Reminder: invoice ' || r.invoice_number || ' is due ' || case when v_days = 0 then 'today' else 'on ' || to_char(r.due_date, 'DD Mon') end end,
        concat_ws(E'\n\n', 'Hello,',
          'This is a friendly reminder that ' || v_amt || ' is outstanding on invoice ' || r.invoice_number
            || ' dated ' || to_char(r.issue_date, 'DD Mon YYYY') || ', due on ' || to_char(r.due_date, 'DD Mon YYYY') || '.',
          case when v_link <> '' then 'View the invoice: ' || v_link end,
          'If you have already paid, please ignore this e-mail or reply with the payment reference.',
          'Thank you,' || E'\n' || r.seller_name),
        'invoice_reminder', 'invoice', r.id, 'inv_rem_mail:' || r.id || ':' || v_stage) then v_n := v_n + 1; end if;
    end if;
  end loop;
  return v_n;
end $$;
revoke execute on function public.generate_invoice_reminders() from public, anon, authenticated;
grant execute on function public.generate_invoice_reminders() to service_role;
do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('agency-os-invoice-reminders', '5 4 * * *', 'select public.generate_invoice_reminders()');
  end if;
end $$;

do $$ declare f text; begin
  foreach f in array array['issue_invoice(uuid,date)','cancel_invoice(uuid,text)',
    'record_payment(uuid,numeric,date,text,text,numeric,text)','delete_payment(uuid)',
    'create_invoice_from_contract(uuid,text,boolean)','get_finance_summary()'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop; end $$;

revoke execute on all functions in schema app from public, anon;
grant execute on all functions in schema app to authenticated, service_role;

-- ===== 20261028000014_payroll.sql =====
-- =====================================================================
-- 0014 PHASE 5: payroll runs and payslips
-- Monthly run from each employee's salary structure (latest revision
-- effective by month end), joining/exit dates, unpaid leave and,
-- optionally, unexplained absences. Calendar-day proration:
--   component × payable days ÷ days in month (rounded to the rupee).
-- Statutory rules (PF/ESI/PT/TDS) are not computed: they are entered as
-- salary components or per-payslip adjustments and must be checked by
-- your accountant.
-- Lifecycle: draft (editable, recalculable) → finalized (employees can
-- see their payslip) → paid. A finalized run can be reopened until paid.
-- =====================================================================

-- payslip details kept with the employee's private record (self + HR only)
alter table public.employee_private
  add column pan_number text check (pan_number is null or pan_number ~ '^[A-Z]{5}[0-9]{4}[A-Z]$'),
  add column uan_number text check (uan_number is null or uan_number ~ '^[0-9]{12}$'),
  add column bank_name text check (bank_name is null or length(bank_name) <= 80),
  add column bank_account_number text check (bank_account_number is null or bank_account_number ~ '^[0-9]{6,20}$'),
  add column bank_ifsc text check (bank_ifsc is null or bank_ifsc ~ '^[A-Z]{4}0[A-Z0-9]{6}$');

create table public.payroll_runs (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  period_month date not null check (extract(day from period_month) = 1),
  status text not null default 'draft' check (status in ('draft','finalized','paid')),
  absent_as_lop boolean not null default false,
  employees_count integer not null default 0,
  gross_total numeric(14,2) not null default 0,
  deductions_total numeric(14,2) not null default 0,
  net_total numeric(14,2) not null default 0,
  missing_salary jsonb not null default '[]'::jsonb,   -- employees skipped because they have no salary structure
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  finalized_by uuid references public.profiles(id) on delete set null,
  finalized_at timestamptz,
  paid_on date,
  paid_by uuid references public.profiles(id) on delete set null,
  unique (org_id, period_month)
);
create trigger trg_audit after insert or update or delete on public.payroll_runs for each row execute function app.audit();

create table public.payslips (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  run_id uuid not null references public.payroll_runs(id) on delete cascade,
  period_month date not null,
  employee_id uuid not null references public.employee_profiles(id) on delete restrict,
  employee_code text not null,
  employee_name text not null,
  designation text,
  department text,
  joining_date date,
  salary_revision_id uuid references public.salary_revisions(id) on delete set null,
  annual_ctc numeric(14,2),
  days_in_month smallint not null,
  payable_days numeric(5,1) not null,
  lop_days numeric(5,1) not null default 0,
  unpaid_leave_days numeric(5,1) not null default 0,
  absent_days numeric(5,1) not null default 0,
  earnings jsonb not null default '[]'::jsonb,      -- [{code, name, full, amount}]
  deductions jsonb not null default '[]'::jsonb,    -- [{code, name, full, amount}]
  adjustments jsonb not null default '[]'::jsonb,   -- [{label, kind: earning|deduction, amount}]
  gross numeric(14,2) not null default 0,
  total_deductions numeric(14,2) not null default 0,
  net_pay numeric(14,2) not null default 0,
  bank jsonb not null default '{}'::jsonb,           -- PAN/UAN/bank snapshot for the payslip and transfer sheet
  updated_at timestamptz not null default now(),
  unique (run_id, employee_id)
);
create index on public.payslips(employee_id, period_month desc);
create trigger trg_audit after insert or update or delete on public.payslips for each row execute function app.audit();

create or replace function app.payroll_released(p_run uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.payroll_runs where id = p_run and status in ('finalized','paid'))
$$;

alter table public.payroll_runs enable row level security;
alter table public.payslips enable row level security;
create policy pr_select on public.payroll_runs for select to authenticated
  using (org_id = (select app.org_id()) and (select app.is_internal())
         and ((select app.has_perm('payroll.view')) or (select app.has_perm('payroll.run'))));
create policy ps_select on public.payslips for select to authenticated using (
  org_id = (select app.org_id()) and (select app.is_internal()) and (
    (select app.has_perm('payroll.view')) or (select app.has_perm('payroll.run'))
    or (employee_id = (select app.my_employee_id()) and app.payroll_released(run_id))));
grant select on public.payroll_runs, public.payslips to authenticated;

-- ---------- pure-ish calculation helpers ----------
-- Payable / unpaid days of one employee in one month.
create or replace function app.payroll_days(p_employee uuid, p_month date, p_absent_as_lop boolean,
  out days_in_month int, out employed_days int, out unpaid_leave_days numeric, out absent_days numeric, out payable_days numeric)
language plpgsql stable security definer set search_path = '' as $$
declare e public.employee_profiles; v_end date; v_from date; v_to date; v_today date; d date; v_cover numeric; a public.attendance_records;
begin
  select * into e from public.employee_profiles where id = p_employee;
  v_end := (p_month + interval '1 month' - interval '1 day')::date;
  days_in_month := v_end - p_month + 1;
  v_from := greatest(p_month, e.joining_date);
  v_to := least(v_end, coalesce(e.exit_date, v_end));
  employed_days := greatest(0, v_to - v_from + 1);
  unpaid_leave_days := 0; absent_days := 0;
  if employed_days = 0 then payable_days := 0; return; end if;

  -- approved leave without pay, on working days only (half days count 0.5)
  select coalesce(sum(case when lr.half_day <> 'none' then 0.5 else 1 end), 0) into unpaid_leave_days
  from public.leave_requests lr join public.leave_types lt on lt.id = lr.leave_type_id and not lt.is_paid
  cross join lateral generate_series(greatest(lr.start_date, v_from), least(lr.end_date, v_to), interval '1 day') g(day)
  where lr.employee_id = p_employee and lr.status = 'approved' and app.is_working_day(p_employee, g.day::date);

  if p_absent_as_lop then
    v_today := app.org_today(e.org_id);
    d := v_from;
    while d <= least(v_to, v_today - 1) loop
      if app.is_working_day(p_employee, d) then
        select coalesce(max(case when lr.half_day <> 'none' then 0.5 else 1 end), 0) into v_cover
          from public.leave_requests lr where lr.employee_id = p_employee and lr.status = 'approved' and d between lr.start_date and lr.end_date;
        if v_cover < 1 then
          select * into a from public.attendance_records where employee_id = p_employee and work_date = d;
          if a.id is null or a.status = 'absent' then absent_days := absent_days + (1 - v_cover);
          elsif a.status = 'half_day' and v_cover = 0 then absent_days := absent_days + 0.5;
          end if;
        end if;
      end if;
      d := d + 1;
    end loop;
  end if;
  payable_days := greatest(0, employed_days - unpaid_leave_days - absent_days);
end $$;

-- (Re)computes one payslip, keeping manual adjustments. Returns false if the employee has no salary structure.
create or replace function app.compute_payslip(p_run uuid, p_employee uuid) returns boolean
language plpgsql security definer set search_path = '' as $$
declare r public.payroll_runs; e public.employee_profiles; sr public.salary_revisions; pv public.employee_private; v_end date; dd record;
        v_earn jsonb; v_ded jsonb; v_adj jsonb; v_gross numeric; v_tded numeric; v_ratio numeric;
begin
  select * into r from public.payroll_runs where id = p_run;
  select * into e from public.employee_profiles where id = p_employee;
  v_end := (r.period_month + interval '1 month' - interval '1 day')::date;
  select * into sr from public.salary_revisions where employee_id = p_employee and effective_from <= v_end
   order by effective_from desc limit 1;
  if sr.id is null then return false; end if;
  dd := app.payroll_days(p_employee, r.period_month, r.absent_as_lop);
  v_ratio := case when dd.days_in_month > 0 then dd.payable_days / dd.days_in_month else 0 end;

  with comp as (
    select j.key as code, j.value::numeric as full_amount, coalesce(sc.name, j.key) as name, coalesce(sc.kind, 'earning') as kind
    from jsonb_each_text(sr.monthly_components) j
    left join public.salary_components sc on sc.org_id = e.org_id and sc.code = j.key
    where j.value ~ '^-?[0-9]+(\.[0-9]+)?$' and j.value::numeric > 0
    union all
    -- no component breakup: pay the CTC as one line
    select 'SALARY', round(sr.annual_ctc / 12, 2), 'Salary', 'earning'
    where not exists (select 1 from jsonb_each_text(sr.monthly_components) j where j.value ~ '^-?[0-9]+(\.[0-9]+)?$' and j.value::numeric > 0)
      and sr.annual_ctc > 0)
  select coalesce(jsonb_agg(jsonb_build_object('code', code, 'name', name, 'full', full_amount, 'amount', round(full_amount * v_ratio))
                            order by code) filter (where kind = 'earning'), '[]'::jsonb),
         coalesce(jsonb_agg(jsonb_build_object('code', code, 'name', name, 'full', full_amount, 'amount', round(full_amount * v_ratio))
                            order by code) filter (where kind = 'deduction'), '[]'::jsonb)
    into v_earn, v_ded from comp;

  select adjustments into v_adj from public.payslips where run_id = p_run and employee_id = p_employee;
  v_adj := coalesce(v_adj, '[]'::jsonb);
  v_gross := coalesce((select sum((x->>'amount')::numeric) from jsonb_array_elements(v_earn) x), 0)
           + coalesce((select sum((x->>'amount')::numeric) from jsonb_array_elements(v_adj) x where x->>'kind' = 'earning'), 0);
  v_tded := coalesce((select sum((x->>'amount')::numeric) from jsonb_array_elements(v_ded) x), 0)
          + coalesce((select sum((x->>'amount')::numeric) from jsonb_array_elements(v_adj) x where x->>'kind' = 'deduction'), 0);
  select * into pv from public.employee_private where employee_id = p_employee;

  insert into public.payslips(org_id, run_id, period_month, employee_id, employee_code, employee_name, designation, department, joining_date,
    salary_revision_id, annual_ctc, days_in_month, payable_days, lop_days, unpaid_leave_days, absent_days, earnings, deductions, adjustments,
    gross, total_deductions, net_pay, bank)
  values (r.org_id, r.id, r.period_month, e.id, e.employee_code, e.full_name, e.designation,
    (select name from public.departments where id = e.department_id), e.joining_date, sr.id, sr.annual_ctc, dd.days_in_month, dd.payable_days,
    dd.unpaid_leave_days + dd.absent_days, dd.unpaid_leave_days, dd.absent_days, v_earn, v_ded, v_adj, v_gross, v_tded, v_gross - v_tded,
    jsonb_strip_nulls(jsonb_build_object('pan', pv.pan_number, 'uan', pv.uan_number, 'bank_name', pv.bank_name,
      'account_number', pv.bank_account_number, 'ifsc', pv.bank_ifsc)))
  on conflict (run_id, employee_id) do update set employee_code = excluded.employee_code, employee_name = excluded.employee_name,
    designation = excluded.designation, department = excluded.department, joining_date = excluded.joining_date,
    salary_revision_id = excluded.salary_revision_id, annual_ctc = excluded.annual_ctc, days_in_month = excluded.days_in_month,
    payable_days = excluded.payable_days, lop_days = excluded.lop_days, unpaid_leave_days = excluded.unpaid_leave_days,
    absent_days = excluded.absent_days, earnings = excluded.earnings, deductions = excluded.deductions,
    gross = excluded.gross, total_deductions = excluded.total_deductions, net_pay = excluded.net_pay, bank = excluded.bank, updated_at = now();
  return true;
end $$;

create or replace function app.refresh_payroll_totals(p_run uuid) returns void
language sql security definer set search_path = '' as $$
  update public.payroll_runs r set employees_count = x.n, gross_total = x.g, deductions_total = x.d, net_total = x.net
  from (select count(*) n, coalesce(sum(gross), 0) g, coalesce(sum(total_deductions), 0) d, coalesce(sum(net_pay), 0) net
        from public.payslips where run_id = p_run) x
  where r.id = p_run
$$;

-- Computes every eligible employee (employed during the month). Keeps adjustments; drops people no longer eligible.
create or replace function app.compute_payroll_run(p_run uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare r public.payroll_runs; emp record; v_end date; v_missing jsonb := '[]'::jsonb;
begin
  select * into r from public.payroll_runs where id = p_run;
  v_end := (r.period_month + interval '1 month' - interval '1 day')::date;
  delete from public.payslips p where p.run_id = r.id and not exists (
    select 1 from public.employee_profiles e where e.id = p.employee_id and e.joining_date <= v_end
      and (e.exit_date is null or e.exit_date >= r.period_month));
  for emp in select * from public.employee_profiles where org_id = r.org_id and joining_date <= v_end
           and (exit_date is null or exit_date >= r.period_month) order by employee_code loop
    if not app.compute_payslip(r.id, emp.id) then
      delete from public.payslips where run_id = r.id and employee_id = emp.id;
      v_missing := v_missing || jsonb_build_object('employee_id', emp.id, 'name', emp.full_name, 'code', emp.employee_code);
    end if;
  end loop;
  update public.payroll_runs set missing_salary = v_missing where id = r.id;
  perform app.refresh_payroll_totals(r.id);
end $$;

create or replace function app.require_payroll_runner() returns void
language plpgsql stable security definer set search_path = '' as $$
begin
  if not (app.is_internal() and app.has_perm('payroll.run')) then
    raise exception 'You need the payroll.run permission' using errcode = '42501'; end if;
end $$;

create or replace function app.lock_run(p_run uuid, p_status text) returns public.payroll_runs
language plpgsql security definer set search_path = '' as $$
declare r public.payroll_runs;
begin
  select * into r from public.payroll_runs where id = p_run and org_id = app.org_id() for update;
  if r.id is null then raise exception 'Payroll run not found' using errcode = 'P0002'; end if;
  if p_status is not null and r.status <> p_status then
    raise exception 'This payroll run is %', r.status using errcode = '22023'; end if;
  return r;
end $$;

-- ---------- public API ----------
create or replace function public.create_payroll_run(p_month date, p_absent_as_lop boolean default false) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_org uuid := app.org_id(); v_id uuid; v_month date := date_trunc('month', p_month)::date;
begin
  perform app.require_payroll_runner();
  if v_month > date_trunc('month', app.org_today(v_org))::date then
    raise exception 'Payroll can''t be run for a future month' using errcode = '22023'; end if;
  begin
    insert into public.payroll_runs(org_id, period_month, absent_as_lop, created_by)
    values (v_org, v_month, coalesce(p_absent_as_lop, false), auth.uid()) returning id into v_id;
  exception when unique_violation then
    raise exception 'A payroll run for % already exists', to_char(v_month, 'FMMonth YYYY') using errcode = '23505';
  end;
  perform app.compute_payroll_run(v_id);
  return v_id;
end $$;

create or replace function public.recalculate_payroll_run(p_run uuid, p_absent_as_lop boolean default null) returns public.payroll_runs
language plpgsql security definer set search_path = '' as $$
declare r public.payroll_runs;
begin
  perform app.require_payroll_runner();
  r := app.lock_run(p_run, 'draft');
  if p_absent_as_lop is not null then update public.payroll_runs set absent_as_lop = p_absent_as_lop where id = r.id; end if;
  perform app.compute_payroll_run(r.id);
  select * into r from public.payroll_runs where id = p_run;
  return r;
end $$;

create or replace function public.set_payslip_adjustments(p_payslip uuid, p_adjustments jsonb) returns public.payslips
language plpgsql security definer set search_path = '' as $$
declare p public.payslips; v_item jsonb;
begin
  perform app.require_payroll_runner();
  select * into p from public.payslips where id = p_payslip and org_id = app.org_id();
  if p.id is null then raise exception 'Payslip not found' using errcode = 'P0002'; end if;
  perform app.lock_run(p.run_id, 'draft');
  if jsonb_typeof(p_adjustments) <> 'array' or jsonb_array_length(p_adjustments) > 20 then
    raise exception 'Adjustments must be a list of at most 20 items' using errcode = '22023'; end if;
  for v_item in select * from jsonb_array_elements(p_adjustments) loop
    if coalesce(length(trim(v_item->>'label')), 0) not between 2 and 80 then raise exception 'Each adjustment needs a label' using errcode = '22023'; end if;
    if coalesce(v_item->>'kind', '') not in ('earning','deduction') then raise exception 'Adjustment kind must be earning or deduction' using errcode = '22023'; end if;
    if coalesce(v_item->>'amount', '') !~ '^[0-9]+(\.[0-9]{1,2})?$' or (v_item->>'amount')::numeric <= 0 or (v_item->>'amount')::numeric > 10000000 then
      raise exception 'Adjustment amounts must be positive numbers' using errcode = '22023'; end if;
  end loop;
  update public.payslips set adjustments = (select coalesce(jsonb_agg(jsonb_build_object('label', trim(x->>'label'), 'kind', x->>'kind',
      'amount', round((x->>'amount')::numeric, 2))), '[]'::jsonb) from jsonb_array_elements(p_adjustments) a(x))
   where id = p.id;
  perform app.compute_payslip(p.run_id, p.employee_id);
  perform app.refresh_payroll_totals(p.run_id);
  select * into p from public.payslips where id = p_payslip;
  return p;
end $$;

create or replace function public.finalize_payroll_run(p_run uuid) returns public.payroll_runs
language plpgsql security definer set search_path = '' as $$
declare r public.payroll_runs; s record;
begin
  perform app.require_payroll_runner();
  r := app.lock_run(p_run, 'draft');
  if not exists (select 1 from public.payslips where run_id = r.id) then
    raise exception 'There are no payslips in this run' using errcode = '22023'; end if;
  if exists (select 1 from public.payslips where run_id = r.id and net_pay < 0) then
    raise exception 'Some payslips have a negative net pay. Fix their adjustments first.' using errcode = '22023'; end if;
  update public.payroll_runs set status = 'finalized', finalized_by = auth.uid(), finalized_at = now() where id = r.id returning * into r;
  for s in select p.id, e.profile_id from public.payslips p join public.employee_profiles e on e.id = p.employee_id
           where p.run_id = r.id and e.profile_id is not null loop
    perform app.notify(s.profile_id, 'payslip_ready', 'Your payslip for ' || to_char(r.period_month, 'FMMonth YYYY') || ' is ready',
      null, '/payroll/payslips/' || s.id, 'payslip', s.id, 'payslip:' || s.id || ':' || extract(epoch from r.finalized_at)::bigint);
  end loop;
  return r;
end $$;

create or replace function public.reopen_payroll_run(p_run uuid) returns public.payroll_runs
language plpgsql security definer set search_path = '' as $$
declare r public.payroll_runs;
begin
  perform app.require_payroll_runner();
  r := app.lock_run(p_run, 'finalized');
  update public.payroll_runs set status = 'draft', finalized_by = null, finalized_at = null where id = r.id returning * into r;
  return r;
end $$;

create or replace function public.mark_payroll_paid(p_run uuid, p_paid_on date) returns public.payroll_runs
language plpgsql security definer set search_path = '' as $$
declare r public.payroll_runs;
begin
  perform app.require_payroll_runner();
  r := app.lock_run(p_run, 'finalized');
  if p_paid_on is null or p_paid_on > app.org_today(r.org_id) then raise exception 'Payment date cannot be in the future' using errcode = '22023'; end if;
  if p_paid_on < r.period_month then raise exception 'Payment date is before the payroll month' using errcode = '22023'; end if;
  update public.payroll_runs set status = 'paid', paid_on = p_paid_on, paid_by = auth.uid() where id = r.id returning * into r;
  return r;
end $$;

create or replace function public.delete_payroll_run(p_run uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare r public.payroll_runs;
begin
  perform app.require_payroll_runner();
  r := app.lock_run(p_run, 'draft');
  delete from public.payroll_runs where id = r.id;
end $$;

do $$ declare f text; begin
  foreach f in array array['create_payroll_run(date,boolean)','recalculate_payroll_run(uuid,boolean)',
    'set_payslip_adjustments(uuid,jsonb)','finalize_payroll_run(uuid)','reopen_payroll_run(uuid)',
    'mark_payroll_paid(uuid,date)','delete_payroll_run(uuid)'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop; end $$;

revoke execute on all functions in schema app from public, anon;
grant execute on all functions in schema app to authenticated, service_role;

-- ===== 20261028000015_recruitment.sql =====
-- =====================================================================
-- 0015 PHASE 5: recruitment — openings, candidates, interviews, offers,
-- and "hire" which turns an accepted offer into an employee record.
-- Visibility: recruitment.view / recruitment.manage see everything; an
-- opening's hiring manager sees its candidates; an interviewer sees the
-- candidates they interview. Offers (CTC) need a recruitment permission.
-- =====================================================================
create table public.job_openings (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  title text not null check (length(trim(title)) between 2 and 120),
  department_id uuid references public.departments(id) on delete set null,
  employment_type public.employment_type not null default 'full_time',
  location text check (location is null or length(location) <= 120),
  positions smallint not null default 1 check (positions between 1 and 100),
  description text,
  requirements text,
  salary_min numeric(14,2) check (salary_min is null or salary_min >= 0),
  salary_max numeric(14,2) check (salary_max is null or salary_max >= 0),
  status text not null default 'open' check (status in ('draft','open','on_hold','closed','filled')),
  hiring_manager_id uuid references public.employee_profiles(id) on delete set null,
  target_date date,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (salary_min is null or salary_max is null or salary_max >= salary_min)
);
create index on public.job_openings(org_id, status);
create trigger trg_jo_touch before update on public.job_openings for each row execute function app.touch_updated_at();
create trigger trg_audit after insert or update or delete on public.job_openings for each row execute function app.audit();

create table public.candidates (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  opening_id uuid not null references public.job_openings(id) on delete restrict,
  full_name text not null check (length(trim(full_name)) between 2 and 120),
  email text check (email is null or email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  phone text check (phone is null or length(phone) <= 30),
  source text not null default 'other' check (source in ('referral','linkedin','naukri','indeed','website','walk_in','agency','other')),
  referred_by uuid references public.employee_profiles(id) on delete set null,
  current_company text,
  experience_years numeric(4,1) check (experience_years is null or experience_years between 0 and 60),
  current_ctc numeric(14,2) check (current_ctc is null or current_ctc >= 0),
  expected_ctc numeric(14,2) check (expected_ctc is null or expected_ctc >= 0),
  notice_period_days smallint check (notice_period_days is null or notice_period_days between 0 and 365),
  location text,
  portfolio_url text check (portfolio_url is null or portfolio_url ~* '^https?://'),
  resume_path text unique,
  resume_name text,
  stage text not null default 'applied' check (stage in ('applied','screening','interview','offer','hired','rejected','withdrawn')),
  rejection_reason text,
  rating smallint check (rating is null or rating between 1 and 5),
  notes text,
  employee_id uuid references public.employee_profiles(id) on delete set null,
  stage_changed_at timestamptz not null default now(),
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index on public.candidates(opening_id, stage);
create index on public.candidates(org_id, created_at desc);
create unique index candidates_one_per_opening on public.candidates(opening_id, lower(email)) where email is not null;
create trigger trg_cand_touch before update on public.candidates for each row execute function app.touch_updated_at();
create trigger trg_audit after insert or update or delete on public.candidates for each row execute function app.audit();

create table public.interviews (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  candidate_id uuid not null references public.candidates(id) on delete cascade,
  round_name text not null check (length(trim(round_name)) between 2 and 80),
  scheduled_at timestamptz not null,
  duration_minutes smallint not null default 45 check (duration_minutes between 15 and 480),
  mode text not null default 'video' check (mode in ('in_person','video','phone')),
  location text check (location is null or length(location) <= 300),
  interviewer_id uuid not null references public.profiles(id) on delete restrict,
  status text not null default 'scheduled' check (status in ('scheduled','completed','cancelled','no_show')),
  rating smallint check (rating is null or rating between 1 and 5),
  recommendation text check (recommendation is null or recommendation in ('strong_yes','yes','no','strong_no')),
  feedback text,
  feedback_at timestamptz,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
create index on public.interviews(candidate_id);
create index on public.interviews(interviewer_id, scheduled_at);
create trigger trg_audit after insert or update or delete on public.interviews for each row execute function app.audit();

create table public.offers (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  candidate_id uuid not null references public.candidates(id) on delete cascade,
  designation text not null check (length(trim(designation)) between 2 and 120),
  department_id uuid references public.departments(id) on delete set null,
  annual_ctc numeric(14,2) not null check (annual_ctc > 0),
  joining_date date not null,
  offer_date date not null default current_date,
  valid_until date,
  status text not null default 'draft' check (status in ('draft','sent','accepted','declined','withdrawn')),
  letter_text text check (letter_text is null or length(letter_text) <= 20000),
  decided_at timestamptz,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (valid_until is null or valid_until >= offer_date)
);
create unique index offers_one_open_per_candidate on public.offers(candidate_id) where status in ('draft','sent','accepted');
create trigger trg_offer_touch before update on public.offers for each row execute function app.touch_updated_at();
create trigger trg_audit after insert or update or delete on public.offers for each row execute function app.audit();

-- ---------- visibility helpers ----------
create or replace function app.can_view_opening(p_opening uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select app.is_internal() and exists (select 1 from public.job_openings o where o.id = p_opening and o.org_id = app.org_id()
    and (app.has_perm('recruitment.view') or app.has_perm('recruitment.manage')
         or (o.hiring_manager_id is not null and o.hiring_manager_id = app.my_employee_id())))
$$;

create or replace function app.can_view_candidate(p_candidate uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select app.is_internal() and exists (select 1 from public.candidates c where c.id = p_candidate and c.org_id = app.org_id()
    and (app.can_view_opening(c.opening_id)
         or exists (select 1 from public.interviews i where i.candidate_id = c.id and i.interviewer_id = auth.uid())))
$$;

create or replace function app.recruiter() returns boolean
language sql stable security definer set search_path = '' as $$
  select app.is_internal() and app.has_perm('recruitment.manage')
$$;

-- ---------- integrity triggers ----------
create or replace function app.opening_before_write() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.department_id is not null and not exists (select 1 from public.departments where id = new.department_id and org_id = new.org_id) then
    raise exception 'Department must belong to the same organization' using errcode = '23514'; end if;
  if new.hiring_manager_id is not null and not exists (select 1 from public.employee_profiles where id = new.hiring_manager_id
      and org_id = new.org_id and status <> 'exited') then
    raise exception 'Hiring manager must be a current employee' using errcode = '23514'; end if;
  return new;
end $$;
create trigger trg_jo_before before insert or update on public.job_openings for each row execute function app.opening_before_write();

create or replace function app.candidate_before_write() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  new.email := nullif(lower(trim(new.email)), '');
  if not exists (select 1 from public.job_openings where id = new.opening_id and org_id = new.org_id) then
    raise exception 'Opening must belong to the same organization' using errcode = '23514'; end if;
  if tg_op = 'INSERT' then
    if new.stage not in ('applied','screening') then new.stage := 'applied'; end if;
    new.employee_id := null;
    new.created_by := coalesce(auth.uid(), new.created_by);
  elsif new.stage is distinct from old.stage then
    if old.stage = 'hired' then raise exception 'A hired candidate can''t be moved to another stage' using errcode = '22023'; end if;
    if new.stage = 'hired' and not app.guards_bypassed() then
      raise exception 'Use "Hire" on an accepted offer to mark someone as hired' using errcode = '22023'; end if;
    new.stage_changed_at := now();
  end if;
  if tg_op = 'UPDATE' and new.employee_id is distinct from old.employee_id and not app.guards_bypassed() then
    raise exception 'The employee link is set by hiring' using errcode = '42501'; end if;
  if new.stage = 'rejected' and coalesce(length(trim(new.rejection_reason)), 0) < 3 then
    raise exception 'Give a rejection reason' using errcode = '22023'; end if;
  if new.referred_by is not null and not exists (select 1 from public.employee_profiles where id = new.referred_by and org_id = new.org_id) then
    raise exception 'Referrer must be an employee of the same organization' using errcode = '23514'; end if;
  if new.resume_path is not null
     and (split_part(new.resume_path, '/', 1) <> new.org_id::text or split_part(new.resume_path, '/', 2) <> 'recruitment') then
    raise exception 'Invalid resume path' using errcode = '42501'; end if;
  return new;
end $$;
create trigger trg_cand_before before insert or update on public.candidates for each row execute function app.candidate_before_write();

create or replace function app.interview_before_write() returns trigger
language plpgsql security definer set search_path = '' as $$
declare c public.candidates;
begin
  select * into c from public.candidates where id = new.candidate_id;
  new.org_id := c.org_id;
  if c.stage in ('hired','rejected','withdrawn') and (tg_op = 'INSERT' or new.scheduled_at is distinct from old.scheduled_at) then
    raise exception 'This candidate is no longer in the pipeline' using errcode = '22023'; end if;
  if not exists (select 1 from public.profiles where id = new.interviewer_id and org_id = c.org_id and client_id is null and is_active) then
    raise exception 'Interviewer must be an active team member' using errcode = '23514'; end if;
  if tg_op = 'INSERT' then new.created_by := coalesce(auth.uid(), new.created_by); new.status := 'scheduled'; end if;
  if tg_op = 'UPDATE' and not app.guards_bypassed() and (new.rating is distinct from old.rating or new.recommendation is distinct from old.recommendation
      or new.feedback is distinct from old.feedback or new.feedback_at is distinct from old.feedback_at) then
    raise exception 'Feedback is submitted by the interviewer' using errcode = '42501'; end if;
  return new;
end $$;
create trigger trg_iv_before before insert or update on public.interviews for each row execute function app.interview_before_write();

create or replace function app.interview_after_write() returns trigger
language plpgsql security definer set search_path = '' as $$
declare c public.candidates; v_tz text;
begin
  select * into c from public.candidates where id = new.candidate_id;
  select timezone into v_tz from public.organizations where id = new.org_id;
  if tg_op = 'INSERT' and c.stage in ('applied','screening') then
    update public.candidates set stage = 'interview' where id = c.id;
  end if;
  if new.status = 'scheduled' and (tg_op = 'INSERT' or new.scheduled_at is distinct from old.scheduled_at or new.interviewer_id is distinct from old.interviewer_id) then
    perform app.notify(new.interviewer_id, 'interview_scheduled', 'Interview: ' || c.full_name || ' (' || new.round_name || ')',
      to_char(new.scheduled_at at time zone v_tz, 'Dy DD Mon, HH12:MI AM') || ' · ' || replace(new.mode, '_', ' ')
        || coalesce(' · ' || new.location, ''),
      '/recruitment/candidates/' || c.id, 'interview', new.id, 'interview:' || new.id || ':' || extract(epoch from new.scheduled_at)::bigint
        || ':' || new.interviewer_id);
  end if;
  return new;
end $$;
create trigger trg_iv_after after insert or update on public.interviews for each row execute function app.interview_after_write();

create or replace function app.offer_before_write() returns trigger
language plpgsql security definer set search_path = '' as $$
declare c public.candidates;
begin
  select * into c from public.candidates where id = new.candidate_id;
  new.org_id := c.org_id;
  if new.department_id is not null and not exists (select 1 from public.departments where id = new.department_id and org_id = new.org_id) then
    raise exception 'Department must belong to the same organization' using errcode = '23514'; end if;
  if tg_op = 'INSERT' then
    if c.stage in ('hired','rejected','withdrawn') then raise exception 'This candidate is no longer in the pipeline' using errcode = '22023'; end if;
    new.status := 'draft'; new.decided_at := null; new.created_by := coalesce(auth.uid(), new.created_by);
  elsif not app.guards_bypassed() then
    if new.status is distinct from old.status then
      raise exception 'Use the offer actions to change its status' using errcode = '42501'; end if;
    if old.status <> 'draft' then raise exception 'Only draft offers can be edited' using errcode = '42501'; end if;
  end if;
  return new;
end $$;
create trigger trg_offer_before before insert or update on public.offers for each row execute function app.offer_before_write();

-- ---------- RLS ----------
alter table public.job_openings enable row level security;
alter table public.candidates enable row level security;
alter table public.interviews enable row level security;
alter table public.offers enable row level security;

create policy jo_select on public.job_openings for select to authenticated using (app.can_view_opening(id));
create policy jo_write on public.job_openings for all to authenticated
  using (org_id = (select app.org_id()) and (select app.recruiter()))
  with check (org_id = (select app.org_id()) and (select app.recruiter()));
create policy cand_select on public.candidates for select to authenticated using (app.can_view_candidate(id));
create policy cand_write on public.candidates for all to authenticated
  using (org_id = (select app.org_id()) and (select app.recruiter()))
  with check (org_id = (select app.org_id()) and (select app.recruiter()));
create policy iv_select on public.interviews for select to authenticated
  using (interviewer_id = auth.uid() or app.can_view_candidate(candidate_id));
create policy iv_write on public.interviews for all to authenticated
  using (org_id = (select app.org_id()) and (select app.recruiter()))
  with check (org_id = (select app.org_id()) and (select app.recruiter()));
create policy offer_select on public.offers for select to authenticated
  using (org_id = (select app.org_id()) and (select app.is_internal())
         and ((select app.has_perm('recruitment.view')) or (select app.has_perm('recruitment.manage'))));
create policy offer_write on public.offers for all to authenticated
  using (org_id = (select app.org_id()) and (select app.recruiter()))
  with check (org_id = (select app.org_id()) and (select app.recruiter()));

grant select, insert, update, delete on public.job_openings, public.candidates, public.offers to authenticated;
grant select, insert, delete on public.interviews to authenticated;
grant update (round_name, scheduled_at, duration_minutes, mode, location, interviewer_id, status) on public.interviews to authenticated;

-- openings with pipeline counts (SECURITY INVOKER: callers only see what RLS allows)
create view public.opening_pipeline with (security_invoker = true) as
select o.id, o.org_id, o.title, o.department_id, o.employment_type, o.location, o.positions, o.status, o.hiring_manager_id,
       o.target_date, o.created_at,
       count(c.id) filter (where c.stage not in ('rejected','withdrawn','hired')) as active,
       count(c.id) filter (where c.stage = 'applied') as applied,
       count(c.id) filter (where c.stage = 'screening') as screening,
       count(c.id) filter (where c.stage = 'interview') as interview,
       count(c.id) filter (where c.stage = 'offer') as offer,
       count(c.id) filter (where c.stage = 'hired') as hired,
       count(c.id) filter (where c.stage in ('rejected','withdrawn')) as closed
from public.job_openings o left join public.candidates c on c.opening_id = o.id
group by o.id;
grant select on public.opening_pipeline to authenticated;

-- ---------- actions ----------
create or replace function public.submit_interview_feedback(p_interview uuid, p_rating smallint, p_recommendation text,
  p_feedback text, p_status text default 'completed') returns public.interviews
language plpgsql security definer set search_path = '' as $$
declare iv public.interviews; v_to uuid;
begin
  select * into iv from public.interviews where id = p_interview and org_id = app.org_id() for update;
  if iv.id is null then raise exception 'Interview not found' using errcode = 'P0002'; end if;
  if not (iv.interviewer_id = auth.uid() or app.recruiter()) then
    raise exception 'Only the interviewer or a recruiter can submit feedback' using errcode = '42501'; end if;
  if p_status not in ('completed','no_show') then raise exception 'Status must be completed or no-show' using errcode = '22023'; end if;
  if p_status = 'completed' then
    if p_rating is null or p_rating not between 1 and 5 then raise exception 'Rate the candidate from 1 to 5' using errcode = '22023'; end if;
    if p_recommendation not in ('strong_yes','yes','no','strong_no') then raise exception 'Choose a recommendation' using errcode = '22023'; end if;
    if coalesce(length(trim(p_feedback)), 0) < 10 then raise exception 'Write at least a sentence of feedback' using errcode = '22023'; end if;
  end if;
  if iv.scheduled_at > now() + interval '1 hour' then raise exception 'Feedback can be submitted once the interview has happened' using errcode = '22023'; end if;
  perform set_config('app.bypass_guards', 'on', true);
  update public.interviews set status = p_status, rating = case when p_status = 'completed' then p_rating end,
    recommendation = case when p_status = 'completed' then p_recommendation end,
    feedback = nullif(trim(p_feedback), ''), feedback_at = now()
  where id = iv.id returning * into iv;
  perform set_config('app.bypass_guards', '', true);
  for v_to in select x from app.profiles_with_perm(iv.org_id, 'recruitment.manage') x loop
    perform app.notify(v_to, 'interview_feedback', 'Interview feedback submitted', iv.round_name,
      '/recruitment/candidates/' || iv.candidate_id, 'interview', iv.id, 'iv_feedback:' || iv.id);
  end loop;
  return iv;
end $$;

-- draft -> sent -> accepted | declined; anything open -> withdrawn
create or replace function public.set_offer_status(p_offer uuid, p_status text) returns public.offers
language plpgsql security definer set search_path = '' as $$
declare o public.offers; c public.candidates; v_ok boolean;
begin
  if not app.recruiter() then raise exception 'You need the recruitment.manage permission' using errcode = '42501'; end if;
  select * into o from public.offers where id = p_offer and org_id = app.org_id() for update;
  if o.id is null then raise exception 'Offer not found' using errcode = 'P0002'; end if;
  select * into c from public.candidates where id = o.candidate_id;
  v_ok := (o.status = 'draft' and p_status in ('sent','withdrawn'))
       or (o.status = 'sent' and p_status in ('accepted','declined','withdrawn'))
       or (o.status = 'accepted' and p_status = 'withdrawn' and c.stage <> 'hired');
  if not v_ok then raise exception 'An offer that is % can''t be marked %', o.status, p_status using errcode = '22023'; end if;
  perform set_config('app.bypass_guards', 'on', true);
  update public.offers set status = p_status,
    offer_date = case when p_status = 'sent' then app.org_today(o.org_id) else offer_date end,
    decided_at = case when p_status in ('accepted','declined','withdrawn') then now() end
  where id = o.id returning * into o;
  if p_status = 'sent' then
    update public.candidates set stage = 'offer' where id = c.id and stage not in ('offer','hired');
    if c.email is not null and o.letter_text is not null then
      perform app.queue_email(o.org_id, c.email, c.full_name, 'Offer of employment — ' || o.designation,
        o.letter_text, 'offer', 'offer', o.id, 'offer_sent:' || o.id);
    end if;
  elsif p_status = 'declined' then
    update public.candidates set stage = 'withdrawn', rejection_reason = coalesce(rejection_reason, 'Declined the offer') where id = c.id;
  end if;
  perform set_config('app.bypass_guards', '', true);
  return o;
end $$;

-- Accepted offer -> employee record (onboarding), first salary revision, candidate marked hired.
create or replace function public.hire_candidate(p_candidate uuid, p_work_email text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare c public.candidates; o public.offers; j public.job_openings; v_emp uuid; v_month numeric; v_basic numeric; v_hra numeric;
begin
  if not (app.recruiter() and app.has_perm('employees.create')) then
    raise exception 'You need recruitment.manage and employees.create to hire' using errcode = '42501'; end if;
  select * into c from public.candidates where id = p_candidate and org_id = app.org_id() for update;
  if c.id is null then raise exception 'Candidate not found' using errcode = 'P0002'; end if;
  if c.stage = 'hired' then raise exception 'Already hired' using errcode = '22023'; end if;
  select * into o from public.offers where candidate_id = c.id and status = 'accepted';
  if o.id is null then raise exception 'The candidate needs an accepted offer first' using errcode = '22023'; end if;
  select * into j from public.job_openings where id = c.opening_id;
  if coalesce(trim(p_work_email), '') !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter a valid work e-mail' using errcode = '22023'; end if;
  if exists (select 1 from public.employee_profiles where org_id = c.org_id and lower(work_email) = lower(trim(p_work_email))) then
    raise exception 'An employee with this work e-mail already exists' using errcode = '23505'; end if;

  insert into public.employee_profiles(org_id, employee_code, full_name, work_email, work_phone, department_id, designation,
    reporting_manager_id, employment_type, status, joining_date)
  values (c.org_id, '', c.full_name, lower(trim(p_work_email)), c.phone, coalesce(o.department_id, j.department_id), o.designation,
    j.hiring_manager_id, j.employment_type, 'onboarding', o.joining_date)
  returning id into v_emp;

  if app.has_perm('salary.edit') then
    v_month := round(o.annual_ctc / 12, 2);
    v_basic := round(v_month * 0.5); v_hra := round(v_month * 0.2);
    insert into public.salary_revisions(org_id, employee_id, effective_from, annual_ctc, monthly_components, reason, created_by)
    values (c.org_id, v_emp, o.joining_date, o.annual_ctc,
      jsonb_build_object('BASIC', v_basic, 'HRA', v_hra, 'SPECIAL', v_month - v_basic - v_hra), 'Offer accepted', auth.uid());
  end if;

  perform set_config('app.bypass_guards', 'on', true);
  update public.candidates set stage = 'hired', employee_id = v_emp where id = c.id;
  if (select count(*) from public.candidates where opening_id = j.id and stage = 'hired') >= j.positions then
    update public.job_openings set status = 'filled' where id = j.id;
  end if;
  perform set_config('app.bypass_guards', '', true);
  return v_emp;
end $$;

do $$ declare f text; begin
  foreach f in array array['submit_interview_feedback(uuid,smallint,text,text,text)','set_offer_status(uuid,text)',
    'hire_candidate(uuid,text)'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop; end $$;

revoke execute on all functions in schema app from public, anon;
grant execute on all functions in schema app to authenticated, service_role;

-- ===== 20261028000016_phase5_defaults.sql =====
-- =====================================================================
-- 0016 PHASE 5: default role permissions, storage area for résumés,
-- and backfill for organizations created before this release.
-- =====================================================================

create or replace function app.seed_phase5_defaults(p_org uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform set_config('app.bypass_guards', 'on', true);
  insert into public.role_permissions(role_id, permission_key, org_id)
  select ro.id, x.perm, p_org
  from (values
    ('super_admin', array['invoices.view','invoices.manage','payroll.view','payroll.run','recruitment.view','recruitment.manage']),
    ('agency_owner', array['invoices.view','invoices.manage','payroll.view','payroll.run','recruitment.view','recruitment.manage']),
    ('hr_manager', array['payroll.view','payroll.run','recruitment.view','recruitment.manage']),
    ('accounts_manager', array['invoices.view','invoices.manage','payroll.view'])
  ) as v(role_key, perms)
  cross join lateral unnest(v.perms) as x(perm)
  join public.roles ro on ro.org_id = p_org and ro.key = v.role_key
  on conflict do nothing;
  insert into public.billing_settings(org_id, legal_name)
  select id, name from public.organizations where id = p_org on conflict do nothing;
  insert into public.email_settings(org_id) values (p_org) on conflict do nothing;
  perform set_config('app.bypass_guards', '', true);
end $$;

-- new organizations: same body as 0008 plus Phase 5 defaults
create or replace function app.seed_org_defaults(p_org uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare r record;
begin
  perform set_config('app.bypass_guards', 'on', true);
  for r in select * from (values
    ('super_admin','Super Admin', false, array(select key from public.permissions)),
    ('agency_owner','Agency Owner', false, array(select key from public.permissions)),
    ('hr_manager','HR Manager', false, array['users.manage','departments.manage','employees.view','employees.create','employees.edit',
      'employees.delete','employees.export','employees.view_sensitive','salary.view','salary.edit','attendance.view_all',
      'attendance.approve','attendance.manage_policy','attendance.export','leave.view_all','leave.approve','leave.manage_policy',
      'leave.export','holidays.manage','announcements.manage','reports.view']),
    ('project_manager','Project Manager', false, array['employees.view','clients.view','clients.create','clients.edit',
      'projects.view_all','projects.create','projects.edit','projects.delete','projects.export','tasks.view_all','tasks.create',
      'tasks.edit_all','tasks.delete','tasks.manage_statuses','reports.view']),
    ('team_leader','Team Leader', false, array['employees.view','clients.view','projects.view_all','tasks.view_all','tasks.create',
      'tasks.edit_all','tasks.delete','reports.view']),
    ('dm_executive','Digital Marketing Executive', false, array['employees.view','tasks.create']),
    ('seo_executive','SEO Executive', false, array['employees.view','tasks.create']),
    ('graphic_designer','Graphic Designer', false, array['employees.view','tasks.create']),
    ('video_editor','Video Editor', false, array['employees.view','tasks.create']),
    ('social_media_manager','Social Media Manager', false, array['employees.view','tasks.create']),
    ('accounts_manager','Accounts Manager', false, array['employees.view','salary.view','clients.view','clients.view_billing','reports.view']),
    ('client','Client', true, array[]::text[])
  ) as v(key, name, is_client, perms) loop
    insert into public.roles(org_id, key, name, is_system, is_client_role)
    values (p_org, r.key, r.name, true, r.is_client) on conflict (org_id, key) do nothing;
    insert into public.role_permissions(role_id, permission_key, org_id)
    select ro.id, unnest(r.perms), p_org from public.roles ro where ro.org_id = p_org and ro.key = r.key
    on conflict do nothing;
  end loop;

  insert into public.task_statuses(org_id, key, name, category, position, color, is_default) values
    (p_org,'todo','To Do','todo',1,'#64748b',true),
    (p_org,'in_progress','In Progress','in_progress',2,'#2563eb',false),
    (p_org,'in_review','In Review','review',3,'#d97706',false),
    (p_org,'changes_requested','Changes Requested','changes_requested',4,'#dc2626',false),
    (p_org,'completed','Completed','done',5,'#16a34a',false)
  on conflict do nothing;

  insert into public.work_schedules(org_id, name, is_default) values (p_org, 'General shift', true) on conflict do nothing;

  insert into public.leave_types(org_id, code, name, annual_quota, is_paid, allow_half_day, color) values
    (p_org,'CL','Casual Leave',12,true,true,'#0ea5e9'),
    (p_org,'SL','Sick Leave',6,true,true,'#f97316'),
    (p_org,'EL','Earned Leave',15,true,false,'#22c55e'),
    (p_org,'LWP','Leave Without Pay',null,false,true,'#94a3b8')
  on conflict do nothing;

  insert into public.salary_components(org_id, code, name, kind) values
    (p_org,'BASIC','Basic','earning'),(p_org,'HRA','House Rent Allowance','earning'),
    (p_org,'SPECIAL','Special Allowance','earning'),(p_org,'PF_EMP','Employee PF','deduction'),
    (p_org,'PT','Professional Tax','deduction')
  on conflict do nothing;

  insert into public.departments(org_id, name)
  select p_org, d from unnest(array['Management','Performance Marketing','SEO','Creative','Social Media','Web Development','HR & Admin','Accounts']) d
  on conflict do nothing;
  perform app.seed_phase4_defaults(p_org);
  perform app.seed_phase5_defaults(p_org);
  perform set_config('app.bypass_guards', '', true);
end $$;

-- ---------- storage: résumés under {org_id}/recruitment/{candidate_id}/... ----------
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
    when 'recruitment' then app.can_view_candidate(parts[3]::uuid)
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
    when 'recruitment' then app.recruiter() and exists (select 1 from public.candidates c where c.id = parts[3]::uuid and c.org_id = app.org_id())
    else false end;
exception when invalid_text_representation then return false;
end $$;

-- existing organizations (e.g. the live one) get the same Phase 5 defaults
do $$ declare o record; begin
  for o in select id from public.organizations loop perform app.seed_phase5_defaults(o.id); end loop;
end $$;

revoke execute on all functions in schema app from public, anon;
grant execute on all functions in schema app to authenticated, service_role;

commit;
