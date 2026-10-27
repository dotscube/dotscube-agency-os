import { describe, expect, it } from 'vitest'
import { can, dashboardKinds, visibleNav } from './permissions'
import { friendlyError } from './errors'
import { extractMentions, fmtMinutes, initials, toCsv } from './utils'
import { ilikeTerm } from './query'
import { orgToday } from '@/features/attendance/TodayAttendanceCard'
import { zonedIso } from '@/features/attendance/AttendancePage'
import { employeeSchema } from '@/features/employees/EmployeesPage'
import { isOverdue } from '@/features/tasks/shared'

describe('permissions', () => {
  const hr = new Set(['employees.view', 'employees.edit', 'leave.approve', 'attendance.view_all'])
  it('checks all/any', () => {
    expect(can(hr, 'employees.view')).toBe(true)
    expect(can(hr, ['employees.view', 'salary.view'])).toBe(false)
    expect(can(hr, ['employees.view', 'salary.view'], 'any')).toBe(true)
    expect(can(hr, undefined)).toBe(true)
  })
  it('filters navigation by audience, permission and employee record', () => {
    const labels = (s: Set<string>, a: 'internal' | 'client', e: boolean) => visibleNav(s, a, e).map((n) => n.label)
    expect(labels(new Set(), 'client', false)).toEqual(['Dashboard', 'Projects', 'Content', 'Campaigns', 'Notifications'])
    expect(labels(new Set(), 'internal', false)).not.toContain('Clients')
    expect(labels(new Set(), 'internal', false)).not.toContain('Attendance')
    expect(labels(new Set(['clients.view']), 'internal', true)).toEqual(expect.arrayContaining(['Clients', 'Attendance', 'Leave', 'Settings']))
  })
  it('picks dashboards by role', () => {
    expect(dashboardKinds(new Set(), 'client')).toEqual(['client'])
    expect(dashboardKinds(new Set(), 'internal')).toEqual(['employee'])
    expect(dashboardKinds(hr, 'internal')).toEqual(['hr', 'employee'])
    expect(dashboardKinds(new Set(['org.manage', 'projects.view_all']), 'internal')).toEqual(['admin', 'manager', 'employee'])
  })
})

describe('friendlyError', () => {
  it('hides RLS internals', () => {
    expect(friendlyError({ code: '42501', message: 'new row violates row-level security policy for table "clients"' })).toBe("You don't have permission to do that.")
  })
  it('passes through business-rule messages', () => {
    expect(friendlyError({ code: '22023', message: 'Insufficient balance: 2 day(s) available' })).toBe('Insufficient balance: 2 day(s) available')
    expect(friendlyError({ code: '42501', message: 'You cannot approve your own correction' })).toBe('You cannot approve your own correction')
  })
  it('never leaks SQL details', () => {
    expect(friendlyError({ code: '42P01', message: 'relation "public.foo" does not exist' })).toBe('Something went wrong. Please try again.')
  })
})

describe('utils', () => {
  it('formats minutes', () => {
    expect(fmtMinutes(null)).toBe('—'); expect(fmtMinutes(45)).toBe('45m'); expect(fmtMinutes(490)).toBe('8h 10m')
  })
  it('builds initials', () => { expect(initials('Manjeet Madhukar')).toBe('MM'); expect(initials('')).toBe('?') })
  it('escapes CSV and neutralises formula injection', () => {
    const csv = toCsv([{ a: 'x,y', b: '=HYPERLINK("evil")', c: 'line\nbreak' }], [{ key: 'a', label: 'A' }, { key: 'b', label: 'B' }, { key: 'c', label: 'C' }])
    expect(csv).toBe('A,B,C\r\n"x,y","\'=HYPERLINK(""evil"")","line\nbreak"')
  })
  it('extracts @mentions of known people only', () => {
    const people = [{ id: '1', full_name: 'Rahul PM' }, { id: '2', full_name: 'Dev Designer' }, { id: '3', full_name: '' }]
    expect(extractMentions('Hey @rahul pm please check, cc @Nobody', people)).toEqual(['1'])
  })
  it('sanitises search terms for PostgREST filters', () => {
    const t = ilikeTerm('acme,(id.eq.1)')
    expect(t).toBe('%acme  id.eq.1%')
    expect(t.slice(1, -1)).not.toMatch(/[,()%_*\\]/)
    expect(ilikeTerm('50%_off')).toBe('%50  off%')
  })
})

describe('timezone helpers', () => {
  it('computes the org-local date', () => {
    // 20:00 UTC on 26 Oct is already 27 Oct in India
    expect(orgToday('Asia/Kolkata', new Date('2026-10-26T20:00:00Z'))).toBe('2026-10-27')
    expect(orgToday('UTC', new Date('2026-10-26T20:00:00Z'))).toBe('2026-10-26')
  })
  it('converts a wall-clock time in a timezone to UTC', () => {
    expect(zonedIso('2026-10-24', '10:05', 'Asia/Kolkata')).toBe('2026-10-24T04:35:00.000Z')
    expect(zonedIso('2026-07-01', '09:00', 'Europe/London')).toBe('2026-07-01T08:00:00.000Z')
  })
})

describe('validation', () => {
  const base = { full_name: 'Sana SEO', work_email: 'sana@a.test', employment_type: 'full_time', status: 'active', joining_date: '2026-01-01' } as const
  it('accepts a valid employee', () => { expect(employeeSchema.safeParse(base).success).toBe(true) })
  it('requires an exit date for exited employees', () => {
    const r = employeeSchema.safeParse({ ...base, status: 'exited' })
    expect(r.success).toBe(false)
    expect(r.error?.issues[0]?.path).toEqual(['exit_date'])
  })
  it('rejects probation ending before joining', () => {
    expect(employeeSchema.safeParse({ ...base, probation_end_date: '2025-12-01' }).success).toBe(false)
  })
})

describe('tasks', () => {
  it('detects overdue only for open tasks', () => {
    expect(isOverdue({ due_date: '2026-10-01' }, 'in_progress', '2026-10-26')).toBe(true)
    expect(isOverdue({ due_date: '2026-10-01' }, 'done', '2026-10-26')).toBe(false)
    expect(isOverdue({ due_date: '2026-10-26' }, 'todo', '2026-10-26')).toBe(false)
    expect(isOverdue({ due_date: null }, 'todo', '2026-10-26')).toBe(false)
  })
})
