#!/usr/bin/env bash
# Rebuilds the local e2e database (migrations + test data) and reloads PostgREST's schema cache.
set -euo pipefail
cd "$(dirname "$0")/../.."
P="psql -h ${PGHOST:-/tmp} -p ${PGPORT:-54329} -U ${PGUSER:-postgres} -v ON_ERROR_STOP=1 -q -X"
$P -d postgres -c "drop database if exists aos_e2e with (force)" -c "create database aos_e2e" >/dev/null
$P -d aos_e2e -f supabase/tests/00_supabase_shim.sql >/dev/null 2>&1
for f in supabase/migrations/*.sql; do $P -d aos_e2e -f "$f" >/dev/null 2>&1; done
$P -d aos_e2e -f supabase/tests/01_harness.sql >/dev/null 2>&1
$P -d aos_e2e -f supabase/tests/10_security_and_rules.sql >/dev/null
$P -d aos_e2e -f supabase/tests/20_phase4.sql >/dev/null
$P -d postgres -c "do \$\$ begin if not exists (select 1 from pg_roles where rolname='authenticator') then create role authenticator login noinherit; end if; end \$\$; grant anon, authenticated, service_role to authenticator;" >/dev/null
pkill -USR1 postgrest || true
echo "e2e database ready"
