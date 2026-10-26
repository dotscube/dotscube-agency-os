# Dotscube Agency OS — Phase 1: Inspection & Plan

_Last updated: 2026-10-26_

## 1. Current architecture assessment

| Item | Finding |
|---|---|
| Existing repository | **None found.** The workspace was empty and no GitHub account is linked to this session, so no existing code could be inspected. |
| Existing database | None. No Supabase project URL/keys were provided. |
| Decision | Greenfield build on the preferred stack. **If an existing Dotscube codebase exists, share the repo and it will be inspected before anything here is merged into it.** |
| Tooling available here | Node 22, PostgreSQL 16 (used to run every migration and RLS test for real), no Supabase CLI (download blocked), so Supabase-specific pieces (`auth` schema, roles) are emulated by `supabase/tests/00_supabase_shim.sql` for local tests only. |

## 2. Proposed application architecture

```
Browser (React 19 + TS + Tailwind + shadcn-style UI)
  │  supabase-js (anon key only; user JWT)
  ▼
Supabase
  ├─ Auth ............ email/password + invitations
  ├─ PostgREST ....... tables + RPCs in schema `public` (all behind RLS)
  ├─ Postgres
  │    ├─ public ..... business tables
  │    ├─ app ........ private helper functions (not exposed over the API)
  │    └─ RLS ........ every table, deny-by-default, org-scoped
  ├─ Storage ......... private buckets, paths prefixed by org_id, policies mirror table RLS
  ├─ Edge Functions .. privileged work (invite e-mails, AI, e-mail notifications) using service role server-side only
  └─ pg_cron ......... scheduled jobs (due/overdue reminders, recurring tasks) — idempotent via dedupe keys
```

Key principles

- **Authorization lives in the database.** The UI hides controls for convenience only; every read/write is checked by RLS or by a `SECURITY DEFINER` RPC that checks permissions itself.
- **Sensitive data is split into separate tables** (`employee_private`, `salary_revisions`, `client_billing`, `contracts`) so a policy can't accidentally leak a column.
- **State changes with business rules go through RPCs** (check-in/out, leave apply/approve, attendance corrections). Users have no direct INSERT/UPDATE on `attendance_records` or `leave_balances`.
- **Server timestamps only** for attendance (`now()` inside the RPC).
- **Everything auditable** via a generic audit trigger writing to `audit_logs`.
- **Configurable, not hardcoded:** roles, permissions, task statuses, leave types, schedules, holidays, employee-ID prefix are all data.

Frontend structure

```
src/
  lib/          supabase client, query client, permission helpers, utils
  components/ui reusable design-system components (button, card, table, dialog, badge, …)
  components/   layout (sidebar, topbar), DataTable, EmptyState, StatCard
  features/     auth, dashboard, employees, attendance, leave, clients, projects, tasks, notifications, settings
  routes.tsx    route table with permission guards
```

## 3. Module dependency map

```
Foundation (orgs, profiles, roles, permissions, audit, departments)
 ├─ Employees ─┬─ Attendance ─┐
 │             ├─ Leave ──────┼─ Payroll prep (P5) ─ Payslips
 │             └─ Performance (P5)
 ├─ Clients ───┬─ Projects ─── Tasks ─┬─ Time tracking (P4) ─ Billing/Invoices (P5)
 │             │      └─ Templates/Recurring (P4)
 │             ├─ Content calendar (P4) ─ Client approvals ─ Client portal (P5)
 │             └─ Campaigns (P4)
 ├─ Notifications (consumed by all modules)
 ├─ Dashboards & Reports (read across modules, RLS-scoped)
 └─ AI assistant (P5, reads reports via server functions only)
```

## 4. Initial database schema (MVP — implemented in `supabase/migrations`)

| Area | Tables |
|---|---|
| Tenancy & RBAC | `organizations`, `profiles`, `permissions` (global catalog), `roles`, `role_permissions`, `user_roles`, `invitations`, `departments`, `audit_logs` |
| HR | `employee_profiles`, `employee_private`, `employment_documents`, `salary_components`, `salary_revisions` (append-only; current salary = latest effective revision), `work_schedules`, `holidays`, `attendance_records`, `attendance_breaks`, `attendance_corrections`, `leave_types`, `leave_balances`, `leave_requests`, `leave_approvals` |
| Clients | `clients`, `client_contacts`, `client_billing`, `client_services`, `contracts`, `client_notes`, `client_onboarding_items` (auto-created by trigger) |
| Work | `projects`, `project_members`, `project_milestones`, `task_statuses`, `tasks`, `task_assignees`, `task_dependencies`, `task_comments`, `task_attachments` |
| Comms | `notifications`, `notification_preferences`, `announcements` |
| Views/RPCs | `project_progress` (security-invoker view), `get_dashboard_metrics()`, `attendance_check_in/out()`, `attendance_break_start/end()`, `request_attendance_correction()`, `decide_attendance_correction()`, `apply_leave()`, `decide_leave()`, `cancel_leave()`, `create_organization()`, `generate_due_notifications()` |

