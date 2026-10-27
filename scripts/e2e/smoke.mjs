// Browser smoke test against the local stack (scripts/e2e/server.mjs + PostgREST + migrated DB with test data).
// Usage: SECRET=... BASE=http://localhost:8787 node scripts/e2e/smoke.mjs <psql-conn>
import { chromium } from 'playwright'
import { execFileSync } from 'node:child_process'
import { mkdirSync } from 'node:fs'
import { sign } from './jwt.mjs'

const BASE = process.env.BASE ?? 'http://localhost:8787'
const SECRET = process.env.SECRET
const OUT = process.env.OUT ?? '/tmp/e2e-shots'
mkdirSync(OUT, { recursive: true })
const psql = (sql) => execFileSync('psql', ['-h', '/tmp', '-p', '54329', '-U', 'postgres', '-d', 'aos_e2e', '-tAX', '-c', sql]).toString().trim()

const results = []
const check = (name, ok, detail = '') => { results.push({ name, ok, detail }); console.log(`${ok ? 'ok  ' : 'FAIL'} ${name}${detail && !ok ? ' — ' + detail : ''}`) }

async function as(email, fn) {
  const id = psql(`select id from auth.users where email = '${email}'`)
  const exp = Math.floor(Date.now() / 1000) + 3600
  const token = sign({ sub: id, role: 'authenticated', aud: 'authenticated', email, exp }, SECRET)
  const session = { access_token: token, refresh_token: 'x', token_type: 'bearer', expires_in: 3600, expires_at: exp,
    user: { id, email, aud: 'authenticated', role: 'authenticated', app_metadata: {}, user_metadata: {}, created_at: new Date().toISOString() } }
  const browser = await chromium.launch()
  const ctx = await browser.newContext({ viewport: { width: 1360, height: 900 } })
  await ctx.addInitScript(([s]) => localStorage.setItem('sb-localhost-auth-token', s), [JSON.stringify(session)])
  const page = await ctx.newPage()
  const errors = []
  page.on('console', (m) => { if (m.type() === 'error' && !/not emulated|Failed to load resource/.test(m.text())) errors.push(m.text()) })
  page.on('pageerror', (e) => errors.push('pageerror: ' + e.message))
  const bad = []
  page.on('response', (r) => { if (r.url().includes('/rest/v1') && r.status() >= 400) bad.push(`${r.status()} ${r.request().method()} ${r.url().replace(BASE, '')}`) })
  const go = async (path, shot) => {
    await page.goto(BASE + path); await page.waitForLoadState('networkidle'); await page.waitForTimeout(300)
    if (shot) await page.screenshot({ path: `${OUT}/${shot}.png`, fullPage: true })
  }
  try { await fn(page, go, bad) } catch (e) { check(`${email}: script error`, false, e.message.split('\n')[0]) }
  check(`${email}: no uncaught errors`, errors.length === 0, errors.slice(0, 3).join(' | '))
  await browser.close()
  return bad
}

const text = (page) => page.locator('main').innerText()

// ---------- Owner / Super Admin ----------
await as('owner@a.test', async (page, go, bad) => {
  await go('/', 'owner-dashboard')
  const t = await text(page)
  check('owner: admin dashboard shows metrics', /Active clients/.test(t) && /Renewals in 45 days/.test(t))
  const dbOverdue = psql(`select count(*) from tasks t join task_statuses s on s.id = t.status_id join organizations o on o.id = t.org_id
    where o.slug = 'dotscube' and s.category not in ('done','cancelled') and t.due_date < (now() at time zone o.timezone)::date`)
  const uiOverdue = (await page.locator('a', { hasText: 'Overdue tasks' }).innerText()).match(/\d+/)?.[0]
  check('owner: overdue card matches database', uiOverdue === dbOverdue, `ui=${uiOverdue} db=${dbOverdue}`)
  await go('/clients?status=active', 'owner-clients')
  check('owner: clients list (filtered from card)', (await text(page)).includes('Maahaul India'))
  await page.getByText('Maahaul India').click(); await page.getByText(/of 7 complete/).waitFor()
  check('owner: client detail with onboarding checklist', /Onboarding checklist/.test(await text(page)) && /7 complete|of 7 complete/.test(await text(page)))
  await page.getByRole('tab', { name: 'Billing & contracts' }).click(); await page.waitForLoadState('networkidle')
  await page.screenshot({ path: `${OUT}/owner-client-billing.png`, fullPage: true })
  check('owner: billing tab shows contract', (await text(page)).includes('SEO retainer'))
  await go('/employees', 'owner-employees')
  check('owner: employee directory', /EMP0004/.test(await text(page)))
  await go('/projects', 'owner-projects')
  await go('/settings', 'owner-settings')
  await page.getByRole('tab', { name: 'Roles & permissions' }).click(); await page.waitForTimeout(500)
  await page.screenshot({ path: `${OUT}/owner-roles.png` })
  check('owner: permission matrix renders', (await page.locator('table input[type=checkbox]').count()) > 300)
  await page.getByRole('tab', { name: 'Audit log' }).click(); await page.locator('tbody tr').nth(10).waitFor({ timeout: 8000 }).catch(() => {})
  check('owner: audit log has entries', (await page.locator('tbody tr').count()) > 10)
  // invite a teammate (Edge Function not available locally -> fallback message, invitation still stored)
  await page.getByRole('tab', { name: 'Invitations' }).click()
  await page.getByLabel('Email').fill('newhire@a.test')
  await page.getByLabel('Role').selectOption({ label: 'Video Editor' })
  await page.getByRole('button', { name: 'Invite', exact: true }).click(); await page.waitForTimeout(1200)
  check('owner: invitation saved with fallback notice', await page.getByText(/Invitation saved/).isVisible() && psql(`select count(*) from invitations where email='newhire@a.test'`) === '1')
  // create a client through the UI
  await go('/clients')
  await page.getByRole('button', { name: 'New client' }).click()
  await page.getByLabel('Client name').fill('Smoke Test Bakery')
  await page.getByLabel('Website').fill('not a url')
  await page.getByRole('button', { name: 'Create client' }).click()
  check('owner: client form validates website', await page.getByText('Enter a full URL').isVisible())
  await page.getByLabel('Website').fill('https://bakery.example')
  await page.getByRole('button', { name: 'Create client' }).click(); await page.waitForURL(/\/clients\/[0-9a-f-]{36}/, { timeout: 8000 }); await page.getByText(/of 7 complete/).waitFor()
  check('owner: client created via UI with checklist', /0 of 7 complete/.test(await text(page)))
  check('owner: no failed API calls', bad.filter((b) => !b.includes('/functions/')).length === 0, bad.join(' | '))
})

