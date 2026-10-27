import { useMemo, useState } from 'react'
import { Link, useSearchParams } from 'react-router-dom'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { toast } from 'sonner'
import { Check, ChevronLeft, ChevronRight, Download, Send, Square, Trash2, X } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { unwrap } from '@/lib/query'
import { friendlyError } from '@/lib/errors'
import { downloadCsv, fmtDate, fmtMinutes, toCsv } from '@/lib/utils'
import { isoDay, shiftDays, weekDays, weekStartOf } from '@/lib/dates'
import { nameOf, usePeople } from '@/lib/lookups'
import type { TimeEntry, Timesheet } from '@/lib/types'
import { useAuth } from '@/features/auth/AuthProvider'
import { DataTable } from '@/components/DataTable'
import { Badge, Button, Card, CardBody, CardHeader, Dialog, EmptyState, ErrorState, Field, Input, PageHeader, Spinner, Tabs, Textarea } from '@/components/ui'
import { Elapsed, useRunningTimer, useTimerActions } from './TaskTimeCard'

type Tab = 'week' | 'approvals' | 'report'
type EntryRow = TimeEntry & { tasks: { title: string } | null; projects: { name: string } | null }
const TS_TONE = { submitted: 'amber', approved: 'green', rejected: 'red' } as const

