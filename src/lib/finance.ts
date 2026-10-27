// Pure helpers for invoices, payroll and offers. The database computes the official numbers;
// these mirror its rules for live previews and printing, and are unit-tested.

export type LineKind = 'management_fee' | 'ad_spend' | 'other'
export interface LineInput { kind: LineKind; quantity: number; unit_price: number; gst_rate: number }
export interface Totals {
  fee: number; adSpend: number; other: number; taxable: number
  cgst: number; sgst: number; igst: number; roundOff: number; total: number
}

export const GST_RATES = [0, 5, 12, 18, 28] as const

const r2 = (n: number) => Math.round((n + Number.EPSILON) * 100) / 100

/** Same maths as app.recalc_invoice: per-line tax rounded to paise, total rounded to the rupee. */
export function invoiceTotals(lines: LineInput[], mode: 'intra' | 'inter'): Totals {
  let fee = 0, adSpend = 0, other = 0, tax = 0
  for (const l of lines) {
    const amount = r2(Number(l.quantity) * Number(l.unit_price))
    if (l.kind === 'management_fee') fee += amount
    else if (l.kind === 'ad_spend') adSpend += amount
    else other += amount
    tax += r2((amount * Number(l.gst_rate)) / 100)
  }
  const taxable = r2(fee + adSpend + other)
  tax = r2(tax)
  const cgst = mode === 'intra' ? r2(tax / 2) : 0
  const sgst = mode === 'intra' ? r2(tax - cgst) : 0
  const igst = mode === 'inter' ? tax : 0
  const raw = r2(taxable + tax)
  const total = Math.round(raw)
  return { fee: r2(fee), adSpend: r2(adSpend), other: r2(other), taxable, cgst, sgst, igst, roundOff: r2(total - raw), total }
}

/** Indian financial year label, e.g. 2026-10-27 -> "2026-27", 2027-02-01 -> "2026-27". */
export function fiscalYear(isoDate: string): string {
  const [y, m] = isoDate.split('-').map(Number) as [number, number]
  const start = m >= 4 ? y : y - 1
  return `${start}-${String((start + 1) % 100).padStart(2, '0')}`
}

export const GST_STATES: Record<string, string> = {
  '01': 'Jammu & Kashmir', '02': 'Himachal Pradesh', '03': 'Punjab', '04': 'Chandigarh', '05': 'Uttarakhand', '06': 'Haryana', '07': 'Delhi',
  '08': 'Rajasthan', '09': 'Uttar Pradesh', '10': 'Bihar', '11': 'Sikkim', '12': 'Arunachal Pradesh', '13': 'Nagaland', '14': 'Manipur',
  '15': 'Mizoram', '16': 'Tripura', '17': 'Meghalaya', '18': 'Assam', '19': 'West Bengal', '20': 'Jharkhand', '21': 'Odisha',
  '22': 'Chhattisgarh', '23': 'Madhya Pradesh', '24': 'Gujarat', '26': 'Dadra & Nagar Haveli and Daman & Diu', '27': 'Maharashtra',
  '29': 'Karnataka', '30': 'Goa', '31': 'Lakshadweep', '32': 'Kerala', '33': 'Tamil Nadu', '34': 'Puducherry', '35': 'Andaman & Nicobar Islands',
  '36': 'Telangana', '37': 'Andhra Pradesh', '38': 'Ladakh', '97': 'Other Territory',
}
export const stateName = (code?: string | null) => (code ? `${GST_STATES[code] ?? 'State'} (${code})` : '—')

export function isValidGstin(v: string): boolean {
  return /^[0-9]{2}[0-9A-Z]{13}$/.test(v.trim().toUpperCase())
}

const ONES = ['', 'One', 'Two', 'Three', 'Four', 'Five', 'Six', 'Seven', 'Eight', 'Nine', 'Ten', 'Eleven', 'Twelve', 'Thirteen',
  'Fourteen', 'Fifteen', 'Sixteen', 'Seventeen', 'Eighteen', 'Nineteen']
const TENS = ['', '', 'Twenty', 'Thirty', 'Forty', 'Fifty', 'Sixty', 'Seventy', 'Eighty', 'Ninety']

function twoDigits(n: number): string {
  if (n < 20) return ONES[n]!
  return TENS[Math.floor(n / 10)]! + (n % 10 ? '-' + ONES[n % 10] : '')
}
function threeDigits(n: number): string {
  const h = Math.floor(n / 100), rest = n % 100
  return [h ? `${ONES[h]} Hundred` : '', rest ? twoDigits(rest) : ''].filter(Boolean).join(' ')
}