// ---------- Project manager ----------
// seed a genuinely blocked task: "Publish blog post" depends on the open task "Write blog post"
psql(`with p as (select id, org_id, owner_id from projects where name = 'Maahaul SEO Q4'),
  a as (insert into tasks(org_id, project_id, title, created_by) select org_id, id, 'Write blog post', owner_id from p returning id, org_id),
  b as (insert into tasks(org_id, project_id, title, created_by) select org_id, id, 'Publish blog post', owner_id from p returning id)
  insert into task_dependencies(task_id, depends_on_task_id, org_id) select b.id, a.id, a.org_id from a, b`)
await as('pm@a.test', async (page, go, bad) => {
  await go('/', 'pm-dashboard')
  await go('/projects')
  await page.getByText('Maahaul SEO Q4').click(); await page.waitForLoadState('networkidle'); await page.waitForTimeout(300)
  await page.screenshot({ path: `${OUT}/pm-project-board.png`, fullPage: true })
  check('pm: kanban board columns', (await page.locator('section[aria-label$="column"]').count()) === 5)
  // create task via UI
  await page.getByRole('button', { name: 'New task' }).click()
  await page.getByLabel('Title').fill('Monthly SEO report')
  await page.getByLabel('Assignee').selectOption({ label: 'Dev Designer' })
  await page.getByRole('button', { name: 'Create task' }).click(); await page.waitForTimeout(800)
  check('pm: task created from UI', (await text(page)).includes('Monthly SEO report'))
  // blocked transition shows server error
  await page.getByRole('link', { name: 'Publish blog post' }).click(); await page.waitForLoadState('networkidle')
  await page.screenshot({ path: `${OUT}/pm-task-detail.png`, fullPage: true })
  await page.getByLabel('Status').selectOption({ label: 'Completed' }); await page.waitForTimeout(800)
  check('pm: dependency rule surfaced to user', await page.getByText('Complete the tasks this one depends on first').first().isVisible())
  // comment with mention
  await page.getByLabel('Write a comment').fill('@Dev Designer please pick this up')
  await page.getByRole('button', { name: 'Post' }).click(); await page.waitForTimeout(800)
  check('pm: comment posted', (await text(page)).includes('please pick this up'))
  await go('/tasks?scope=all&due=overdue', 'pm-overdue')
  await go('/leave?tab=approvals', 'pm-leave-approvals')
  check('pm: no unexpected API failures', bad.filter((b) => !b.startsWith('400 PATCH')).length === 0, bad.join(' | '))
})
check('db: mention notification created', psql(`select count(*) from notifications where type='mention'`) === '1')

