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
