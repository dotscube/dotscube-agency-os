# Setup & deployment

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
