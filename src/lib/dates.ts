import { addDays, format, parseISO, startOfWeek } from 'date-fns'

/** yyyy-MM-dd for a Date (local calendar day). */
export const isoDay = (d: Date) => format(d, 'yyyy-MM-dd')

/** Monday of the week containing `day` (ISO weeks, as the database uses). */
export function weekStartOf(day: string | Date): string {
  const d = typeof day === 'string' ? parseISO(day) : day
  return isoDay(startOfWeek(d, { weekStartsOn: 1 }))
}

export function shiftDays(day: string, n: number): string {
  return isoDay(addDays(parseISO(day), n))
}

/** The seven yyyy-MM-dd days of the week starting at `monday`. */
export function weekDays(monday: string): string[] {
  return Array.from({ length: 7 }, (_, i) => shiftDays(monday, i))
}

/** 6x7 grid of days covering the month of `monthDay` (weeks start Monday). */
export function monthGrid(monthDay: string): string[] {
  const d = parseISO(monthDay)
  const first = new Date(d.getFullYear(), d.getMonth(), 1)
  const start = startOfWeek(first, { weekStartsOn: 1 })
  return Array.from({ length: 42 }, (_, i) => isoDay(addDays(start, i)))
}

/** Parses "1:30", "1.5", "90m", "2h", "1h 15m" into minutes; null if invalid. */
export function parseDuration(input: string): number | null {
  const s = input.trim().toLowerCase()
  if (!s) return null
  let m: RegExpMatchArray | null
  if ((m = s.match(/^(\d{1,2}):([0-5]\d)$/))) return Number(m[1]) * 60 + Number(m[2])
  if ((m = s.match(/^(\d+(?:\.\d+)?)\s*h(?:\s*(\d{1,2})\s*m)?$/))) return Math.round(Number(m[1]) * 60) + Number(m[2] ?? 0)
  if ((m = s.match(/^(\d+)\s*m(?:in)?$/))) return Number(m[1])
  if ((m = s.match(/^\d+(?:\.\d+)?$/))) return Math.round(Number(s) * 60)
  return null
}
