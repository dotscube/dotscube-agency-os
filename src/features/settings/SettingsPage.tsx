import { useMemo, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { toast } from 'sonner'
import { Plus, Trash2 } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { createInvitation, inviteToast, unwrap } from '@/lib/query'
import { fmtDate, titleCase } from '@/lib/utils'
import { nameOf, useDepartments, useLeaveTypes, usePeople, useRoles, useTaskStatuses } from '@/lib/lookups'
import type { Permission } from '@/lib/permissions'
import type { Holiday, StatusCategory } from '@/lib/types'
import { useAuth } from '@/features/auth/AuthProvider'
import { DataTable } from '@/components/DataTable'
import { NOTIFICATION_TYPES } from '@/features/notifications/NotificationsPage'
import { Badge, Button, Card, CardBody, CardHeader, EmptyState, Field, Input, PageHeader, Select, Tabs, Textarea } from '@/components/ui'

type Tab = 'org' | 'roles' | 'invites' | 'departments' | 'holidays' | 'leave' | 'schedule' | 'statuses' | 'announcements' | 'notifications' | 'audit'

function OrgSettings() {
  const { org, refresh, can } = useAuth()
  const [name, setName] = useState(org?.name ?? ''); const [tz, setTz] = useState(org?.timezone ?? 'Asia/Kolkata'); const [prefix, setPrefix] = useState(org?.employee_code_prefix ?? 'EMP')
  const save = useMutation({ mutationFn: async () => unwrap(await supabase.from('organizations').update({ name, timezone: tz, employee_code_prefix: prefix.toUpperCase() }).eq('id', org!.id)),
    onSuccess: () => { toast.success('Saved'); refresh() } })
  const disabled = !can('org.manage')
  return (
    <Card><CardHeader title="Organization" /><CardBody className="grid max-w-2xl gap-4 sm:grid-cols-2">
      <Field label="Agency name">{(p) => <Input {...p} value={name} disabled={disabled} onChange={(e) => setName(e.target.value)} />}</Field>
      <Field label="Timezone" hint="IANA name, e.g. Asia/Kolkata">{(p) => <Input {...p} value={tz} disabled={disabled} onChange={(e) => setTz(e.target.value)} />}</Field>
      <Field label="Employee ID prefix" hint="Applies to new employees">{(p) => <Input {...p} value={prefix} maxLength={8} disabled={disabled} onChange={(e) => setPrefix(e.target.value)} />}</Field>
      <div className="sm:col-span-2"><Button disabled={disabled} loading={save.isPending} onClick={() => save.mutate()}>Save</Button></div>
    </CardBody></Card>
  )
}

function RolesMatrix() {
  const { can, org } = useAuth()
  const qc = useQueryClient()
  const { data: roles } = useRoles()
  const perms = useQuery({ queryKey: ['permissions'], queryFn: async () => unwrap(await supabase.from('permissions').select('*').order('module').order('key')) as { key: Permission; module: string; description: string }[] })
  const rp = useQuery({ queryKey: ['role_permissions'], queryFn: async () => unwrap(await supabase.from('role_permissions').select('role_id, permission_key')) as { role_id: string; permission_key: string }[] })
  const has = useMemo(() => new Set(rp.data?.map((x) => `${x.role_id}|${x.permission_key}`)), [rp.data])
  const toggle = useMutation({
    mutationFn: async ({ role, perm, on }: { role: string; perm: string; on: boolean }) => on
      ? unwrap(await supabase.from('role_permissions').insert({ role_id: role, permission_key: perm, org_id: org!.id }))
      : unwrap(await supabase.from('role_permissions').delete().eq('role_id', role).eq('permission_key', perm)),
    onSettled: () => qc.invalidateQueries({ queryKey: ['role_permissions'] }),
  })
  const [newRole, setNewRole] = useState('')
  const addRole = useMutation({ mutationFn: async () => unwrap(await supabase.from('roles').insert({ org_id: org!.id, name: newRole.trim(), key: newRole.trim().toLowerCase().replace(/[^a-z0-9]+/g, '_').slice(0, 40) })),
    onSuccess: () => { setNewRole(''); qc.invalidateQueries({ queryKey: ['roles'] }) } })
  const editable = can('roles.manage')
  const staffRoles = roles?.filter((r) => !r.is_client_role) ?? []
  return (
    <Card><CardHeader title="Roles & permissions" description="Changes apply immediately and are enforced by the database. Super Admin is fixed; client users never receive internal permissions."
      action={editable && <div className="flex gap-2"><Input aria-label="New role name" placeholder="New role name" value={newRole} onChange={(e) => setNewRole(e.target.value)} className="w-48" />
        <Button size="sm" disabled={newRole.trim().length < 2} onClick={() => addRole.mutate()}><Plus />Add role</Button></div>} />
      <div className="max-h-[70vh] overflow-auto">
        <table className="text-xs">
          <thead className="sticky top-0 z-10 bg-card"><tr className="border-b"><th scope="col" className="sticky left-0 bg-card px-3 py-2 text-left font-medium">Permission</th>
            {staffRoles.map((r) => <th key={r.id} scope="col" className="min-w-20 px-2 py-2 text-center font-medium"><span className="block max-w-24 whitespace-normal">{r.name}</span></th>)}</tr></thead>
          <tbody>{perms.data?.map((p) => (
            <tr key={p.key} className="border-b hover:bg-muted/30">
              <th scope="row" className="sticky left-0 bg-card px-3 py-1.5 text-left font-normal"><span className="font-mono">{p.key}</span><span className="block text-muted-foreground">{p.description}</span></th>
              {staffRoles.map((r) => { const on = has.has(`${r.id}|${p.key}`); return (
                <td key={r.id} className="text-center"><input type="checkbox" aria-label={`${r.name}: ${p.key}`} checked={on} disabled={!editable || r.key === 'super_admin' || toggle.isPending}
                  onChange={() => toggle.mutate({ role: r.id, perm: p.key, on: !on })} /></td>) })}
            </tr>))}</tbody>
        </table>
      </div>
    </Card>
  )
}

function Invitations() {
  const { org, session } = useAuth()
  const qc = useQueryClient()
  const { data: roles } = useRoles()
  const [email, setEmail] = useState(''); const [role, setRole] = useState('')
  const list = useQuery({ queryKey: ['invitations'], queryFn: async () => unwrap(await supabase.from('invitations').select('*').order('created_at', { ascending: false }).limit(100)) as
    { id: string; email: string; role_id: string; accepted_at: string | null; expires_at: string; client_id: string | null }[] })
  const create = useMutation({ mutationFn: async () => createInvitation({ org_id: org!.id, email, role_id: role, invited_by: session!.user.id }),
    onSuccess: (r) => { toast.success(inviteToast(email, r.emailed)); setEmail(''); qc.invalidateQueries({ queryKey: ['invitations'] }) } })
  const revoke = useMutation({ mutationFn: async (id: string) => unwrap(await supabase.from('invitations').delete().eq('id', id)), onSuccess: () => qc.invalidateQueries({ queryKey: ['invitations'] }) })
  return (
    <Card><CardHeader title="Invitations" description="Invite staff here (or from an employee's Account tab to link their record). Invite clients from the client's Portal tab." />
      <CardBody className="flex flex-col gap-2 border-b sm:flex-row">
        <Input type="email" aria-label="Email" placeholder="name@dotscube.com" value={email} onChange={(e) => setEmail(e.target.value)} />
        <Select aria-label="Role" className="sm:w-56" value={role} onChange={(e) => setRole(e.target.value)}><option value="">Role…</option>
          {roles?.filter((r) => !r.is_client_role).map((r) => <option key={r.id} value={r.id}>{r.name}</option>)}</Select>
        <Button disabled={!/^\S+@\S+\.\S+$/.test(email) || !role} loading={create.isPending} onClick={() => create.mutate()}>Invite</Button></CardBody>
      <DataTable rows={list.data} loading={list.isLoading} empty={<EmptyState title="No invitations" />} columns={[
        { key: 'e', header: 'Email', render: (i) => i.email }, { key: 'r', header: 'Role', render: (i) => nameOf(roles, i.role_id) },
        { key: 's', header: 'Status', render: (i) => i.accepted_at ? <Badge tone="green">Joined {fmtDate(i.accepted_at)}</Badge> : new Date(i.expires_at) < new Date() ? <Badge tone="red">Expired</Badge> : <Badge tone="amber">Pending</Badge> },
        { key: 'x', header: '', render: (i) => !i.accepted_at && <Button size="icon" variant="ghost" aria-label="Revoke invitation" onClick={() => revoke.mutate(i.id)}><Trash2 /></Button> },
      ]} />
    </Card>
  )
}

function SimpleList<T extends { id: string }>({ title, description, rows, columns, onAdd, addForm }: {
  title: string; description?: string; rows?: T[]; columns: Parameters<typeof DataTable<T>>[0]['columns']; onAdd?: () => void; addForm?: React.ReactNode
}) {
  return <Card><CardHeader title={title} description={description} />{addForm && <CardBody className="flex flex-col gap-2 border-b sm:flex-row">{addForm}{onAdd && null}</CardBody>}
    <DataTable rows={rows} columns={columns} empty={<EmptyState title="Nothing configured" />} /></Card>
}

function Departments() {
  const { org, can } = useAuth()
  const qc = useQueryClient()
  const { data } = useDepartments()
  const { data: people } = usePeople()
  const [name, setName] = useState('')
  const add = useMutation({ mutationFn: async () => unwrap(await supabase.from('departments').insert({ org_id: org!.id, name: name.trim() })), onSuccess: () => { setName(''); qc.invalidateQueries({ queryKey: ['departments'] }) } })
  const del = useMutation({ mutationFn: async (id: string) => unwrap(await supabase.from('departments').delete().eq('id', id)), onSuccess: () => qc.invalidateQueries({ queryKey: ['departments'] }) })
  return <SimpleList title="Departments" rows={data as { id: string; name: string; head_profile_id?: string }[]}
    addForm={can('departments.manage') && <><Input aria-label="Department name" placeholder="Department name" value={name} onChange={(e) => setName(e.target.value)} />
      <Button disabled={name.trim().length < 2} onClick={() => add.mutate()}><Plus />Add</Button></>}
    columns={[{ key: 'n', header: 'Department', render: (d) => d.name }, { key: 'h', header: 'Head', render: (d) => nameOf(people, d.head_profile_id) },
      { key: 'x', header: '', render: (d) => can('departments.manage') && <Button size="icon" variant="ghost" aria-label={`Delete ${d.name}`} onClick={() => del.mutate(d.id)}><Trash2 /></Button> }]} />
}

function Holidays() {
  const { org, can } = useAuth()
  const qc = useQueryClient()
  const year = new Date().getFullYear()
  const list = useQuery({ queryKey: ['holidays'], queryFn: async () => unwrap(await supabase.from('holidays').select('*').gte('holiday_date', `${year}-01-01`).order('holiday_date')) as Holiday[] })
  const [date, setDate] = useState(''); const [name, setName] = useState(''); const [optional, setOptional] = useState(false)
  const add = useMutation({ mutationFn: async () => unwrap(await supabase.from('holidays').insert({ org_id: org!.id, holiday_date: date, name, is_optional: optional })),
    onSuccess: () => { setDate(''); setName(''); qc.invalidateQueries({ queryKey: ['holidays'] }) } })
  const del = useMutation({ mutationFn: async (id: string) => unwrap(await supabase.from('holidays').delete().eq('id', id)), onSuccess: () => qc.invalidateQueries({ queryKey: ['holidays'] }) })
  return <SimpleList title="Holiday calendar" description="Non-optional holidays are excluded from leave day counts." rows={list.data}
    addForm={can('holidays.manage') && <><Input type="date" aria-label="Date" className="sm:w-44" value={date} onChange={(e) => setDate(e.target.value)} />
      <Input aria-label="Holiday name" placeholder="e.g. Diwali" value={name} onChange={(e) => setName(e.target.value)} />
      <label className="flex items-center gap-2 whitespace-nowrap text-sm"><input type="checkbox" checked={optional} onChange={(e) => setOptional(e.target.checked)} />Optional</label>
      <Button disabled={!date || name.trim().length < 2} onClick={() => add.mutate()}><Plus />Add</Button></>}
    columns={[{ key: 'd', header: 'Date', render: (h) => fmtDate(h.holiday_date, 'EEE, dd MMM yyyy') }, { key: 'n', header: 'Holiday', render: (h) => h.name },
      { key: 'o', header: 'Type', render: (h) => h.is_optional ? <Badge>Optional</Badge> : <Badge tone="blue">Office closed</Badge> },
      { key: 'x', header: '', render: (h) => can('holidays.manage') && <Button size="icon" variant="ghost" aria-label={`Delete ${h.name}`} onClick={() => del.mutate(h.id)}><Trash2 /></Button> }]} />
}

function LeaveTypes() {
  const { can } = useAuth()
  const qc = useQueryClient()
  const { data } = useLeaveTypes()
  const editable = can('leave.manage_policy')
  const save = useMutation({ mutationFn: async ({ id, patch }: { id: string; patch: Record<string, unknown> }) => unwrap(await supabase.from('leave_types').update(patch).eq('id', id)),
    onSuccess: () => { toast.success('Saved'); qc.invalidateQueries({ queryKey: ['leave_types'] }) } })
  const allocate = useMutation({ mutationFn: async () => unwrap(await supabase.rpc('allocate_leave_balances', { p_year: new Date().getFullYear() })) as number,
    onSuccess: (n) => toast.success(`${n} new balance record(s) created`) })
  return (
    <Card><CardHeader title="Leave policy" description="Quota blank = no balance limit (e.g. unpaid leave)."
      action={editable && <Button size="sm" variant="outline" loading={allocate.isPending} onClick={() => allocate.mutate()}>Allocate {new Date().getFullYear()} balances</Button>} />
      <DataTable rows={data} columns={[
        { key: 'n', header: 'Type', render: (t) => <span className="flex items-center gap-2"><span className="size-2 rounded-full" style={{ background: t.color }} />{t.name} <span className="text-muted-foreground">({t.code})</span></span> },
        { key: 'q', header: 'Annual quota', render: (t) => editable ? <Input type="number" min={0} step={0.5} aria-label={`${t.name} quota`} className="h-8 w-20" defaultValue={t.annual_quota ?? ''}
          onBlur={(e) => { const v = e.target.value === '' ? null : Number(e.target.value); if (v !== t.annual_quota) save.mutate({ id: t.id, patch: { annual_quota: v } }) }} /> : t.annual_quota ?? '∞' },
        { key: 'l', header: 'Approval levels', render: (t) => editable ? <Select aria-label={`${t.name} approval levels`} className="h-8 w-16" value={t.approval_levels}
          onChange={(e) => save.mutate({ id: t.id, patch: { approval_levels: Number(e.target.value) } })}>{[1, 2, 3].map((n) => <option key={n}>{n}</option>)}</Select> : t.approval_levels },
        { key: 'h', header: 'Half day', render: (t) => editable ? <input type="checkbox" aria-label={`${t.name} half day`} checked={t.allow_half_day} onChange={(e) => save.mutate({ id: t.id, patch: { allow_half_day: e.target.checked } })} /> : t.allow_half_day ? 'Yes' : 'No' },
        { key: 'p', header: 'Paid', render: (t) => t.is_paid ? 'Yes' : 'No' },
        { key: 'a', header: 'Active', render: (t) => editable ? <input type="checkbox" aria-label={`${t.name} active`} checked={t.is_active} onChange={(e) => save.mutate({ id: t.id, patch: { is_active: e.target.checked } })} /> : t.is_active ? 'Yes' : 'No' },
      ]} />
    </Card>
  )
}

function Schedule() {
  const { can } = useAuth()
  const qc = useQueryClient()
  const q = useQuery({ queryKey: ['work_schedules'], queryFn: async () => unwrap(await supabase.from('work_schedules').select('*').order('name')) as
    { id: string; name: string; start_time: string; end_time: string; grace_minutes: number; half_day_minutes: number; full_day_minutes: number; weekly_offs: number[]; is_default: boolean }[] })
  const save = useMutation({ mutationFn: async ({ id, patch }: { id: string; patch: Record<string, unknown> }) => unwrap(await supabase.from('work_schedules').update(patch).eq('id', id)),
    onSuccess: () => { toast.success('Schedule saved'); qc.invalidateQueries({ queryKey: ['work_schedules'] }) } })
  const editable = can('attendance.manage_policy')
  const DAYS = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']
  return (
    <div className="space-y-4">{q.data?.map((s) => (
      <Card key={s.id}><CardHeader title={s.name} description={s.is_default ? 'Default schedule for employees without one' : undefined} />
        <CardBody className="grid gap-4 sm:grid-cols-3">
          <Field label="Start time">{(p) => <Input type="time" {...p} disabled={!editable} defaultValue={s.start_time.slice(0, 5)} onBlur={(e) => save.mutate({ id: s.id, patch: { start_time: e.target.value } })} />}</Field>
          <Field label="End time">{(p) => <Input type="time" {...p} disabled={!editable} defaultValue={s.end_time.slice(0, 5)} onBlur={(e) => save.mutate({ id: s.id, patch: { end_time: e.target.value } })} />}</Field>
          <Field label="Grace (minutes)">{(p) => <Input type="number" min={0} {...p} disabled={!editable} defaultValue={s.grace_minutes} onBlur={(e) => save.mutate({ id: s.id, patch: { grace_minutes: Number(e.target.value) } })} />}</Field>
          <Field label="Half day after (hours)">{(p) => <Input type="number" step={0.5} min={0} {...p} disabled={!editable} defaultValue={s.half_day_minutes / 60} onBlur={(e) => save.mutate({ id: s.id, patch: { half_day_minutes: Math.round(Number(e.target.value) * 60) } })} />}</Field>
          <Field label="Full day after (hours)">{(p) => <Input type="number" step={0.5} min={0} {...p} disabled={!editable} defaultValue={s.full_day_minutes / 60} onBlur={(e) => save.mutate({ id: s.id, patch: { full_day_minutes: Math.round(Number(e.target.value) * 60) } })} />}</Field>
          <fieldset className="space-y-1.5"><legend className="text-sm font-medium">Weekly offs</legend><div className="flex flex-wrap gap-2">{DAYS.map((d, i) => (
            <label key={d} className="flex items-center gap-1 text-sm"><input type="checkbox" disabled={!editable} checked={s.weekly_offs.includes(i + 1)}
              onChange={(e) => save.mutate({ id: s.id, patch: { weekly_offs: e.target.checked ? [...s.weekly_offs, i + 1].sort() : s.weekly_offs.filter((x) => x !== i + 1) } })} />{d}</label>))}</div></fieldset>
        </CardBody></Card>))}</div>
  )
}

function Statuses() {
  const { org, can } = useAuth()
  const qc = useQueryClient()
  const { data } = useTaskStatuses()
  const [name, setName] = useState(''); const [cat, setCat] = useState<StatusCategory>('in_progress')
  const add = useMutation({ mutationFn: async () => unwrap(await supabase.from('task_statuses').insert({ org_id: org!.id, name: name.trim(), category: cat,
    key: name.trim().toLowerCase().replace(/[^a-z]+/g, '_').replace(/^_|_$/g, '').slice(0, 30), position: (data?.length ?? 0) + 1 })),
    onSuccess: () => { setName(''); qc.invalidateQueries({ queryKey: ['task_statuses'] }) } })
  return <SimpleList title="Task statuses" description="Each status maps to a category; workflow rules (review, completion, progress) use the category." rows={data}
    addForm={can('tasks.manage_statuses') && <><Input aria-label="Status name" placeholder="e.g. Client approval" value={name} onChange={(e) => setName(e.target.value)} />
      <Select aria-label="Category" className="sm:w-48" value={cat} onChange={(e) => setCat(e.target.value as StatusCategory)}>
        {(['todo', 'in_progress', 'review', 'changes_requested', 'done', 'cancelled'] as const).map((c) => <option key={c} value={c}>{titleCase(c)}</option>)}</Select>
      <Button disabled={name.trim().length < 2} onClick={() => add.mutate()}><Plus />Add</Button></>}
    columns={[{ key: 'n', header: 'Status', render: (s) => <span className="flex items-center gap-2"><span className="size-2 rounded-full" style={{ background: s.color }} />{s.name}</span> },
      { key: 'c', header: 'Category', render: (s) => titleCase(s.category) }, { key: 'd', header: '', render: (s) => s.is_default && <Badge>Default</Badge> }]} />
}

function Announcements() {
  const { org, session, can } = useAuth()
  const qc = useQueryClient()
  const [title, setTitle] = useState(''); const [body, setBody] = useState('')
  const list = useQuery({ queryKey: ['announcements'], queryFn: async () => unwrap(await supabase.from('announcements').select('*').order('created_at', { ascending: false })) as { id: string; title: string; body: string; created_at: string }[] })
  const add = useMutation({ mutationFn: async () => unwrap(await supabase.from('announcements').insert({ org_id: org!.id, title, body, created_by: session!.user.id })),
    onSuccess: () => { setTitle(''); setBody(''); qc.invalidateQueries({ queryKey: ['announcements'] }) } })
  const del = useMutation({ mutationFn: async (id: string) => unwrap(await supabase.from('announcements').delete().eq('id', id)), onSuccess: () => qc.invalidateQueries({ queryKey: ['announcements'] }) })
  return (
    <Card><CardHeader title="Announcements" description="Shown on every employee's dashboard." />
      {can('announcements.manage') && <CardBody className="space-y-2 border-b"><Input aria-label="Title" placeholder="Title" value={title} onChange={(e) => setTitle(e.target.value)} />
        <Textarea aria-label="Message" placeholder="Message" value={body} onChange={(e) => setBody(e.target.value)} />
        <Button disabled={title.trim().length < 2 || !body.trim()} onClick={() => add.mutate()}>Publish</Button></CardBody>}
      <DataTable rows={list.data} empty={<EmptyState title="No announcements" />} columns={[{ key: 't', header: 'Title', render: (a) => a.title }, { key: 'd', header: 'Published', render: (a) => fmtDate(a.created_at) },
        { key: 'x', header: '', render: (a) => can('announcements.manage') && <Button size="icon" variant="ghost" aria-label="Delete announcement" onClick={() => del.mutate(a.id)}><Trash2 /></Button> }]} />
    </Card>
  )
}

function NotificationPrefs() {
  const { session } = useAuth()
  const qc = useQueryClient()
  const q = useQuery({ queryKey: ['notification_preferences'], queryFn: async () => unwrap(await supabase.from('notification_preferences').select('*')) as { type: string; in_app: boolean; email: boolean }[] })
  const save = useMutation({ mutationFn: async (row: { type: string; in_app: boolean; email: boolean }) => unwrap(await supabase.from('notification_preferences').upsert({ profile_id: session!.user.id, ...row })),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['notification_preferences'] }) })
  const pref = (type: string) => q.data?.find((p) => p.type === type) ?? { type, in_app: true, email: true }
  return (
    <Card><CardHeader title="My notification preferences" description="Email delivery activates once an email provider is configured." />
      <DataTable rows={Object.entries(NOTIFICATION_TYPES).map(([type, label]) => ({ id: type, type, label }))} columns={[
        { key: 'l', header: 'Event', render: (r) => r.label },
        { key: 'i', header: 'In-app', render: (r) => <input type="checkbox" aria-label={`${r.label} in-app`} checked={pref(r.type).in_app} onChange={(e) => save.mutate({ ...pref(r.type), in_app: e.target.checked })} /> },
        { key: 'e', header: 'Email', render: (r) => <input type="checkbox" aria-label={`${r.label} email`} checked={pref(r.type).email} onChange={(e) => save.mutate({ ...pref(r.type), email: e.target.checked })} /> },
      ]} />
    </Card>
  )
}