function MyWeek() {
  const { session } = useAuth()
  const uid = session!.user.id
  const qc = useQueryClient()
  const [week, setWeek] = useState(() => weekStartOf(new Date()))
  const days = weekDays(week)
  const thisWeek = weekStartOf(new Date())
  const running = useRunningTimer()
  const { stop } = useTimerActions()
  const entries = useQuery({ queryKey: ['time', 'mine', week],
    queryFn: async () => unwrap(await supabase.from('time_entries').select('*, tasks(title), projects(name)').eq('profile_id', uid)
      .gte('entry_date', days[0]).lte('entry_date', days[6]).order('entry_date').order('created_at')) as EntryRow[] })
  const sheet = useQuery({ queryKey: ['time', 'sheet', uid, week],
    queryFn: async () => unwrap(await supabase.from('timesheets').select('*').eq('profile_id', uid).eq('week_start', week).maybeSingle()) as Timesheet | null })
  const inv = () => qc.invalidateQueries({ queryKey: ['time'] })
  const submit = useMutation({ mutationFn: async () => unwrap(await supabase.rpc('submit_timesheet', { p_week_start: week })),
    onSuccess: () => { inv(); toast.success('Timesheet submitted for approval') } })
  const remove = useMutation({ mutationFn: async (id: string) => unwrap(await supabase.from('time_entries').delete().eq('id', id)), onSuccess: inv })
  const locked = sheet.data?.status === 'submitted' || sheet.data?.status === 'approved'
  const byDay = useMemo(() => Object.fromEntries(days.map((d) => [d, (entries.data ?? []).filter((e) => e.entry_date === d)])), [days, entries.data])
  const total = (entries.data ?? []).reduce((s, e) => s + (e.minutes ?? 0), 0)

  return (
    <div className="space-y-4">
      {running.data && <Card><CardBody className="flex flex-wrap items-center justify-between gap-3">
        <div className="text-sm"><p className="text-muted-foreground">Timer running</p>
          <Link to={`/tasks/${running.data.task_id}`} className="font-medium text-primary">{running.data.tasks?.title ?? 'Task'}</Link></div>
        <Button variant="outline" loading={stop.isPending} onClick={() => stop.mutate()}><Square />Stop · <Elapsed since={running.data.started_at!} /></Button>
      </CardBody></Card>}
      <Card>
        <CardBody className="flex flex-wrap items-center justify-between gap-3 border-b">
          <div className="flex items-center gap-2">
            <Button size="icon" variant="outline" aria-label="Previous week" onClick={() => setWeek(shiftDays(week, -7))}><ChevronLeft /></Button>
            <p className="min-w-44 text-center text-sm font-medium">{fmtDate(days[0], 'dd MMM')} – {fmtDate(days[6], 'dd MMM yyyy')}</p>
            <Button size="icon" variant="outline" aria-label="Next week" disabled={week >= thisWeek} onClick={() => setWeek(shiftDays(week, 7))}><ChevronRight /></Button>
            {week !== thisWeek && <Button size="sm" variant="ghost" onClick={() => setWeek(thisWeek)}>This week</Button>}
          </div>
          <div className="flex items-center gap-3 text-sm">
            <span>Total <strong className="tabular-nums">{fmtMinutes(total)}</strong></span>
            {sheet.data && <Badge tone={TS_TONE[sheet.data.status]}>{sheet.data.status === 'submitted' ? 'Awaiting approval' : sheet.data.status === 'approved' ? 'Approved' : 'Rejected'}</Badge>}
            {!locked && <Button size="sm" disabled={total === 0} loading={submit.isPending} onClick={() => submit.mutate()}><Send />{sheet.data?.status === 'rejected' ? 'Resubmit' : 'Submit timesheet'}</Button>}
          </div>
        </CardBody>
        {sheet.data?.status === 'rejected' && sheet.data.decision_note && <CardBody className="border-b bg-red-50 text-sm text-red-800 dark:bg-red-950/30 dark:text-red-200">
          Returned by {sheet.data.decided_by ? 'your approver' : 'approver'}: {sheet.data.decision_note}</CardBody>}
        {entries.isLoading ? <Spinner /> : entries.error ? <ErrorState message={friendlyError(entries.error)} onRetry={entries.refetch} /> : (
          <ul className="divide-y">{days.map((d) => {
            const list = byDay[d] ?? []
            const dayTotal = list.reduce((s, e) => s + (e.minutes ?? 0), 0)
            return (
              <li key={d} className="px-4 py-3 sm:px-5">
                <div className="flex items-center justify-between text-sm"><span className={d === isoDay(new Date()) ? 'font-semibold text-primary' : 'font-medium'}>{fmtDate(d, 'EEEE, dd MMM')}</span>
                  <span className="tabular-nums text-muted-foreground">{dayTotal ? fmtMinutes(dayTotal) : '—'}</span></div>
                {list.length > 0 && <ul className="mt-2 space-y-1.5">{list.map((e) => (
                  <li key={e.id} className="flex items-center justify-between gap-3 rounded-md bg-muted/50 px-3 py-2 text-sm">
                    <span className="min-w-0"><Link to={`/tasks/${e.task_id}`} className="block truncate font-medium hover:text-primary">{e.tasks?.title ?? 'Task'}</Link>
                      <span className="block truncate text-xs text-muted-foreground">{e.projects?.name}{e.note ? ` · ${e.note}` : ''}{e.source === 'timer' ? ' · timer' : ''}</span></span>
                    <span className="flex shrink-0 items-center gap-2 tabular-nums">{e.source === 'timer' && !e.ended_at ? <Elapsed since={e.started_at!} /> : fmtMinutes(e.minutes)}
                      {!locked && <button aria-label="Delete entry" className="text-muted-foreground hover:text-destructive" onClick={() => window.confirm('Delete this time entry?') && remove.mutate(e.id)}><Trash2 className="size-3.5" /></button>}</span>
                  </li>))}</ul>}
              </li>)
          })}</ul>)}
      </Card>
      <p className="text-sm text-muted-foreground">Log time from any task's page (timer or manual entry). Submitting locks the week until your manager approves or returns it.</p>
    </div>
  )
}

