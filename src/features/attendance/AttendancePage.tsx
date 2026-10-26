import { useMemo, useState } from 'react'
import { useSearchParams } from 'react-router-dom'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { z } from 'zod'
import { toast } from 'sonner'
import { Download, PencilLine } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { unwrap } from '@/lib/query'
import { friendlyError } from '@/lib/errors'
import { downloadCsv, fmtDate, fmtMinutes, fmtTime, toCsv } from '@/lib/utils'
import { nameOf, useEmployeesLite } from '@/lib/lookups'
import type { AttendanceCorrection, AttendanceRecord } from '@/lib/types'
import { useAuth } from '@/features/auth/AuthProvider'
import { DataTable } from '@/components/DataTable'
import { Badge, Button, Card, CardHeader, Dialog, Field, Input, PageHeader, StatusBadge, Tabs, Textarea } from '@/components/ui'
import { attendanceLabel, orgToday, TodayAttendanceCard } from './TodayAttendanceCard'

type Tab = 'mine' | 'team' | 'approvals' | 'report'

function monthRange(month: string) {
  const [y, m] = month.split('-').map(Number) as [number, number]
  const last = new Date(Date.UTC(y, m, 0)).getUTCDate()
  return { from: `${month}-01`, to: `${month}-${String(last).padStart(2, '0')}` }
}

const correctionSchema = z.object({
  work_date: z.string().min(1, 'Pick a date'),
  check_in: z.string().regex(/^\d{2}:\d{2}$/, 'Enter a time'),
  check_out: z.string().regex(/^\d{2}:\d{2}$/, 'Enter a time'),
  reason: z.string().trim().min(5, 'Explain briefly (min 5 characters)'),
}).refine((v) => v.check_out > v.check_in, { message: 'Check-out must be after check-in', path: ['check_out'] })