function AuditLog() {
  const { data: people } = usePeople()
  const [table, setTable] = useState('')
  const q = useQuery({ queryKey: ['audit_logs', table], queryFn: async () => {
    let s = supabase.from('audit_logs').select('id, actor_id, action, table_name, record_id, created_at, old_data, new_data').order('created_at', { ascending: false }).limit(200)
    if (table) s = s.eq('table_name', table)
    return unwrap(await s) as { id: number; actor_id: string | null; action: string; table_name: string; record_id: string | null; created_at: string; old_data: Record<string, unknown> | null; new_data: Record<string, unknown> | null }[]
  } })
  const changed = (o: Record<string, unknown> | null, n: Record<string, unknown> | null) => !o || !n ? '' :
    Object.keys(n).filter((k) => k !== 'updated_at' && JSON.stringify(o[k]) !== JSON.stringify(n[k])).join(', ')
  return (
    <Card><CardHeader title="Audit log" description="Latest 200 changes. Records cannot be edited or deleted by users."
      action={<Select aria-label="Table" className="w-56" value={table} onChange={(e) => setTable(e.target.value)}><option value="">All tables</option>
        {['attendance_records', 'attendance_corrections', 'leave_requests', 'leave_balances', 'employee_profiles', 'salary_revisions', 'clients', 'contracts', 'projects', 'tasks', 'user_roles', 'role_permissions'].map((t) => <option key={t}>{t}</option>)}</Select>} />
      <DataTable rows={q.data?.map((r) => ({ ...r, id: String(r.id) }))} loading={q.isLoading} columns={[
        { key: 't', header: 'When', render: (r) => fmtDate(r.created_at, 'dd MMM yyyy, hh:mm:ss a') },
        { key: 'a', header: 'Who', render: (r) => r.actor_id ? nameOf(people, r.actor_id) : 'System' },
        { key: 'x', header: 'Action', render: (r) => <Badge tone={r.action === 'DELETE' ? 'red' : r.action === 'INSERT' ? 'green' : 'blue'}>{r.action}</Badge> },
        { key: 'tb', header: 'Record', render: (r) => <span className="font-mono text-xs">{r.table_name}</span> },
        { key: 'c', header: 'Changed fields', render: (r) => <span className="text-xs text-muted-foreground">{changed(r.old_data, r.new_data)}</span> },
      ]} />
    </Card>
  )
}

