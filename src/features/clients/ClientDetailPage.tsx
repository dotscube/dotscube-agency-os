import { useState } from 'react'
import { Link, useParams } from 'react-router-dom'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { z } from 'zod'
import { toast } from 'sonner'
import { ArrowLeft, Check, Mail, Plus, Trash2 } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { createInvitation, inviteToast, unwrap } from '@/lib/query'
import { friendlyError } from '@/lib/errors'
import { fmtDate, fmtMoney, titleCase } from '@/lib/utils'
import { nameOf, useEmployeesLite, usePeople, useRoles } from '@/lib/lookups'
import { SERVICE_TYPES, type Client, type ClientBilling, type ClientContact, type ClientNote, type ClientService, type Contract, type ProjectOverview, serviceLabel } from '@/lib/types'
import { GST_STATES } from '@/lib/finance'
import { useAuth } from '@/features/auth/AuthProvider'
import { DataTable } from '@/components/DataTable'
import { Badge, Button, Card, CardBody, CardHeader, DescriptionList, Dialog, EmptyState, ErrorState, Field, Input, PageHeader, Select,
  Spinner, StatusBadge, Tabs, Textarea } from '@/components/ui'
import { ClientFormFields, clientSchema, toClientRow, type ClientForm } from './ClientsPage'

type Tab = 'overview' | 'contacts' | 'services' | 'billing' | 'projects' | 'notes' | 'portal'

function useList<T>(key: string, table: string, clientId: string, order = 'created_at', enabled = true) {
  return useQuery({
    queryKey: [table, clientId], enabled,
    queryFn: async () => unwrap(await supabase.from(table).select('*').eq('client_id', clientId).order(order, { ascending: order !== 'created_at' })) as T[],
    meta: { key },
  })
}

function Onboarding({ client }: { client: Client }) {
  const { session } = useAuth()
  const qc = useQueryClient()
  const items = useQuery({
    queryKey: ['client_onboarding_items', client.id],
    queryFn: async () => unwrap(await supabase.from('client_onboarding_items').select('*').eq('client_id', client.id).order('position')) as
      { id: string; title: string; done_at: string | null }[],
  })
  const toggle = useMutation({
    mutationFn: async (i: { id: string; done_at: string | null }) => unwrap(await supabase.from('client_onboarding_items')
      .update({ done_at: i.done_at ? null : new Date().toISOString(), done_by: i.done_at ? null : session!.user.id }).eq('id', i.id)),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['client_onboarding_items', client.id] }),
  })
  const done = items.data?.filter((i) => i.done_at).length ?? 0
  return (
    <Card><CardHeader title="Onboarding checklist" description={`${done} of ${items.data?.length ?? 0} complete`} />
      <ul className="divide-y">{items.data?.map((i) => (
        <li key={i.id}><label className="flex cursor-pointer items-center gap-3 px-5 py-2.5 text-sm hover:bg-muted/40">
          <input type="checkbox" checked={Boolean(i.done_at)} onChange={() => toggle.mutate(i)} className="size-4" />
          <span className={i.done_at ? 'text-muted-foreground line-through' : ''}>{i.title}</span>
          {i.done_at && <span className="ml-auto text-xs text-muted-foreground">{fmtDate(i.done_at)}</span>}
        </label></li>
      ))}</ul>
    </Card>
  )
}

const contactSchema = z.object({ name: z.string().trim().min(2), designation: z.string().optional(), email: z.string().email().optional().or(z.literal('')),
  phone: z.string().max(20).optional(), is_primary: z.boolean() })

