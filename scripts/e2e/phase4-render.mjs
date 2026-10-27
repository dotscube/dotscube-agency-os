// Phase 4 browser render test. Runs the built app in Chromium with the REST API answered from JSON fixtures
// exported from the test database (realistic rows, no PostgREST needed). It checks that every new screen renders,
// key interactions work and nothing throws. Database rules are covered separately by supabase/tests.
// Usage: FIX=<fixture dir> BASE=http://localhost:8787 node scripts/e2e/phase4-render.mjs
import { chromium } from 'playwright'
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { join } from 'node:path'

const FIX = process.env.FIX, BASE = process.env.BASE ?? 'http://localhost:8787', OUT = process.env.OUT ?? '/tmp/e2e-shots'
mkdirSync(OUT, { recursive: true })
const fx = (t) => { try { return JSON.parse(readFileSync(join(FIX, `${t}.json`), 'utf8')) } catch { return [] } }
const results = []
const check = (name, ok, detail = '') => { results.push({ name, ok }); console.log(`${ok ? 'ok  ' : 'FAIL'} ${name}${detail && !ok ? ' — ' + detail : ''}`) }

const tables = Object.fromEntries(['profiles', 'organizations', 'employee_profiles', 'task_statuses', 'clients', 'projects', 'project_overview', 'tasks',
  'task_assignees', 'project_members', 'content_items', 'campaign_summary', 'campaign_imports', 'campaign_metrics_daily', 'campaigns', 'timesheets',
  'time_entries', 'project_templates', 'template_tasks', 'recurring_task_rules', 'recurring_task_runs', 'notifications', 'departments', 'roles',
  'user_roles', 'employment_documents', 'project_milestones', 'leave_types', 'holidays'].map((t) => [t, fx(t)]))
const byId = (t, id) => tables[t].find((r) => r.id === id)
// embedded relations the screens select
const embed = (t, r) => {
  if (t === 'time_entries') return { ...r, tasks: { title: byId('tasks', r.task_id)?.title ?? 'Task' }, projects: { name: byId('projects', r.project_id)?.name ?? 'Project' } }
  if (t === 'project_templates') return { ...r, template_tasks: [{ count: tables.template_tasks.filter((x) => x.template_id === r.id).length }] }
  if (t === 'tasks') return { ...r, task_assignees: tables.task_assignees.filter((a) => a.task_id === r.id).map((a) => ({ profile_id: a.profile_id })) }
  return r
}
const applyFilters = (rows, params) => {
  for (const [k, v] of params) {
    if (['select', 'order', 'limit', 'offset', 'or', 'and', 'on_conflict', 'columns'].includes(k) || k.includes('.')) continue
    const [op, ...rest] = v.split('.'); const val = rest.join('.')
    rows = rows.filter((r) => {
      if (!(k in r)) return true
      const x = r[k] == null ? null : String(r[k])
      switch (op) {
        case 'eq': return x === val
        case 'neq': return x !== val
        case 'is': return val === 'null' ? x === null : String(r[k]) === val
        case 'not': return rest[0] === 'is' ? x !== null : true
        case 'in': return val.replace(/[()]/g, '').split(',').includes(x)
        case 'gte': return x !== null && x >= val
        case 'lte': return x !== null && x.slice(0, val.length) <= val
        case 'gt': return x !== null && x > val
        case 'lt': return x !== null && x < val
        default: return true
      }
    })
  }
  return rows
}

