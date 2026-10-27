-- =====================================================================
-- 0011 PHASE 4: ad campaign tracking (Google / Meta) with CSV import
-- Ad spend lives here and is never mixed with the agency's management
-- fee (contracts.management_fee, billing permission only).
-- Duplicate protection: one metrics row per campaign per day, and the
-- same file (SHA-256) cannot be imported twice.
-- =====================================================================
create table public.campaigns (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  client_id uuid not null references public.clients(id) on delete cascade,
  project_id uuid references public.projects(id) on delete set null,
  platform text not null check (platform in ('google_ads','meta_ads','other')),
  name text not null check (length(trim(name)) between 2 and 200),
  external_id text check (external_id is null or length(external_id) between 1 and 64),
  objective text,
  status text not null default 'active' check (status in ('draft','active','paused','ended')),
  start_date date,
  end_date date,
  monthly_budget numeric(14,2) check (monthly_budget is null or monthly_budget >= 0),  -- ad spend budget (client's money)
  currency char(3) not null default 'INR',
  client_visible boolean not null default true,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (end_date is null or start_date is null or end_date >= start_date)
);
create unique index campaigns_external on public.campaigns(org_id, platform, external_id) where external_id is not null;
create unique index campaigns_client_name on public.campaigns(client_id, platform, lower(name));
create index on public.campaigns(client_id);
create trigger trg_camp_touch before update on public.campaigns for each row execute function app.touch_updated_at();
create trigger trg_audit after insert or update or delete on public.campaigns for each row execute function app.audit();

create table public.campaign_imports (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  client_id uuid not null references public.clients(id) on delete cascade,
  platform text not null,
  file_name text not null,
  file_sha256 text not null check (file_sha256 ~ '^[0-9a-f]{64}$'),
  rows_total integer not null default 0,
  rows_inserted integer not null default 0,
  rows_updated integer not null default 0,
  rows_skipped integer not null default 0,
  campaigns_created integer not null default 0,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (org_id, file_sha256)
);

create table public.campaign_metrics_daily (
  campaign_id uuid not null references public.campaigns(id) on delete cascade,
  metric_date date not null,
  org_id uuid not null references public.organizations(id) on delete cascade,
  impressions bigint not null default 0 check (impressions >= 0),
  clicks bigint not null default 0 check (clicks >= 0),
  spend numeric(14,2) not null default 0 check (spend >= 0),
  conversions numeric(12,2) not null default 0 check (conversions >= 0),
  conversion_value numeric(14,2) not null default 0 check (conversion_value >= 0),
  import_id uuid references public.campaign_imports(id) on delete set null,
  updated_at timestamptz not null default now(),
  primary key (campaign_id, metric_date),
  check (clicks <= impressions or impressions = 0)
);
create index on public.campaign_metrics_daily(org_id, metric_date);

create or replace function app.campaign_before_write() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.clients where id = new.client_id and org_id = new.org_id) then
    raise exception 'Client must belong to the same organization' using errcode = '23514'; end if;
  if new.project_id is not null and not exists (select 1 from public.projects where id = new.project_id
       and org_id = new.org_id and client_id = new.client_id) then
    raise exception 'Project must belong to the same client' using errcode = '23514'; end if;
  return new;
end $$;
create trigger trg_camp_before before insert or update on public.campaigns
  for each row execute function app.campaign_before_write();

create or replace function app.metric_before_write() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  new.org_id := (select org_id from public.campaigns where id = new.campaign_id);
  new.updated_at := now();
  return new;
end $$;
create trigger trg_metric_before before insert or update on public.campaign_metrics_daily
  for each row execute function app.metric_before_write();

create or replace function app.can_view_campaign(p_campaign uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.campaigns c where c.id = p_campaign and c.org_id = app.org_id() and (
    (app.is_internal() and (app.has_perm('campaigns.view') or app.has_perm('campaigns.manage') or app.can_view_client(c.client_id)))
    or (c.client_visible and c.client_id = app.client_id())))
$$;

