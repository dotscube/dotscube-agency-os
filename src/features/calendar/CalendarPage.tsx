import { useMemo, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { addDays, format, parseISO } from 'date-fns'
import { supabase } from '@/lib/supabase'
import { unwrap } from '@/lib/query'
import { friendlyError } from '@/lib/errors'
import { isoDay, monthGrid } from '@/lib/dates'
import { useTaskStatuses } from '@/lib/lookups'
import type { ContentItem, Task } from '@/lib/types'
import { useAuth } from '@/features/auth/AuthProvider'
import { MonthCalendar, type CalendarItem } from '@/components/MonthCalendar'
import { ErrorState, PageHeader } from '@/components/ui'
import { CONTENT_COLORS } from '@/features/content/ContentPage'

type Layer = 'tasks' | 'content' | 'projects'

export default function CalendarPage() {
  const { session } = useAuth()
  const navigate = useNavigate()
  const uid = session!.user.id
  const { data: statuses } = useTaskStatuses()
  const [month, setMonth] = useState(() => isoDay(new Date()))
  const [mine, setMine] = useState(true)
  const [layers, setLayers] = useState<Set<Layer>>(new Set(['tasks', 'content', 'projects']))
  const grid = monthGrid(month)
  const from = grid[0]!, to = grid[41]!
  const tasks = useQuery({ queryKey: ['calendar', 'tasks', from, mine], enabled: layers.has('tasks'),
    queryFn: async () => {
      const cols = mine ? 'id, title, due_date, status_id, task_assignees!inner(profile_id)' : 'id, title, due_date, status_id'
      let q = supabase.from('tasks').select(cols).gte('due_date', from).lte('due_date', to).limit(2000)
      if (mine) q = q.eq('task_assignees.profile_id', uid)
      return unwrap(await q) as unknown as Pick<Task, 'id' | 'title' | 'due_date' | 'status_id'>[]
    } })
  const content = useQuery({ queryKey: ['calendar', 'content', from], enabled: layers.has('content'),
    queryFn: async () => unwrap(await supabase.from('content_items').select('id, title, scheduled_at, status').gte('scheduled_at', from)
      .lt('scheduled_at', isoDay(addDays(parseISO(to), 1))).neq('status', 'cancelled').limit(2000)) as Pick<ContentItem, 'id' | 'title' | 'scheduled_at' | 'status'>[] })
  const projects = useQuery({ queryKey: ['calendar', 'projects', from], enabled: layers.has('projects'),
    queryFn: async () => unwrap(await supabase.from('projects').select('id, name, due_date, status').gte('due_date', from).lte('due_date', to)
      .in('status', ['planning', 'active', 'on_hold'])) as { id: string; name: string; due_date: string; status: string }[] })
  const items = useMemo<CalendarItem[]>(() => {
    const cat = (sid: string) => statuses?.find((s) => s.id === sid)
    const out: CalendarItem[] = []
    if (layers.has('projects')) projects.data?.forEach((p) => out.push({ id: 'p' + p.id, day: p.due_date, label: `◆ ${p.name} due`, color: '#7c3aed', onClick: () => navigate(`/projects/${p.id}`) }))
    if (layers.has('tasks')) tasks.data?.forEach((t) => { const s = cat(t.status_id)
      out.push({ id: 't' + t.id, day: t.due_date!, label: t.title, color: s?.color ?? '#2563eb', muted: s?.category === 'done' || s?.category === 'cancelled', onClick: () => navigate(`/tasks/${t.id}`) }) })
    if (layers.has('content')) content.data?.forEach((c) => out.push({ id: 'c' + c.id, day: isoDay(parseISO(c.scheduled_at!)),
      label: `${format(parseISO(c.scheduled_at!), 'HH:mm')} ${c.title}`, color: CONTENT_COLORS[c.status], onClick: () => navigate('/content') }))
    return out
  }, [layers, tasks.data, content.data, projects.data, statuses, navigate])
  const toggle = (l: Layer) => setLayers((s) => { const n = new Set(s); if (n.has(l)) n.delete(l); else n.add(l); return n })
  const err = tasks.error ?? content.error ?? projects.error
  return (
    <div className="space-y-6">
      <PageHeader title="Calendar" description="Task due dates, scheduled content and project deadlines in one place." />
      {err && <ErrorState message={friendlyError(err)} />}
      <MonthCalendar month={month} onMonthChange={setMonth} items={items} toolbar={
        <div className="flex flex-wrap items-center gap-3 text-sm">
          {(['tasks', 'content', 'projects'] as Layer[]).map((l) => <label key={l} className="flex items-center gap-1.5"><input type="checkbox" checked={layers.has(l)} onChange={() => toggle(l)} />{l === 'projects' ? 'Project deadlines' : l === 'tasks' ? 'Tasks' : 'Content'}</label>)}
          {layers.has('tasks') && <label className="flex items-center gap-1.5 border-l pl-3"><input type="checkbox" checked={mine} onChange={(e) => setMine(e.target.checked)} />Only my tasks</label>}
        </div>} />
    </div>
  )
}
