import { useState } from 'react'
import { Link, useParams } from 'react-router-dom'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { z } from 'zod'
import { toast } from 'sonner'
import { ArrowLeft, Mail, Plus } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { createInvitation, inviteToast, unwrap } from '@/lib/query'
import { friendlyError } from '@/lib/errors'
import { fmtDate, fmtMoney, titleCase } from '@/lib/utils'
import { nameOf, useDepartments, useEmployeesLite, useRoles } from '@/lib/lookups'
import type { Employee, EmployeePrivate, SalaryRevision } from '@/lib/types'
import { useAuth } from '@/features/auth/AuthProvider'
import { Avatar, Badge, Button, Card, CardBody, CardHeader, DescriptionList, Dialog, EmptyState, ErrorState, Field, Input, PageHeader,
  Select, Spinner, StatusBadge, Tabs, Textarea } from '@/components/ui'
import { DataTable } from '@/components/DataTable'
import { EmployeeDocuments } from './EmployeeDocuments'
import { EmployeeFormFields, employeeSchema, toEmployeeRow, type EmployeeForm } from './EmployeesPage'

type Tab = 'overview' | 'private' | 'documents' | 'salary' | 'account'

function EditEmployee({ emp, onDone }: { emp: Employee; onDone: () => void }) {
  const qc = useQueryClient()
  const form = useForm<EmployeeForm>({
    resolver: zodResolver(employeeSchema),
    defaultValues: {
      ...emp, work_phone: emp.work_phone ?? '', designation: emp.designation ?? '', department_id: emp.department_id ?? '',
      reporting_manager_id: emp.reporting_manager_id ?? '', probation_end_date: emp.probation_end_date ?? '', exit_date: emp.exit_date ?? '', exit_reason: emp.exit_reason ?? '',
    },
  })
  const submit = form.handleSubmit(async (v) => {
    const { error } = await supabase.from('employee_profiles').update(toEmployeeRow(v)).eq('id', emp.id)
    if (error) return toast.error(friendlyError(error))
    toast.success('Saved'); qc.invalidateQueries({ queryKey: ['employee', emp.id] }); qc.invalidateQueries({ queryKey: ['employees'] }); onDone()
  })
  return (
    <form onSubmit={submit} className="space-y-4">
      <EmployeeFormFields form={form} excludeId={emp.id} />
      <div className="flex justify-end gap-2"><Button type="button" variant="outline" onClick={onDone}>Cancel</Button><Button type="submit" loading={form.formState.isSubmitting}>Save</Button></div>
    </form>
  )
}

const privateSchema = z.object({
  personal_email: z.string().email().optional().or(z.literal('')), personal_phone: z.string().max(20).optional(), date_of_birth: z.string().optional(),
  address: z.string().max(500).optional(), emergency_contact_name: z.string().max(120).optional(), emergency_contact_relation: z.string().max(40).optional(),
  emergency_contact_phone: z.string().max(20).optional(),
})

function PrivateDetails({ emp, editable }: { emp: Employee; editable: boolean }) {
  const qc = useQueryClient()
  const [editing, setEditing] = useState(false)
  const q = useQuery({
    queryKey: ['employee_private', emp.id],
    queryFn: async () => unwrap(await supabase.from('employee_private').select('*').eq('employee_id', emp.id).maybeSingle()) as EmployeePrivate | null,
  })
  const form = useForm<z.infer<typeof privateSchema>>({ resolver: zodResolver(privateSchema) })
  const submit = form.handleSubmit(async (v) => {
    const clean = Object.fromEntries(Object.entries(v).map(([k, x]) => [k, x ? x : null]))
    const { error } = await supabase.from('employee_private').upsert({ employee_id: emp.id, org_id: emp.org_id, ...clean })
    if (error) return toast.error(friendlyError(error))
    toast.success('Saved'); setEditing(false); qc.invalidateQueries({ queryKey: ['employee_private', emp.id] })
  })
  if (q.isLoading) return <Spinner />
  if (q.error) return <ErrorState message={friendlyError(q.error)} />
  const d = q.data
  return (
    <Card>
      <CardHeader title="Private details" description="Visible only to this employee and authorised HR staff."
        action={editable && !editing && <Button size="sm" variant="outline" onClick={() => { form.reset(Object.fromEntries(Object.entries(d ?? {}).map(([k, v]) => [k, v ?? '']))); setEditing(true) }}>Edit</Button>} />
      <CardBody>
        {editing ? (
          <form onSubmit={submit} className="grid gap-4 sm:grid-cols-2">
            {(['personal_email', 'personal_phone', 'date_of_birth', 'emergency_contact_name', 'emergency_contact_relation', 'emergency_contact_phone'] as const).map((k) => (
              <Field key={k} label={titleCase(k)} error={form.formState.errors[k]?.message}>{(p) => <Input type={k === 'date_of_birth' ? 'date' : 'text'} {...p} {...form.register(k)} />}</Field>
            ))}
            <Field label="Address" className="sm:col-span-2">{(p) => <Textarea {...p} {...form.register('address')} />}</Field>
            <div className="flex justify-end gap-2 sm:col-span-2"><Button type="button" variant="outline" onClick={() => setEditing(false)}>Cancel</Button><Button type="submit" loading={form.formState.isSubmitting}>Save</Button></div>
          </form>
        ) : !d ? <EmptyState title="No private details recorded" /> : (
          <DescriptionList items={[
            { label: 'Personal email', value: d.personal_email }, { label: 'Personal phone', value: d.personal_phone },
            { label: 'Date of birth', value: fmtDate(d.date_of_birth) }, { label: 'Address', value: d.address },
            { label: 'Emergency contact', value: d.emergency_contact_name && `${d.emergency_contact_name}${d.emergency_contact_relation ? ` (${d.emergency_contact_relation})` : ''}` },
            { label: 'Emergency phone', value: d.emergency_contact_phone },
          ]} />
        )}
      </CardBody>
    </Card>
  )
}

