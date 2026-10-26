# Dotscube Agency OS

Project, HR and client operations platform for a digital marketing agency — React + TypeScript + Tailwind on Supabase (Postgres, Auth, RLS, Storage).

**Start here:** `docs/PHASE1_PLAN.md` (architecture, schema, role matrix, roadmap) · `docs/STATUS.md` (what's done and how it was verified) · `docs/SETUP.md` (deploy & run).

## Quick start
```bash
cp .env.example .env.local        # add your Supabase URL + anon key
npm install
npm run dev
```
Apply the database with `supabase db push` (see `docs/SETUP.md`). The first person to sign up creates the organization and becomes Super Admin.

## Scripts
| Command | Purpose |
|---|---|
| `npm run dev` / `build` / `preview` | Vite dev server, production build, preview |
| `npm run typecheck` | Strict TypeScript check |
| `npm test` | Unit + component tests (Vitest) |
| `npm run test:db` | Migrations + 141 security/business-rule tests on a local PostgreSQL |

## Layout
```
supabase/migrations/   schema, RLS policies, business-rule functions (source of truth for security)
supabase/functions/    Edge Functions (service-role work only)
supabase/tests/        database test suite (+ a shim emulating Supabase auth on plain Postgres)
src/lib/               supabase client, permissions, query helpers, types, utils
src/components/        design-system components, DataTable, layout
src/features/          auth, dashboard, employees, attendance, leave, clients, projects, tasks, notifications, settings
scripts/e2e/           local browser smoke-test stack (PostgREST proxy + Playwright)
```

## Security model in one paragraph
The browser only ever holds the anon key and the user's JWT. Every table has Row Level Security scoped to the user's organization; sensitive data (salary, private HR details, billing, contracts) lives in separate tables behind dedicated permissions; client-portal users can only see rows explicitly marked client-visible for their own company. State changes with rules (attendance, leave, approvals) go through `SECURITY DEFINER` functions that check permissions themselves and use server time. Hiding a button in the UI is never the protection — the database refuses the operation.