function Contacts({ client, canEdit }: { client: Client; canEdit: boolean }) {
  const qc = useQueryClient()
  const [open, setOpen] = useState(false)
  const list = useList<ClientContact>('contacts', 'client_contacts', client.id, 'name')
  const form = useForm<z.infer<typeof contactSchema>>({ resolver: zodResolver(contactSchema), defaultValues: { is_primary: false } })
  const submit = form.handleSubmit(async (v) => {
    const { error } = await supabase.from('client_contacts').insert({ ...v, email: v.email || null, org_id: client.org_id, client_id: client.id })
    if (error) return toast.error(friendlyError(error))
    setOpen(false); form.reset(); qc.invalidateQueries({ queryKey: ['client_contacts', client.id] })
  })
  const del = useMutation({ mutationFn: async (id: string) => unwrap(await supabase.from('client_contacts').delete().eq('id', id)),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['client_contacts', client.id] }) })
  return (
    <Card><CardHeader title="Contacts" action={canEdit && <Button size="sm" onClick={() => setOpen(true)}><Plus />Add contact</Button>} />
      <DataTable rows={list.data} loading={list.isLoading} empty={<EmptyState title="No contacts yet" />} columns={[
        { key: 'n', header: 'Name', render: (c) => <span className="flex items-center gap-2">{c.name}{c.is_primary && <Badge tone="blue">Primary</Badge>}</span> },
        { key: 'd', header: 'Designation', render: (c) => c.designation ?? '—' },
        { key: 'e', header: 'Email', render: (c) => c.email ? <a className="text-primary" href={`mailto:${c.email}`}>{c.email}</a> : '—' },
        { key: 'p', header: 'Phone', render: (c) => c.phone ?? '—' },
        { key: 'x', header: '', render: (c) => canEdit && <Button size="icon" variant="ghost" aria-label={`Delete ${c.name}`} onClick={() => del.mutate(c.id)}><Trash2 /></Button> },
      ]} />
      <Dialog open={open} onClose={() => setOpen(false)} title="Add contact" footer={<Button onClick={submit} loading={form.formState.isSubmitting}>Save</Button>}>
        <form onSubmit={submit} className="grid gap-4 sm:grid-cols-2">
          <Field label="Name" error={form.formState.errors.name?.message}>{(p) => <Input {...p} {...form.register('name')} />}</Field>
          <Field label="Designation">{(p) => <Input {...p} {...form.register('designation')} />}</Field>
          <Field label="Email" error={form.formState.errors.email?.message}>{(p) => <Input type="email" {...p} {...form.register('email')} />}</Field>
          <Field label="Phone">{(p) => <Input {...p} {...form.register('phone')} />}</Field>
          <label className="flex items-center gap-2 text-sm"><input type="checkbox" {...form.register('is_primary')} />Primary contact</label>
        </form>
      </Dialog>
    </Card>
  )
}

function Services({ client, canEdit }: { client: Client; canEdit: boolean }) {
  const qc = useQueryClient()
  const list = useList<ClientService>('services', 'client_services', client.id, 'start_date')
  const [svc, setSvc] = useState('seo')
  const add = useMutation({
    mutationFn: async () => unwrap(await supabase.from('client_services').insert({ org_id: client.org_id, client_id: client.id, service: svc, start_date: new Date().toISOString().slice(0, 10) })),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['client_services', client.id] }),
  })
  const setStatus = useMutation({
    mutationFn: async ({ id, status }: { id: string; status: string }) => unwrap(await supabase.from('client_services').update({ status, end_date: status === 'ended' ? new Date().toISOString().slice(0, 10) : null }).eq('id', id)),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['client_services', client.id] }),
  })
  return (
    <Card><CardHeader title="Services purchased" action={canEdit && <div className="flex gap-2">
      <Select aria-label="Service" value={svc} onChange={(e) => setSvc(e.target.value)} className="w-48">{SERVICE_TYPES.map((s) => <option key={s} value={s}>{serviceLabel(s)}</option>)}</Select>
      <Button size="sm" onClick={() => add.mutate()} loading={add.isPending}><Plus />Add</Button></div>} />
      <DataTable rows={list.data} loading={list.isLoading} empty={<EmptyState title="No services recorded" />} columns={[
        { key: 's', header: 'Service', render: (s) => serviceLabel(s.service) },
        { key: 'f', header: 'Started', render: (s) => fmtDate(s.start_date) },
        { key: 'e', header: 'Ended', render: (s) => fmtDate(s.end_date) },
        { key: 'st', header: 'Status', render: (s) => canEdit
          ? <Select aria-label="Service status" value={s.status} onChange={(e) => setStatus.mutate({ id: s.id, status: e.target.value })} className="h-8 w-28">
            {['active', 'paused', 'ended'].map((x) => <option key={x}>{x}</option>)}</Select> : <StatusBadge value={s.status} /> },
      ]} />
    </Card>
  )
}