const revisionSchema = z.object({
  effective_from: z.string().min(1, 'Required'),
  annual_ctc: z.coerce.number().min(0, 'Must be positive'),
  basic: z.coerce.number().min(0), hra: z.coerce.number().min(0), special: z.coerce.number().min(0),
  reason: z.string().max(300).optional(),
})

function Salary({ emp, canEdit }: { emp: Employee; canEdit: boolean }) {
  const { org, session } = useAuth()
  const qc = useQueryClient()
  const [open, setOpen] = useState(false)
  const q = useQuery({
    queryKey: ['salary', emp.id],
    queryFn: async () => unwrap(await supabase.from('salary_revisions').select('*').eq('employee_id', emp.id).order('effective_from', { ascending: false })) as SalaryRevision[],
  })
  const form = useForm<z.input<typeof revisionSchema>, unknown, z.output<typeof revisionSchema>>({ resolver: zodResolver(revisionSchema), defaultValues: { basic: 0, hra: 0, special: 0 } })
  const submit = form.handleSubmit(async (v) => {
    const { error } = await supabase.from('salary_revisions').insert({
      org_id: emp.org_id, employee_id: emp.id, effective_from: v.effective_from, annual_ctc: v.annual_ctc,
      monthly_components: { BASIC: v.basic, HRA: v.hra, SPECIAL: v.special }, reason: v.reason || null, created_by: session!.user.id,
    })
    if (error) return toast.error(friendlyError(error))
    toast.success('Salary revision recorded'); setOpen(false); form.reset(); qc.invalidateQueries({ queryKey: ['salary', emp.id] })
  })
  const today = new Date().toISOString().slice(0, 10)
  const current = q.data?.find((r) => r.effective_from <= today)
  return (
    <Card>
      <CardHeader title="Salary" description="Revisions are append-only; corrections are made with a new revision."
        action={canEdit && <Button size="sm" onClick={() => setOpen(true)}><Plus />New revision</Button>} />
      {current && <CardBody className="border-b"><p className="text-sm text-muted-foreground">Current annual CTC</p>
        <p className="text-2xl font-semibold">{fmtMoney(current.annual_ctc, org?.currency)}</p></CardBody>}
      <DataTable rows={q.data} loading={q.isLoading} error={q.error ? friendlyError(q.error) : null} empty={<EmptyState title="No salary recorded" />} columns={[
        { key: 'e', header: 'Effective from', render: (r) => <span className="flex items-center gap-2">{fmtDate(r.effective_from)}{r.id === current?.id && <Badge tone="green">Current</Badge>}</span> },
        { key: 'c', header: 'Annual CTC', render: (r) => fmtMoney(r.annual_ctc, org?.currency) },
        { key: 'm', header: 'Monthly components', render: (r) => Object.entries(r.monthly_components).map(([k, v]) => `${k}: ${fmtMoney(v, org?.currency)}`).join(' · ') || '—' },
        { key: 'r', header: 'Reason', render: (r) => r.reason ?? '—' },
      ]} />
      <Dialog open={open} onClose={() => setOpen(false)} title="New salary revision"
        footer={<><Button variant="outline" onClick={() => setOpen(false)}>Cancel</Button><Button onClick={submit} loading={form.formState.isSubmitting}>Save</Button></>}>
        <form onSubmit={submit} className="grid gap-4 sm:grid-cols-2">
          <Field label="Effective from" error={form.formState.errors.effective_from?.message}>{(p) => <Input type="date" {...p} {...form.register('effective_from')} />}</Field>
          <Field label="Annual CTC" error={form.formState.errors.annual_ctc?.message}>{(p) => <Input type="number" min={0} {...p} {...form.register('annual_ctc')} />}</Field>
          <Field label="Monthly basic">{(p) => <Input type="number" min={0} {...p} {...form.register('basic')} />}</Field>
          <Field label="Monthly HRA">{(p) => <Input type="number" min={0} {...p} {...form.register('hra')} />}</Field>
          <Field label="Monthly special allowance">{(p) => <Input type="number" min={0} {...p} {...form.register('special')} />}</Field>
          <Field label="Reason">{(p) => <Input {...p} {...form.register('reason')} />}</Field>
        </form>
      </Dialog>
    </Card>
  )
}