/** Indian numbering system in words: 3950000.5 -> "Thirty-Nine Lakh Fifty Thousand Rupees and Fifty Paise Only". */
export function amountInWords(value: number): string {
  const rupees = Math.floor(Math.abs(value))
  const paise = Math.round((Math.abs(value) - rupees) * 100)
  const parts: string[] = []
  const crore = Math.floor(rupees / 1e7), lakh = Math.floor((rupees % 1e7) / 1e5), thousand = Math.floor((rupees % 1e5) / 1e3), rest = rupees % 1e3
  if (crore) parts.push(`${crore >= 100 ? amountInWords(crore).replace(/ Rupees.*$/, '') : twoDigits(crore)} Crore`)
  if (lakh) parts.push(`${twoDigits(lakh)} Lakh`)
  if (thousand) parts.push(`${twoDigits(thousand)} Thousand`)
  if (rest) parts.push(threeDigits(rest))
  const words = parts.length ? parts.join(' ') : 'Zero'
  return `${words} Rupees${paise ? ` and ${twoDigits(paise)} Paise` : ''} Only`
}

/** Two-decimal money for invoices and payslips (fmtMoney rounds to whole rupees). */
export function fmtAmount(value?: number | null, currency = 'INR'): string {
  if (value == null) return '—'
  return new Intl.NumberFormat('en-IN', { style: 'currency', currency, minimumFractionDigits: 2, maximumFractionDigits: 2 }).format(Number(value))
}

/** Days overdue relative to today (negative = not yet due). */
export function daysPastDue(dueDate: string, todayIso: string): number {
  return Math.round((Date.parse(todayIso) - Date.parse(dueDate)) / 86_400_000)
}

export interface PayslipLine { code?: string; name?: string; label?: string; kind?: string; amount: number }

/** Bank transfer sheet rows from payslips (skips zero net pay). */
export function bankSheet(slips: { employee_code: string; employee_name: string; net_pay: number; bank: { bank_name?: string; account_number?: string; ifsc?: string } }[]) {
  return slips.filter((s) => Number(s.net_pay) > 0).map((s) => ({
    employee_code: s.employee_code, employee_name: s.employee_name, bank_name: s.bank.bank_name ?? '', account_number: s.bank.account_number ?? '',
    ifsc: s.bank.ifsc ?? '', amount: Number(s.net_pay).toFixed(2), missing_bank: !s.bank.account_number || !s.bank.ifsc ? 'yes' : '',
  }))
}

/** Default monthly split used when hiring from an offer: Basic 50%, HRA 20%, Special = rest (matches hire_candidate). */
export function splitCtc(annualCtc: number) {
  const month = r2(annualCtc / 12)
  const basic = Math.round(month * 0.5), hra = Math.round(month * 0.2)
  return { month, basic, hra, special: r2(month - basic - hra) }
}

export function offerLetter(o: { agency: string; candidate: string; designation: string; department?: string | null; annualCtc: number
  joiningDate: string; validUntil?: string | null; location?: string | null; signatory?: string | null }): string {
  const ctc = new Intl.NumberFormat('en-IN', { style: 'currency', currency: 'INR', maximumFractionDigits: 0 }).format(o.annualCtc)
  const s = splitCtc(o.annualCtc)
  const fmt = (d: string) => new Date(d + 'T00:00:00').toLocaleDateString('en-IN', { day: '2-digit', month: 'long', year: 'numeric' })
  return [
    `Dear ${o.candidate},`,
    `We are delighted to offer you the position of ${o.designation}${o.department ? ` in our ${o.department} team` : ''} at ${o.agency}${o.location ? `, based in ${o.location}` : ''}.`,
    `Your annual cost to company (CTC) will be ${ctc}. Indicative monthly break-up: Basic ₹${s.basic.toLocaleString('en-IN')}, HRA ₹${s.hra.toLocaleString('en-IN')}, Special allowance ₹${s.special.toLocaleString('en-IN')}. Statutory deductions apply as per law.`,
    `Your joining date will be ${fmt(o.joiningDate)}. On joining, please bring your ID proof, address proof, PAN card, educational certificates, relieving letter from your last employer and a cancelled cheque.`,
    o.validUntil ? `This offer is valid until ${fmt(o.validUntil)}. Please confirm your acceptance by replying to this letter.` : 'Please confirm your acceptance by replying to this letter.',
    'We look forward to having you on the team.',
    `Warm regards,\n${o.signatory ?? 'HR Team'}\n${o.agency}`,
  ].join('\n\n')
}