const contractSchema = z.object({
  title: z.string().trim().min(2), start_date: z.string().min(1, 'Required'), end_date: z.string().optional(),
  billing_cycle: z.enum(['one_time', 'monthly', 'quarterly', 'yearly']), management_fee: z.coerce.number().min(0),
  renewal_reminder_days: z.coerce.number().int().min(0).max(365), auto_renew: z.boolean(),
}).refine((v) => !v.end_date || v.end_date >= v.start_date, { path: ['end_date'], message: 'Must be after start' })

function Billing({ client }: { client: Client }) {
  const { org } = useAuth()
  const qc = useQueryClient()
  const [open, setOpen] = useState(false)
  const billing = useQuery({ queryKey: ['client_billing', client.id],
    queryFn: async () => unwrap(await supabase.from('client_billing').select('*').eq('client_id', client.id).maybeSingle()) as ClientBilling | null })
  const contracts = useList<Contract>('contracts', 'contracts', client.id, 'start_date')
  const bForm = useForm<Partial<ClientBilling>>()
  const saveBilling = bForm.handleSubmit(async (v) => {
    const { error } = await supabase.from('client_billing').upsert({ client_id: client.id, org_id: client.org_id, billing_name: v.billing_name || null,
      billing_email: v.billing_email || null, gst_number: v.gst_number ? v.gst_number.toUpperCase() : null, billing_address: v.billing_address || null,
      payment_terms_days: Number(v.payment_terms_days ?? 15), state_code: v.gst_number ? v.gst_number.slice(0, 2) : v.state_code || null })
    if (error) return toast.error(friendlyError(error))
    toast.success('Billing details saved'); qc.invalidateQueries({ queryKey: ['client_billing', client.id] })
  })
  const cForm = useForm<z.input<typeof contractSchema>, unknown, z.output<typeof contractSchema>>({ resolver: zodResolver(contractSchema),
    defaultValues: { billing_cycle: 'monthly', management_fee: 0, renewal_reminder_days: 30, auto_renew: false } })
  const addContract = cForm.handleSubmit(async (v) => {
    const { error } = await supabase.from('contracts').insert({ ...v, end_date: v.end_date || null, org_id: client.org_id, client_id: client.id })
    if (error) return toast.error(friendlyError(error))
    setOpen(false); cForm.reset(); qc.invalidateQueries({ queryKey: ['contracts', client.id] })
  })
  if (billing.isLoading) return <Spinner />
  return (
    <div className="space-y-4">
      <Card><CardHeader title="Billing details" description="Visible only to people with billing access." />
        <CardBody><form key={billing.data ? 'loaded' : 'empty'} onSubmit={saveBilling} className="grid gap-4 sm:grid-cols-2">
          <Field label="Billing name">{(p) => <Input {...p} defaultValue={billing.data?.billing_name ?? ''} {...bForm.register('billing_name')} />}</Field>
          <Field label="Billing email">{(p) => <Input type="email" {...p} defaultValue={billing.data?.billing_email ?? ''} {...bForm.register('billing_email')} />}</Field>
          <Field label="GSTIN" hint="15 characters">{(p) => <Input {...p} defaultValue={billing.data?.gst_number ?? ''} {...bForm.register('gst_number')} />}</Field>
          <Field label="State (place of supply)" hint="Taken from the GSTIN when there is one; decides CGST+SGST or IGST">{(p) => <Select {...p} defaultValue={billing.data?.state_code ?? ''} {...bForm.register('state_code')}>
            <option value="">—</option>{Object.entries(GST_STATES).map(([k, n]) => <option key={k} value={k}>{n} ({k})</option>)}</Select>}</Field>
          <Field label="Payment terms (days)">{(p) => <Input type="number" {...p} defaultValue={billing.data?.payment_terms_days ?? 15} {...bForm.register('payment_terms_days')} />}</Field>
          <Field label="Billing address" className="sm:col-span-2">{(p) => <Textarea {...p} defaultValue={billing.data?.billing_address ?? ''} {...bForm.register('billing_address')} />}</Field>
          <div className="sm:col-span-2"><Button type="submit" loading={bForm.formState.isSubmitting}>Save billing details</Button></div>
        </form></CardBody></Card>
      <Card><CardHeader title="Contracts" description="Agency management fees only — ad spend is tracked separately." action={<Button size="sm" onClick={() => setOpen(true)}><Plus />Add contract</Button>} />
        <DataTable rows={contracts.data} loading={contracts.isLoading} empty={<EmptyState title="No contracts" />} columns={[
          { key: 't', header: 'Contract', render: (c) => c.title },
          { key: 'p', header: 'Period', render: (c) => `${fmtDate(c.start_date)} – ${fmtDate(c.end_date)}` },
          { key: 'f', header: 'Fee', render: (c) => `${fmtMoney(c.management_fee, org?.currency)} / ${titleCase(c.billing_cycle)}` },
          { key: 'r', header: 'Reminder', render: (c) => `${c.renewal_reminder_days} days before${c.auto_renew ? ' · auto-renew' : ''}` },
          { key: 's', header: 'Status', render: (c) => <StatusBadge value={c.status} /> },
        ]} /></Card>
      <Dialog open={open} onClose={() => setOpen(false)} title="Add contract" footer={<Button onClick={addContract} loading={cForm.formState.isSubmitting}>Save</Button>}>
        <form onSubmit={addContract} className="grid gap-4 sm:grid-cols-2">
          <Field label="Title" className="sm:col-span-2" error={cForm.formState.errors.title?.message}>{(p) => <Input {...p} {...cForm.register('title')} />}</Field>
          <Field label="Start" error={cForm.formState.errors.start_date?.message}>{(p) => <Input type="date" {...p} {...cForm.register('start_date')} />}</Field>
          <Field label="End" error={cForm.formState.errors.end_date?.message}>{(p) => <Input type="date" {...p} {...cForm.register('end_date')} />}</Field>
          <Field label="Billing cycle">{(p) => <Select {...p} {...cForm.register('billing_cycle')}>{['one_time', 'monthly', 'quarterly', 'yearly'].map((x) => <option key={x} value={x}>{titleCase(x)}</option>)}</Select>}</Field>
          <Field label="Management fee">{(p) => <Input type="number" min={0} {...p} {...cForm.register('management_fee')} />}</Field>
          <Field label="Remind days before end">{(p) => <Input type="number" min={0} {...p} {...cForm.register('renewal_reminder_days')} />}</Field>
          <label className="flex items-center gap-2 self-end text-sm"><input type="checkbox" {...cForm.register('auto_renew')} />Auto-renews</label>
        </form>
      </Dialog>
    </div>
  )
}

