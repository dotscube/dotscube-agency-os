import { useNavigate } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { Download } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { ilikeTerm, unwrap, unwrapPage } from '@/lib/query'
import { friendlyError } from '@/lib/errors'
import { downloadCsv, fmtDate, titleCase, toCsv } from '@/lib/utils'
import { nameOf, useClientsLite, usePeople, useTaskStatuses } from '@/lib/lookups'
import { PRIORITIES, type StatusCategory } from '@/lib/types'
import { useAuth } from '@/features/auth/AuthProvider'
import { DataTable, SearchBox, useTableState } from '@/components/DataTable'
import { Button, Card, PageHeader, Select, StatusBadge, Tabs } from '@/components/ui'
import { isOverdue, StatusPill, TASK_SELECT, type TaskWithAssignees } from './shared'

type Scope = 'mine' | 'review' | 'all'
const NONE = '00000000-0000-0000-0000-000000000000'

export default function TasksPage() {
  const { can, session } = useAuth()
  const navigate = useNavigate()
  const t = useTableState({ sort: { column: 'due_date', ascending: true } })
  const scope = (t.params.get('scope') as Scope) ?? 'mine'
  const due = t.params.get('due') ?? ''
  const category = (t.params.get('category') ?? '') as StatusCategory | ''
  const priority = t.params.get('priority') ?? ''
  const project = t.params.get('project') ?? ''
  const client = t.params.get('client') ?? ''
  const assignee = t.params.get('assignee') ?? ''
  const showDone = t.params.get('done') === '1'
  const { data: statuses } = useTaskStatuses()
  const { data: people } = usePeople()
  const { data: clients } = useClientsLite(can('clients.view'))
  const projects = useQuery({ queryKey: ['projects', 'lite'], queryFn: async () => unwrap(await supabase.from('projects').select('id, name').order('name')) as { id: string; name: string }[] })
  const today = new Date().toISOString().slice(0, 10)
  const weekEnd = new Date(Date.now() + 7 * 86400_000).toISOString().slice(0, 10)
  const uid = session!.user.id
  const assigneeFilter = scope === 'mine' ? uid : assignee

  const idsForAssignee = useQuery({
    queryKey: ['task_assignees', assigneeFilter], enabled: Boolean(assigneeFilter),
    queryFn: async () => (unwrap(await supabase.from('task_assignees').select('task_id').eq('profile_id', assigneeFilter)) as { task_id: string }[]).map((r) => r.task_id),
  })

  const buildQuery = (count: boolean) => {
    let q = supabase.from('tasks').select(TASK_SELECT, count ? { count: 'exact' } : undefined)
    if (assigneeFilter) q = q.in('id', idsForAssignee.data?.length ? idsForAssignee.data : [NONE])
    if (scope === 'review') q = q.eq('reviewer_id', uid)
    if (t.search) q = q.ilike('title', ilikeTerm(t.search))
    const cats: StatusCategory[] = category ? [category] : scope === 'review' ? ['review'] : showDone ? [] :['todo', 'in_progress', 'review', 'changes_requested']
    if (cats.length && statuses) q = q.in('status_id', statuses.filter((s) => cats.includes(s.category)).map((s) => s.id))
    if (due === 'overdue') q = q.lt('due_date', today)
    if (due === 'today') q = q.eq('due_date', today)
    if (due === 'week') q = q.gte('due_date', today).lte('due_date', weekEnd)
    if (priority) q = q.eq('priority', priority)
    if (project) q = q.eq('project_id', project)
    if (client) q = q.eq('client_id', client)
    return q.order(t.sort!.column, { ascending: t.sort!.ascending, nullsFirst: false })
  }
  const list = useQuery({
    queryKey: ['tasks', 'list', scope, t.search, due, category, priority, project, client, assignee, showDone, idsForAssignee.data, t.sort, t.page],
    enabled: Boolean(statuses) && (!assigneeFilter || Boolean(idsForAssignee.data)),
    queryFn: async () => unwrapPage(await buildQuery(true).range((t.page - 1) * t.pageSize, t.page * t.pageSize - 1)) as { rows: TaskWithAssignees[]; total: number },
  })
  const projectName = (id: string) => projects.data?.find((p) => p.id === id)?.name ?? '—'
  const statusOf = (id: string) => statuses?.find((s) => s.id === id)

  const exportCsv = async () => {
    const rows = unwrap(await buildQuery(false).limit(5000)) as TaskWithAssignees[]
    downloadCsv('tasks.csv', toCsv(rows.map((r) => ({ ...r, project: projectName(r.project_id), status: statusOf(r.status_id)?.name,
      assignees: r.task_assignees.map((a) => nameOf(people, a.profile_id)).join('; '), reviewer: nameOf(people, r.reviewer_id),
      estimate_h: r.estimated_minutes != null ? (r.estimated_minutes / 60).toFixed(2) : '' })), [
      { key: 'title', label: 'Task' }, { key: 'project', label: 'Project' }, { key: 'status', label: 'Status' }, { key: 'priority', label: 'Priority' },
      { key: 'assignees', label: 'Assignees' }, { key: 'reviewer', label: 'Reviewer' }, { key: 'start_date', label: 'Start' }, { key: 'due_date', label: 'Due' },
      { key: 'estimate_h', label: 'Estimate (h)' }, { key: 'completed_at', label: 'Completed' }]))
  }

  const scopes: { value: Scope; label: string }[] = [{ value: 'mine', label: 'Assigned to me' }, { value: 'review', label: 'To review' }, { value: 'all', label: 'All visible tasks' }]
  return (
    <div>
      <PageHeader title="Tasks" description="Create tasks from inside a project." actions={can('projects.export') && <Button variant="outline" onClick={exportCsv}><Download />Export</Button>} />
      <Tabs tabs={scopes} value={scope} onChange={(s) => t.setFilter('scope', s)} />
      <Card className="mt-4">
        <div className="flex flex-col flex-wrap gap-2 border-b p-3 sm:flex-row sm:items-center">
          <SearchBox value={t.search} onChange={t.setSearch} placeholder="Search tasks" />
          <Select aria-label="Due" className="sm:w-36" value={due} onChange={(e) => t.setFilter('due', e.target.value)}>
            <option value="">Any due date</option><option value="overdue">Overdue</option><option value="today">Due today</option><option value="week">Next 7 days</option></Select>
          <Select aria-label="Status" className="sm:w-44" value={category} onChange={(e) => t.setFilter('category', e.target.value)}>
            <option value="">Open statuses</option>{statuses?.map((s) => <option key={s.id} value={s.category}>{s.name}</option>)}</Select>
          <Select aria-label="Priority" className="sm:w-32" value={priority} onChange={(e) => t.setFilter('priority', e.target.value)}>
            <option value="">Any priority</option>{PRIORITIES.map((p) => <option key={p} value={p}>{titleCase(p)}</option>)}</Select>
          <Select aria-label="Project" className="sm:w-44" value={project} onChange={(e) => t.setFilter('project', e.target.value)}>
            <option value="">All projects</option>{projects.data?.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}</Select>
          {clients && <Select aria-label="Client" className="sm:w-40" value={client} onChange={(e) => t.setFilter('client', e.target.value)}>
            <option value="">All clients</option>{clients.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</Select>}
          {scope === 'all' && <Select aria-label="Assignee" className="sm:w-40" value={assignee} onChange={(e) => t.setFilter('assignee', e.target.value)}>
            <option value="">Anyone</option>{people?.map((p) => <option key={p.id} value={p.id}>{p.full_name || p.email}</option>)}</Select>}
          <label className="flex items-center gap-1.5 text-sm"><input type="checkbox" checked={showDone} onChange={(e) => t.setFilter('done', e.target.checked ? '1' : null)} />Include completed</label>
        </div>
        <DataTable rows={list.data?.rows} total={list.data?.total} loading={list.isLoading} error={list.error ? friendlyError(list.error) : null} onRetry={list.refetch}
          page={t.page} pageSize={t.pageSize} onPageChange={t.setPage} sort={t.sort} onSortChange={t.setSort} onRowClick={(r) => navigate(`/tasks/${r.id}`)}
          columns={[
            { key: 't', header: 'Task', sortKey: 'title', render: (r) => <span><span className="block font-medium">{r.title}</span><span className="text-xs text-muted-foreground">{projectName(r.project_id)}</span></span> },
            { key: 's', header: 'Status', render: (r) => <StatusPill status={statusOf(r.status_id)} /> },
            { key: 'a', header: 'Assignees', render: (r) => r.task_assignees.map((a) => nameOf(people, a.profile_id)).join(', ') || '—' },
            { key: 'd', header: 'Due', sortKey: 'due_date', render: (r) => <span className={isOverdue(r, statusOf(r.status_id)?.category, today) ? 'font-medium text-destructive' : ''}>{fmtDate(r.due_date)}</span> },
            { key: 'p', header: 'Priority', sortKey: 'priority', render: (r) => <StatusBadge value={r.priority} /> },
          ]} />
      </Card>
    </div>
  )
}
