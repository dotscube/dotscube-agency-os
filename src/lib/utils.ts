import { clsx, type ClassValue } from 'clsx'
import { twMerge } from 'tailwind-merge'
import { format, parseISO } from 'date-fns'

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs))
}

export function fmtDate(value?: string | null, pattern = 'dd MMM yyyy'): string {
  if (!value) return '—'
  try { return format(parseISO(value), pattern) } catch { return '—' }
}

export function fmtTime(value?: string | null): string {
  return fmtDate(value, 'hh:mm a')
}

export function fmtMinutes(min?: number | null): string {
  if (min == null) return '—'
  const h = Math.floor(min / 60)
  const m = min % 60
  return h ? `${h}h ${m.toString().padStart(2, '0')}m` : `${m}m`
}

export function fmtMoney(value?: number | null, currency = 'INR'): string {
  if (value == null) return '—'
  return new Intl.NumberFormat('en-IN', { style: 'currency', currency, maximumFractionDigits: 0 }).format(value)
}

export function initials(name?: string | null): string {
  if (!name) return '?'
  return name.split(/\s+/).filter(Boolean).slice(0, 2).map((p) => p[0]!.toUpperCase()).join('')
}

export function titleCase(s?: string | null): string {
  if (!s) return ''
  return s.replace(/_/g, ' ').replace(/\b\w/g, (c) => c.toUpperCase())
}

/** Extract @mentions ("@Full Name" matched against known people) from a comment. */
export function extractMentions(body: string, people: { id: string; full_name: string }[]): string[] {
  const lower = body.toLowerCase()
  return people
    .filter((p) => p.full_name && lower.includes('@' + p.full_name.toLowerCase()))
    .map((p) => p.id)
}

/** Converts rows to RFC 4180 CSV. */
export function toCsv(rows: Record<string, unknown>[], columns: { key: string; label: string }[]): string {
  const esc = (v: unknown) => {
    if (v == null) return ''
    const s = typeof v === 'object' ? JSON.stringify(v) : String(v)
    const safe = /^[=+\-@]/.test(s) ? `'${s}` : s // neutralise spreadsheet formula injection
    return /[",\n\r]/.test(safe) ? `"${safe.replace(/"/g, '""')}"` : safe
  }
  return [columns.map((c) => esc(c.label)).join(','), ...rows.map((r) => columns.map((c) => esc(r[c.key])).join(','))].join('\r\n')
}

export function downloadCsv(filename: string, csv: string) {
  const blob = new Blob(['﻿' + csv], { type: 'text/csv;charset=utf-8' })
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url
  a.download = filename
  a.click()
  URL.revokeObjectURL(url)
}