function Notes({ client }: { client: Client }) {
  const { session } = useAuth()
  const { data: people } = usePeople()
  const qc = useQueryClient()
  const list = useList<ClientNote>('notes', 'client_notes', client.id)
  const [body, setBody] = useState('')
  const [channel, setChannel] = useState('note')
  const add = useMutation({
    mutationFn: async () => unwrap(await supabase.from('client_notes').insert({ org_id: client.org_id, client_id: client.id, author_id: session!.user.id, channel, body })),
    onSuccess: () => { setBody(''); qc.invalidateQueries({ queryKey: ['client_notes', client.id] }) },
  })
  return (
    <Card><CardHeader title="Communication log" description="Internal only — never shown to the client." />
      <CardBody className="space-y-3 border-b">
        <Textarea aria-label="Note" placeholder="What was discussed?" value={body} onChange={(e) => setBody(e.target.value)} />
        <div className="flex gap-2"><Select aria-label="Channel" className="w-36" value={channel} onChange={(e) => setChannel(e.target.value)}>
          {['note', 'call', 'meeting', 'email', 'whatsapp'].map((c) => <option key={c} value={c}>{titleCase(c)}</option>)}</Select>
          <Button disabled={!body.trim()} loading={add.isPending} onClick={() => add.mutate()}>Add</Button></div>
      </CardBody>
      {!list.data?.length ? <EmptyState title="No notes yet" /> : <ul className="divide-y">{list.data.map((n) => (
        <li key={n.id} className="px-5 py-3"><div className="flex items-center gap-2 text-xs text-muted-foreground"><Badge>{titleCase(n.channel)}</Badge>
          {nameOf(people, n.author_id)} · {fmtDate(n.created_at, 'dd MMM yyyy, hh:mm a')}</div>
          <p className="mt-1 whitespace-pre-line text-sm">{n.body}</p></li>))}</ul>}
    </Card>
  )
}