Conventions: UUID PKs, `org_id` on every tenant table, `created_at/updated_at` with trigger, FK `on delete restrict` for business records and `cascade` only for pure child rows (assignees, comments), unique constraints for natural keys (employee code per org, attendance per employee/day, leave balance per employee/type/year), indexes on every FK and common filter.

## 5. Role–permission matrix (default seed — editable per organization)

Legend: ✔ granted · own = only own records via ownership policy · team = direct reports via manager policy · member = projects they're on

| Permission | Super Admin | Owner | HR | PM | Team Lead | Exec roles¹ | Accounts | Client |
|---|---|---|---|---|---|---|---|---|
| org.manage / roles.manage | ✔ | ✔ | | | | | | |
| users.manage (invite) | ✔ | ✔ | ✔ | | | | | |
| audit.view | ✔ | ✔ | | | | | | |
| employees.view (directory) | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ | |
| employees.create/edit/delete/export | ✔ | ✔ | ✔ | | | | | |
| employees.view_sensitive | ✔ | ✔ | ✔ | | | own | own | |
| salary.view | ✔ | ✔ | ✔ | | | own | ✔ | |
| salary.edit | ✔ | ✔ | ✔ | | | | | |
| attendance.view_all / approve / export | ✔ | ✔ | ✔ | team | team | own | own | |
| attendance.manage_policy | ✔ | ✔ | ✔ | | | | | |
| leave.view_all / approve / export | ✔ | ✔ | ✔ | team | team | own | own | |
| leave.manage_policy, holidays.manage | ✔ | ✔ | ✔ | | | | | |
| clients.view | ✔ | ✔ | | ✔ | ✔ | | ✔ | own org (limited) |
| clients.create/edit | ✔ | ✔ | | ✔ | | | | |
| clients.delete/export | ✔ | ✔ | | | | | | |
| clients.view_billing (billing, contracts) | ✔ | ✔ | | | | | ✔ | |
| projects.view_all | ✔ | ✔ | | ✔ | ✔ | member | | client-visible only |
| projects.create/edit | ✔ | ✔ | | ✔ | | | | |
| projects.delete/export | ✔ | ✔ | | ✔ | | | | |
| tasks.view_all | ✔ | ✔ | | ✔ | ✔ | member | | client-visible only |
| tasks.create | ✔ | ✔ | | ✔ | ✔ | member | | |
| tasks.edit_all / delete | ✔ | ✔ | | ✔ | ✔ | assignee/reviewer | | |
| tasks.manage_statuses, departments.manage | ✔ | ✔ | HR: depts | ✔ statuses | | | | |
| announcements.manage | ✔ | ✔ | ✔ | | | | | |
| reports.view | ✔ | ✔ | ✔ | ✔ | ✔ | | ✔ | |

¹ Digital Marketing Executive, SEO Executive, Graphic Designer, Video Editor, Social Media Manager.

Client users are a separate kind of account (`profiles.client_id` set). They never receive internal permissions — `app.has_perm()` returns false for them regardless of role rows.

## 6. MVP feature checklist

- [x] Org bootstrap (`create_organization`) seeding default roles, permissions, task statuses, leave types, schedule
- [x] Invitations (email-matched on sign-up) for employees and client users
- [x] Role/permission management (DB + settings UI)
- [x] Employee directory, profile, departments, reporting manager, private details, compensation & revision history (restricted)
- [x] Attendance: server-timestamped check-in/out, breaks, late/half/full-day rules, configurable schedule & grace, correction requests + approval, audit trail
- [x] Leave: configurable types, balances, half-day, holiday/weekly-off aware day counts, overlap & balance checks, multi-level approval, cancellation restoring balance
- [x] Holidays
- [x] Clients: profile, contacts, services, billing (restricted), contracts (restricted), notes, account manager
- [x] Projects: subprojects, owner, members, dates, milestones, budget, status, priority, computed progress, client visibility
- [x] Tasks: configurable statuses, assignees, reviewer, subtasks, dependencies (cycle-safe), comments (internal/client), attachments metadata, review rules, filters, Kanban
- [x] Notifications: assignment, review request, leave/correction requests and decisions, due/overdue (idempotent job)
- [x] Role-specific dashboard metrics from real data, cards link to filtered lists
- [ ] Email delivery of notifications (Edge Function stub; needs an email provider key)
- [ ] File upload UI for task attachments/documents (schema + storage policy written; UI in next stage)

