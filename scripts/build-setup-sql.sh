#!/usr/bin/env bash
# Regenerates the paste-into-SQL-Editor files from supabase/migrations (the source of truth).
#   supabase/setup.sql              -> a brand-new Supabase project (all migrations)
#   supabase/upgrade_phase4.sql     -> an existing Phase 1-3 project (only the Phase 4 migrations)
set -euo pipefail
cd "$(dirname "$0")/.."
{
  echo "-- Dotscube Agency OS: complete database setup."
  echo "-- Paste this whole file into Supabase > SQL Editor > New query > Run. Run it ONCE on a new project."
  echo "-- Generated from supabase/migrations (the source of truth)."
  for f in supabase/migrations/*.sql; do echo; echo "-- ===== $(basename "$f") ====="; cat "$f"; done
} > supabase/setup.sql
{
  echo "-- Dotscube Agency OS: Phase 4 upgrade (templates, recurring tasks, time tracking, content calendar, campaigns)."
  echo "-- For a project that already ran setup.sql from Phase 1-3. Paste into Supabase > SQL Editor > New query > Run, ONCE."
  echo "-- Existing organizations get the new permissions and the 8 starter templates automatically."
  echo "-- Generated from supabase/migrations (the source of truth)."
  echo "begin;"
  for f in supabase/migrations/2026102700000[89]_*.sql supabase/migrations/2026102700001[01]_*.sql; do echo; echo "-- ===== $(basename "$f") ====="; cat "$f"; done
  echo; echo "commit;"
} > supabase/upgrade_phase4.sql
echo "wrote supabase/setup.sql and supabase/upgrade_phase4.sql"