function Portal({ client }: { client: Client }) {
  const { org, session } = useAuth()
  const { data: roles } = useRoles()
  const [email, setEmail] = useState('')
  const users = useQuery({ queryKey: ['client-users', client.id],
    queryFn: async () => unwrap(await supabase.from('profiles').select('id, full_name, email, is_active').eq('client_id', client.id)) as { id: string; full_name: string; email: string; is_active: boolean }[] })
  const invite = useMutation({
    mutationFn: async () => createInvitation({ org_id: org!.id, email, client_id: client.id,
      role_id: roles!.find((r) => r.is_client_role)!.id, invited_by: session!.user.id }),
    onSuccess: (r) => { toast.success(inviteToast(email, r.emailed)); setEmail('') },
  })
  return (
    <Card><CardHeader title="Client portal access" description="Client users only see projects, milestones, tasks and comments you mark as client-visible." />
      <CardBody className="flex gap-2 border-b"><Input type="email" aria-label="Client email" placeholder="client@company.com" value={email} onChange={(e) => setEmail(e.target.value)} />
        <Button disabled={!/^\S+@\S+\.\S+$/.test(email)} loading={invite.isPending} onClick={() => invite.mutate()}><Mail />Invite</Button></CardBody>
      <DataTable rows={users.data} loading={users.isLoading} empty={<EmptyState title="No portal users yet" />} columns={[
        { key: 'n', header: 'Name', render: (u) => u.full_name || '—' }, { key: 'e', header: 'Email', render: (u) => u.email },
        { key: 's', header: 'Status', render: (u) => <StatusBadge value={u.is_active ? 'active' : 'paused'} /> }]} />
    </Card>
  )
}

