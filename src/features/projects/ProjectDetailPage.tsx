import { useState } from 'react'
import { Link, useNavigate, useParams } from 'react-router-dom'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { toast } from 'sonner'
import { ArrowLeft, Plus, Trash2 } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { unwrap } from '@/lib/query'
import { friendlyError } from '@/lib/errors'
import { fmtDate, fmtMoney, titleCase } from '@/lib/utils'
import { nameOf, usePeople, useTaskStatuses } from '@/lib/lookups'
import type { Milestone, ProjectMember, ProjectOverview } from '@/lib/types'
import { serviceLabel } from '@/lib/types'
import { useAuth } from '@/features/auth/AuthProvider'
import { DataTable } from '@/components/DataTable'
import { Avatar, Badge, Button, Card, CardBody, CardHeader, DescriptionList, EmptyState, ErrorState, Input, PageHeader, Select, Spinner,
  StatusBadge, Tabs } from '@/components/ui'
import { CreateTaskDialog, isOverdue, KanbanBoard, StatusPill, TASK_SELECT, type TaskWithAssignees } from '@/features/tasks/shared'
import { ProjectTime, ProjectTimeline, RecurringRules } from './projectExtras'
import { ProjectFormFields, projectSchema, toProjectRow, type ProjectFormIn, type ProjectFormOut } from './ProjectsPage'

type Tab = 'board' | 'list' | 'timeline' | 'milestones' | 'recurring' | 'time' | 'team' | 'details'

function Milestones({ project, canManage }: { project: ProjectOverview; canManage: boolean }) {
  const { audience } = useAuth()
  const qc = useQueryClient()
  const [title, setTitle] = useState(''); const [due, setDue] = useState('')
  const list = useQuery({ queryKey: ['project', project.id, 'milestones'],
    queryFn: async () => unwrap(await supabase.from('project_milestones').select('*').eq('project_id', project.id).order('due_date', { nullsFirst: false })) as Milestone[] })
  const inv = () => qc.invalidateQueries({ queryKey: ['project', project.id, 'milestones'] })
  const add = useMutation({ mutationFn: async () => unwrap(await supabase.from('project_milestones').insert({ org_id: project.org_id, project_id: project.id, title, due_date: due || null })),
    onSuccess: () => { setTitle(''); setDue(''); inv() } })
  const toggle = useMutation({ mutationFn: async (m: Milestone) => unwrap(await supabase.from('project_milestones').update({ completed_at: m.completed_at ? null : new Date().toISOString() }).eq('id', m.id)), onSuccess: inv })
  const share = useMutation({ mutationFn: async (m: Milestone) => unwrap(await supabase.from('project_milestones').update({ client_visible: !m.client_visible }).eq('id', m.id)), onSuccess: inv })
  return (
    <Card>
      {canManage && <CardBody className="flex flex-col gap-2 border-b sm:flex-row">
        <Input aria-label="Milestone title" placeholder="Milestone title" value={title} onChange={(e) => setTitle(e.target.value)} />
        <Input aria-label="Due date" type="date" className="sm:w-44" value={due} onChange={(e) => setDue(e.target.value)} />
        <Button disabled={title.trim().length < 2} loading={add.isPending} onClick={() => add.mutate()}><Plus />Add</Button></CardBody>}
      <DataTable rows={list.data} loading={list.isLoading} empty={<EmptyState title="No milestones yet" />} columns={[
        { key: 'c', header: '', className: 'w-10', render: (m) => <input type="checkbox" aria-label={`Mark ${m.title} complete`} checked={Boolean(m.completed_at)} disabled={!canManage} onChange={() => toggle.mutate(m)} /> },
        { key: 't', header: 'Milestone', render: (m) => <span className={m.completed_at ? 'text-muted-foreground line-through' : 'font-medium'}>{m.title}</span> },
        { key: 'd', header: 'Due', render: (m) => fmtDate(m.due_date) },
        ...(audience === 'internal' ? [{ key: 'v', header: 'Client can see', render: (m: Milestone) => canManage
          ? <input type="checkbox" aria-label="Visible to client" checked={m.client_visible} onChange={() => share.mutate(m)} /> : (m.client_visible ? 'Yes' : 'No') }] : []),
      ]} />
    </Card>
  )
}