/** Builds an ISO timestamp for a wall-clock time in the given IANA timezone. */
export function zonedIso(date: string, time: string, timeZone: string): string {
  const guess = new Date(`${date}T${time}:00Z`)
  const parts = new Intl.DateTimeFormat('en-US', { timeZone, hour12: false, year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit' })
    .formatToParts(guess).reduce<Record<string, string>>((a, p) => ({ ...a, [p.type]: p.value }), {})
  const asZoned = Date.UTC(+parts.year!, +parts.month! - 1, +parts.day!, +parts.hour! % 24, +parts.minute!)
  return new Date(guess.getTime() - (asZoned - guess.getTime())).toISOString()
}

function CorrectionDialog({ open, onClose }: { open: boolean; onClose: () => void }) {
  const { org } = useAuth()
  const qc = useQueryClient()
  const form = useForm<z.infer<typeof correctionSchema>>({ resolver: zodResolver(correctionSchema) })
  const submit = form.handleSubmit(async (v) => {
    const tz = org?.timezone ?? 'Asia/Kolkata'
    const { error } = await supabase.rpc('request_attendance_correction', {
      p_work_date: v.work_date, p_check_in: zonedIso(v.work_date, v.check_in, tz), p_check_out: zonedIso(v.work_date, v.check_out, tz), p_reason: v.reason,
    })
    if (error) return toast.error(friendlyError(error))
    toast.success('Correction submitted for approval')
    qc.invalidateQueries({ queryKey: ['attendance'] })
    form.reset(); onClose()
  })
  const e = form.formState.errors
  return (
    <Dialog open={open} onClose={onClose} title="Request attendance correction" description="Your manager or HR will review it."
      footer={<><Button variant="outline" onClick={onClose}>Cancel</Button><Button onClick={submit} loading={form.formState.isSubmitting}>Submit</Button></>}>
      <form className="grid gap-4 sm:grid-cols-2" onSubmit={submit}>
        <Field label="Date" error={e.work_date?.message} className="sm:col-span-2">{(p) => <Input type="date" max={orgToday(org?.timezone)} {...p} {...form.register('work_date')} />}</Field>
        <Field label="Check-in" error={e.check_in?.message}>{(p) => <Input type="time" {...p} {...form.register('check_in')} />}</Field>
        <Field label="Check-out" error={e.check_out?.message}>{(p) => <Input type="time" {...p} {...form.register('check_out')} />}</Field>
        <Field label="Reason" error={e.reason?.message} className="sm:col-span-2">{(p) => <Textarea {...p} {...form.register('reason')} />}</Field>
      </form>
    </Dialog>
  )
}

export default function AttendancePage() {
  const { employee, can, org } = useAuth()
  const [params, setParams] = useSearchParams()
  const tab = (params.get('tab') as Tab) ?? 'mine'
  const setTab = (t: Tab) => setParams({ tab: t })
  const [month, setMonth] = useState(orgToday(org?.timezone).slice(0, 7))
  const [day, setDay] = useState(orgToday(org?.timezone))
  const [corrOpen, setCorrOpen] = useState(false)
  const { data: people } = useEmployeesLite()
  const qc = useQueryClient()
  const { from, to } = monthRange(month)
  const lateOnly = params.get('late') === '1'

  const mine = useQuery({
    queryKey: ['attendance', 'mine', month], enabled: tab === 'mine' && Boolean(employee),
    queryFn: async () => unwrap(await supabase.from('attendance_records').select('*').eq('employee_id', employee!.id)
      .gte('work_date', from).lte('work_date', to).order('work_date', { ascending: false })) as AttendanceRecord[],
  })
  const myCorrections = useQuery({
    queryKey: ['attendance', 'my-corrections'], enabled: tab === 'mine' && Boolean(employee),
    queryFn: async () => unwrap(await supabase.from('attendance_corrections').select('*').eq('employee_id', employee!.id)
      .order('created_at', { ascending: false }).limit(10)) as AttendanceCorrection[],
  })
  const team = useQuery({
    queryKey: ['attendance', 'team', day, lateOnly], enabled: tab === 'team',
    queryFn: async () => {
      let q = supabase.from('attendance_records').select('*').eq('work_date', day).neq('employee_id', employee?.id ?? '00000000-0000-0000-0000-000000000000')
      if (lateOnly) q = q.gt('late_minutes', 0)
      return unwrap(await q.order('check_in_at')) as AttendanceRecord[]
    },
  })
  const approvals = useQuery({
    queryKey: ['attendance', 'approvals'], enabled: tab === 'approvals',
    queryFn: async () => unwrap(await supabase.from('attendance_corrections').select('*').eq('status', 'pending')
      .neq('employee_id', employee?.id ?? '00000000-0000-0000-0000-000000000000').order('created_at')) as AttendanceCorrection[],
  })
  const report = useQuery({
    queryKey: ['attendance', 'report', month], enabled: tab === 'report',
    queryFn: async () => unwrap(await supabase.from('attendance_records').select('*').gte('work_date', from).lte('work_date', to)) as AttendanceRecord[],
  })
  const summary = useMemo(() => {
    const m = new Map<string, { employee_id: string; present: number; half_day: number; absent: number; late: number; minutes: number }>()
    for (const r of report.data ?? []) {
      const s = m.get(r.employee_id) ?? { employee_id: r.employee_id, present: 0, half_day: 0, absent: 0, late: 0, minutes: 0 }
      if (r.status === 'present') s.present++; else if (r.status === 'half_day') s.half_day++; else if (r.status === 'absent') s.absent++
      if (r.late_minutes > 0) s.late++
      s.minutes += r.worked_minutes ?? 0
      m.set(r.employee_id, s)
    }
    return [...m.values()].map((s) => ({ ...s, id: s.employee_id, name: nameOf(people, s.employee_id) })).sort((a, b) => a.name.localeCompare(b.name))
  }, [report.data, people])

  const decide = useMutation({
    mutationFn: async ({ id, approve }: { id: string; approve: boolean }) =>
      unwrap(await supabase.rpc('decide_attendance_correction', { p_id: id, p_approve: approve, p_note: null })),
    onSuccess: (_d, v) => { toast.success(v.approve ? 'Correction approved' : 'Correction rejected'); qc.invalidateQueries({ queryKey: ['attendance'] }); qc.invalidateQueries({ queryKey: ['dashboard'] }) },
  })

  const recordColumns = (withName: boolean) => [
    ...(withName ? [{ key: 'emp', header: 'Employee', render: (r: AttendanceRecord) => nameOf(people, r.employee_id) }] : []),
    { key: 'date', header: 'Date', render: (r: AttendanceRecord) => fmtDate(r.work_date, 'EEE, dd MMM') },
    { key: 'in', header: 'In', render: (r: AttendanceRecord) => fmtTime(r.check_in_at) },
    { key: 'out', header: 'Out', render: (r: AttendanceRecord) => fmtTime(r.check_out_at) },
    { key: 'break', header: 'Break', render: (r: AttendanceRecord) => fmtMinutes(r.break_minutes) },
    { key: 'worked', header: 'Worked', render: (r: AttendanceRecord) => fmtMinutes(r.worked_minutes) },
    { key: 'late', header: 'Late', render: (r: AttendanceRecord) => r.late_minutes ? <Badge tone="amber">{fmtMinutes(r.late_minutes)}</Badge> : '—' },
    { key: 'status', header: 'Status', render: (r: AttendanceRecord) => <span className="flex gap-1"><StatusBadge value={attendanceLabel(r)} />{r.source === 'correction' && <Badge tone="slate">Corrected</Badge>}</span> },
  ]

  const tabs: { value: Tab; label: string }[] = [{ value: 'mine', label: 'My attendance' }, { value: 'team', label: 'Team' }, { value: 'approvals', label: 'Approvals' }]
  if (can(['attendance.view_all', 'reports.view'], 'any')) tabs.push({ value: 'report', label: 'Monthly report' })

  return (
    <div className="space-y-6">
      <PageHeader title="Attendance" actions={<Button variant="outline" onClick={() => setCorrOpen(true)}><PencilLine />Request correction</Button>} />
      <Tabs tabs={tabs} value={tab} onChange={setTab} />
      {tab === 'mine' && (
        <>
          <TodayAttendanceCard />
          <Card>
            <CardHeader title="History" action={<Input type="month" aria-label="Month" value={month} onChange={(e) => setMonth(e.target.value)} className="w-40" />} />
            <DataTable columns={recordColumns(false)} rows={mine.data} loading={mine.isLoading} error={mine.error ? friendlyError(mine.error) : null} onRetry={mine.refetch} />
          </Card>
          {Boolean(myCorrections.data?.length) && (
            <Card>
              <CardHeader title="My correction requests" />
              <DataTable rows={myCorrections.data} columns={[
                { key: 'd', header: 'Date', render: (c) => fmtDate(c.work_date) },
                { key: 't', header: 'Requested', render: (c) => `${fmtTime(c.requested_check_in)} – ${fmtTime(c.requested_check_out)}` },
                { key: 'r', header: 'Reason', render: (c) => c.reason },
                { key: 's', header: 'Status', render: (c) => <StatusBadge value={c.status} /> },
              ]} />
            </Card>
          )}
        </>
      )}
      {tab === 'team' && (
        <Card>
          <CardHeader title="Team attendance" description="People you manage, or everyone if you have HR access."
            action={<div className="flex items-center gap-2">
              <label className="flex items-center gap-1.5 text-sm"><input type="checkbox" checked={lateOnly}
                onChange={(e) => { const n = new URLSearchParams(params); if (e.target.checked) n.set('late', '1'); else n.delete('late'); setParams(n) }} />Late only</label>
              <Input type="date" aria-label="Day" value={day} onChange={(e) => setDay(e.target.value)} className="w-40" /></div>} />
          <DataTable columns={recordColumns(true)} rows={team.data} loading={team.isLoading} error={team.error ? friendlyError(team.error) : null} onRetry={team.refetch} />
        </Card>
      )}
      {tab === 'approvals' && (
        <Card>
          <CardHeader title="Pending corrections" description="Requests from people you manage, or everyone if you can approve attendance." />
          <DataTable rows={approvals.data} loading={approvals.isLoading} error={approvals.error ? friendlyError(approvals.error) : null} columns={[
            { key: 'e', header: 'Employee', render: (c) => nameOf(people, c.employee_id) },
            { key: 'd', header: 'Date', render: (c) => fmtDate(c.work_date) },
            { key: 't', header: 'Requested', render: (c) => `${fmtTime(c.requested_check_in)} – ${fmtTime(c.requested_check_out)}` },
            { key: 'r', header: 'Reason', render: (c) => <span className="line-clamp-2 max-w-xs">{c.reason}</span> },
            { key: 'a', header: '', render: (c) => <div className="flex justify-end gap-2">
              <Button size="sm" variant="outline" onClick={() => decide.mutate({ id: c.id, approve: false })} disabled={decide.isPending}>Reject</Button>
              <Button size="sm" onClick={() => decide.mutate({ id: c.id, approve: true })} disabled={decide.isPending}>Approve</Button></div> },
          ]} />
        </Card>
      )}
      {tab === 'report' && (
        <Card>
          <CardHeader title="Monthly summary" action={<div className="flex gap-2">
            <Input type="month" aria-label="Month" value={month} onChange={(e) => setMonth(e.target.value)} className="w-40" />
            {can('attendance.export') && <Button variant="outline" disabled={!summary.length} onClick={() => downloadCsv(`attendance-${month}.csv`, toCsv(
              summary.map((s) => ({ ...s, hours: (s.minutes / 60).toFixed(1) })),
              [{ key: 'name', label: 'Employee' }, { key: 'present', label: 'Present' }, { key: 'half_day', label: 'Half days' }, { key: 'absent', label: 'Short days' }, { key: 'late', label: 'Late days' }, { key: 'hours', label: 'Hours worked' }]))}>
              <Download />Export CSV</Button>}</div>} />
          <DataTable rows={summary} loading={report.isLoading} error={report.error ? friendlyError(report.error) : null} columns={[
            { key: 'n', header: 'Employee', render: (s) => s.name },
            { key: 'p', header: 'Present', render: (s) => s.present },
            { key: 'h', header: 'Half days', render: (s) => s.half_day },
            { key: 'a', header: 'Short days', render: (s) => s.absent },
            { key: 'l', header: 'Late days', render: (s) => s.late },
            { key: 'w', header: 'Hours', render: (s) => (s.minutes / 60).toFixed(1) },
          ]} />
        </Card>
      )}
      <CorrectionDialog open={corrOpen} onClose={() => setCorrOpen(false)} />
    </div>
  )
}