alter table public.campaigns enable row level security;
alter table public.campaign_imports enable row level security;
alter table public.campaign_metrics_daily enable row level security;
create policy camp_select on public.campaigns for select to authenticated using (app.can_view_campaign(id));
create policy camp_write on public.campaigns for all to authenticated
  using (org_id = (select app.org_id()) and (select app.has_perm('campaigns.manage')))
  with check (org_id = (select app.org_id()) and (select app.has_perm('campaigns.manage')));
create policy cimp_select on public.campaign_imports for select to authenticated
  using (org_id = (select app.org_id()) and (select app.is_internal())
         and ((select app.has_perm('campaigns.view')) or (select app.has_perm('campaigns.manage'))));
create policy cm_select on public.campaign_metrics_daily for select to authenticated using (app.can_view_campaign(campaign_id));
create policy cm_write on public.campaign_metrics_daily for all to authenticated
  using (org_id = (select app.org_id()) and (select app.has_perm('campaigns.manage')))
  with check ((select app.has_perm('campaigns.manage')) and app.can_view_campaign(campaign_id));
grant select, insert, update, delete on public.campaigns, public.campaign_metrics_daily to authenticated;
grant select on public.campaign_imports to authenticated;

-- campaign totals (SECURITY INVOKER view: RLS of the caller applies)
create view public.campaign_summary with (security_invoker = true) as
select c.id as campaign_id, c.client_id, c.platform, c.name, c.status, c.monthly_budget, c.currency,
       coalesce(sum(m.impressions), 0) as impressions, coalesce(sum(m.clicks), 0) as clicks,
       coalesce(sum(m.spend), 0) as spend, coalesce(sum(m.conversions), 0) as conversions,
       coalesce(sum(m.conversion_value), 0) as conversion_value,
       case when sum(m.impressions) > 0 then round(100.0 * sum(m.clicks) / sum(m.impressions), 2) end as ctr_pct,
       case when sum(m.clicks) > 0 then round(sum(m.spend) / sum(m.clicks), 2) end as cpc,
       case when sum(m.conversions) > 0 then round(sum(m.spend) / sum(m.conversions), 2) end as cpa,
       case when sum(m.spend) > 0 then round(sum(m.conversion_value) / sum(m.spend), 2) end as roas,
       min(m.metric_date) as first_date, max(m.metric_date) as last_date
from public.campaigns c left join public.campaign_metrics_daily m on m.campaign_id = c.id
group by c.id;
grant select on public.campaign_summary to authenticated;

-- Import parsed CSV rows for one client + platform.
-- p_rows: [{"campaign": "Name", "campaign_id": "123" (optional), "date": "2026-10-01", "impressions": 1, "clicks": 1,
--           "spend": 1.5, "conversions": 0, "conversion_value": 0}, ...]
-- p_mode: 'skip' keeps existing days untouched, 'overwrite' replaces them.
create or replace function public.import_campaign_metrics(p_client uuid, p_platform text, p_file_name text,
  p_file_sha256 text, p_rows jsonb, p_mode text default 'skip') returns public.campaign_imports
language plpgsql security definer set search_path = '' as $$
declare v_org uuid := app.org_id(); v_imp public.campaign_imports; r jsonb; v_camp uuid; v_date date; v_name text; v_ext text;
        v_ins int := 0; v_upd int := 0; v_skip int := 0; v_new_camps int := 0; v_existed boolean; v_n int := 0; v_today date;
