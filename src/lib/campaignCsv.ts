// Parses Google Ads / Meta Ads "by day" CSV exports into rows for import_campaign_metrics().
// Pure functions so they can be unit-tested.

export interface MetricRow {
  campaign: string; campaign_id?: string; date: string
  impressions: number; clicks: number; spend: number; conversions: number; conversion_value: number
}
export interface ParseResult { rows: MetricRow[]; errors: string[]; skipped: number; columns: Record<string, string> }

/** RFC 4180 CSV (quotes, escaped quotes, CRLF); also handles tab-separated files (Google Ads "CSV" downloads are often UTF-16 TSV). */
export function parseCsv(text: string): string[][] {
  const src = text.replace(/^﻿/, '')
  const firstLine = src.split(/\r?\n/, 1)[0] ?? ''
  const delim = (firstLine.match(/\t/g)?.length ?? 0) > (firstLine.match(/,/g)?.length ?? 0) ? '\t' : ','
  const out: string[][] = []
  let row: string[] = [], cell = '', q = false
  for (let i = 0; i < src.length; i++) {
    const c = src[i]!
    if (q) {
      if (c === '"' && src[i + 1] === '"') { cell += '"'; i++ }
      else if (c === '"') q = false
      else cell += c
    } else if (c === '"') q = true
    else if (c === delim) { row.push(cell); cell = '' }
    else if (c === '\n' || c === '\r') {
      if (c === '\r' && src[i + 1] === '\n') i++
      row.push(cell); out.push(row); row = []; cell = ''
    } else cell += c
  }
  if (cell !== '' || row.length) { row.push(cell); out.push(row) }
  return out.filter((r) => r.some((x) => x.trim() !== ''))
}

const norm = (h: string) => h.toLowerCase().replace(/\(.*?\)/g, '').replace(/[^a-z]+/g, ' ').trim()
const ALIASES: Record<keyof MetricRow, string[]> = {
  campaign: ['campaign', 'campaign name'],
  campaign_id: ['campaign id'],
  date: ['day', 'date', 'reporting starts', 'reporting date'],
  impressions: ['impressions', 'impr'],
  clicks: ['clicks', 'link clicks', 'clicks all'],
  spend: ['cost', 'amount spent', 'spend'],
  conversions: ['conversions', 'conv', 'results', 'purchases', 'leads'],
  conversion_value: ['conv value', 'conversion value', 'all conv value', 'purchases conversion value', 'purchase conversion value', 'website purchases conversion value'],
}

export function parseNumber(v: string | undefined): number {
  if (v == null) return 0
  const s = v.trim()
  if (s === '' || s === '--' || s === '-' || s === ' --') return 0
  const n = Number(s.replace(/[₹$€£,\s%]/g, '').replace(/^INR/i, ''))
  return Number.isFinite(n) ? n : NaN
}

const MONTHS: Record<string, number> = { jan: 1, feb: 2, mar: 3, apr: 4, may: 5, jun: 6, jul: 7, aug: 8, sep: 9, oct: 10, nov: 11, dec: 12 }
const pad = (n: number) => String(n).padStart(2, '0')
const valid = (y: number, m: number, d: number) => {
  const dt = new Date(Date.UTC(y, m - 1, d))
  return dt.getUTCFullYear() === y && dt.getUTCMonth() === m - 1 && dt.getUTCDate() === d ? `${y}-${pad(m)}-${pad(d)}` : null
}
/** Accepts 2026-10-01, 01/10/2026 (day first, Indian format), 1-Oct-2026, "Oct 1, 2026", "1 Oct 2026". */
export function parseDate(v: string | undefined): string | null {
  if (!v) return null
  const s = v.trim()
  let m: RegExpMatchArray | null
  if ((m = s.match(/^(\d{4})-(\d{1,2})-(\d{1,2})/))) return valid(+m[1]!, +m[2]!, +m[3]!)
  if ((m = s.match(/^(\d{1,2})[/.-](\d{1,2})[/.-](\d{4})$/))) return valid(+m[3]!, +m[2]!, +m[1]!)
  if ((m = s.match(/^(\d{1,2})[\s-]([A-Za-z]{3})[a-z]*[\s,-]+(\d{4})$/))) return MONTHS[m[2]!.toLowerCase()] ? valid(+m[3]!, MONTHS[m[2]!.toLowerCase()]!, +m[1]!) : null
  if ((m = s.match(/^([A-Za-z]{3})[a-z]*\s+(\d{1,2}),?\s+(\d{4})$/))) return MONTHS[m[1]!.toLowerCase()] ? valid(+m[3]!, MONTHS[m[1]!.toLowerCase()]!, +m[2]!) : null
  return null
}

