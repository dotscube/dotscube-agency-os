import { useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { toast } from 'sonner'
import { Pause, Play, Plus, Repeat, Trash2 } from 'lucide-react'
import { differenceInCalendarDays, parseISO } from 'date-fns'
import { supabase } from '@/lib/supabase'
import { unwrap } from '@/lib/query'
import { fmtDate, fmtMinutes, titleCase } from '@/lib/utils'
import { isoDay, shiftDays } from '@/lib/dates'
import { nameOf, usePeople } from '@/lib/lookups'
import { PRIORITIES, type ProjectOverview, type RecurringRule, type TaskStatus } from '@/lib/types'
import { useAuth } from '@/features/auth/AuthProvider'
import { DataTable } from '@/components/DataTable'
import { Badge, Button, Card, CardBody, CardHeader, Dialog, EmptyState, Field, Input, Select, Spinner } from '@/components/ui'
import type { TaskWithAssignees } from '@/features/tasks/shared'

const WEEKDAYS = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday']
export const describeRule = (r: Pick<RecurringRule, 'frequency' | 'weekday' | 'day_of_month'>) =>
  r.frequency === 'weekly' ? `Every ${WEEKDAYS[(r.weekday ?? 1) - 1]}` : `Monthly on day ${r.day_of_month}`

export function RecurringRules({ project, canManage }: { project: ProjectOverview; canManage: boolean }) {
  const { session } = useAuth()
  const qc = useQueryClient()
  const { data: people } = usePeople()
  const [open, setOpen] = useState(false)
  const [f, setF] = useState({ title: '', frequency: 'weekly', weekday: '1', day: '1', due: '2', assignee: '', reviewer: '', priority: 'medium', hours: '', start: isoDay(new Date()), end: '', client_visible: false })
  const rules = useQuery({ queryKey: ['project', project.id, 'recurring'],
    queryFn: async () => unwrap(await supabase.from('recurring_task_rules').select('*').eq('project_id', project.id).order('created_at')) as RecurringRule[] })
  const runs = useQuery({ queryKey: ['project', project.id, 'recurring-runs'], enabled: Boolean(rules.data?.length),
    queryFn: async () => unwrap(await supabase.from('recurring_task_runs').select('rule_id, period_key, task_id, generated_at').in('rule_id', rules.data!.map((r) => r.id))
      .order('generated_at', { ascending: false })) as { rule_id: string; period_key: string; task_id: string | null; generated_at: string }[] })
  const inv = () => qc.invalidateQueries({ queryKey: ['project', project.id] })
  const create = useMutation({
    mutationFn: async () => unwrap(await supabase.from('recurring_task_rules').insert({
      org_id: project.org_id, project_id: project.id, title: f.title.trim(), frequency: f.frequency,
      weekday: f.frequency === 'weekly' ? Number(f.weekday) : null, day_of_month: f.frequency === 'monthly' ? Number(f.day) : null,
      due_after_days: Number(f.due) || 0, assignee_id: f.assignee || null, reviewer_id: f.reviewer || null, priority: f.priority,
      estimated_minutes: f.hours ? Math.round(Number(f.hours) * 60) : null, start_date: f.start, end_date: f.end || null,
      client_visible: f.client_visible, created_by: session!.user.id })),
    onSuccess: () => { inv(); setOpen(false); setF({ ...f, title: '' }); toast.success('Recurring task added. Tasks are created automatically on each scheduled day.') },
  })
  const toggle = useMutation({ mutationFn: async (r: RecurringRule) => unwrap(await supabase.from('recurring_task_rules').update({ is_active: !r.is_active }).eq('id', r.id)), onSuccess: inv })
  const remove = useMutation({ mutationFn: async (id: string) => unwrap(await supabase.from('recurring_task_rules').delete().eq('id', id)), onSuccess: inv })
  const set = (k: keyof typeof f) => (e: { target: { value: string } }) => setF({ ...f, [k]: e.target.value })
  const active = people?.filter((p) => p.is_active)
  return (
    <Card>
      <CardHeader title="Recurring tasks" description="A new task is created automatically each week or month — never twice for the same period."
        action={canManage && <Button size="sm" onClick={() => setOpen(true)}><Plus />Add</Button>} />
      <DataTable rows={rules.data} loading={rules.isLoading} empty={<EmptyState icon={<Repeat />} title="No recurring tasks" description="e.g. weekly GBP posts or a monthly report." />} columns={[
        { key: 't', header: 'Task', render: (r) => <span className="font-medium">{r.title}</span> },
        { key: 's', header: 'Schedule', render: (r) => <span>{describeRule(r)}<span className="block text-xs text-muted-foreground">due {r.due_after_days} day(s) later</span></span> },
        { key: 'a', header: 'Assignee', render: (r) => nameOf(people, r.assignee_id) },
        { key: 'l', header: 'Last created', render: (r) => { const last = runs.data?.find((x) => x.rule_id === r.id)
          return last?.task_id ? <Link className="text-primary" to={`/tasks/${last.task_id}`}>{last.period_key}</Link> : last ? last.period_key : '—' } },
        { key: 'st', header: 'Status', render: (r) => r.end_date && r.end_date < isoDay(new Date()) ? <Badge tone="slate">Ended</Badge> : r.is_active ? <Badge tone="green">Active</Badge> : <Badge tone="slate">Paused</Badge> },
        { key: 'x', header: '', render: (r) => canManage && <span className="flex justify-end gap-1">
          <Button size="icon" variant="ghost" aria-label={r.is_active ? 'Pause' : 'Resume'} onClick={() => toggle.mutate(r)}>{r.is_active ? <Pause /> : <Play />}</Button>
          <Button size="icon" variant="ghost" aria-label="Delete rule" onClick={() => window.confirm('Delete this recurring rule? Tasks already created stay.') && remove.mutate(r.id)}><Trash2 /></Button></span> },
      ]} />
      <Dialog open={open} onClose={() => setOpen(false)} title="New recurring task" wide
        footer={<><Button variant="outline" onClick={() => setOpen(false)}>Cancel</Button><Button disabled={f.title.trim().length < 2} loading={create.isPending} onClick={() => create.mutate()}>Save</Button></>}>
        <div className="grid gap-4 sm:grid-cols-2">
          <Field label="Task title" className="sm:col-span-2" hint="The date is added automatically, e.g. “Weekly GBP post (04 Nov)”">{(p) => <Input {...p} value={f.title} onChange={set('title')} />}</Field>
          <Field label="Repeats">{(p) => <Select {...p} value={f.frequency} onChange={set('frequency')}><option value="weekly">Weekly</option><option value="monthly">Monthly</option></Select>}</Field>
          {f.frequency === 'weekly'
            ? <Field label="On">{(p) => <Select {...p} value={f.weekday} onChange={set('weekday')}>{WEEKDAYS.map((d, i) => <option key={d} value={i + 1}>{d}</option>)}</Select>}</Field>
            : <Field label="Day of month" hint="1–28, so it exists in every month">{(p) => <Input {...p} type="number" min={1} max={28} value={f.day} onChange={set('day')} />}</Field>}
          <Field label="Due after (days)">{(p) => <Input {...p} type="number" min={0} max={60} value={f.due} onChange={set('due')} />}</Field>
          <Field label="Estimate (hours)">{(p) => <Input {...p} type="number" min={0} step="0.25" value={f.hours} onChange={set('hours')} />}</Field>
          <Field label="Assignee">{(p) => <Select {...p} value={f.assignee} onChange={set('assignee')}><option value="">Unassigned</option>{active?.map((x) => <option key={x.id} value={x.id}>{x.full_name || x.email}</option>)}</Select>}</Field>
          <Field label="Reviewer">{(p) => <Select {...p} value={f.reviewer} onChange={set('reviewer')}><option value="">No review step</option>{active?.map((x) => <option key={x.id} value={x.id}>{x.full_name || x.email}</option>)}</Select>}</Field>
          <Field label="Priority">{(p) => <Select {...p} value={f.priority} onChange={set('priority')}>{PRIORITIES.map((x) => <option key={x} value={x}>{titleCase(x)}</option>)}</Select>}</Field>
          <Field label="Starts">{(p) => <Input {...p} type="date" value={f.start} onChange={set('start')} />}</Field>
          <Field label="Ends (optional)">{(p) => <Input {...p} type="date" min={f.start} value={f.end} onChange={set('end')} />}</Field>
          <label className="flex items-center gap-2 self-end text-sm"><input type="checkbox" checked={f.client_visible} onChange={(e) => setF({ ...f, client_visible: e.target.checked })} />Visible to client</label>
        </div>
      </Dialog>
    </Card>
  )
}

export function ProjectTime({ projectId }: { projectId: string }) {
  const q = useQuery({ queryKey: ['time', 'project', projectId],
    queryFn: async () => unwrap(await supabase.rpc('project_time_summary', { p_project: projectId })) as { task_id: string; title: string; estimated_minutes: number | null; logged_minutes: number }[] })
  const totals = useMemo(() => (q.data ?? []).reduce((a, r) => ({ est: a.est + (r.estimated_minutes ?? 0), log: a.log + Number(r.logged_minutes) }), { est: 0, log: 0 }), [q.data])
  return (
    <Card>
      <CardHeader title="Time vs estimate" description={`${fmtMinutes(totals.log)} logged · ${fmtMinutes(totals.est)} estimated`} />
      <DataTable rows={q.data} loading={q.isLoading} rowKey={(r) => r.task_id} empty={<EmptyState title="No tasks yet" />} columns={[
        { key: 't', header: 'Task', render: (r) => <Link className="font-medium hover:text-primary" to={`/tasks/${r.task_id}`}>{r.title}</Link> },
        { key: 'e', header: 'Estimate', render: (r) => fmtMinutes(r.estimated_minutes) },
        { key: 'l', header: 'Logged', render: (r) => <span className={r.estimated_minutes && Number(r.logged_minutes) > r.estimated_minutes ? 'font-medium text-destructive' : ''}>{fmtMinutes(Number(r.logged_minutes))}</span> },
        { key: 'b', header: '', className: 'w-40', render: (r) => r.estimated_minutes ? <div className="h-1.5 rounded-full bg-muted"><div className={`h-1.5 rounded-full ${Number(r.logged_minutes) > r.estimated_minutes ? 'bg-destructive' : 'bg-primary'}`}
          style={{ width: `${Math.min(100, (Number(r.logged_minutes) / r.estimated_minutes) * 100)}%` }} /></div> : null },
      ]} />
    </Card>
  )
}

/** Gantt-style timeline of tasks that have dates. */
export function ProjectTimeline({ project, tasks, statuses }: { project: ProjectOverview; tasks: TaskWithAssignees[] | undefined; statuses: TaskStatus[] | undefined }) {
  if (!tasks) return <Spinner />
  const dated = tasks.filter((t) => t.start_date || t.due_date)
  if (!dated.length) return <Card><EmptyState title="No dated tasks yet" description="Add start or due dates to tasks to see them on the timeline." /></Card>
  const starts = dated.map((t) => t.start_date ?? t.due_date!)
  const ends = dated.map((t) => t.due_date ?? t.start_date!)
  const min = [project.start_date, ...starts].filter(Boolean).sort()[0]!
  const max = [project.due_date, ...ends].filter(Boolean).sort().at(-1)!
  const span = Math.max(1, differenceInCalendarDays(parseISO(max), parseISO(min)) + 1)
  const pos = (d: string) => (differenceInCalendarDays(parseISO(d), parseISO(min)) / span) * 100
  const today = isoDay(new Date())
  const weeks: string[] = []
  for (let d = min; d <= max; d = shiftDays(d, 7)) weeks.push(d)
  const color = (sid: string) => statuses?.find((s) => s.id === sid)?.color ?? '#64748b'
  return (
    <Card><CardBody className="overflow-x-auto">
      <div className="min-w-[640px]">
        <div className="relative ml-48 h-6 border-b text-xs text-muted-foreground">
          {weeks.map((w) => <span key={w} className="absolute -translate-x-1/2 whitespace-nowrap" style={{ left: `${pos(w)}%` }}>{fmtDate(w, 'dd MMM')}</span>)}
        </div>
        <ul className="relative">
          {today >= min && today <= max && <div aria-hidden className="absolute bottom-0 top-0 ml-48 w-[calc(100%-12rem)]">
            <div className="absolute bottom-0 top-0 w-px bg-destructive/60" style={{ left: `${pos(today)}%` }} /></div>}
          {dated.sort((a, b) => (a.start_date ?? a.due_date!).localeCompare(b.start_date ?? b.due_date!)).map((t) => {
            const s = t.start_date ?? t.due_date!, e = t.due_date ?? t.start_date!
            const left = pos(s), width = Math.max(1.2, ((differenceInCalendarDays(parseISO(e), parseISO(s)) + 1) / span) * 100)
            return (
              <li key={t.id} className="flex h-9 items-center border-b last:border-0">
                <Link to={`/tasks/${t.id}`} className="w-48 shrink-0 truncate pr-3 text-sm hover:text-primary" title={t.title}>{t.title}</Link>
                <div className="relative h-full flex-1">
                  <div className="absolute top-2 h-5 rounded" title={`${fmtDate(s)} – ${fmtDate(e)}`}
                    style={{ left: `${left}%`, width: `${width}%`, backgroundColor: color(t.status_id), opacity: 0.85 }} />
                </div>
              </li>)
          })}
        </ul>
        <p className="mt-3 text-xs text-muted-foreground">Bars are coloured by task status. The red line is today.</p>
      </div>
    </CardBody></Card>
  )
}