export default function ClientDetailPage() {
  const { id } = useParams()
  const { can } = useAuth()
  const qc = useQueryClient()
  const [tab, setTab] = useState<Tab>('overview')
  const [editing, setEditing] = useState(false)
  const { data: people } = useEmployeesLite()
  const q = useQuery({ queryKey: ['client', id], queryFn: async () => unwrap(await supabase.from('clients').select('*').eq('id', id!).maybeSingle()) as Client | null })
  const projects = useQuery({ queryKey: ['projects', 'by-client', id], enabled: tab === 'projects',
    queryFn: async () => unwrap(await supabase.from('project_overview').select('*').eq('client_id', id!).order('created_at', { ascending: false })) as ProjectOverview[] })
  const form = useForm<ClientForm>({ resolver: zodResolver(clientSchema) })
  if (q.isLoading) return <Spinner />
  if (q.error) return <ErrorState message={friendlyError(q.error)} onRetry={q.refetch} />
  const c = q.data
  if (!c) return <EmptyState title="Client not found" description="It may not exist or you may not have access." />
  const canEdit = can('clients.edit')
  const save = form.handleSubmit(async (v) => {
    const { error } = await supabase.from('clients').update(toClientRow(v)).eq('id', c.id)
    if (error) return toast.error(friendlyError(error))
    toast.success('Saved'); setEditing(false); qc.invalidateQueries({ queryKey: ['client', id] }); qc.invalidateQueries({ queryKey: ['clients'] })
  })
  const tabs: { value: Tab; label: string }[] = [{ value: 'overview', label: 'Overview' }, { value: 'contacts', label: 'Contacts' }, { value: 'services', label: 'Services' }]
  if (can('clients.view_billing')) tabs.push({ value: 'billing', label: 'Billing & contracts' })
  tabs.push({ value: 'projects', label: 'Projects' }, { value: 'notes', label: 'Notes' })
  if (can('users.manage')) tabs.push({ value: 'portal', label: 'Portal access' })

  return (
    <div className="space-y-6">
      <Link to="/clients" className="inline-flex items-center gap-1 text-sm text-muted-foreground hover:text-foreground"><ArrowLeft className="size-4" />Clients</Link>
      <PageHeader title={c.name} description={[c.industry, c.city].filter(Boolean).join(' · ') || undefined}
        actions={<><StatusBadge value={c.status} />{canEdit && tab === 'overview' && !editing &&
          <Button variant="outline" onClick={() => { form.reset(Object.fromEntries(Object.entries(c).map(([k, v]) => [k, v ?? ''])) as ClientForm); setEditing(true) }}>Edit</Button>}</>} />
      <Tabs tabs={tabs} value={tab} onChange={setTab} />
      {tab === 'overview' && (editing ? (
        <Card><CardBody><form onSubmit={save} className="space-y-4"><ClientFormFields form={form} />
          <div className="flex justify-end gap-2"><Button type="button" variant="outline" onClick={() => setEditing(false)}>Cancel</Button><Button type="submit" loading={form.formState.isSubmitting}><Check />Save</Button></div>
        </form></CardBody></Card>
      ) : (
        <div className="grid gap-4 lg:grid-cols-3">
          <Card className="lg:col-span-2"><CardBody className="space-y-6">
            <DescriptionList items={[
              { label: 'Legal name', value: c.legal_name }, { label: 'Website', value: c.website && <a className="text-primary" href={c.website} target="_blank" rel="noreferrer noopener">{c.website}</a> },
              { label: 'Account manager', value: nameOf(people, c.account_manager_id) }, { label: 'Client since', value: fmtDate(c.created_at) },
            ]} />
            <div><p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">Brand guidelines</p>
              <p className="mt-1 whitespace-pre-line text-sm">{c.brand_guidelines || '—'}</p></div>
          </CardBody></Card>
          <Onboarding client={c} />
        </div>
      ))}
      {tab === 'contacts' && <Contacts client={c} canEdit={canEdit} />}
      {tab === 'services' && <Services client={c} canEdit={canEdit} />}
      {tab === 'billing' && <Billing client={c} />}
      {tab === 'notes' && <Notes client={c} />}
      {tab === 'portal' && <Portal client={c} />}
      {tab === 'projects' && <Card><DataTable rows={projects.data} loading={projects.isLoading} empty={<EmptyState title="No projects for this client" />} columns={[
        { key: 'n', header: 'Project', render: (p) => <Link className="font-medium text-primary" to={`/projects/${p.id}`}>{p.name}</Link> },
        { key: 's', header: 'Service', render: (p) => serviceLabel(p.service) },
        { key: 'd', header: 'Due', render: (p) => fmtDate(p.due_date) },
        { key: 'p', header: 'Progress', render: (p) => `${p.progress_pct}%` },
        { key: 'st', header: 'Status', render: (p) => <StatusBadge value={p.status} /> }]} /></Card>}
    </div>
  )
}
