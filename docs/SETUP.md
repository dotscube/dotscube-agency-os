# Setup & deployment

## Fastest path (no command line, ~15 minutes)
1. **Supabase** (supabase.com, free plan) → New project → region *Mumbai* → set a database password.
2. **Database → Extensions** → enable `pg_cron`.
3. **SQL Editor → New query** → paste the whole of `supabase/setup.sql` → **Run** (once).
4. **Authentication → Sign In / Providers → Email**: for a quick start turn **"Confirm email" off** (the free built-in mailer sends only a few e-mails per hour; add your own SMTP later and turn it back on).
5. **Project Settings → API**: copy the **Project URL** and the **anon public** key. Never use the `service_role` key in the website.
6. **Vercel** (vercel.com, sign in with GitHub) → **Add New → Project** → import `dotscube/dotscube-agency-os` → framework *Vite* → add environment variables `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY` → **Deploy**.
7. Back in Supabase → **Authentication → URL Configuration** → set **Site URL** to your Vercel URL (e.g. `https://dotscube-agency-os.vercel.app`).
8. Open the Vercel URL → **Create an account** → set up the agency. You are Super Admin.

## Upgrading an existing project to Phase 4
If your project already ran `setup.sql` from Phase 1–3 (the live Dotscube project did):
1. **SQL Editor → New query** → paste the whole of `supabase/upgrade_phase4.sql` → **Run** (once). It runs in a single transaction, so it either fully applies or changes nothing.
2. Then deploy the new frontend (push to GitHub; Vercel redeploys automatically).
Do it in this order: the new screens need the new tables.

## Upgrading an existing project to Phase 5
If your project already ran Phase 4 (`upgrade_phase4.sql`):
1. **SQL Editor → New query** → paste the whole of `supabase/upgrade_phase5.sql` → **Run** (once, single transaction). Existing organizations get the new permissions, billing settings and e-mail settings (switched off).
2. Deploy the new frontend (push to GitHub; Vercel redeploys).
3. **Invoices → Billing settings**: enter your legal name, GSTIN, bank details and invoice prefix before issuing the first invoice.

## E-mail (notifications, invoices, payment reminders, offer letters)
E-mails are queued in the database and sent by the `send-emails` Edge Function through [Resend](https://resend.com). Nothing is queued until you switch it on.
1. **Resend**: create an account, add and verify your domain (DNS records), create an API key.
2. **Supabase → Edge Functions → Deploy a new function → Via editor**: name it `send-emails`, paste `supabase/functions/send-emails/index.ts`, deploy.
   (CLI alternative: `supabase functions deploy send-emails`.)
3. **Edge Functions → Secrets**: add `RESEND_API_KEY` and `EMAIL_FROM_ADDRESS` (an address on your verified domain, e.g. `notify@dotscube.com`).
4. **Integrations → Cron → Create job**: type *Supabase Edge Function*, function `send-emails`, method POST, every 5 minutes (`*/5 * * * *`),
   and add the header `Authorization: Bearer <service_role key>`.
5. In the app: **Settings → E-mail** → tick *Send e-mails*, check the app address → **Save** → **Send me a test e-mail**.
The same page shows how many e-mails are waiting, sent and failed, with the last error. Each person can turn individual e-mails off under **Settings → My notifications**.

## 1. Create the Supabase project
1. Create a project at supabase.com (region close to India, e.g. Mumbai `ap-south-1`).
2. **Database → Extensions:** enable `pg_cron` *before* running migrations (the due/overdue reminder job schedules itself if it's present).
3. **Authentication → URL configuration:** set the Site URL to where the app will be hosted.
4. **Authentication → Providers → Email:** keep "Confirm email" on for production.

## 2. Apply migrations
```bash
npm i -g supabase              # or use npx supabase
supabase login
supabase link --project-ref <your-project-ref>
supabase db push               # applies supabase/migrations in order
supabase functions deploy send-invite
supabase functions deploy send-emails
```
Do **not** run anything in `supabase/tests/` against the hosted project — `00_supabase_shim.sql` is for local plain-Postgres testing only.

## 3. Run the app
```bash
cp .env.example .env.local     # set VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY (anon key only!)
npm install
npm run dev
```
First sign-up → "Set up your agency" → you become Super Admin with a linked employee record. Default roles, task statuses, leave types, departments, a work schedule and salary components are created automatically.

## 4. Inviting people
- **Staff:** Employees → open the employee → *Account* tab → choose a role → *Invite*. When they sign up with that e-mail they are linked to the organization, the role and their employee record automatically.
- **Clients:** Clients → open the client → *Portal access* → *Invite*.
- Sending the e-mail itself is done by the `send-invite` Edge Function (or tell people to sign up at your URL — the invitation is matched by e-mail either way).

## 5. Hosting the frontend
`npm run build` produces static files in `dist/`. Host on Vercel, Netlify, Cloudflare Pages or any static host; configure SPA fallback to `index.html`. Only the two `VITE_` variables are needed at build time.

## 6. Backups & recovery
- Supabase Pro includes daily backups; enable **Point-in-Time Recovery** for production HR/payroll data.
- Keep migrations in Git; every schema change is a new migration file — never edit tables by hand in the dashboard.
- Before production migrations: take a manual backup (`supabase db dump -f backup.sql`), apply to a staging project first.
- Storage files (bucket `agency-files`) are not covered by database PITR — schedule a periodic copy if documents are business-critical.

## 7. Testing
```bash
npm test                       # unit + component tests (Vitest)
npm run typecheck
# database tests need a local PostgreSQL 15+ superuser connection:
PGHOST=/tmp PGPORT=5432 PGUSER=postgres npm run test:db
```
Browser smoke tests (`scripts/e2e/`) run the built app against PostgREST + Postgres with the test data; see the header of `scripts/e2e/smoke.mjs`.