export default function SettingsPage() {
  const { can } = useAuth()
  const all: { value: Tab; label: string; show: boolean }[] = [
    { value: 'org', label: 'Organization', show: true },
    { value: 'roles', label: 'Roles & permissions', show: can(['roles.manage', 'users.manage'], 'any') },
    { value: 'invites', label: 'Invitations', show: can('users.manage') },
    { value: 'departments', label: 'Departments', show: true },
    { value: 'holidays', label: 'Holidays', show: true },
    { value: 'leave', label: 'Leave policy', show: can(['leave.manage_policy', 'leave.view_all'], 'any') },
    { value: 'schedule', label: 'Work schedule', show: can(['attendance.manage_policy', 'attendance.view_all'], 'any') },
    { value: 'statuses', label: 'Task statuses', show: true },
    { value: 'announcements', label: 'Announcements', show: can('announcements.manage') },
    { value: 'notifications', label: 'My notifications', show: true },
    { value: 'audit', label: 'Audit log', show: can('audit.view') },
  ]
  const tabs = all.filter((t) => t.show)
  const [tab, setTab] = useState<Tab>(tabs[0]!.value)
  return (
    <div className="space-y-6">
      <PageHeader title="Settings" />
      <Tabs tabs={tabs} value={tab} onChange={setTab} />
      {tab === 'org' && <OrgSettings />}
      {tab === 'roles' && <RolesMatrix />}
      {tab === 'invites' && <Invitations />}
      {tab === 'departments' && <Departments />}
      {tab === 'holidays' && <Holidays />}
      {tab === 'leave' && <LeaveTypes />}
      {tab === 'schedule' && <Schedule />}
      {tab === 'statuses' && <Statuses />}
      {tab === 'announcements' && <Announcements />}
      {tab === 'notifications' && <NotificationPrefs />}
      {tab === 'audit' && <AuditLog />}
    </div>
  )
}
