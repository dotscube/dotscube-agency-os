// Phase 5 end-to-end test: the built app in Chromium against the real test database through scripts/e2e/sql-rest.mjs
// (row-level security, triggers and RPCs all run for real). Run after `npm run test:db` so the fixtures exist.
// Usage: BASE=http://localhost:8787 node scripts/e2e/phase5-e2e.mjs
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

// ---------- Accounts: invoices ----------
await as('acc@a.test', { width: 1360, height: 900 }, async (page, go) => {
  await go('/invoices', 'p5-invoices')
  let t = await main(page)
  check('invoices: list shows numbered invoices', /INV\/20\d\d-\d\d\/0001/.test(t) && t.includes('Maahaul India'))
  check('invoices: overdue invoice flagged', /Overdue \d+d/.test(t))
  await page.getByRole('tab', { name: 'Collections' }).click(); await settle(page)
  await page.screenshot({ path: `${OUT}/p5-collections.png`, fullPage: true })
  t = await main(page)
  check('collections: outstanding, ageing and top debtors', t.includes('Outstanding') && t.includes('1–30 days') && t.includes('Second Client'))
  await page.getByRole('tab', { name: 'Billing settings' }).click(); await settle(page)
  check('billing settings: GSTIN loaded', (await page.getByLabel('GSTIN', { exact: true }).inputValue()) === '08AAACD1234F1Z2')
  await page.getByLabel('Phone').fill('+91 98290 00000'); await page.getByRole('button', { name: 'Save' }).click(); await settle(page)
  check('billing settings: saved', (await one(`select phone from public.billing_settings where gstin = '08AAACD1234F1Z2'`)).phone === '+91 98290 00000')

  await page.getByRole('tab', { name: 'Invoices' }).click()
  await page.getByRole('button', { name: 'New invoice' }).click()
  await dialog(page).getByLabel('Client').selectOption({ label: 'Maahaul India' }); await settle(page, 300)
  await dialog(page).getByLabel('Contract', { exact: true }).selectOption({ index: 1 })
  await dialog(page).getByLabel('Billing month').fill('2026-10')
  await page.screenshot({ path: `${OUT}/p5-new-invoice.png` })
  await page.getByRole('button', { name: 'Create draft' }).click(); await settle(page, 800)
  check('new invoice: opens the draft', /\/invoices\/[0-9a-f-]{36}$/.test(page.url()))
  t = await main(page)
  check('draft: fee line from contract', t.includes('SEO retainer — October 2026'))
  check('draft: ad spend line from October campaign data', /Ad spend — Google Ads — October 2026/.test(t))
  check('draft: CGST and SGST for same-state client', t.includes('CGST') && t.includes('SGST') && !t.includes('IGST'))
  await page.getByRole('button', { name: 'Add line' }).click()
  await dialog(page).getByLabel('Type').selectOption('other')
  await dialog(page).getByLabel('Description').fill('Landing page design')
  await dialog(page).getByLabel('Rate', { exact: true }).fill('5000')
  await dialog(page).getByRole('button', { name: 'Save' }).click(); await settle(page)
  check('draft: line added and totals recomputed', (await main(page)).includes('Landing page design') && Number((await one(`select other_subtotal from public.invoices where id = $1`, [page.url().split('/').pop()])).other_subtotal) === 5000)
  await page.screenshot({ path: `${OUT}/p5-draft.png`, fullPage: true })
  await page.getByRole('button', { name: 'Issue invoice' }).click()
  await dialog(page).getByRole('button', { name: /^Issue/ }).click(); await settle(page, 800)
  const inv = await one(`select * from public.invoices where id = $1`, [page.url().split('/').pop()])
  check('issue: invoice numbered and locked', inv.status === 'issued' && /^INV\/\d{4}-\d{2}\/\d{4}$/.test(inv.invoice_number))
  t = await main(page)
  check('issued: shows number, amount in words and payment details', t.includes(inv.invoice_number) && /Rupees.*Only/.test(t) && t.includes('HDFC'))
  check('issued: lines are no longer editable', !(await page.getByRole('button', { name: 'Add line' }).isVisible()))
  await page.screenshot({ path: `${OUT}/p5-invoice.png`, fullPage: true })
  await page.getByRole('button', { name: 'Record payment' }).click()
  await dialog(page).getByLabel('Amount received').fill('10000')
  await dialog(page).getByLabel('Reference').fill('UTR-E2E-1')
  await dialog(page).getByRole('button', { name: 'Save' }).click(); await settle(page)
  const after = await one(`select status, amount_received from public.invoices where id = $1`, [inv.id])
  check('payment: recorded, invoice part paid', after.status === 'partially_paid' && Number(after.amount_received) === 10000)
  check('payment: listed with reference', (await main(page)).includes('Ref UTR-E2E-1'))
  await page.getByRole('button', { name: 'Record payment' }).click()
  await dialog(page).getByLabel('Amount received').fill('9999999')
  check('payment: overpayment blocked in the form', await dialog(page).getByRole('button', { name: 'Save' }).isDisabled())
  await page.keyboard.press('Escape')
  check('print button available', await page.getByRole('button', { name: 'Print / PDF' }).isVisible())
})

