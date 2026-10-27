# Implementation status — 27 Oct 2026

Scope delivered: **Phase 1 (plan), Phase 2 (foundation), Phase 3 (MVP) and Phase 4 (agency operations)**. Phases 5–6 are not started.

## Phase 4 — agency operations (27 Oct 2026)

| Feature | Status | Notes |
|---|---|---|
| Project templates | ✅ Done | 8 starter templates (one per service, 5–7 tasks each with day offsets, durations, estimates). Template editor at **Templates**; **Projects → From template** creates the project and all tasks with dates from the chosen start. Uses the caller's own rights (no privilege gained via templates). |
| Recurring tasks | ✅ Done | Weekly (weekday) or monthly (day 1–28) rules per project, with assignee, reviewer, estimate, end date, pause. Hourly `pg_cron` job `generate_recurring_tasks()`; a unique key per rule+period makes it impossible to create the same period twice, and missed runs catch up within the period. |
| Time tracking | ✅ Done | Timer start/stop on any task (server time, one running timer per person), manual entries (no future dates, max 60 days back, max 24 h/day), actual-vs-estimate on tasks and per project. |
| Timesheets | ✅ Done | Weekly submit → reporting manager / `timesheets.approve` approves or returns with a reason. Submitted/approved weeks are locked; returned weeks unlock. Nobody can approve their own. Team report with CSV export (`time.view_all`). |
| Content calendar | ✅ Done | Pipeline idea → in progress → internal review → client review → changes requested / approved → scheduled → published. Month calendar + list. Clients see items only from client review onwards and approve or request changes in the portal (feedback required); approved content is locked; staff can't fake client feedback. Notifications both ways. |
| Campaign tracking | ✅ Done | Google/Meta campaigns per client, CSV import of daily exports (Google Ads and Meta Ads Manager formats, UTF-16/TSV, title and total rows handled) with preview, keep-or-replace for days already present, one row per campaign per day, and the same file (SHA-256) refused twice. CTR, CPC, CPA and ROAS. Ad spend is separate from management fees (fees stay billing-permission only). Clients see their own campaigns. |
| Calendar & timeline | ✅ Done | **Calendar** page combining task due dates, scheduled content and project deadlines (filterable, agenda layout on phones). Project **Timeline** tab (Gantt-style). |
| Employee documents | ✅ Done | Documents tab on the employee profile: HR uploads/deletes; the employee and HR can open. Files live in the private `agency-files` bucket. |

New permissions (added to existing organizations automatically by `upgrade_phase4.sql`): `projects.manage_templates`, `time.view_all`, `timesheets.approve`, `content.view_all`, `content.manage`, `campaigns.view`, `campaigns.manage`. Defaults: Owner/Super Admin and PM get all; Team Leader gets time/approvals/content view/campaign view; HR gets time/approvals; Social Media Manager gets content; DM Executive gets campaigns; Accounts gets time view and campaign view.

### How Phase 4 was verified
| Check | Result |
|---|---|
| Database tests (`npm run test:db`) | **251 / 251 pass** (141 earlier + 110 Phase 4: templates, recurring idempotency, timer/timesheet rules and locks, content approval workflow and client isolation, CSV import duplicates/validation/rollback, cross-org isolation). Every “denied” test was checked to fail for the intended reason. |
| Unit tests (`npm test`) | **36 / 36 pass** (+12: CSV parser for Google/Meta exports, dates, durations, navigation). |
| Type check + production build | **pass** |
| Browser render test (`scripts/e2e/phase4-render.mjs`) | **42 / 42 pass**: every new screen in Chromium as Owner, Designer and Client plus a phone viewport, with data exported from the test database; interactions (from template, recurring rule, time entry, content status, CSV preview + import) send the right requests; no runtime errors; no horizontal scroll on phones. |
| Upgrade path | `upgrade_phase4.sql` applied to a Phase 1–3 database that already had an organization: templates and permissions were added. `setup.sql` applied to an empty database. |

**Not run for Phase 4 in this session:** the full PostgREST smoke suite (`scripts/e2e/smoke.mjs`), because the PostgREST binary couldn't be downloaded here. Run it locally or check these on the live project after upgrading: file upload to Storage (employee documents), the hourly recurring-task job, and a real Google/Meta export file.

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

## Next milestone (Phase 5 — finance & people)
1. Invoices and payments (GST, management fee vs ad spend shown separately, payment reminders).
2. Payroll run from salary structures, attendance and leave (payslips).
3. Recruitment pipeline (openings, candidates, interviews, offer letters).
4. Email delivery for notifications (provider such as Resend/SMTP).
