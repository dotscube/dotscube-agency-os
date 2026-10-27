import { useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { toast } from 'sonner'
import { ArrowDown, ArrowUp, LayoutTemplate, Plus, Trash2 } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { unwrap } from '@/lib/query'
import { fmtMinutes, titleCase } from '@/lib/utils'
import { isoDay } from '@/lib/dates'
import { useClientsLite } from '@/lib/lookups'
import { PRIORITIES, SERVICE_TYPES, serviceLabel, type ProjectTemplate, type TemplateTask } from '@/lib/types'
import { useAuth } from '@/features/auth/AuthProvider'
import { DataTable } from '@/components/DataTable'
import { Badge, Button, Card, CardBody, CardHeader, Dialog, EmptyState, Field, Input, PageHeader, Select, Spinner, Textarea } from '@/components/ui'

export function useTemplates() {
  return useQuery({ queryKey: ['templates'],
    queryFn: async () => unwrap(await supabase.from('project_templates').select('*, template_tasks(count)').order('name')) as
      (ProjectTemplate & { template_tasks: { count: number }[] })[] })
}

/** Create a project (with its tasks) from a template. */
export function FromTemplateDialog({ open, onClose }: { open: boolean; onClose: () => void }) {
  const { can } = useAuth()
  const navigate = useNavigate()
  const qc = useQueryClient()
  const templates = useTemplates()
  const { data: clients } = useClientsLite(can('clients.view'))
  const [tpl, setTpl] = useState(''); const [name, setName] = useState(''); const [client, setClient] = useState('')
  const [start, setStart] = useState(isoDay(new Date())); const [share, setShare] = useState(false)
  const chosen = templates.data?.find((t) => t.id === tpl)
  const create = useMutation({
    mutationFn: async () => unwrap(await supabase.rpc('create_project_from_template', { p_template: tpl, p_name: name.trim() || chosen?.name,
      p_client: client || null, p_start: start || null, p_client_visible: share })) as string,
    onSuccess: (id) => { qc.invalidateQueries({ queryKey: ['projects'] }); toast.success('Project created from template'); onClose(); navigate(`/projects/${id}`) },
  })
  const pick = (id: string) => {
    setTpl(id)
    const t = templates.data?.find((x) => x.id === id)
    const c = clients?.find((x) => x.id === client)
    if (t) setName(c ? `${c.name} – ${t.name}` : t.name)
  }
  return (
    <Dialog open={open} onClose={onClose} title="New project from template" description="Creates the project and all of the template's tasks with dates relative to the start date."
      footer={<><Button variant="outline" onClick={onClose}>Cancel</Button><Button disabled={!tpl || name.trim().length < 2} loading={create.isPending} onClick={() => create.mutate()}>Create project</Button></>}>
      <div className="grid gap-4 sm:grid-cols-2">
        <Field label="Template" className="sm:col-span-2">{(p) => <Select {...p} value={tpl} onChange={(e) => pick(e.target.value)}><option value="">Choose a template…</option>
          {templates.data?.filter((t) => t.is_active).map((t) => <option key={t.id} value={t.id}>{t.name} ({t.template_tasks[0]?.count ?? 0} tasks)</option>)}</Select>}</Field>
        <Field label="Client">{(p) => <Select {...p} value={client} onChange={(e) => { setClient(e.target.value); const c = clients?.find((x) => x.id === e.target.value); if (chosen) setName(c ? `${c.name} – ${chosen.name}` : chosen.name) }}>
          <option value="">Internal project</option>{clients?.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</Select>}</Field>
        <Field label="Start date">{(p) => <Input {...p} type="date" value={start} onChange={(e) => setStart(e.target.value)} />}</Field>
        <Field label="Project name" className="sm:col-span-2">{(p) => <Input {...p} value={name} onChange={(e) => setName(e.target.value)} />}</Field>
        <label className="flex items-center gap-2 text-sm sm:col-span-2"><input type="checkbox" checked={share} onChange={(e) => setShare(e.target.checked)} />Share with client portal</label>
        {chosen && <p className="text-sm text-muted-foreground sm:col-span-2">{chosen.description} · about {chosen.default_duration_days} days.</p>}
      </div>
    </Dialog>
  )
}

function TemplateEditor({ template, onDeleted }: { template: ProjectTemplate; onDeleted: () => void }) {
  const qc = useQueryClient()
  const tasks = useQuery({ queryKey: ['templates', template.id, 'tasks'],
    queryFn: async () => unwrap(await supabase.from('template_tasks').select('*').eq('template_id', template.id).order('position')) as TemplateTask[] })
  const inv = () => { qc.invalidateQueries({ queryKey: ['templates'] }) }
  const [title, setTitle] = useState(''); const [off, setOff] = useState('0'); const [dur, setDur] = useState('3'); const [hrs, setHrs] = useState('')
  const add = useMutation({
    mutationFn: async () => unwrap(await supabase.from('template_tasks').insert({ template_id: template.id, org_id: template.org_id, title: title.trim(),
      start_offset_days: Number(off) || 0, duration_days: Number(dur) || 0, estimated_minutes: hrs ? Math.round(Number(hrs) * 60) : null,
      position: (tasks.data?.at(-1)?.position ?? 0) + 1 })),
    onSuccess: () => { setTitle(''); setHrs(''); inv() } })
  const patch = useMutation({ mutationFn: async (v: { id: string; row: Partial<TemplateTask> }) => unwrap(await supabase.from('template_tasks').update(v.row).eq('id', v.id)), onSuccess: inv })
  const remove = useMutation({ mutationFn: async (id: string) => unwrap(await supabase.from('template_tasks').delete().eq('id', id)), onSuccess: inv })
  const savePatch = useMutation({ mutationFn: async (row: Partial<ProjectTemplate>) => unwrap(await supabase.from('project_templates').update(row).eq('id', template.id)),
    onSuccess: () => { inv(); toast.success('Template saved') } })
  const del = useMutation({ mutationFn: async () => unwrap(await supabase.from('project_templates').delete().eq('id', template.id)),
    onSuccess: () => { inv(); onDeleted(); toast.success('Template deleted') } })
  const move = (t: TemplateTask, dir: -1 | 1) => {
    const list = tasks.data ?? []
    const i = list.findIndex((x) => x.id === t.id); const j = i + dir
    if (j < 0 || j >= list.length) return
    patch.mutate({ id: t.id, row: { position: list[j]!.position } }); patch.mutate({ id: list[j]!.id, row: { position: t.position } })
  }
  return (
    <Card>
      <CardHeader title={template.name} description={`${template.service ? serviceLabel(template.service) + ' · ' : ''}${template.default_duration_days} days`}
        action={<div className="flex gap-2">
          <Button size="sm" variant="outline" onClick={() => savePatch.mutate({ is_active: !template.is_active })}>{template.is_active ? 'Deactivate' : 'Activate'}</Button>
          <Button size="sm" variant="outline" aria-label="Delete template" onClick={() => window.confirm(`Delete template "${template.name}"? Projects already created are not affected.`) && del.mutate()}><Trash2 /></Button></div>} />
      <CardBody className="grid gap-3 border-b sm:grid-cols-[1fr_8rem]">
        <Field label="Description">{(p) => <Textarea {...p} rows={2} defaultValue={template.description ?? ''} key={template.id + 'd'}
          onBlur={(e) => e.target.value !== (template.description ?? '') && savePatch.mutate({ description: e.target.value || null })} />}</Field>
        <Field label="Duration (days)">{(p) => <Input {...p} type="number" min={1} max={730} defaultValue={template.default_duration_days} key={template.id + 'n'}
          onBlur={(e) => Number(e.target.value) !== template.default_duration_days && savePatch.mutate({ default_duration_days: Number(e.target.value) })} />}</Field>
      </CardBody>
      {tasks.isLoading ? <Spinner /> : <DataTable rows={tasks.data} empty={<EmptyState title="No tasks in this template" />} columns={[
        { key: 'o', header: '', className: 'w-16', render: (t) => <span className="flex">
          <button aria-label="Move up" className="p-1 text-muted-foreground hover:text-foreground" onClick={() => move(t, -1)}><ArrowUp className="size-3.5" /></button>
          <button aria-label="Move down" className="p-1 text-muted-foreground hover:text-foreground" onClick={() => move(t, 1)}><ArrowDown className="size-3.5" /></button></span> },
        { key: 't', header: 'Task', render: (t) => <span className="font-medium">{t.title}</span> },
        { key: 'w', header: 'When', render: (t) => `Day ${t.start_offset_days + 1}–${t.start_offset_days + t.duration_days + 1}` },
        { key: 'e', header: 'Estimate', render: (t) => fmtMinutes(t.estimated_minutes) },
        { key: 'p', header: 'Priority', render: (t) => <Select aria-label="Priority" className="h-8 w-28" value={t.priority}
          onChange={(e) => patch.mutate({ id: t.id, row: { priority: e.target.value as TemplateTask['priority'] } })}>{PRIORITIES.map((p) => <option key={p} value={p}>{titleCase(p)}</option>)}</Select> },
        { key: 'c', header: 'Client sees', render: (t) => <input type="checkbox" aria-label="Visible to client" checked={t.client_visible} onChange={() => patch.mutate({ id: t.id, row: { client_visible: !t.client_visible } })} /> },
        { key: 'x', header: '', render: (t) => <Button size="icon" variant="ghost" aria-label={`Remove ${t.title}`} onClick={() => remove.mutate(t.id)}><Trash2 /></Button> },
      ]} />}
      <CardBody className="grid gap-2 border-t sm:grid-cols-[1fr_6rem_6rem_6rem_auto] sm:items-end">
        <Field label="New task">{(p) => <Input {...p} value={title} onChange={(e) => setTitle(e.target.value)} placeholder="e.g. Competitor analysis" />}</Field>
        <Field label="Starts day">{(p) => <Input {...p} type="number" min={1} value={Number(off) + 1} onChange={(e) => setOff(String(Math.max(0, Number(e.target.value) - 1)))} />}</Field>
        <Field label="Days">{(p) => <Input {...p} type="number" min={0} value={dur} onChange={(e) => setDur(e.target.value)} />}</Field>
        <Field label="Hours">{(p) => <Input {...p} type="number" min={0} step="0.5" value={hrs} onChange={(e) => setHrs(e.target.value)} />}</Field>
        <Button disabled={title.trim().length < 2} loading={add.isPending} onClick={() => add.mutate()}><Plus />Add</Button>
      </CardBody>
    </Card>
  )
}

export default function TemplatesPage() {
  const { org } = useAuth()
  const qc = useQueryClient()
  const templates = useTemplates()
  const [sel, setSel] = useState<string | null>(null)
  const [creating, setCreating] = useState(false)
  const [name, setName] = useState(''); const [service, setService] = useState('')
  const create = useMutation({
    mutationFn: async () => unwrap(await supabase.from('project_templates').insert({ org_id: org!.id, name: name.trim(), service: service || null }).select('id').single()) as { id: string },
    onSuccess: (r) => { qc.invalidateQueries({ queryKey: ['templates'] }); setSel(r.id); setCreating(false); setName(''); setService('') },
  })
  const current = templates.data?.find((t) => t.id === (sel ?? templates.data?.[0]?.id))
  return (
    <div className="space-y-6">
      <PageHeader title="Project templates" description="Reusable task lists for each service. Use them from Projects → New from template."
        actions={<Button onClick={() => setCreating(true)}><Plus />New template</Button>} />
      {templates.isLoading ? <Spinner /> : !templates.data?.length ? <Card><EmptyState icon={<LayoutTemplate />} title="No templates yet" /></Card> : (
        <div className="grid gap-4 lg:grid-cols-[16rem_1fr]">
          <Card><ul className="p-2">{templates.data.map((t) => (
            <li key={t.id}><button onClick={() => setSel(t.id)} className={`flex w-full items-center justify-between gap-2 rounded-md px-3 py-2 text-left text-sm ${current?.id === t.id ? 'bg-accent text-accent-foreground' : 'hover:bg-muted'}`}>
              <span className="truncate">{t.name}</span><span className="flex shrink-0 items-center gap-1">{!t.is_active && <Badge tone="slate">Off</Badge>}
                <span className="text-xs text-muted-foreground">{t.template_tasks[0]?.count ?? 0}</span></span></button></li>))}</ul></Card>
          {current && <TemplateEditor key={current.id} template={current} onDeleted={() => setSel(null)} />}
        </div>)}
      <Dialog open={creating} onClose={() => setCreating(false)} title="New template"
        footer={<><Button variant="outline" onClick={() => setCreating(false)}>Cancel</Button><Button disabled={name.trim().length < 2} loading={create.isPending} onClick={() => create.mutate()}>Create</Button></>}>
        <div className="space-y-4">
          <Field label="Name">{(p) => <Input {...p} value={name} onChange={(e) => setName(e.target.value)} placeholder="e.g. Instagram growth – 3 months" />}</Field>
          <Field label="Service">{(p) => <Select {...p} value={service} onChange={(e) => setService(e.target.value)}><option value="">—</option>
            {SERVICE_TYPES.map((s) => <option key={s} value={s}>{serviceLabel(s)}</option>)}</Select>}</Field>
        </div>
      </Dialog>
    </div>
  )
}
