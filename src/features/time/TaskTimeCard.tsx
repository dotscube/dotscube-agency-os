import { useEffect, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { toast } from 'sonner'
import { Play, Plus, Square } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { unwrap } from '@/lib/query'
import { friendlyError } from '@/lib/errors'
import { fmtDate, fmtMinutes } from '@/lib/utils'
import { isoDay, parseDuration } from '@/lib/dates'
import { nameOf, usePeople } from '@/lib/lookups'
import type { TimeEntry } from '@/lib/types'
import { useAuth } from '@/features/auth/AuthProvider'
import { Button, Card, CardBody, CardHeader, Input } from '@/components/ui'

/** Live elapsed time for a running timer, e.g. "1:05:09". */
export function Elapsed({ since }: { since: string }) {
  const [now, setNow] = useState(() => Date.now())
  useEffect(() => { const t = setInterval(() => setNow(Date.now()), 1000); return () => clearInterval(t) }, [])
  const s = Math.max(0, Math.floor((now - new Date(since).getTime()) / 1000))
  const hh = Math.floor(s / 3600), mm = Math.floor((s % 3600) / 60), ss = s % 60
  return <span className="tabular-nums">{hh}:{String(mm).padStart(2, '0')}:{String(ss).padStart(2, '0')}</span>
}

export function useRunningTimer() {
  const { session, audience } = useAuth()
  return useQuery({
    queryKey: ['time', 'running'], enabled: audience === 'internal' && Boolean(session),
    queryFn: async () => unwrap(await supabase.from('time_entries').select('*, tasks(title)').eq('profile_id', session!.user.id)
      .eq('source', 'timer').is('ended_at', null).maybeSingle()) as (TimeEntry & { tasks: { title: string } | null }) | null,
  })
}

export function useTimerActions() {
  const qc = useQueryClient()
  const inv = () => { qc.invalidateQueries({ queryKey: ['time'] }) }
  const start = useMutation({ mutationFn: async (taskId: string) => unwrap(await supabase.rpc('start_timer', { p_task: taskId })),
    onSuccess: () => { inv(); toast.success('Timer started') } })
  const stop = useMutation({ mutationFn: async () => unwrap(await supabase.rpc('stop_timer')) as TimeEntry | null,
    onSuccess: (e) => { inv(); if (e) toast.success(`Logged ${fmtMinutes(e.minutes)}`) } })
  return { start, stop }
}

/** Timer, manual entry and actual-vs-estimate for one task (internal users). */
export function TaskTimeCard({ taskId, orgId }: { taskId: string; orgId: string }) {
  const { session } = useAuth()
  const uid = session!.user.id
  const qc = useQueryClient()
  const { data: people } = usePeople()
  const running = useRunningTimer()
  const { start, stop } = useTimerActions()
  const [dur, setDur] = useState(''); const [day, setDay] = useState(isoDay(new Date())); const [note, setNote] = useState('')
  const summary = useQuery({ queryKey: ['time', 'task', taskId, 'summary'],
    queryFn: async () => (unwrap(await supabase.rpc('task_time_summary', { p_task: taskId })) as { logged_minutes: number; estimated_minutes: number | null; running: boolean }[])[0] ?? null })
  const entries = useQuery({ queryKey: ['time', 'task', taskId, 'entries'],
    queryFn: async () => unwrap(await supabase.from('time_entries').select('*').eq('task_id', taskId).order('entry_date', { ascending: false }).limit(20)) as TimeEntry[] })
  const add = useMutation({
    mutationFn: async () => {
      const minutes = parseDuration(dur)
      if (!minutes || minutes > 1440) throw new Error('Enter time like 1:30, 1.5, 90m or 2h')
      return unwrap(await supabase.from('time_entries').insert({ org_id: orgId, profile_id: uid, task_id: taskId, // project_id is filled in by the database from the task
        entry_date: day, minutes, note: note.trim() || null, source: 'manual' }))
    },
    onSuccess: () => { setDur(''); setNote(''); qc.invalidateQueries({ queryKey: ['time'] }); toast.success('Time logged') },
    onError: (e) => toast.error(friendlyError(e)),
  })
  const mine = running.data?.task_id === taskId
  const logged = Number(summary.data?.logged_minutes ?? 0)
  const est = summary.data?.estimated_minutes ?? null
  const pct = est ? Math.min(100, Math.round((logged / est) * 100)) : null
  return (
    <Card>
      <CardHeader title="Time" description={est ? `${fmtMinutes(logged)} of ${fmtMinutes(est)} estimated` : `${fmtMinutes(logged)} logged`} />
      <CardBody className="space-y-3 text-sm">
        {pct != null && <div className="h-2 rounded-full bg-muted" role="progressbar" aria-valuenow={pct} aria-valuemin={0} aria-valuemax={100} aria-label="Time used vs estimate">
          <div className={`h-2 rounded-full ${logged > (est ?? 0) ? 'bg-destructive' : 'bg-primary'}`} style={{ width: `${pct}%` }} /></div>}
        {mine ? <Button variant="outline" className="w-full" loading={stop.isPending} onClick={() => stop.mutate()}><Square />Stop · <Elapsed since={running.data!.started_at!} /></Button>
          : <Button variant="outline" className="w-full" loading={start.isPending} onClick={() => start.mutate(taskId)}><Play />{running.data ? 'Switch timer to this task' : 'Start timer'}</Button>}
        <div className="grid grid-cols-[1fr_auto] gap-2">
          <Input aria-label="Time spent" placeholder="e.g. 1:30 or 45m" value={dur} onChange={(e) => setDur(e.target.value)} />
          <Input aria-label="Date" type="date" max={isoDay(new Date())} value={day} onChange={(e) => setDay(e.target.value)} />
          <Input aria-label="Note" placeholder="What did you do? (optional)" className="col-span-2" value={note} onChange={(e) => setNote(e.target.value)} />
        </div>
        <Button size="sm" className="w-full" disabled={!dur.trim()} loading={add.isPending} onClick={() => add.mutate()}><Plus />Log time</Button>
        {!!entries.data?.length && <ul className="divide-y border-t pt-1">{entries.data.map((e) => (
          <li key={e.id} className="flex items-center justify-between gap-2 py-1.5">
            <span className="min-w-0"><span className="block truncate">{e.profile_id === uid ? 'You' : nameOf(people, e.profile_id)}{e.note ? ` · ${e.note}` : ''}</span>
              <span className="text-xs text-muted-foreground">{fmtDate(e.entry_date, 'dd MMM')}{e.source === 'timer' ? ' · timer' : ''}</span></span>
            <span className="shrink-0 font-medium tabular-nums">{e.ended_at || e.source === 'manual' ? fmtMinutes(e.minutes) : <Elapsed since={e.started_at!} />}</span>
          </li>))}</ul>}
      </CardBody>
    </Card>
  )
}