## 7. Implementation plan & milestones

| Milestone | Scope | Exit criteria |
|---|---|---|
| M1 Foundation | Schema foundation, RBAC helpers, audit, app shell, auth, settings | RLS tests pass for cross-org and cross-role |
| M2 HR MVP | Employees, attendance, leave, holidays | Calculation + permission tests pass |
| M3 Work MVP | Clients, projects, tasks, Kanban, notifications, dashboards | Visibility + workflow tests pass; build passes |
| M4 Agency ops | Templates, recurring tasks, content calendar, campaigns (CSV import), time tracking | Idempotent generation tests |
| M5 Advanced | Payroll prep, recruitment, performance, client portal, invoices, AI assistant | Payroll calc tests, client portal isolation tests |
| M6 Production | E2E tests, accessibility, perf, backups, runbook | Release checklist signed off |

This delivery covers **M1–M3** (see `docs/STATUS.md` for exactly what is verified).

Note on the matrix: Settings is reachable by every internal user (for personal notification preferences); each settings tab is permission-filtered.

## 8. Security risks & mitigations

| Risk | Mitigation |
|---|---|
| Cross-tenant data leak | `org_id` on every row; every policy requires `org_id = app.org_id()`; tests attempt cross-org reads/writes |
| Client sees internal data | Client users fail `app.is_internal()`; client access is a separate, narrow policy per table (`client_visible = true` and matching `client_id`); internal comments flagged `is_internal` |
| Salary / HR exposure | Separate tables with dedicated permissions; directory table holds no sensitive columns |
| Attendance tampering | No direct write grants; RPC uses `now()`; corrections need approval; audit trigger |
| Privilege escalation via roles/invitations | `roles.manage` required to edit roles, and only permissions you hold can be added; assigning or inviting into a role requires holding all of its *sensitive* permissions (admin, salary, HR-private, billing, exports, policy); users cannot change their own roles; only Super Admins grant Super Admin; the last Super Admin cannot be removed |
| SECURITY DEFINER abuse | `search_path = ''`, fully-qualified names, explicit permission checks inside each function, `EXECUTE` revoked from `public`/`anon` |
| Service-role key leak | Only used in Edge Functions via env; frontend uses anon key only; `.env.example` documents this |
| Duplicate automation | Unique `dedupe_key` on notifications; recurring generation keyed by (rule, period) |
| File access | Private buckets; storage policy checks the org prefix and table-level visibility |
| Brute force | Supabase Auth rate limits; sensitive RPCs (check-in) guarded by unique constraints |

## 9. Testing strategy

1. **Database tests** (`supabase/tests/*.sql`): run real migrations on Postgres 16; impersonate users by setting JWT claims; assert allowed and **denied** operations for each role, cross-org isolation, client isolation, attendance/leave calculations, task workflow rules, notification idempotency.
2. **Unit tests** (Vitest): permission helpers, date/leave utilities, form schemas.
3. **Type checking + production build** on every stage.
4. **Next:** Playwright E2E against a Supabase staging project (needs project credentials).

## 10. Questions needing a business decision (assumptions used until answered)

| # | Question | Assumption made |
|---|---|---|
| 1 | Is there an existing codebase or Supabase project? | No — greenfield. |
| 2 | One agency or multi-agency SaaS? | Multi-tenant-ready schema; one org per user. |
| 3 | Office timezone & default hours | Asia/Kolkata, 10:00–19:00, 15-min grace, Sunday off. Half day ≥ 4h, full day ≥ 8h. |
| 4 | Leave types & quotas | Seeded: Casual 12, Sick 6, Earned 15, Unpaid 0 (unlimited). Editable. |
| 5 | Leave approval levels | 1 level (reporting manager or HR); configurable per leave type up to 3. |
| 6 | Pending leave counts against balance? | Yes, pending days are reserved. |
| 7 | Saturdays | Working day by default; set per schedule. |
| 8 | Can employees see their own salary? | Yes, read-only. |
| 9 | Project progress rule | % of top-level, non-cancelled tasks in a "done" status category; weighted by estimated time when every task has an estimate. |
| 10 | Who approves attendance corrections? | Reporting manager or anyone with `attendance.approve`. |
| 11 | Email provider for notifications | Not chosen — e-mail delivery left as a configured Edge Function. |
| 12 | Payroll statutory rules (PF/ESI/PT/TDS) | Out of MVP; will be configurable per jurisdiction and validated by your accountant before use. |