function Team({ project, canManage }: { project: ProjectOverview; canManage: boolean }) {
  const { data: people } = usePeople()
  const qc = useQueryClient()
  const [pid, setPid] = useState(''); const [role, setRole] = useState('member')
  const list = useQuery({ queryKey: ['project', project.id, 'members'],
    queryFn: async () => unwrap(await supabase.from('project_members').select('*').eq('project_id', project.id)) as ProjectMember[] })
  const inv = () => qc.invalidateQueries({ queryKey: ['project', project.id, 'members'] })
  const add = useMutation({ mutationFn: async () => unwrap(await supabase.from('project_members').insert({ project_id: project.id, profile_id: pid, org_id: project.org_id, project_role: role })),
    onSuccess: () => { setPid(''); inv() } })
  const remove = useMutation({ mutationFn: async (id: string) => unwrap(await supabase.from('project_members').delete().eq('project_id', project.id).eq('profile_id', id)), onSuccess: inv })
  return (
    <Card>
      <CardHeader title="Project team" description={`Owner: ${nameOf(people, project.owner_id)}. Members can see and create tasks in this project.`} />
      {canManage && <CardBody className="flex flex-col gap-2 border-b sm:flex-row">
        <Select aria-label="Person" value={pid} onChange={(e) => setPid(e.target.value)}><option value="">Add a person…</option>
          {people?.filter((p) => p.is_active && !list.data?.some((m) => m.profile_id === p.id)).map((p) => <option key={p.id} value={p.id}>{p.full_name || p.email}</option>)}</Select>
        <Select aria-label="Project role" className="sm:w-36" value={role} onChange={(e) => setRole(e.target.value)}>{['manager', 'member', 'viewer'].map((r) => <option key={r} value={r}>{titleCase(r)}</option>)}</Select>
        <Button disabled={!pid} loading={add.isPending} onClick={() => add.mutate()}>Add</Button></CardBody>}
      <DataTable rows={list.data} loading={list.isLoading} rowKey={(m) => m.profile_id} empty={<EmptyState title="No members yet" />} columns={[
        { key: 'n', header: 'Person', render: (m) => <span className="flex items-center gap-2"><Avatar name={nameOf(people, m.profile_id)} />{nameOf(people, m.profile_id)}</span> },
        { key: 'r', header: 'Role', render: (m) => <Badge>{titleCase(m.project_role)}</Badge> },
        { key: 'x', header: '', render: (m) => canManage && <Button size="icon" variant="ghost" aria-label="Remove member" onClick={() => remove.mutate(m.profile_id)}><Trash2 /></Button> },
      ]} />
    </Card>
  )
}

