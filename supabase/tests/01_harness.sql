-- Minimal SQL test harness (no pgTAP dependency). Local test database only.
drop schema if exists tst cascade;
create schema tst;
create table tst.results (n serial, name text, ok boolean, detail text);
create table tst.ids (k text primary key, v uuid);
grant usage on schema tst to authenticated;
grant all on all tables in schema tst to authenticated;
grant all on all sequences in schema tst to authenticated;

create function tst.id(p text) returns uuid language sql stable as $$ select v from tst.ids where k = p $$;
create function tst.put(p text, v uuid) returns uuid language sql as $$
  insert into tst.ids values (p, v) on conflict (k) do update set v = excluded.v returning v $$;

create function tst.ok(p_cond boolean, p_name text, p_detail text default null) returns void language sql as $$
  insert into tst.results(name, ok, detail) values (p_name, coalesce(p_cond, false), p_detail) $$;

create function tst.eq(p_got anyelement, p_want anyelement, p_name text) returns void language sql as $$
  insert into tst.results(name, ok, detail)
  values (p_name, p_got is not distinct from p_want, 'got ' || coalesce(p_got::text,'NULL') || ', want ' || coalesce(p_want::text,'NULL')) $$;

-- passes if the statement raises (optionally with a given SQLSTATE or message fragment)
create function tst.throws(p_sql text, p_name text, p_like text default null) returns void language plpgsql as $$
begin
  execute p_sql;
  insert into tst.results(name, ok, detail) values (p_name, false, 'no error raised');
exception when others then
  insert into tst.results(name, ok, detail)
  values (p_name, p_like is null or sqlstate = p_like or sqlerrm ilike '%' || p_like || '%', sqlstate || ': ' || sqlerrm);
end $$;

create function tst.lives(p_sql text, p_name text) returns void language plpgsql as $$
begin
  execute p_sql;
  insert into tst.results(name, ok) values (p_name, true);
exception when others then
  insert into tst.results(name, ok, detail) values (p_name, false, sqlstate || ': ' || sqlerrm);
end $$;

create function tst.scalar(p_sql text) returns text language plpgsql as $$
declare v text; begin execute p_sql into v; return v; end $$;

-- run as postgres: create an auth user (fires handle_new_user)
create function tst.new_user(p_email text, p_name text) returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into auth.users(email, raw_user_meta_data) values (p_email, jsonb_build_object('full_name', p_name)) returning id into v;
  perform tst.put(p_email, v);
  return v;
end $$;

create function tst.login(p_email text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', tst.id(p_email), 'role', 'authenticated')::text, false);
end $$;
grant execute on all functions in schema tst to authenticated;
