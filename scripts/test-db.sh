#!/usr/bin/env bash
# Runs all migrations + database tests against a throwaway local PostgreSQL database.
# Usage: PGHOST=/tmp PGPORT=54329 PGUSER=postgres scripts/test-db.sh
set -euo pipefail
cd "$(dirname "$0")/.."
DB=${TEST_DB:-agency_os_test}
P="psql -v ON_ERROR_STOP=1 -q -X"
$P -d postgres -c "drop database if exists $DB" -c "create database $DB" >/dev/null
$P -d $DB -f supabase/tests/00_supabase_shim.sql >/dev/null 2>&1
for f in supabase/migrations/*.sql; do $P -d $DB -f "$f" >/dev/null 2>/tmp/mig.err || { cat /tmp/mig.err; exit 1; }; done
$P -d $DB -f supabase/tests/01_harness.sql >/dev/null
for f in supabase/tests/[1-8]*.sql; do $P -d $DB -f "$f" || exit 1; done
$P -d $DB -f supabase/tests/99_report.sql
