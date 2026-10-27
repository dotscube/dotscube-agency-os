import { describe, expect, it } from 'vitest'
import { amountInWords, bankSheet, daysPastDue, fiscalYear, invoiceTotals, isValidGstin, offerLetter, splitCtc } from './finance'
import { NAV_ITEMS, visibleNav } from './permissions'

describe('invoice totals (mirrors app.recalc_invoice)', () => {
  const lines = [
    { kind: 'management_fee' as const, quantity: 1, unit_price: 25000, gst_rate: 18 },
    { kind: 'ad_spend' as const, quantity: 1, unit_price: 10000, gst_rate: 0 },
  ]
  it('splits GST into CGST + SGST within the same state', () => {
    const t = invoiceTotals(lines, 'intra')
    expect(t).toMatchObject({ fee: 25000, adSpend: 10000, taxable: 35000, cgst: 2250, sgst: 2250, igst: 0, total: 39500 })
  })
  it('uses IGST across states', () => {
    const t = invoiceTotals(lines, 'inter')
    expect(t).toMatchObject({ cgst: 0, sgst: 0, igst: 4500, total: 39500 })
  })
  it('keeps ad spend out of the fee subtotal and taxes it at its own rate', () => {
    const t = invoiceTotals([{ kind: 'ad_spend', quantity: 1, unit_price: 1000, gst_rate: 18 }], 'intra')
    expect(t.fee).toBe(0); expect(t.adSpend).toBe(1000); expect(t.cgst + t.sgst).toBe(180)
  })
  it('rounds the total to the rupee and records the round-off', () => {
    const t = invoiceTotals([{ kind: 'other', quantity: 3, unit_price: 333.33, gst_rate: 18 }], 'intra')
    expect(t.taxable).toBe(999.99); expect(t.total).toBe(1180); expect(t.roundOff).toBeCloseTo(1180 - (999.99 + 180), 2)
  })
  it('handles an odd paisa split between CGST and SGST', () => {
    const t = invoiceTotals([{ kind: 'other', quantity: 1, unit_price: 100.05, gst_rate: 18 }], 'intra')
    expect(t.cgst + t.sgst).toBeCloseTo(18.01, 2)
  })
})

describe('financial year and dates', () => {
  it('labels Indian financial years (April–March)', () => {
    expect(fiscalYear('2026-10-27')).toBe('2026-27')
    expect(fiscalYear('2027-03-31')).toBe('2026-27')
    expect(fiscalYear('2027-04-01')).toBe('2027-28')
    expect(fiscalYear('2099-12-01')).toBe('2099-00')
  })
  it('counts days past due', () => {
    expect(daysPastDue('2026-10-20', '2026-10-27')).toBe(7)
    expect(daysPastDue('2026-10-30', '2026-10-27')).toBe(-3)
  })
  it('validates GSTIN shape', () => {
    expect(isValidGstin('08abcde1234f1z5')).toBe(true)
    expect(isValidGstin('8ABCDE1234F1Z5')).toBe(false)
  })
})

describe('amount in words (Indian numbering)', () => {
  it('writes lakhs and crores', () => {
    expect(amountInWords(39500)).toBe('Thirty-Nine Thousand Five Hundred Rupees Only')
    expect(amountInWords(1180)).toBe('One Thousand One Hundred Eighty Rupees Only')
    expect(amountInWords(3950000.5)).toBe('Thirty-Nine Lakh Fifty Thousand Rupees and Fifty Paise Only')
    expect(amountInWords(12_34_56_789)).toBe('Twelve Crore Thirty-Four Lakh Fifty-Six Thousand Seven Hundred Eighty-Nine Rupees Only')
    expect(amountInWords(0)).toBe('Zero Rupees Only')
  })
})

describe('payroll helpers', () => {
  it('splits CTC like hire_candidate does', () => {
    expect(splitCtc(450000)).toEqual({ month: 37500, basic: 18750, hra: 7500, special: 11250 })
  })
  it('builds the bank transfer sheet and flags missing bank details', () => {
    const rows = bankSheet([
      { employee_code: 'EMP1', employee_name: 'A', net_pay: 1000, bank: { account_number: '123456', ifsc: 'HDFC0001234', bank_name: 'HDFC' } },
      { employee_code: 'EMP2', employee_name: 'B', net_pay: 500, bank: {} },
      { employee_code: 'EMP3', employee_name: 'C', net_pay: 0, bank: {} },
    ])
    expect(rows).toHaveLength(2)
    expect(rows[0]).toMatchObject({ amount: '1000.00', missing_bank: '' })
    expect(rows[1]!.missing_bank).toBe('yes')
  })
})

describe('offer letter', () => {
  it('includes the essentials', () => {
    const t = offerLetter({ agency: 'Dotscube', candidate: 'Ravi', designation: 'SEO Executive', annualCtc: 450000, joiningDate: '2026-11-16', validUntil: '2026-11-05' })
    expect(t).toContain('Dear Ravi')
    expect(t).toContain('SEO Executive')
    expect(t).toContain('₹4,50,000')
    expect(t).toContain('valid until')
  })
})

describe('Phase 5 navigation', () => {
  it('shows Invoices only with an invoices permission, Payroll to employees, Recruitment to recruiters', () => {
    const labels = (perms: string[], hasEmployee = true) => visibleNav(new Set(perms), 'internal', hasEmployee).map((n) => n.label)
    expect(labels([])).toContain('Payroll')
    expect(labels([])).not.toContain('Invoices')
    expect(labels([])).not.toContain('Recruitment')
    expect(labels(['invoices.view'])).toContain('Invoices')
    expect(labels(['recruitment.view'])).toContain('Recruitment')
    expect(labels([], false)).not.toContain('Payroll')
  })
  it('clients see their invoices in the portal', () => {
    expect(visibleNav(new Set(), 'client', false).map((n) => n.to)).toContain('/invoices')
    expect(NAV_ITEMS.find((n) => n.to === '/invoices')!.audience).toContain('client')
  })
})

describe('Platform navigation', () => {
  it('shows Platform only to platform admins', () => {
    const all = new Set(['org.manage', 'roles.manage'])
    expect(visibleNav(all, 'internal', true).map((n) => n.to)).not.toContain('/platform')
    expect(visibleNav(all, 'internal', true, true).map((n) => n.to)).toContain('/platform')
    expect(visibleNav(new Set(), 'client', false, true).map((n) => n.to)).not.toContain('/platform')
  })
})