// ---------- Client portal ----------
await as('cli@maahaul.test', { width: 1360, height: 900 }, async (page, go) => {
  await go('/', 'p5-client-dashboard')
  check('client dashboard: amount due shown', /due/.test(await main(page)) && (await main(page)).includes('unpaid invoice'))
  await go('/invoices', 'p5-client-invoices')
  const t = await main(page)
  check('client: sees own issued invoices only', /INV\/\d{4}-\d{2}\/0001/.test(t) && !t.includes('Draft') && !/\/0002/.test(t))
  check('client: cannot create invoices', !(await page.getByRole('button', { name: 'New invoice' }).isVisible()))
  await page.getByText(/INV\/\d{4}-\d{2}\/0001/).first().click(); await settle(page)
  check('client: opens invoice, cannot record payments', (await main(page)).includes('Tax Invoice') && !(await page.getByRole('button', { name: 'Record payment' }).isVisible()))
})

// ---------- HR: payroll and recruitment ----------
await as('hr@a.test', { width: 1360, height: 900 }, async (page, go) => {
  await go('/payroll', 'p5-payroll-runs')
  check('payroll: September run listed as paid', /September 2026[\s\S]*Paid/.test(await main(page)))
  await page.getByRole('button', { name: 'Run payroll' }).click()
  await dialog(page).getByLabel('Month').fill('2026-10')
  await dialog(page).getByRole('button', { name: 'Calculate' }).click(); await settle(page, 800)
  let t = await main(page)
  check('payroll: October draft calculated', t.includes('October 2026') && t.includes('Sana SEO') && t.includes('Draft'))
  check('payroll: people without salary flagged', t.includes('no salary structure') && t.includes('Rahul PM'))
  await page.getByText('Sana SEO').click(); await settle(page, 300)
  await dialog(page).getByRole('button', { name: 'Add adjustment' }).click()
  await dialog(page).getByLabel('Label').fill('Diwali bonus'); await dialog(page).getByLabel('Amount').fill('1500')
  await dialog(page).getByRole('button', { name: 'Save' }).click(); await settle(page)
  const slip = await one(`select p.gross, p.adjustments from public.payslips p join public.payroll_runs r on r.id = p.run_id
    join public.employee_profiles e on e.id = p.employee_id where r.period_month = '2026-10-01' and e.work_email = 'seo@a.test'`)
  check('payroll: adjustment saved into the payslip', slip.adjustments[0]?.label === 'Diwali bonus' && Number(slip.gross) === 29500)
  await page.screenshot({ path: `${OUT}/p5-payroll-run.png`, fullPage: true })
  await page.getByRole('button', { name: 'Finalize' }).click(); await settle(page, 800)
  check('payroll: finalized', (await one(`select status from public.payroll_runs where period_month = '2026-10-01'`)).status === 'finalized')
  check('payroll: bank transfer sheet offered', await page.getByRole('button', { name: 'Bank transfer sheet' }).isVisible())

  await go('/recruitment', 'p5-recruitment')
  await page.getByLabel('Status').selectOption(''); await settle(page)
  check('recruitment: openings with pipeline', (await main(page)).includes('SEO Executive') && /1\/1/.test(await main(page)))
  await page.getByRole('button', { name: 'New opening' }).click()
  await dialog(page).getByLabel('Job title').fill('Graphic Designer')
  await dialog(page).getByLabel('Location').fill('Jaipur')
  await dialog(page).getByRole('button', { name: 'Save' }).click(); await settle(page)
  await page.getByLabel('Status').selectOption('active'); await settle(page)
  await page.getByText('Graphic Designer').first().click(); await settle(page)
  await page.getByRole('button', { name: 'Add candidate' }).click()
  await dialog(page).getByLabel('Full name').fill('Neha Sharma'); await dialog(page).getByLabel('E-mail').fill('neha@cand.test')
  await dialog(page).getByLabel('Expected CTC (annual)').fill('360000')
  await dialog(page).getByRole('button', { name: 'Add' }).click(); await settle(page)
  check('opening board: candidate in Applied', /Applied\s*1/.test(await main(page)) && (await main(page)).includes('Neha Sharma'))
  await page.screenshot({ path: `${OUT}/p5-opening.png`, fullPage: true })
  await page.getByText('Neha Sharma').click(); await settle(page)
  await page.getByLabel('Move to stage').selectOption('screening'); await settle(page)
  check('candidate: moved to screening', (await one(`select stage from public.candidates where email = 'neha@cand.test'`)).stage === 'screening')
  await page.getByRole('button', { name: 'Schedule' }).click()
  await dialog(page).getByLabel('Interviewer').selectOption({ label: 'Dev Designer' })
  await dialog(page).getByLabel('Date & time').fill('2026-12-02T11:00')
  await dialog(page).getByLabel(/Meeting link/).fill('https://meet.google.com/abc-defg-hij')
  await dialog(page).getByRole('button', { name: 'Save' }).click(); await settle(page)
  check('candidate: interview scheduled, stage moved on', (await one(`select stage from public.candidates where email = 'neha@cand.test'`)).stage === 'interview')
  await page.getByRole('button', { name: 'Create offer' }).click()
  await dialog(page).getByLabel('Joining date').fill('2026-12-15')
  await dialog(page).getByRole('button', { name: 'Write letter from template' }).click()
  check('offer: letter drafted from template', (await dialog(page).getByLabel('Offer letter').inputValue()).includes('Dear Neha Sharma'))
  await dialog(page).getByRole('button', { name: 'Save draft' }).click(); await settle(page)
  await page.getByRole('button', { name: 'Mark as sent' }).click(); await settle(page)
  check('offer: sent and candidate at offer stage', (await one(`select o.status, c.stage from public.offers o join public.candidates c on c.id = o.candidate_id where c.email = 'neha@cand.test'`)).stage === 'offer')
  await page.screenshot({ path: `${OUT}/p5-candidate.png`, fullPage: true })
})