async function as(email, viewport, fn) {
  const profile = tables.profiles.find((p) => p.email === email)
  const perms = JSON.parse(readFileSync(join(FIX, `perms-${email}.json`), 'utf8'))
  const writes = []
  const browser = await chromium.launch()
  const ctx = await browser.newContext({ viewport })
  const exp = Math.floor(Date.now() / 1000) + 3600
  const session = { access_token: 'h.' + Buffer.from(JSON.stringify({ sub: profile.id, exp })).toString('base64url') + '.s', refresh_token: 'x', token_type: 'bearer',
    expires_in: 3600, expires_at: exp, user: { id: profile.id, email, aud: 'authenticated', role: 'authenticated', app_metadata: {}, user_metadata: {} } }
  await ctx.addInitScript(([s]) => localStorage.setItem('sb-localhost-auth-token', s), [JSON.stringify(session)])
  await ctx.route('**/rest/v1/**', async (route) => {
    const req = route.request(); const url = new URL(req.url()); const path = url.pathname.replace('/rest/v1/', '')
    const json = (body, status = 200, headers = {}) => route.fulfill({ status, contentType: 'application/json', headers: { 'access-control-allow-origin': '*', 'access-control-expose-headers': 'content-range', ...headers }, body: JSON.stringify(body) })
    if (req.method() === 'OPTIONS') return route.fulfill({ status: 204, headers: { 'access-control-allow-origin': '*', 'access-control-allow-headers': '*', 'access-control-allow-methods': '*' } })
    if (path.startsWith('rpc/')) {
      const fn = path.slice(4)
      if (fn === 'my_permissions') return json(perms)
      if (fn === 'task_time_summary') return json([{ logged_minutes: 92, estimated_minutes: 240, running: false }])
      if (fn === 'project_time_summary') { const pid = JSON.parse(req.postData() || '{}').p_project
        return json(tables.tasks.filter((t) => t.project_id === pid).map((t) => ({ task_id: t.id, title: t.title, estimated_minutes: t.estimated_minutes, logged_minutes: 30 }))) }
      if (fn === 'get_dashboard_metrics') return json({ today: '2026-10-27', team_workload: [], tasks_by_status: [], my_attendance_today: null })
      writes.push(`rpc ${fn} ${req.postData()}`)
      if (fn === 'import_campaign_metrics') return json({ id: 'x', rows_inserted: 2, rows_updated: 0, rows_skipped: 0, campaigns_created: 1 })
      return json(null)
    }
    if (req.method() !== 'GET' && req.method() !== 'HEAD') { writes.push(`${req.method()} ${path} ${req.postData() ?? ''}`); return json([], 201) }
    const scoped = (tables[path] ?? []).filter((r) => !('org_id' in r) || r.org_id === profile.org_id) // stand-in for org-level RLS
    const rows = applyFilters(scoped.map((r) => embed(path, r)), url.searchParams)
    const range = { 'content-range': `0-${Math.max(0, rows.length - 1)}/${rows.length}` }
    if ((req.headers()['accept'] ?? '').includes('vnd.pgrst.object')) {
      return rows.length ? json(rows[0], 200, range) : json({ code: 'PGRST116', message: 'JSON object requested, multiple (or no) rows returned', details: 'The result contains 0 rows' }, 406)
    }
    return json(rows, 200, range)
  })
  const page = await ctx.newPage()
  const errors = []
  page.on('console', (m) => { if (m.type() === 'error' && !/Failed to load resource|not emulated|status of 406/.test(m.text())) errors.push(m.text()) })
  page.on('pageerror', (e) => errors.push('pageerror: ' + e.message))
  const go = async (p, shot) => { await page.goto(BASE + p); await page.waitForLoadState('networkidle'); await page.waitForTimeout(400); if (shot) await page.screenshot({ path: `${OUT}/${shot}.png`, fullPage: true }) }
  try { await fn(page, go, writes) } catch (e) { check(`${email}: script error`, false, e.message.split('\n')[0]) }
  check(`${email} (${viewport.width}px): no runtime errors`, errors.length === 0, errors.slice(0, 3).join(' | '))
  await browser.close()
}
const main = (page) => page.locator('main').innerText()
const id = (t, pred) => tables[t].find(pred)?.id

