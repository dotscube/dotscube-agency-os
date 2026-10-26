# Implementation status — 26 Oct 2026

Scope delivered: **Phase 1 (plan), Phase 2 (foundation) and Phase 3 (MVP)**. Phases 4–6 are not started.

## How this was verified

| Check | Result | What it covers |
|---|---|---|
| Database tests (`npm run test:db`) | **141 / 141 pass** | Real migrations on PostgreSQL 16, users impersonated through JWT claims exactly as Supabase does. Cross-org isolation, every role's allowed *and* denied operations, client-portal isolation, privilege escalation, attendance maths, leave day counting/balances/multi-level approval, task review & dependency rules, progress calculation, notifications and job idempotency, dashboard scoping, audit trail, API-style `INSERT … RETURNING`. |
| Unit & component tests (`npm test`) | **24 / 24 pass** | Permission/nav logic, error mapping (no SQL leaks), CSV escaping incl. formula injection, timezone conversion, form validation, table sorting/paging/empty/error states, accessible field wiring. |
| Type check + production build | **pass** | `tsc -b` strict, `vite build`. |
| Browser smoke tests (`scripts/e2e/smoke.mjs`) | **45 / 45 pass** | The built app driven by Playwright against PostgREST + the migrated database, signed in as Owner, PM, Designer, HR and Client, plus a mobile viewport: dashboards, creating clients/tasks/leave through the UI, approvals, server-rule errors surfaced to the user, client isolation in the UI, no console errors, no failed API calls. |

Bugs found and fixed by this testing: RLS blocked "create and return" inserts from the UI (policies now evaluate row columns); an invitation trigger fired on acceptance; client-portal progress exposed internal task counts; HR could invite people into roles more powerful than their own.

## Module status (against the Definition of Done)

| Module | Status | Notes |
|---|---|---|
| Foundation: auth, orgs, RBAC, audit | ✅ Done | Configurable roles & permission matrix UI; audit log viewer. |
| A Dashboards | ✅ Done | Admin / HR / Projects / My work / Client views from real data; cards open filtered lists. *Billing & collections* and *recruitment/payroll status* wait for Phase 5 modules. |
| B Employees | ✅ Done (docs upload UI pending) | Directory, profile, private details, salary history, account & roles, exit fields. `employment_documents` table + storage policy exist; the upload screen is not built yet. |
| C Attendance | ✅ Done | Server timestamps, breaks, late/half/full-day rules, configurable schedule, corrections + approvals, monthly report + CSV. |
| D Leave | ✅ Done | Types, balances, half-day, holidays/weekly offs, overlap & balance checks, 1–3 approval levels, cancellation. |
| E Clients | ✅ Done | Profile, contacts, services, billing & contracts (restricted), notes, onboarding checklist (auto), portal invites, renewal reminders. |
| F Projects | ✅ Mostly | Sub-projects, owner, team, milestones, budget, computed progress, board/list views, client sharing. **Calendar/timeline views, project templates, recurring projects: Phase 4.** |
| G Tasks | ✅ Mostly | Assignees, reviewer, subtasks, dependencies, comments, @mentions, attachments, configurable statuses, filters, Kanban. **Time tracking/actual hours and recurrence: Phase 4.** Department filter not yet added. |
| N Notifications | ✅ In-app done | Assignment, review, mentions, client feedback, leave/correction requests & decisions, due/overdue, renewals. **E-mail delivery not built** (needs a provider). |
| Global search | ✅ Done | Tasks, projects, clients, employees — RLS-scoped. |

## Not yet verified on a live Supabase project
These parts depend on Supabase services that couldn't run in this environment. They are written to Supabase's documented APIs but **must be checked on a staging project before production**:
- Supabase Auth sign-up / sign-in / password reset screens (tests injected sessions directly).
- `storage.objects` policies and file upload/download for task attachments.
- The `send-invite` Edge Function (the UI falls back to "ask them to sign up" if it isn't deployed).
- `pg_cron` scheduling of `generate_due_notifications()` (the function itself is tested).

## Known limitations / assumptions
- One organization per user account.
- Client users can see a shared project's overall progress percentage (computed from all its tasks), not the internal task list or counts.
- Leave spanning two calendar years must be split into two requests.
- Rate limiting relies on Supabase Auth's built-in limits; no custom limits on RPCs yet.
- Main JS bundle is ~690 kB (≈200 kB gzipped); route-level code splitting is in place, vendor splitting can come later.

## Next milestone (Phase 4 — agency operations)
1. Project templates for the 8 services + idempotent recurring task generation (`recurring_task_rules`, unique per rule+period).
2. Time tracking: timers, manual entries, timesheet submission/approval, actual vs estimated hours.
3. Content calendar pipeline with client approvals.
4. Campaign tracking (Google/Meta) with CSV import + duplicate protection, ad spend kept separate from fees.
5. Employee document upload UI; calendar & timeline views.
