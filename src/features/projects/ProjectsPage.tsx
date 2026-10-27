import { useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { z } from 'zod'
import { toast } from 'sonner'
import { Download, LayoutTemplate, Plus } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { ilikeTerm, unwrap, unwrapPage } from '@/lib/query'
import { friendlyError } from '@/lib/errors'
import { downloadCsv, fmtDate, fmtMoney, titleCase, toCsv } from '@/lib/utils'
import { nameOf, useClientsLite, usePeople, useTaskStatuses } from '@/lib/lookups'
import { PRIORITIES, SERVICE_TYPES, type ProjectOverview, type ProjectStatus, serviceLabel } from '@/lib/types'
import { useAuth } from '@/features/auth/AuthProvider'
import { DataTable, SearchBox, useTableState } from '@/components/DataTable'
import { Badge, Button, Card, Dialog, Field, Input, PageHeader, Select, StatusBadge, Textarea } from '@/components/ui'
import { FromTemplateDialog } from './templates'

const STATUSES: ProjectStatus[] = ['planning', 'active', 'on_hold', 'completed', 'cancelled']

export const projectSchema = z.object({
  name: z.string().trim().min(2, 'Required').max(160),
  description: z.string().max(5000).optional(),
  client_id: z.string().optional(), parent_project_id: z.string().optional(),
  service: z.string().optional(), owner_id: z.string().optional(),
  status: z.enum(['planning', 'active', 'on_hold', 'completed', 'cancelled']),
  priority: z.enum(['low', 'medium', 'high', 'urgent']),
  start_date: z.string().optional(), due_date: z.string().optional(),
  budget_amount: z.coerce.number().min(0).optional().or(z.literal('')),
  client_visible: z.boolean(),
}).refine((v) => !v.due_date || !v.start_date || v.due_date >= v.start_date, { path: ['due_date'], message: 'Due date is before start date' })
export type ProjectFormIn = z.input<typeof projectSchema>
export type ProjectFormOut = z.output<typeof projectSchema>

export const toProjectRow = (v: ProjectFormOut) => ({
  name: v.name, description: v.description || null, client_id: v.client_id || null, parent_project_id: v.parent_project_id || null,
  service: v.service || null, owner_id: v.owner_id || null, status: v.status, priority: v.priority, start_date: v.start_date || null,
  due_date: v.due_date || null, budget_amount: v.budget_amount === '' || v.budget_amount == null ? null : Number(v.budget_amount), client_visible: v.client_visible,
})

export function ProjectFormFields({ form, excludeId }: { form: ReturnType<typeof useForm<ProjectFormIn, unknown, ProjectFormOut>>; excludeId?: string }) {
  const { can } = useAuth()
  const { data: clients } = useClientsLite(can('clients.view'))
  const { data: people } = usePeople()
  const parents = useQuery({ queryKey: ['projects', 'parents'],
    queryFn: async () => unwrap(await supabase.from('projects').select('id, name').is('parent_project_id', null).order('name')) as { id: string; name: string }[] })
  const e = form.formState.errors
  const r = form.register
  return (
    <div className="grid gap-4 sm:grid-cols-2">
      <Field label="Project name" error={e.name?.message} className="sm:col-span-2">{(p) => <Input {...p} {...r('name')} />}</Field>
      <Field label="Client">{(p) => <Select {...p} {...r('client_id')}><option value="">Internal project</option>{clients?.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</Select>}</Field>
      <Field label="Service">{(p) => <Select {...p} {...r('service')}><option value="">—</option>{SERVICE_TYPES.map((s) => <option key={s} value={s}>{serviceLabel(s)}</option>)}</Select>}</Field>
      <Field label="Project owner">{(p) => <Select {...p} {...r('owner_id')}><option value="">—</option>{people?.filter((x) => x.is_active).map((x) => <option key={x.id} value={x.id}>{x.full_name || x.email}</option>)}</Select>}</Field>
      <Field label="Parent project" hint="Makes this a sub-project">{(p) => <Select {...p} {...r('parent_project_id')}><option value="">None</option>
        {parents.data?.filter((x) => x.id !== excludeId).map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}</Select>}</Field>
      <Field label="Status">{(p) => <Select {...p} {...r('status')}>{STATUSES.map((s) => <option key={s} value={s}>{titleCase(s)}</option>)}</Select>}</Field>
      <Field label="Priority">{(p) => <Select {...p} {...r('priority')}>{PRIORITIES.map((s) => <option key={s} value={s}>{titleCase(s)}</option>)}</Select>}</Field>
      <Field label="Start date">{(p) => <Input type="date" {...p} {...r('start_date')} />}</Field>
      <Field label="Due date" error={e.due_date?.message}>{(p) => <Input type="date" {...p} {...r('due_date')} />}</Field>
      <Field label="Budget" error={e.budget_amount?.message}>{(p) => <Input type="number" min={0} {...p} {...r('budget_amount')} />}</Field>
      <label className="flex items-center gap-2 self-end text-sm"><input type="checkbox" {...r('client_visible')} />Share with client portal</label>
      <Field label="Description" className="sm:col-span-2">{(p) => <Textarea rows={3} {...p} {...r('description')} />}</Field>
    </div>
  )
}

function CreateProjectDialog({ open, onClose }: { open: boolean; onClose: () => void }) {
  const { org, session } = useAuth()
  const qc = useQueryClient()
  const navigate = useNavigate()
  const form = useForm<ProjectFormIn, unknown, ProjectFormOut>({ resolver: zodResolver(projectSchema),
    defaultValues: { status: 'planning', priority: 'medium', client_visible: false, owner_id: session?.user.id } })
  const submit = form.handleSubmit(async (v) => {
    const { data, error } = await supabase.from('projects').insert({ ...toProjectRow(v), org_id: org!.id, created_by: session!.user.id }).select('id').single()
    if (error) return toast.error(friendlyError(error))
    toast.success('Project created'); qc.invalidateQueries({ queryKey: ['projects'] }); form.reset(); onClose(); navigate(`/projects/${data.id}`)
  })
  return (
    <Dialog open={open} onClose={onClose} title="New project" wide
      footer={<><Button variant="outline" onClick={onClose}>Cancel</Button><Button onClick={submit} loading={form.formState.isSubmitting}>Create project</Button></>}>
      <form onSubmit={submit}><ProjectFormFields form={form} /></form>
    </Dialog>
  )
}

export default function ProjectsPage() {
  const { can, audience, org } = useAuth()
  const navigate = useNavigate()
  const t = useTableState({ sort: { column: 'due_date', ascending: true } })
  const status = t.params.get('status') ?? ''
  const risk = t.params.get('risk') === '1'
  const [open, setOpen] = useState(false)
  const [fromTpl, setFromTpl] = useState(false)
  const { data: people } = usePeople()
  const { data: statuses } = useTaskStatuses()
  const today = new Date().toISOString().slice(0, 10)
  const in7 = new Date(Date.now() + 7 * 86400_000).toISOString().slice(0, 10)

  // projects with overdue open tasks (same rule as the dashboard's "at risk" metric)
  const overdueProjects = useQuery({
    queryKey: ['projects', 'overdue-ids', statuses?.length], enabled: risk && Boolean(statuses),
    queryFn: async () => {
      const open = statuses!.filter((s) => s.category !== 'done' && s.category !== 'cancelled').map((s) => s.id)
      const rows = unwrap(await supabase.from('tasks').select('project_id').lt('due_date', today).in('status_id', open)) as { project_id: string }[]
      return [...new Set(rows.map((r) => r.project_id))]
    },
  })

  const buildQuery = (count: boolean) => {
    let q = supabase.from('project_overview').select('*', count ? { count: 'exact' } : undefined)
    if (t.search) q = q.ilike('name', ilikeTerm(t.search))
    if (status) q = q.eq('status', status)
    if (risk) {
      q = q.eq('status', 'active')
      const ids = overdueProjects.data ?? []
      q = q.or(`and(due_date.lte.${in7},progress_pct.lt.80)${ids.length ? `,id.in.(${ids.join(',')})` : ''}`)
    }
    return q.order(t.sort!.column, { ascending: t.sort!.ascending, nullsFirst: false })
  }
  const list = useQuery({
    queryKey: ['projects', t.search, status, risk, overdueProjects.data, t.sort, t.page], enabled: !risk || Boolean(overdueProjects.data),
    queryFn: async () => unwrapPage(await buildQuery(true).range((t.page - 1) * t.pageSize, t.page * t.pageSize - 1)) as { rows: ProjectOverview[]; total: number },
  })
  const exportCsv = async () => {
    const rows = unwrap(await buildQuery(false).limit(5000)) as ProjectOverview[]
    downloadCsv('projects.csv', toCsv(rows.map((r) => ({ ...r, owner: nameOf(people, r.owner_id) })), [
      { key: 'name', label: 'Project' }, { key: 'client_name', label: 'Client' }, { key: 'service', label: 'Service' }, { key: 'owner', label: 'Owner' },
      { key: 'status', label: 'Status' }, { key: 'priority', label: 'Priority' }, { key: 'start_date', label: 'Start' }, { key: 'due_date', label: 'Due' },
      { key: 'progress_pct', label: 'Progress %' }, { key: 'total_tasks', label: 'Tasks' }, { key: 'budget_amount', label: 'Budget' }]))
  }

  return (
    <div>
      <PageHeader title="Projects" actions={audience === 'internal' && <>
        {can('projects.export') && <Button variant="outline" onClick={exportCsv}><Download />Export</Button>}
        {can('projects.create') && <Button variant="outline" onClick={() => setFromTpl(true)}><LayoutTemplate />From template</Button>}
        {can('projects.create') && <Button onClick={() => setOpen(true)}><Plus />New project</Button>}</>} />
      <Card>
        <div className="flex flex-col gap-2 border-b p-3 sm:flex-row sm:items-center">
          <SearchBox value={t.search} onChange={t.setSearch} placeholder="Search projects" />
          <Select aria-label="Status" className="sm:w-44" value={status} onChange={(e) => t.setFilter('status', e.target.value)}>
            <option value="">All statuses</option>{STATUSES.map((s) => <option key={s} value={s}>{titleCase(s)}</option>)}</Select>
          {risk && <Badge tone="amber" className="gap-2">At risk<button aria-label="Clear risk filter" onClick={() => t.setFilter('risk', null)}>×</button></Badge>}
        </div>
        <DataTable rows={list.data?.rows} total={list.data?.total} loading={list.isLoading} error={list.error ? friendlyError(list.error) : null} onRetry={list.refetch}
          page={t.page} pageSize={t.pageSize} onPageChange={t.setPage} sort={t.sort} onSortChange={t.setSort} onRowClick={(r) => navigate(`/projects/${r.id}`)}
          columns={[
            { key: 'n', header: 'Project', sortKey: 'name', render: (p) => <span><span className="block font-medium">{p.name}</span>
              <span className="text-xs text-muted-foreground">{p.client_name ?? 'Internal'}{p.service ? ` · ${serviceLabel(p.service)}` : ''}</span></span> },
            ...(audience === 'internal' ? [{ key: 'o', header: 'Owner', render: (p: ProjectOverview) => nameOf(people, p.owner_id) }] : []),
            { key: 'd', header: 'Due', sortKey: 'due_date', render: (p) => <span className={p.due_date && p.due_date < today && p.status === 'active' ? 'font-medium text-destructive' : ''}>{fmtDate(p.due_date)}</span> },
            { key: 'pr', header: 'Progress', sortKey: 'progress_pct', render: (p) => (
              <div className="flex items-center gap-2"><div className="h-1.5 w-20 rounded-full bg-muted"><div className="h-1.5 rounded-full bg-primary" style={{ width: `${p.progress_pct}%` }} /></div>
                <span className="text-xs tabular-nums text-muted-foreground">{p.progress_pct}%</span></div>) },
            ...(audience === 'internal' ? [{ key: 'b', header: 'Budget', render: (p: ProjectOverview) => fmtMoney(p.budget_amount, org?.currency) }] : []),
            { key: 'p', header: 'Priority', render: (p) => <StatusBadge value={p.priority} /> },
            { key: 's', header: 'Status', sortKey: 'status', render: (p) => <StatusBadge value={p.status} /> },
          ]} />
      </Card>
      <CreateProjectDialog open={open} onClose={() => setOpen(false)} />
      <FromTemplateDialog open={fromTpl} onClose={() => setFromTpl(false)} />
    </div>
  )
}