function Approvals() {
  const { session } = useAuth()
  const { data: people } = usePeople()
  const qc = useQueryClient()
  const [rejecting, setRejecting] = useState<Timesheet | null>(null)
  const [note, setNote] = useState('')
  const [open, setOpen] = useState<string | null>(null)
  const list = useQuery({ queryKey: ['time', 'approvals'],
    queryFn: async () => unwrap(await supabase.from('timesheets').select('*').neq('profile_id', session!.user.id).eq('status', 'submitted').order('week_start')) as Timesheet[] })
  const detail = useQuery({ queryKey: ['time', 'sheet-entries', open], enabled: Boolean(open),
    queryFn: async () => unwrap(await supabase.from('time_entries').select('*, tasks(title), projects(name)').eq('timesheet_id', open!).order('entry_date')) as EntryRow[] })
  const decide = useMutation({
    mutationFn: async (v: { id: string; approve: boolean; note?: string }) => unwrap(await supabase.rpc('decide_timesheet', { p_timesheet: v.id, p_approve: v.approve, p_note: v.note ?? null })),
    onSuccess: (_d, v) => { qc.invalidateQueries({ queryKey: ['time'] }); setRejecting(null); setNote(''); toast.success(v.approve ? 'Timesheet approved' : 'Timesheet returned') },
  })
  return (
    <Card>
      <DataTable rows={list.data} loading={list.isLoading} error={list.error ? friendlyError(list.error) : null} onRowClick={(t) => setOpen(open === t.id ? null : t.id)}
        empty={<EmptyState title="Nothing to approve" description="Submitted timesheets from your team appear here." />} columns={[
          { key: 'p', header: 'Person', render: (t) => <span className="font-medium">{nameOf(people, t.profile_id)}</span> },
          { key: 'w', header: 'Week', render: (t) => `${fmtDate(t.week_start, 'dd MMM')} – ${fmtDate(shiftDays(t.week_start, 6), 'dd MMM')}` },
          { key: 'h', header: 'Hours', render: (t) => <span className="tabular-nums">{fmtMinutes(t.total_minutes)}</span> },
          { key: 's', header: 'Submitted', render: (t) => fmtDate(t.submitted_at, 'dd MMM, hh:mm a') },
          { key: 'a', header: '', render: (t) => <span className="flex justify-end gap-2" onClick={(e) => e.stopPropagation()}>
            <Button size="sm" variant="outline" onClick={() => setRejecting(t)}><X />Return</Button>
            <Button size="sm" loading={decide.isPending && decide.variables?.id === t.id} onClick={() => decide.mutate({ id: t.id, approve: true })}><Check />Approve</Button></span> },
        ]} />
      {open && <CardBody className="border-t">
        <p className="mb-2 text-sm font-medium">Entries</p>
        {detail.isLoading ? <Spinner /> : <ul className="space-y-1 text-sm">{detail.data?.map((e) => <li key={e.id} className="flex justify-between gap-3">
          <span className="truncate">{fmtDate(e.entry_date, 'EEE dd MMM')} · {e.projects?.name} · {e.tasks?.title}{e.note ? ` — ${e.note}` : ''}</span>
          <span className="shrink-0 tabular-nums">{fmtMinutes(e.minutes)}</span></li>)}</ul>}
      </CardBody>}
      <Dialog open={Boolean(rejecting)} onClose={() => setRejecting(null)} title="Return timesheet" description="The person can fix their entries and resubmit."
        footer={<><Button variant="outline" onClick={() => setRejecting(null)}>Cancel</Button>
          <Button variant="destructive" disabled={!note.trim()} loading={decide.isPending} onClick={() => rejecting && decide.mutate({ id: rejecting.id, approve: false, note })}>Return</Button></>}>
        <Field label="Reason">{(p) => <Textarea {...p} rows={3} value={note} onChange={(e) => setNote(e.target.value)} placeholder="e.g. Please add notes to Tuesday's entries" />}</Field>
      </Dialog>
    </Card>
  )
}