function Account({ emp }: { emp: Employee }) {
  const { org, session, can } = useAuth()
  const { data: roles } = useRoles()
  const qc = useQueryClient()
  const [roleId, setRoleId] = useState('')
  const userRoles = useQuery({
    queryKey: ['user_roles', emp.profile_id], enabled: Boolean(emp.profile_id),
    queryFn: async () => unwrap(await supabase.from('user_roles').select('role_id').eq('user_id', emp.profile_id!)) as { role_id: string }[],
  })
  const profile = useQuery({
    queryKey: ['profile', emp.profile_id], enabled: Boolean(emp.profile_id),
    queryFn: async () => unwrap(await supabase.from('profiles').select('id, is_active, email').eq('id', emp.profile_id!).single()) as { id: string; is_active: boolean; email: string },
  })
  const invite = useMutation({
    mutationFn: async () => createInvitation({ org_id: org!.id, email: emp.work_email, role_id: roleId, employee_id: emp.id, invited_by: session!.user.id }),
    onSuccess: (r) => toast.success(inviteToast(emp.work_email, r.emailed)),
  })
  const addRole = useMutation({
    mutationFn: async () => unwrap(await supabase.from('user_roles').insert({ user_id: emp.profile_id, role_id: roleId, org_id: org!.id, assigned_by: session!.user.id })),
    onSuccess: () => { toast.success('Role added'); qc.invalidateQueries({ queryKey: ['user_roles', emp.profile_id] }) },
  })
  const removeRole = useMutation({
    mutationFn: async (rid: string) => unwrap(await supabase.from('user_roles').delete().eq('user_id', emp.profile_id!).eq('role_id', rid)),
    onSuccess: () => { toast.success('Role removed'); qc.invalidateQueries({ queryKey: ['user_roles', emp.profile_id] }) },
  })
  const toggleActive = useMutation({
    mutationFn: async () => unwrap(await supabase.from('profiles').update({ is_active: !profile.data!.is_active }).eq('id', emp.profile_id!)),
    onSuccess: () => { toast.success('Account updated'); qc.invalidateQueries({ queryKey: ['profile', emp.profile_id] }) },
  })
  const staffRoles = roles?.filter((r) => !r.is_client_role) ?? []

  if (!emp.profile_id) return (
    <Card><CardHeader title="Sign-in access" description="This employee doesn't have an account yet." />
      <CardBody className="flex flex-col gap-3 sm:flex-row sm:items-end">
        <Field label="Role" className="sm:w-64">{(p) => <Select {...p} value={roleId} onChange={(e) => setRoleId(e.target.value)}><option value="">Select role…</option>
          {staffRoles.map((r) => <option key={r.id} value={r.id}>{r.name}</option>)}</Select>}</Field>
        <Button disabled={!roleId || !can('users.manage')} loading={invite.isPending} onClick={() => invite.mutate()}><Mail />Invite {emp.work_email}</Button>
      </CardBody></Card>
  )
  return (
    <Card><CardHeader title="Account & roles" description={profile.data?.email}
      action={can('users.manage') && emp.profile_id !== session?.user.id && profile.data &&
        <Button size="sm" variant={profile.data.is_active ? 'destructive' : 'outline'} onClick={() => toggleActive.mutate()}>{profile.data.is_active ? 'Deactivate' : 'Reactivate'}</Button>} />
      <CardBody className="space-y-4">
        <div className="flex flex-wrap gap-2">{userRoles.data?.map((ur) => (
          <Badge key={ur.role_id} tone="blue" className="gap-1">{nameOf(roles, ur.role_id)}
            {can('users.manage') && <button aria-label={`Remove ${nameOf(roles, ur.role_id)}`} className="ml-1 hover:text-destructive" onClick={() => removeRole.mutate(ur.role_id)}>×</button>}</Badge>
        ))}</div>
        {can('users.manage') && <div className="flex gap-2"><Select aria-label="Role to add" className="sm:w-64" value={roleId} onChange={(e) => setRoleId(e.target.value)}>
          <option value="">Add role…</option>{staffRoles.filter((r) => !userRoles.data?.some((u) => u.role_id === r.id)).map((r) => <option key={r.id} value={r.id}>{r.name}</option>)}</Select>
          <Button variant="outline" disabled={!roleId} onClick={() => addRole.mutate()}>Add</Button></div>}
      </CardBody></Card>
  )
}