// ---------- Designer (employee) ----------
await as('des@a.test', async (page, go, bad) => {
  await go('/', 'designer-dashboard')
  const t = await text(page)
  check('designer: employee dashboard', /My open tasks/.test(t) && /Today's attendance/.test(t))
  check('designer: no admin tab', !(await page.getByRole('tab', { name: 'Agency' }).count()))
  check('designer: nav hides Clients', !(await page.getByRole('link', { name: 'Clients' }).count()))
  await go('/clients', 'designer-clients-denied')
  check('designer: clients route guarded', /don't have access/.test(await text(page)))
  await go('/leave')
  await page.getByRole('button', { name: 'Apply for leave' }).click()
  await page.getByLabel('Leave type').selectOption({ label: 'Casual Leave' })
  await page.getByLabel('From').fill('2027-08-02'); await page.getByLabel('To').fill('2027-08-06'); await page.waitForTimeout(700)
  check('designer: leave day preview', /Counts as 5 working day/.test(await page.locator('dialog').innerText()))
  await page.getByRole('button', { name: 'Submit request' }).click(); await page.waitForTimeout(800)
  await page.screenshot({ path: `${OUT}/designer-leave.png`, fullPage: true })
  check('designer: leave applied', (await text(page)).includes('02 Aug 2027'))
  await go('/notifications', 'designer-notifications')
  check('designer: notifications listed', /New task assigned/.test(await text(page)))
  const emp = psql(`select id from employee_profiles where work_email='seo@a.test'`)
  await go(`/employees/${emp}`)
  check('designer: no salary tab for colleague', !(await page.getByRole('tab', { name: 'Salary' }).count()))
  check('designer: no failed API calls', bad.length === 0, bad.join(' | '))
})

// ---------- HR ----------
await as('hr@a.test', async (page, go, bad) => {
  await go('/', 'hr-dashboard')
  check('hr: HR dashboard', /Headcount/.test(await text(page)))
  await go('/leave?tab=approvals')
  check('hr: sees pending leave', (await text(page)).includes('Dev Designer'))
  await page.locator('tr', { hasText: '02 Aug 2027' }).getByRole('button', { name: 'Approve' }).click(); await page.waitForTimeout(1000)
  check('hr: approves leave', psql(`select status from leave_requests where start_date='2027-08-02'`) === 'approved')
  await go('/attendance?tab=report', 'hr-attendance-report')
  const emp = psql(`select id from employee_profiles where work_email='seo@a.test'`)
  await go(`/employees/${emp}`)
  await page.getByRole('tab', { name: 'Salary' }).click(); await page.waitForLoadState('networkidle')
  await page.screenshot({ path: `${OUT}/hr-salary.png`, fullPage: true })
  check('hr: salary visible', /4,80,000/.test(await text(page)))
  check('hr: no failed API calls', bad.length === 0, bad.join(' | '))
})

// ---------- Client portal ----------
await as('cli@maahaul.test', async (page, go, bad) => {
  await go('/', 'client-overview')
  const t = await text(page)
  check('client: sees shared project', t.includes('Maahaul SEO Q4'))
  check('client: nav is limited', (await page.locator('nav[aria-label="Main"] a').count()) === 5)
  await page.getByText('Maahaul SEO Q4').click(); await page.waitForLoadState('networkidle')
  await page.getByRole('tab', { name: 'List' }).click(); await page.waitForTimeout(300)
  await page.screenshot({ path: `${OUT}/client-project.png`, fullPage: true })
  const lt = await text(page)
  check('client: only client-visible tasks', lt.includes('Keyword research') && !lt.includes('Technical audit') && !lt.includes('Monthly SEO report'))
  await page.getByText('Keyword research').click(); await page.getByText('Research is under way').waitFor()
  const tt = await text(page)
  check('client: internal comments hidden', !tt.includes('use the paid tool') && tt.includes('Research is under way'))
  await go('/employees')
  check('client: employees route blocked', /don't have access/.test(await text(page)))
  check('client: no failed API calls', bad.length === 0, bad.join(' | '))
})

// ---------- Mobile layout ----------
{
  const browser = await chromium.launch()
  const id = psql(`select id from auth.users where email = 'des@a.test'`)
  const exp = Math.floor(Date.now() / 1000) + 3600
  const token = sign({ sub: id, role: 'authenticated', aud: 'authenticated', exp }, SECRET)
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 } })
  await ctx.addInitScript(([s]) => localStorage.setItem('sb-localhost-auth-token', s),
    [JSON.stringify({ access_token: token, refresh_token: 'x', token_type: 'bearer', expires_in: 3600, expires_at: exp, user: { id, aud: 'authenticated', role: 'authenticated', app_metadata: {}, user_metadata: {} } })])
  const page = await ctx.newPage()
  await page.goto(BASE + '/'); await page.waitForLoadState('networkidle')
  await page.screenshot({ path: `${OUT}/mobile-dashboard.png`, fullPage: true })
  await page.getByRole('button', { name: 'Open navigation' }).click()
  await page.screenshot({ path: `${OUT}/mobile-nav.png` })
  check('mobile: nav drawer opens', await page.getByRole('dialog', { name: 'Navigation' }).isVisible())
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth)
  check('mobile: no horizontal page overflow', !overflow)
  await browser.close()
}

const failed = results.filter((r) => !r.ok)
console.log(`\n${results.length - failed.length} passed, ${failed.length} failed`)
process.exit(failed.length ? 1 : 0)