export default function ProjectDetailPage() {
  const { id } = useParams()
  const navigate = useNavigate()
  const { audience, can, session, org } = useAuth()
  const qc = useQueryClient()
  const [tab, setTab] = useState<Tab>('board')
  const [creating, setCreating] = useState(false)
  const [editing, setEditing] = useState(false)
  const { data: statuses } = useTaskStatuses()
  const { data: people } = usePeople()
  const q = useQuery({ queryKey: ['project', id], queryFn: async () => unwrap(await supabase.from('project_overview').select('*').eq('id', id!).maybeSingle()) as ProjectOverview | null })
  const members = useQuery({ queryKey: ['project', id, 'members'], enabled: audience === 'internal',
    queryFn: async () => unwrap(await supabase.from('project_members').select('*').eq('project_id', id!)) as ProjectMember[] })
  const tasks = useQuery({ queryKey: ['tasks', 'project', id],
    queryFn: async () => unwrap(await supabase.from('tasks').select(TASK_SELECT).eq('project_id', id!).is('parent_task_id', null).order('position')) as TaskWithAssignees[] })
  const form = useForm<ProjectFormIn, unknown, ProjectFormOut>({ resolver: zodResolver(projectSchema) })

  if (q.isLoading) return <Spinner />
  if (q.error) return <ErrorState message={friendlyError(q.error)} onRetry={q.refetch} />
  const p = q.data
  if (!p) return <EmptyState title="Project not found" description="It may not exist or you may not have access." />
  const myRole = members.data?.find((m) => m.profile_id === session?.user.id)?.project_role
  const canManage = audience === 'internal' && (can('projects.edit') || p.owner_id === session?.user.id || myRole === 'manager')
  const canCreateTask = audience === 'internal' && (canManage || (can('tasks.create') && (can('tasks.view_all') || myRole === 'member' || myRole === 'manager')))
  const save = form.handleSubmit(async (v) => {
    const { error } = await supabase.from('projects').update(toProjectRow(v)).eq('id', p.id)
    if (error) return toast.error(friendlyError(error))
    toast.success('Project saved'); setEditing(false); qc.invalidateQueries({ queryKey: ['project', id] }); qc.invalidateQueries({ queryKey: ['projects'] })
  })
  const remove = async () => {
    if (!window.confirm(`Delete "${p.name}" and all its tasks? This cannot be undone.`)) return
    const { error } = await supabase.from('projects').delete().eq('id', p.id)
    if (error) return toast.error(friendlyError(error))
    toast.success('Project deleted'); qc.invalidateQueries({ queryKey: ['projects'] }); navigate('/projects')
  }
  const statusOf = (sid: string) => statuses?.find((s) => s.id === sid)
  const tabs: { value: Tab; label: string }[] = [{ value: 'board', label: 'Board' }, { value: 'list', label: 'List' }, { value: 'timeline', label: 'Timeline' },
    { value: 'milestones', label: 'Milestones' }]
  if (audience === 'internal') tabs.push({ value: 'recurring', label: 'Recurring' }, { value: 'time', label: 'Time' }, { value: 'team', label: 'Team' }, { value: 'details', label: 'Details' })

  return (
    <div className="space-y-6">
      <Link to="/projects" className="inline-flex items-center gap-1 text-sm text-muted-foreground hover:text-foreground"><ArrowLeft className="size-4" />Projects</Link>
      <PageHeader title={p.name} description={`${p.client_name ?? 'Internal'}${p.service ? ` · ${serviceLabel(p.service)}` : ''} · due ${fmtDate(p.due_date)}`}
        actions={<>{canCreateTask && <Button onClick={() => setCreating(true)}><Plus />New task</Button>}</>} />
      <Card><CardBody className="flex flex-wrap items-center gap-x-8 gap-y-3">
        <div className="min-w-48 flex-1"><div className="flex justify-between text-sm"><span className="text-muted-foreground">Progress</span><span className="font-medium">{p.progress_pct}%</span></div>
          <div className="mt-1.5 h-2 rounded-full bg-muted"><div className="h-2 rounded-full bg-primary transition-all" style={{ width: `${p.progress_pct}%` }} /></div>
          {audience === 'internal' && <p className="mt-1 text-xs text-muted-foreground">{p.completed_tasks} of {p.total_tasks} tasks complete (weighted by estimates when every task has one)</p>}</div>
        <StatusBadge value={p.status} /><StatusBadge value={p.priority} />
        {audience === 'internal' && p.client_visible && <Badge tone="blue">Shared with client</Badge>}
      </CardBody></Card>
      <Tabs tabs={tabs} value={tab} onChange={setTab} />
      {tasks.error && <ErrorState message={friendlyError(tasks.error)} onRetry={tasks.refetch} />}
      {tab === 'board' && (tasks.isLoading || !statuses ? <Spinner /> : tasks.data?.length === 0
        ? <Card><EmptyState title="No tasks yet" action={canCreateTask && <Button onClick={() => setCreating(true)}><Plus />Create the first task</Button>} /></Card>
        : <KanbanBoard tasks={tasks.data ?? []} statuses={statuses} readOnly={audience !== 'internal'} />)}
      {tab === 'list' && <Card><DataTable rows={tasks.data} loading={tasks.isLoading} onRowClick={(t) => navigate(`/tasks/${t.id}`)} empty={<EmptyState title="No tasks yet" />} columns={[
        { key: 't', header: 'Task', render: (t) => <span className="font-medium">{t.title}</span> },
        { key: 's', header: 'Status', render: (t) => <StatusPill status={statusOf(t.status_id)} /> },
        ...(audience === 'internal' ? [{ key: 'a', header: 'Assignees', render: (t: TaskWithAssignees) => t.task_assignees.map((a) => nameOf(people, a.profile_id)).join(', ') || '—' }] : []),
        { key: 'd', header: 'Due', render: (t) => <span className={isOverdue(t, statusOf(t.status_id)?.category) ? 'font-medium text-destructive' : ''}>{fmtDate(t.due_date)}</span> },
        { key: 'p', header: 'Priority', render: (t) => <StatusBadge value={t.priority} /> },
      ]} /></Card>}
      {tab === 'timeline' && <ProjectTimeline project={p} tasks={tasks.data} statuses={statuses} />}
      {tab === 'milestones' && <Milestones project={p} canManage={canManage} />}
      {tab === 'recurring' && <RecurringRules project={p} canManage={canManage} />}
      {tab === 'time' && <ProjectTime projectId={p.id} />}
      {tab === 'team' && <Team project={p} canManage={canManage} />}
      {tab === 'details' && (editing ? (
        <Card><CardBody><form onSubmit={save} className="space-y-4"><ProjectFormFields form={form} excludeId={p.id} />
          <div className="flex justify-end gap-2"><Button type="button" variant="outline" onClick={() => setEditing(false)}>Cancel</Button><Button type="submit" loading={form.formState.isSubmitting}>Save</Button></div>
        </form></CardBody></Card>
      ) : (
        <Card><CardHeader title="Project details" action={<div className="flex gap-2">
          {can('projects.delete') && <Button variant="outline" onClick={remove}><Trash2 />Delete</Button>}
          {canManage && <Button variant="outline" onClick={() => { form.reset(Object.fromEntries(Object.entries(p).map(([k, v]) => [k, v ?? ''])) as ProjectFormIn); setEditing(true) }}>Edit</Button>}</div>} />
          <CardBody className="space-y-6"><DescriptionList items={[
            { label: 'Owner', value: nameOf(people, p.owner_id) }, { label: 'Client', value: p.client_id ? <Link className="text-primary" to={`/clients/${p.client_id}`}>{p.client_name}</Link> : 'Internal' },
            { label: 'Start', value: fmtDate(p.start_date) }, { label: 'Due', value: fmtDate(p.due_date) },
            { label: 'Budget', value: fmtMoney(p.budget_amount, org?.currency) }, { label: 'Client portal', value: p.client_visible ? 'Shared' : 'Not shared' },
          ]} /><div><p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">Description</p><p className="mt-1 whitespace-pre-line text-sm">{p.description || '—'}</p></div></CardBody></Card>
      ))}
      <CreateTaskDialog open={creating} onClose={() => setCreating(false)} projectId={p.id}
        memberIds={can('tasks.view_all') ? undefined : [...(members.data?.map((m) => m.profile_id) ?? []), ...(p.owner_id ? [p.owner_id] : [])]} />
    </div>
  )
}