export default function EmployeeDetailPage() {
  const { id } = useParams()
  const { can, employee: me } = useAuth()
  const [tab, setTab] = useState<Tab>('overview')
  const [editing, setEditing] = useState(false)
  const { data: depts } = useDepartments()
  const { data: people } = useEmployeesLite()
  const q = useQuery({
    queryKey: ['employee', id],
    queryFn: async () => unwrap(await supabase.from('employee_profiles').select('*').eq('id', id!).maybeSingle()) as Employee | null,
  })
  if (q.isLoading) return <Spinner />
  if (q.error) return <ErrorState message={friendlyError(q.error)} onRetry={q.refetch} />
  const emp = q.data
  if (!emp) return <EmptyState title="Employee not found" description="It may not exist or you may not have access." />
  const isMe = me?.id === emp.id
  const tabs: { value: Tab; label: string }[] = [{ value: 'overview', label: 'Overview' }]
  if (isMe || can('employees.view_sensitive')) tabs.push({ value: 'private', label: 'Private details' }, { value: 'documents', label: 'Documents' })
  if (isMe || can('salary.view')) tabs.push({ value: 'salary', label: 'Salary' })
  if (can('users.manage')) tabs.push({ value: 'account', label: 'Account' })

  return (
    <div className="space-y-6">
      <Link to="/employees" className="inline-flex items-center gap-1 text-sm text-muted-foreground hover:text-foreground"><ArrowLeft className="size-4" />Employees</Link>
      <PageHeader title={emp.full_name} description={`${emp.employee_code} · ${emp.designation ?? 'No designation'}`}
        actions={can('employees.edit') && tab === 'overview' && !editing && <Button variant="outline" onClick={() => setEditing(true)}>Edit</Button>} />
      <Tabs tabs={tabs} value={tab} onChange={setTab} />
      {tab === 'overview' && (editing ? <Card><CardBody><EditEmployee emp={emp} onDone={() => setEditing(false)} /></CardBody></Card> : (
        <Card><CardBody className="flex flex-col gap-6 sm:flex-row">
          <Avatar name={emp.full_name} className="size-16 text-lg" />
          <DescriptionList items={[
            { label: 'Status', value: <StatusBadge value={emp.status} /> }, { label: 'Employment type', value: titleCase(emp.employment_type) },
            { label: 'Work email', value: emp.work_email }, { label: 'Work phone', value: emp.work_phone },
            { label: 'Department', value: nameOf(depts, emp.department_id) },
            { label: 'Reporting manager', value: emp.reporting_manager_id ? <Link className="text-primary" to={`/employees/${emp.reporting_manager_id}`}>{nameOf(people, emp.reporting_manager_id)}</Link> : '—' },
            { label: 'Joined', value: fmtDate(emp.joining_date) }, { label: 'Probation ends', value: fmtDate(emp.probation_end_date) },
            ...(emp.exit_date ? [{ label: 'Exit date', value: fmtDate(emp.exit_date) }, { label: 'Exit reason', value: emp.exit_reason }] : []),
          ]} />
        </CardBody></Card>
      ))}
      {tab === 'private' && <PrivateDetails emp={emp} editable={isMe || (can('employees.view_sensitive') && can('employees.edit'))} />}
      {tab === 'documents' && <EmployeeDocuments emp={emp} canManage={can('employees.view_sensitive') && can('employees.edit')} />}
      {tab === 'salary' && <Salary emp={emp} canEdit={can('salary.edit')} />}
      {tab === 'account' && <Account emp={emp} />}
    </div>
  )
}