// ---------- Employee: own payslip, interviewer view ----------
await as('seo@a.test', { width: 1360, height: 900 }, async (page, go) => {
  const nav = await page.locator('nav[aria-label="Main"]').innerText().catch(() => '')
  await go('/payroll', 'p5-my-payslips')
  const navText = await page.locator('nav[aria-label="Main"]').innerText()
  check('employee: nav has Payroll, not Invoices or Recruitment', navText.includes('Payroll') && !navText.includes('Invoices') && !navText.includes('Recruitment'), nav)
  const t = await main(page)
  check('employee: sees own September and October payslips', t.includes('September 2026') && t.includes('October 2026') && !t.includes('Payroll runs'))
  await page.getByText('October 2026').click(); await settle(page)
  await page.screenshot({ path: `${OUT}/p5-payslip.png`, fullPage: true })
  const s = await main(page)
  check('payslip: earnings, bonus and net pay in words', s.includes('Diwali bonus') && s.includes('Net pay') && /Rupees.*Only/.test(s))
  await go('/recruitment')
  check('interviewer: sees their interview with feedback', (await main(page)).includes('Ravi Kumar') && (await main(page)).includes('Yes'))
  await go('/invoices')
  check('employee: invoices page guarded', /don't have access/.test(await main(page)))
})

await as('des@a.test', { width: 1360, height: 900 }, async (page, go) => {
  await go('/recruitment')
  await page.getByRole('tab', { name: 'My interviews' }).click(); await settle(page)
  check('new interviewer: upcoming interview listed', (await main(page)).includes('Neha Sharma') && (await main(page)).includes('Upcoming'))
  await page.getByText('Neha Sharma').click(); await settle(page)
  const t = await main(page)
  check('interviewer: candidate profile without CTC or offer details', t.includes('Neha Sharma') && !t.includes('Expected CTC') && !t.includes('Annual CTC') && !(await page.getByRole('button', { name: 'Mark as sent' }).isVisible()))
})

// ---------- Owner: settings and dashboard ----------
await as('owner@a.test', { width: 1360, height: 900 }, async (page, go) => {
  await go('/', 'p5-dashboard')
  const t = await main(page)
  check('dashboard: billing & collections and payroll cards', t.includes('Billing & collections') && t.includes('Payroll') && t.includes('open position'))
  await go('/settings')
  await page.getByRole('tab', { name: 'E-mail' }).click(); await settle(page)
  await page.screenshot({ path: `${OUT}/p5-email-settings.png`, fullPage: true })
  const e = await main(page)
  check('settings: e-mail delivery status', e.includes('Delivery status') && e.includes('Waiting') && (await page.getByLabel('Send e-mails').isChecked()))
  await page.getByRole('button', { name: 'Send me a test e-mail' }).click(); await settle(page)
  check('settings: test e-mail queued', Number((await one(`select count(*) from public.email_outbox where category = 'test' and to_email = 'owner@a.test'`)).count) >= 2)
  const emp = (await one(`select id from public.employee_profiles where work_email = 'mid@a.test'`)).id
  await go(`/employees/${emp}`)
  await page.getByRole('tab', { name: 'Private details' }).click(); await settle(page)
  check('employee: salary account shown masked', (await main(page)).includes('•••• 6789'))
})

// ---------- Mobile ----------
await as('acc@a.test', { width: 390, height: 844 }, async (page, go) => {
  const inv = (await one(`select id from public.invoices where status <> 'draft' order by created_at limit 1`)).id
  for (const p of ['/invoices', `/invoices/${inv}`, '/payroll', '/']) {
    await go(p, `p5-mobile${p.replace(/\//g, '-').slice(0, 30)}`)
    const overflow = await page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth + 1)
    check(`mobile ${p.slice(0, 20)}: no horizontal page overflow`, !overflow)
  }
})
await as('hr@a.test', { width: 390, height: 844 }, async (page, go) => {
  for (const p of ['/recruitment', '/payroll']) {
    await go(p, `p5-mobile-hr${p.replace('/', '-')}`)
    check(`mobile ${p}: no horizontal page overflow`, !(await page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth + 1)))
  }
})

await db.end()
const failed = results.filter((r) => !r.ok).length
console.log(`\n${results.length - failed}/${results.length} passed`)
process.exit(failed ? 1 : 0)