export function parseCampaignCsv(text: string): ParseResult {
  const table = parseCsv(text)
  const errors: string[] = []
  // export files often start with a title line or two; the header is the first row with a campaign and a date column
  const headerIdx = table.findIndex((r) => {
    const n = r.map(norm)
    return n.some((h) => ALIASES.campaign.includes(h) || ALIASES.campaign_id.includes(h)) && n.some((h) => ALIASES.date.includes(h))
  })
  if (headerIdx < 0) return { rows: [], errors: ['Could not find the header row. The file needs Campaign and Day/Date columns (export the report "by day").'], skipped: 0, columns: {} }
  const header = table[headerIdx]!.map(norm)
  const col: Partial<Record<keyof MetricRow, number>> = {}
  const columns: Record<string, string> = {}
  for (const key of Object.keys(ALIASES) as (keyof MetricRow)[]) {
    // prefer the earliest alias (most specific mapping) that is present
    for (const a of ALIASES[key]) {
      const i = header.indexOf(a)
      if (i >= 0 && !Object.values(col).includes(i)) { col[key] = i; columns[key] = table[headerIdx]![i]!; break }
    }
  }
  if (col.spend == null) errors.push('No cost / amount spent column found.')
  const rows: MetricRow[] = []
  let skipped = 0
  table.slice(headerIdx + 1).forEach((r, k) => {
    const line = headerIdx + k + 2
    const get = (key: keyof MetricRow) => (col[key] != null ? r[col[key]!] ?? '' : '')
    const campaign = get('campaign').trim(), campaign_id = get('campaign_id').trim()
    if (/^total/i.test(campaign) || /^total/i.test(r[0] ?? '') || (!campaign && !campaign_id)) { skipped++; return }
    const date = parseDate(get('date'))
    if (!date) { errors.push(`Line ${line}: unreadable date "${get('date')}"`); return }
    const nums = { impressions: parseNumber(get('impressions')), clicks: parseNumber(get('clicks')), spend: parseNumber(get('spend')),
      conversions: parseNumber(get('conversions')), conversion_value: parseNumber(get('conversion_value')) }
    const bad = Object.entries(nums).find(([, v]) => !Number.isFinite(v) || v < 0)
    if (bad) { errors.push(`Line ${line}: invalid ${bad[0]} value`); return }
    rows.push({ campaign: campaign || `Campaign ${campaign_id}`, ...(campaign_id ? { campaign_id } : {}), date,
      impressions: Math.round(nums.impressions), clicks: Math.round(nums.clicks), spend: Math.round(nums.spend * 100) / 100,
      conversions: Math.round(nums.conversions * 100) / 100, conversion_value: Math.round(nums.conversion_value * 100) / 100 })
  })
  return { rows, errors, skipped, columns }
}

export async function sha256Hex(data: ArrayBuffer | string): Promise<string> {
  const buf = typeof data === 'string' ? new TextEncoder().encode(data) : new Uint8Array(data)
  const hash = await crypto.subtle.digest('SHA-256', buf)
  return [...new Uint8Array(hash)].map((b) => b.toString(16).padStart(2, '0')).join('')
}

/** Decodes an uploaded file, handling the UTF-16 files Google Ads produces. */
export function decodeFile(buf: ArrayBuffer): string {
  const b = new Uint8Array(buf)
  if (b[0] === 0xff && b[1] === 0xfe) return new TextDecoder('utf-16le').decode(buf)
  if (b[0] === 0xfe && b[1] === 0xff) return new TextDecoder('utf-16be').decode(buf)
  return new TextDecoder('utf-8').decode(buf)
}
