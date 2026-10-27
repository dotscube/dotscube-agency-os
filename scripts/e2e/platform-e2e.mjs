// Platform admin end-to-end test (also Phase 5 harness): the built app in Chromium against the real test database through scripts/e2e/sql-rest.mjs
// (row-level security, triggers and RPCs all run for real). Run after `npm run test:db` so the fixtures exist.
// Usage: BASE=http://localhost:8787 node scripts/e2e/platform-e2e.mjs
import { chromium } from 'playwright'
import { mkdirSync } from 'node:fs'
import pg from 'pg'

const BASE = process.env.BASE ?? 'http://localhost:8787', OUT = process.env.OUT ?? '/tmp/e2e-shots'
mkdirSync(OUT, { recursive: true })
const db = new pg.Client({ connectionString: process.env.DATABASE_URL }); await db.connect()
const one = async (sql, args = []) => (await db.query(sql, args)).rows[0]
const results = []
const check = (name, ok, detail = '') => { results.push({ name, ok }); console.log(`${ok ? 'ok  ' : 'FAIL'} ${name}${detail && !ok ? ' — ' + detail : ''}`) }

async function as(email, viewport, fn) {
  const { id } = await one('select id from public.profiles where email = $1', [email])
  const browser = await chromium.launch()
  const ctx = await browser.newContext({ viewport })
  const exp = Math.floor(Date.now() / 1000) + 3600
  const session = { access_token: 'h.' + Buffer.from(JSON.stringify({ sub: id, exp, role: 'authenticated' })).toString('base64url') + '.s', refresh_token: 'x',
    token_type: 'bearer', expires_in: 3600, expires_at: exp, user: { id, email, aud: 'authenticated', role: 'authenticated', app_metadata: {}, user_metadata: {} } }
  await ctx.addInitScript(([s]) => localStorage.setItem('sb-localhost-auth-token', s), [JSON.stringify(session)])
  const page = await ctx.newPage()
  page.on('dialog', (d) => d.accept())
  const errors = []
  page.on('console', (m) => { if (m.type() === 'error' && !/Failed to load resource|status of 40[0-9]|status of 501/.test(m.text())) errors.push(m.text()) })
  page.on('pageerror', (e) => errors.push('pageerror: ' + e.message))
  const failedApi = []
  page.on('response', (r) => { if (r.url().includes('/rest/v1/') && r.status() >= 500) failedApi.push(`${r.status()} ${r.url()}`) })
  const go = async (p, shot) => { await page.goto(BASE + p); await page.waitForLoadState('networkidle'); await page.waitForTimeout(300); if (shot) await page.screenshot({ path: `${OUT}/${shot}.png`, fullPage: true }) }
  try { await fn(page, go) } catch (e) { check(`${email}: script error`, false, e.message.split('\n')[0]) }
  check(`${email} (${viewport.width}px): no runtime errors`, errors.length === 0, errors.slice(0, 3).join(' | '))
  check(`${email} (${viewport.width}px): no server errors`, failedApi.length === 0, failedApi.slice(0, 3).join(' | '))
  await browser.close()
}
const main = (page) => page.locator('main').innerText()
const dialog = (page) => page.locator('dialog[open]')
const settle = (page, ms = 500) => page.waitForLoadState('networkidle').then(() => page.waitForTimeout(ms))

// ---------- Platform owner ----------
await as('owner@a.test', { width: 1360, height: 900 }, async (page, go) => {
  await go('/platform', 'pa-agencies')
  const nav = await page.locator('nav[aria-label="Main"]').innerText()
  check('owner: Platform in the menu', nav.includes('Platform'))
  let t = await main(page)
  check('agencies: every agency listed with founder', t.includes('Dotscube Digital') && t.includes('Other Agency') && t.includes('owner@b.test') && t.includes('Yours'))
  await page.getByText('Other Agency').click(); await settle(page)
  check('agency detail: members with roles', (await dialog(page).innerText()).includes('Super Admin'))
  await dialog(page).getByLabel('User limit').fill('3')
  await dialog(page).getByRole('button', { name: 'Save' }).click(); await settle(page)
  check('agency: user limit saved', (await one(`select max_users from public.organizations where slug = 'other-agency'`)).max_users === 3)
  await dialog(page).getByLabel('Reason for suspension').fill('Unpaid subscription')
  await page.screenshot({ path: `${OUT}/pa-agency.png` })
  await dialog(page).getByRole('button', { name: 'Suspend' }).click(); await settle(page)
  check('agency: suspended', (await one(`select status from public.organizations where slug = 'other-agency'`)).status === 'suspended')
  check('agencies: suspended badge', (await main(page)).includes('Suspended'))
  await page.locator('main').getByText('Dotscube Digital').first().click(); await settle(page)
  check('own agency cannot be suspended', (await dialog(page).innerText()).includes("can't be suspended"))
  await page.keyboard.press('Escape')
  await page.getByRole('tab', { name: 'Sign-ups & admins' }).click(); await settle(page)
  await page.getByLabel('Only people I invite').check()
  await page.getByRole('button', { name: 'Save' }).first().click(); await settle(page)
  check('sign-ups: invite-only saved', (await one(`select org_creation from public.platform_settings`)).org_creation === 'invite_only')
  await page.getByLabel('E-mail', { exact: true }).fill('newagency@x.test')
  await page.getByRole('button', { name: 'Invite' }).click(); await settle(page)
  check('sign-ups: agency invitation listed', (await main(page)).includes('newagency@x.test'))
  await page.screenshot({ path: `${OUT}/pa-signups.png`, fullPage: true })
})

await as('owner@b.test', { width: 1360, height: 900 }, async (page, go) => {
  await go('/', 'pa-suspended')
  check('suspended agency sees why', (await page.locator('body').innerText()).includes('suspended'))
})

await as('owner@a.test', { width: 1360, height: 900 }, async (page, go) => {
  await go('/platform')
  await page.getByText('Other Agency').click(); await settle(page)
  await dialog(page).getByRole('button', { name: 'Reactivate' }).click(); await settle(page)
  check('agency: reactivated', (await one(`select status from public.organizations where slug = 'other-agency'`)).status === 'active')
})

await as('owner@b.test', { width: 1360, height: 900 }, async (page, go) => {
  await go('/')
  const nav = await page.locator('nav[aria-label="Main"]').innerText()
  check('reactivated agency works; other Super Admin has no Platform menu', nav.includes('Dashboard') && !nav.includes('Platform'))
  await go('/platform')
  check('other Super Admin: platform page guarded', /don't have access/.test(await main(page)))
})

await as('stranger@x.test', { width: 1360, height: 900 }, async (page, go) => {
  await go('/onboarding', 'pa-onboarding-invite-only')
  check('invite-only explained on onboarding', (await page.locator('body').innerText()).includes('by invitation'))
})

await as('owner@a.test', { width: 390, height: 844 }, async (page, go) => {
  await go('/platform', 'pa-mobile')
  check('mobile /platform: no horizontal page overflow', !(await page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth + 1)))
})

await db.end()
const failed = results.filter((r) => !r.ok).length
console.log(`\n${results.length - failed}/${results.length} passed`)
process.exit(failed ? 1 : 0)