// ---------- Owner ----------
await as('owner@a.test', { width: 1360, height: 900 }, async (page, go, writes) => {
  await go('/templates', 'p4-templates')
  let t = await main(page)
  check('templates: 8 service templates listed', ['SEO Monthly Retainer', 'Google Ads Campaign Setup', 'Website Development', 'Email Marketing Campaign'].every((n) => t.includes(n)))
  await page.locator('main li button', { hasText: 'Website Development' }).click(); await page.waitForTimeout(300)
  check('templates: editor shows template tasks', (await main(page)).includes('Wireframes & design'))

  await go('/projects')
  await page.getByRole('button', { name: 'From template' }).click()
  const opt = await page.getByLabel('Template', { exact: true }).locator('option', { hasText: 'SEO Monthly Retainer' }).getAttribute('value')
  await page.getByLabel('Template', { exact: true }).selectOption(opt)
  check('projects: template dialog prefills name', (await page.getByLabel('Project name').inputValue()) === 'SEO Monthly Retainer')
  await page.screenshot({ path: `${OUT}/p4-from-template.png` })
  await page.getByRole('button', { name: 'Create project' }).click(); await page.waitForTimeout(500)
  check('projects: create from template calls RPC', writes.some((w) => w.startsWith('rpc create_project_from_template')))

  const proj = id('projects', (p) => p.name === 'Maahaul SEO November')
  await go(`/projects/${proj}`)
  await page.getByRole('tab', { name: 'Timeline' }).click(); await page.waitForTimeout(300)
  await page.screenshot({ path: `${OUT}/p4-timeline.png`, fullPage: true })
  check('project: timeline shows dated tasks', (await main(page)).includes('Monthly SEO report') && (await page.locator('li .rounded').count()) >= 6)
  await page.getByRole('tab', { name: 'Recurring' }).click(); await page.waitForTimeout(300)
  t = await main(page)
  check('project: recurring rules listed with schedule', t.includes('Weekly GBP post') && t.includes('Every Wednesday') && t.includes('Monthly on day 5'))
  await page.getByRole('button', { name: 'Add' }).click()
  await page.getByLabel('Task title').fill('Weekly review call'); await page.getByLabel('Repeats').selectOption('monthly')
  check('project: monthly rule asks for day of month', await page.getByLabel('Day of month').isVisible())
  await page.getByRole('button', { name: 'Save' }).click(); await page.waitForTimeout(300)
  check('project: recurring rule saved', writes.some((w) => w.startsWith('POST recurring_task_rules') && w.includes('"day_of_month":1')))
  await page.keyboard.press('Escape')
  await page.getByRole('tab', { name: 'Time', exact: true }).click(); await page.waitForTimeout(300)
  check('project: time vs estimate tab', /logged/.test(await main(page)))

  const task = id('tasks', (x) => x.title === 'Technical audit')
  await go(`/tasks/${task}`, 'p4-task-time')
  t = await main(page)
  check('task: time card shows actual vs estimate', t.includes('1h 32m of 4h 00m estimated'))
  await page.getByLabel('Time spent').fill('1:15'); await page.getByRole('button', { name: 'Log time' }).click(); await page.waitForTimeout(300)
  check('task: manual time entry posts 75 minutes', writes.some((w) => w.startsWith('POST time_entries') && w.includes('"minutes":75')))
  await page.getByLabel('Time spent').fill('later'); await page.getByRole('button', { name: 'Log time' }).click(); await page.waitForTimeout(300)
  check('task: invalid duration explained', await page.getByText(/Enter time like/).first().isVisible())

  await go('/time', 'p4-time-week')
  check('time: week view', /Submit timesheet|Awaiting approval|Approved/.test(await main(page)))
  await go('/time?tab=report', 'p4-time-report')
  check('time: team report tab', /By person|No time logged/.test(await main(page)))

  await go('/content', 'p4-content-calendar')
  await page.getByRole('button', { name: 'Next month' }).click(); await page.waitForTimeout(300)
  await page.screenshot({ path: `${OUT}/p4-content-november.png`, fullPage: true })
  check('content: scheduled post on calendar', (await main(page)).includes('Diwali offer reel'))
  await page.getByRole('tab', { name: 'List' }).click(); await page.waitForTimeout(200)
  await page.getByText('Unapproved post').click(); await page.waitForTimeout(200)
  check('content: item dialog offers next steps', await page.getByRole('button', { name: 'Start work' }).isVisible())
  await page.getByRole('button', { name: 'Start work' }).click(); await page.waitForTimeout(300)
  check('content: status change saved', writes.some((w) => w.startsWith('PATCH content_items') && w.includes('in_progress')))
  await page.keyboard.press('Escape')
  await page.getByRole('button', { name: 'New content' }).click()
  check('content: new content form', await page.getByLabel('Publish date & time').isVisible())
  await page.keyboard.press('Escape')

  await go('/campaigns', 'p4-campaigns')
  t = await main(page)
  check('campaigns: summary with spend & ROAS', t.includes('Brand Search') && t.includes('₹5,300') && t.includes('13.96×'))
  await page.getByText('Brand Search').click(); await page.waitForTimeout(400)
  await page.screenshot({ path: `${OUT}/p4-campaign-detail.png` })
  check('campaigns: detail shows daily rows', (await page.locator('dialog[open]').innerText()).includes('Cost per click'))
  await page.keyboard.press('Escape')
  await page.getByRole('button', { name: 'Import CSV' }).first().click()
  const csv = join(OUT, 'google-ads-export.csv')
  writeFileSync(csv, 'Campaign performance\nDay,Campaign,Campaign ID,Impr.,Clicks,Cost,Conversions,Conv. value\n2026-10-20,Brand Search,111,"1,200",80,"2,000.00",6,"30,000.00"\n2026-10-21,Remarketing,222,900,30,750.5,2,8000\nTotal,,,2100,110,2750.5,8,38000\n')
  await page.locator('dialog[open]').getByLabel('Client', { exact: true }).selectOption({ label: 'Maahaul India' })
  await page.locator('dialog[open] input[type=file]').setInputFiles(csv); await page.waitForTimeout(400)
  await page.screenshot({ path: `${OUT}/p4-import-preview.png` })
  const d = await page.locator('dialog[open]').innerText()
  check('campaigns: CSV preview (rows, campaigns, spend)', /2\s*day rows/.test(d) && /2\s*campaign/.test(d) && d.includes('₹2,751'))
  await page.getByRole('button', { name: 'Import', exact: true }).click(); await page.waitForTimeout(400)
  check('campaigns: import sends rows with file hash', writes.some((w) => w.startsWith('rpc import_campaign_metrics') && /"p_file_sha256":"[0-9a-f]{64}"/.test(w) && w.includes('"spend":750.5')))

  await go('/calendar', 'p4-calendar')
  await page.getByRole('button', { name: 'Next month' }).click(); await page.waitForTimeout(300)
  await page.getByLabel('Only my tasks').uncheck(); await page.waitForTimeout(400)
  await page.screenshot({ path: `${OUT}/p4-calendar-november.png`, fullPage: true })
  t = await main(page)
  check('calendar: tasks, content and deadlines together', t.includes('Diwali offer reel') && t.includes('Maahaul SEO November due') && t.includes('Monthly SEO report'))

  const emp = id('employee_profiles', (e) => e.work_email === 'des@a.test')
  await go(`/employees/${emp}`)
  await page.getByRole('tab', { name: 'Documents' }).click(); await page.waitForTimeout(300)
  check('employee: documents tab with upload', await page.getByRole('button', { name: 'Upload' }).isVisible())
})