function TeamReport() {
  const { data: people } = usePeople()
  const [from, setFrom] = useState(() => shiftDays(weekStartOf(new Date()), -21))
  const [to, setTo] = useState(() => isoDay(new Date()))
  const q = useQuery({ queryKey: ['time', 'report', from, to],
    queryFn: async () => unwrap(await supabase.from('time_entries').select('profile_id, minutes, billable, entry_date, projects(name), tasks(title)')
      .gte('entry_date', from).lte('entry_date', to).not('minutes', 'is', null).limit(10000)) as unknown as
      { profile_id: string; minutes: number; billable: boolean; entry_date: string; projects: { name: string } | null; tasks: { title: string } | null }[] })
  const byPerson = useMemo(() => {
    const m = new Map<string, number>()
    q.data?.forEach((e) => m.set(e.profile_id, (m.get(e.profile_id) ?? 0) + e.minutes))
    return [...m.entries()].map(([id, min]) => ({ id, min })).sort((a, b) => b.min - a.min)
  }, [q.data])
  const byProject = useMemo(() => {
    const m = new Map<string, number>()
    q.data?.forEach((e) => { const k = e.projects?.name ?? '—'; m.set(k, (m.get(k) ?? 0) + e.minutes) })
    return [...m.entries()].map(([name, min]) => ({ name, min })).sort((a, b) => b.min - a.min)
  }, [q.data])
  const exportCsv = () => downloadCsv(`time-${from}-to-${to}.csv`, toCsv((q.data ?? []).map((e) => ({
    date: e.entry_date, person: nameOf(people, e.profile_id), project: e.projects?.name, task: e.tasks?.title, hours: (e.minutes / 60).toFixed(2), billable: e.billable ? 'yes' : 'no',
  })), [{ key: 'date', label: 'Date' }, { key: 'person', label: 'Person' }, { key: 'project', label: 'Project' }, { key: 'task', label: 'Task' }, { key: 'hours', label: 'Hours' }, { key: 'billable', label: 'Billable' }]))
  const max = Math.max(1, ...byPerson.map((p) => p.min))
  return (
    <div className="space-y-4">
      <Card><CardBody className="flex flex-wrap items-end gap-3">
        <Field label="From">{(p) => <Input {...p} type="date" value={from} max={to} onChange={(e) => setFrom(e.target.value)} />}</Field>
        <Field label="To">{(p) => <Input {...p} type="date" value={to} min={from} onChange={(e) => setTo(e.target.value)} />}</Field>
        <Button variant="outline" disabled={!q.data?.length} onClick={exportCsv}><Download />Export CSV</Button>
      </CardBody></Card>
      {q.isLoading ? <Spinner /> : q.error ? <ErrorState message={friendlyError(q.error)} onRetry={q.refetch} /> : !q.data?.length ? <Card><EmptyState title="No time logged in this period" /></Card> : (
        <div className="grid gap-4 lg:grid-cols-2">
          <Card><CardHeader title="By person" /><CardBody className="space-y-2.5">{byPerson.map((p) => (
            <div key={p.id} className="text-sm"><div className="flex justify-between"><span>{nameOf(people, p.id)}</span><span className="tabular-nums">{fmtMinutes(p.min)}</span></div>
              <div className="mt-1 h-1.5 rounded-full bg-muted"><div className="h-1.5 rounded-full bg-primary" style={{ width: `${(p.min / max) * 100}%` }} /></div></div>))}
          </CardBody></Card>
          <Card><CardHeader title="By project" /><CardBody><ul className="divide-y text-sm">{byProject.map((p) => (
            <li key={p.name} className="flex justify-between py-1.5"><span className="truncate">{p.name}</span><span className="tabular-nums">{fmtMinutes(p.min)}</span></li>))}</ul></CardBody></Card>
        </div>)}
    </div>
  )
}

export default function TimePage() {
  const { can, session } = useAuth()
  const [params, setParams] = useSearchParams()
  const pending = useQuery({ queryKey: ['time', 'approvals', 'count'],
    queryFn: async () => (await supabase.from('timesheets').select('id', { count: 'exact', head: true }).neq('profile_id', session!.user.id).eq('status', 'submitted')).count ?? 0 })
  const showApprovals = can('timesheets.approve') || (pending.data ?? 0) > 0
  const tabs: { value: Tab; label: string; count?: number }[] = [{ value: 'week', label: 'My week' }]
  if (showApprovals) tabs.push({ value: 'approvals', label: 'Approvals', count: pending.data || undefined })
  if (can('time.view_all')) tabs.push({ value: 'report', label: 'Team report' })
  const tab = (tabs.some((t) => t.value === params.get('tab')) ? params.get('tab') : 'week') as Tab
  return (
    <div className="space-y-6">
      <PageHeader title="Time" description="Track time on tasks and submit weekly timesheets." />
      {tabs.length > 1 && <Tabs tabs={tabs} value={tab} onChange={(t) => setParams({ tab: t }, { replace: true })} />}
      {tab === 'week' && <MyWeek />}
      {tab === 'approvals' && <Approvals />}
      {tab === 'report' && <TeamReport />}
    </div>
  )
}