begin
  if not (app.is_internal() and app.has_perm('campaigns.manage')) then
    raise exception 'Not allowed to import campaign data' using errcode = '42501'; end if;
  if not exists (select 1 from public.clients where id = p_client and org_id = v_org) then
    raise exception 'Client not found' using errcode = 'P0002'; end if;
  if p_platform not in ('google_ads','meta_ads','other') then raise exception 'Unknown platform' using errcode = '22023'; end if;
  if p_mode not in ('skip','overwrite') then raise exception 'Mode must be skip or overwrite' using errcode = '22023'; end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    raise exception 'The file has no data rows' using errcode = '22023'; end if;
  if jsonb_array_length(p_rows) > 20000 then raise exception 'Too many rows (max 20,000 per file)' using errcode = '22023'; end if;
  if exists (select 1 from public.campaign_imports where org_id = v_org and file_sha256 = lower(p_file_sha256)) then
    raise exception 'This exact file was already imported' using errcode = '23505'; end if;
  v_today := app.org_today(v_org);

  insert into public.campaign_imports(org_id, client_id, platform, file_name, file_sha256, created_by)
  values (v_org, p_client, p_platform, left(p_file_name, 255), lower(p_file_sha256), auth.uid()) returning * into v_imp;

  for r in select * from jsonb_array_elements(p_rows) loop
    v_n := v_n + 1;
    v_name := nullif(trim(r->>'campaign'), '');
    v_ext := nullif(trim(r->>'campaign_id'), '');
    begin
      v_date := (r->>'date')::date;
    exception when others then
      raise exception 'Row %: invalid date "%"', v_n, r->>'date' using errcode = '22023';
    end;
    if v_name is null and v_ext is null then raise exception 'Row %: campaign name is missing', v_n using errcode = '22023'; end if;
    if v_date is null or v_date > v_today then raise exception 'Row %: date is missing or in the future', v_n using errcode = '22023'; end if;

    v_camp := null;
    if v_ext is not null then
      select id into v_camp from public.campaigns where org_id = v_org and platform = p_platform and external_id = v_ext;
      if v_camp is not null and not exists (select 1 from public.campaigns where id = v_camp and client_id = p_client) then
        raise exception 'Row %: campaign ID % belongs to another client', v_n, v_ext using errcode = '23514'; end if;
    end if;
    if v_camp is null and v_name is not null then
      select id into v_camp from public.campaigns where client_id = p_client and platform = p_platform and lower(name) = lower(v_name);
    end if;
    if v_camp is null then
      insert into public.campaigns(org_id, client_id, platform, name, external_id, created_by)
      values (v_org, p_client, p_platform, coalesce(v_name, 'Campaign ' || v_ext), v_ext, auth.uid()) returning id into v_camp;
      v_new_camps := v_new_camps + 1;
    end if;

    v_existed := exists (select 1 from public.campaign_metrics_daily where campaign_id = v_camp and metric_date = v_date);
    if v_existed and p_mode = 'skip' then v_skip := v_skip + 1; continue; end if;
    begin
      insert into public.campaign_metrics_daily(campaign_id, metric_date, org_id, impressions, clicks, spend, conversions, conversion_value, import_id)
      values (v_camp, v_date, v_org, coalesce((r->>'impressions')::bigint, 0), coalesce((r->>'clicks')::bigint, 0),
              coalesce((r->>'spend')::numeric, 0), coalesce((r->>'conversions')::numeric, 0),
              coalesce((r->>'conversion_value')::numeric, 0), v_imp.id)
      on conflict (campaign_id, metric_date) do update set impressions = excluded.impressions, clicks = excluded.clicks,
        spend = excluded.spend, conversions = excluded.conversions, conversion_value = excluded.conversion_value,
        import_id = excluded.import_id;
    exception when check_violation or invalid_text_representation or numeric_value_out_of_range then
      raise exception 'Row %: numbers must be valid and not negative (clicks cannot exceed impressions)', v_n using errcode = '22023';
    end;
    if v_existed then v_upd := v_upd + 1; else v_ins := v_ins + 1; end if;
  end loop;

  update public.campaign_imports set rows_total = v_n, rows_inserted = v_ins, rows_updated = v_upd, rows_skipped = v_skip,
    campaigns_created = v_new_camps where id = v_imp.id returning * into v_imp;
  return v_imp;
end $$;
revoke execute on function public.import_campaign_metrics(uuid, text, text, text, jsonb, text) from public, anon;
grant execute on function public.import_campaign_metrics(uuid, text, text, text, jsonb, text) to authenticated;
revoke execute on all functions in schema app from public, anon;
grant execute on all functions in schema app to authenticated, service_role;