// ---------- Designer (no Phase 4 permissions) ----------
await as('des@a.test', { width: 1360, height: 900 }, async (page, go) => {
  await go('/time')
  check('designer: own time page', /My week|Submit timesheet|Total/.test(await main(page)))
  const nav = await page.locator('nav[aria-label="Main"]').innerText()
  check('designer: nav hides Templates and Campaigns', !nav.includes('Templates') && !nav.includes('Campaigns') && nav.includes('Calendar'))
  await go('/templates')
  check('designer: templates page guarded', /don't have access/.test(await main(page)))
})

// ---------- Client portal ----------
await as('cli@maahaul.test', { width: 1360, height: 900 }, async (page, go, writes) => {
  await go('/content', 'p4-client-content')
  const nav = await page.locator('nav[aria-label="Main"] a').allInnerTexts()
  check('client: nav has Content and Campaigns only added', nav.length === 5 && nav.some((n) => n.includes('Content')) && nav.some((n) => n.includes('Campaigns')))
  await page.getByRole('tab', { name: 'List' }).click(); await page.waitForTimeout(200)
  await page.getByText('Diwali offer reel').click(); await page.waitForTimeout(200)
  check('client: sees caption and status', (await page.locator('dialog[open]').innerText()).includes('new logo'))
  await page.keyboard.press('Escape')
  await go('/campaigns', 'p4-client-campaigns')
  check('client: sees own campaign performance', (await main(page)).includes('Brand Search') && !(await main(page)).includes('Import history'))
  await go('/time')
  check('client: time page blocked', /don't have access/.test(await main(page)))
  await go('/calendar')
  check('client: calendar blocked', /don't have access/.test(await main(page)))
  check('client: made no writes', writes.length === 0, writes.join(' | '))
})

// ---------- Mobile ----------
await as('owner@a.test', { width: 390, height: 844 }, async (page, go) => {
  for (const p of ['/content', '/calendar', '/campaigns', '/time', '/templates']) {
    await go(p, `p4-mobile${p.replace('/', '-')}`)
    const overflow = await page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth + 1)
    check(`mobile ${p}: no horizontal page overflow`, !overflow)
  }
})

const failed = results.filter((r) => !r.ok).length
console.log(`\n${results.length - failed}/${results.length} passed`)
process.exit(failed ? 1 : 0)
