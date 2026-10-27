import { describe, expect, it } from 'vitest'
import { parseCampaignCsv, parseCsv, parseDate, parseNumber, sha256Hex, decodeFile } from './campaignCsv'
import { monthGrid, parseDuration, weekDays, weekStartOf } from './dates'
import { visibleNav } from './permissions'

describe('campaign CSV import', () => {
  it('parses a Google Ads "by day" export with title lines, quoted numbers and a totals row', () => {
    const csv = [
      'Campaign report', '"1 October 2026 - 3 October 2026"',
      'Day,Campaign,Campaign ID,Impr.,Clicks,Cost,Conversions,Conv. value',
      '2026-10-01,Brand Search,111,"1,000",100,"2,500.50",10,"50,000.00"',
      '2026-10-02,Brand Search,111,800,40,"1,000.00",4.5,--',
      'Total: Account,,,"1,800",140,"3,500.50",14.5,"50,000.00"',
    ].join('\n')
    const r = parseCampaignCsv(csv)
    expect(r.errors).toEqual([])
    expect(r.skipped).toBe(1)
    expect(r.rows).toHaveLength(2)
    expect(r.rows[0]).toEqual({ campaign: 'Brand Search', campaign_id: '111', date: '2026-10-01', impressions: 1000, clicks: 100, spend: 2500.5, conversions: 10, conversion_value: 50000 })
    expect(r.rows[1]!.conversion_value).toBe(0)
    expect(r.columns.spend).toBe('Cost')
  })

  it('parses a Meta Ads Manager export (Amount spent (INR), Reporting starts, Results)', () => {
    const csv = 'Campaign name,Reporting starts,Reporting ends,Impressions,Link clicks,Amount spent (INR),Results\n' +
      'Diwali Leads,01/10/2026,01/10/2026,5000,120,1500.75,12\nDiwali Leads,02/10/2026,02/10/2026,4000,90,1200,9\n'
    const r = parseCampaignCsv(csv)
    expect(r.errors).toEqual([])
    expect(r.rows.map((x) => [x.date, x.clicks, x.spend, x.conversions])).toEqual([['2026-10-01', 120, 1500.75, 12], ['2026-10-02', 90, 1200, 9]])
  })

  it('reports unreadable dates and negative numbers by line instead of importing them', () => {
    const r = parseCampaignCsv('Date,Campaign,Cost\n2026-13-45,A,10\n2026-10-01,A,-5\n2026-10-02,A,7')
    expect(r.rows).toHaveLength(1)
    expect(r.errors).toEqual(['Line 2: unreadable date "2026-13-45"', 'Line 3: invalid spend value'])
  })

  it('explains a missing header row', () => {
    expect(parseCampaignCsv('foo,bar\n1,2').errors[0]).toMatch(/header row/)
  })

  it('handles tab-separated UTF-16 files and quoted fields with commas and newlines', () => {
    expect(parseCsv('a\tb\n"x, y"\t"multi\nline"')).toEqual([['a', 'b'], ['x, y', 'multi\nline']])
    const text = 'Day\tCampaign\tCost\n2026-10-01\tA\t5'
    const bytes = new Uint8Array([0xff, 0xfe, ...Array.from(text).flatMap((c) => [c.charCodeAt(0), 0])])
    expect(parseCampaignCsv(decodeFile(bytes.buffer)).rows[0]).toMatchObject({ campaign: 'A', spend: 5 })
  })

  it('parses dates and numbers in common export formats', () => {
    expect(parseDate('2026-10-05')).toBe('2026-10-05')
    expect(parseDate('05/10/2026')).toBe('2026-10-05')
    expect(parseDate('5-Oct-2026')).toBe('2026-10-05')
    expect(parseDate('Oct 5, 2026')).toBe('2026-10-05')
    expect(parseDate('31/02/2026')).toBeNull()
    expect(parseNumber('₹1,23,456.70')).toBe(123456.7)
    expect(parseNumber('--')).toBe(0)
    expect(Number.isNaN(parseNumber('abc'))).toBe(true)
  })

  it('hashes file contents so the same file cannot be imported twice', async () => {
    expect(await sha256Hex('abc')).toBe('ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad')
  })
})

describe('date helpers', () => {
  it('uses ISO weeks starting Monday', () => {
    expect(weekStartOf('2026-11-01')).toBe('2026-10-26') // Sunday belongs to the week starting Monday 26 Oct
    expect(weekStartOf('2026-10-26')).toBe('2026-10-26')
    expect(weekDays('2026-10-26')).toEqual(['2026-10-26', '2026-10-27', '2026-10-28', '2026-10-29', '2026-10-30', '2026-10-31', '2026-11-01'])
  })
  it('builds a 6-week month grid starting on Monday', () => {
    const g = monthGrid('2026-11-15')
    expect(g).toHaveLength(42)
    expect(g[0]).toBe('2026-10-26')
    expect(g).toContain('2026-11-30')
  })
  it('parses durations typed by people', () => {
    expect(parseDuration('1:30')).toBe(90)
    expect(parseDuration('1.5')).toBe(90)
    expect(parseDuration('45m')).toBe(45)
    expect(parseDuration('2h')).toBe(120)
    expect(parseDuration('1h 15m')).toBe(75)
    expect(parseDuration('soon')).toBeNull()
  })
})

describe('Phase 4 navigation', () => {
  const labels = (s: Set<string>, a: 'internal' | 'client') => visibleNav(s, a, true).map((n) => n.label)
  it('shows Templates and Campaigns to staff only with the permission', () => {
    expect(labels(new Set(), 'internal')).toEqual(expect.arrayContaining(['Calendar', 'Time', 'Content']))
    expect(labels(new Set(), 'internal')).not.toContain('Templates')
    expect(labels(new Set(), 'internal')).not.toContain('Campaigns')
    expect(labels(new Set(['projects.manage_templates', 'campaigns.view']), 'internal')).toEqual(expect.arrayContaining(['Templates', 'Campaigns']))
  })
  it('never shows staff-only pages to clients', () => {
    const c = labels(new Set(), 'client')
    for (const l of ['Calendar', 'Time', 'Templates', 'Clients', 'Employees']) expect(c).not.toContain(l)
  })
})
