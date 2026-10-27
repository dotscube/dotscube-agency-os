import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { toast } from 'sonner'
import { Ban, MailPlus, Play, ShieldCheck, Trash2, UserPlus } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { unwrap } from '@/lib/query'
import { friendlyError } from '@/lib/errors'
import { fmtDate } from '@/lib/utils'
import type { PlatformAgency, PlatformMember, PlatformSettings } from '@/lib/types'
import { useAuth } from '@/features/auth/AuthProvider'
import { DataTable } from '@/components/DataTable'
import { Badge, Button, Card, CardBody, CardHeader, Dialog, EmptyState, ErrorState, Field, Input, PageHeader, Select, Spinner, Tabs, Textarea } from '@/components/ui'

const CREATION = {
  open: { label: 'Anyone can sign up and create an agency', hint: 'Good for a public SaaS sign-up page.' },
  invite_only: { label: 'Only people I invite', hint: 'They sign up with the invited e-mail, then create their agency.' },
  closed: { label: 'Nobody (only Dotscube)', hint: 'New sign-ups can only join an agency that invites them.' },
} as const

function AgencyDialog({ a, onClose }: { a: PlatformAgency; onClose: () => void }) {
  const qc = useQueryClient()
  const [plan, setPlan] = useState(a.plan); const [max, setMax] = useState(a.max_users != null ? String(a.max_users) : ''); const [notes, setNotes] = useState(a.platform_notes ?? '')
  const [reason, setReason] = useState('')
  const members = useQuery({ queryKey: ['platform', 'members', a.id], queryFn: async () => unwrap(await supabase.rpc('platform_agency_members', { p_org: a.id })) as PlatformMember[] })
  const inv = () => qc.invalidateQueries({ queryKey: ['platform'] })
  const save = useMutation({ mutationFn: async () => unwrap(await supabase.rpc('platform_update_agency', { p_org: a.id, p_plan: plan, p_max_users: max ? Number(max) : null, p_notes: notes })),
    onSuccess: () => { toast.success('Agency updated'); inv() } })
  const status = useMutation({ mutationFn: async (s: 'active' | 'suspended') => unwrap(await supabase.rpc('platform_set_agency_status', { p_org: a.id, p_status: s, p_reason: reason || null })),
    onSuccess: (_, s) => { toast.success(s === 'suspended' ? `${a.name} suspended` : `${a.name} reactivated`); inv(); onClose() } })
  return (
    <Dialog open onClose={onClose} wide title={a.name} description={`${a.founder ? `Founded by ${a.founder.name || a.founder.email} (${a.founder.email}) · ` : ''}created ${fmtDate(a.created_at)}`}>
      <div className="space-y-5 text-sm">
        <div className="grid grid-cols-3 gap-3 sm:grid-cols-6">
          {([['Staff', a.staff_users], ['Client users', a.client_users], ['Employees', a.employees], ['Clients', a.clients], ['Projects', a.projects], ['Invoices', a.invoices]] as const).map(([l, v]) => (
            <div key={l} className="rounded-md border p-2 text-center"><p className="text-lg font-semibold">{v}</p><p className="text-xs text-muted-foreground">{l}</p></div>))}
        </div>
        <div className="grid gap-4 sm:grid-cols-3">
          <Field label="Plan">{(p) => <Input {...p} value={plan} onChange={(e) => setPlan(e.target.value.toLowerCase().replace(/[^a-z0-9_]/g, ''))} />}</Field>
          <Field label="User limit" hint="Blank = unlimited">{(p) => <Input {...p} type="number" min={1} value={max} onChange={(e) => setMax(e.target.value)} />}</Field>
          <div className="self-end"><Button loading={save.isPending} disabled={plan.length < 2} onClick={() => save.mutate()}>Save</Button></div>
          <Field label="Private notes (only platform admins see these)" className="sm:col-span-3">{(p) => <Textarea {...p} value={notes} onChange={(e) => setNotes(e.target.value)} />}</Field>
        </div>
        <div>
          <p className="mb-2 font-medium">Members</p>
          <DataTable rows={members.data} loading={members.isLoading} error={members.error ? friendlyError(members.error) : null} empty={<EmptyState title="No members" />} columns={[
            { key: 'n', header: 'Name', render: (m) => <span><span className="block">{m.full_name || '—'}</span><span className="text-xs text-muted-foreground">{m.email}</span></span> },
            { key: 'r', header: 'Roles', render: (m) => m.roles ?? '—' },
            { key: 't', header: 'Type', render: (m) => (m.is_client ? <Badge tone="slate">Client</Badge> : <Badge tone="blue">Staff</Badge>) },
            { key: 's', header: 'Status', render: (m) => (m.is_active ? 'Active' : 'Deactivated') },
          ]} />
        </div>
        <div className="rounded-md border p-4">
          {a.status === 'active' ? (a.is_platform_home ? <p className="text-muted-foreground">This is your own agency; it can't be suspended.</p> : <>
            <p className="mb-2 font-medium">Suspend this agency</p>
            <p className="mb-3 text-muted-foreground">Everyone in it, including their clients, immediately loses access. Their data is kept, and you can reactivate at any time.</p>
            <div className="flex flex-col gap-2 sm:flex-row"><Input aria-label="Reason for suspension" placeholder="Reason, e.g. unpaid subscription" value={reason} onChange={(e) => setReason(e.target.value)} />
              <Button variant="destructive" disabled={reason.trim().length < 3} loading={status.isPending} onClick={() => status.mutate('suspended')}><Ban />Suspend</Button></div>
          </>) : <>
            <p className="mb-2 font-medium text-destructive">Suspended {fmtDate(a.suspended_at)}: {a.suspended_reason}</p>
            <Button loading={status.isPending} onClick={() => status.mutate('active')}><Play />Reactivate</Button>
          </>}
        </div>
      </div>
    </Dialog>
  )
}

function Agencies() {
  const [open, setOpen] = useState<PlatformAgency | null>(null)
  const [filter, setFilter] = useState('')
  const q = useQuery({ queryKey: ['platform', 'agencies'], queryFn: async () => unwrap(await supabase.rpc('platform_agencies')) as PlatformAgency[] })
  const rows = (q.data ?? []).filter((a) => !filter || a.status === filter).sort((x, y) => Number(y.is_platform_home) - Number(x.is_platform_home) || y.created_at.localeCompare(x.created_at))
  const current = open && q.data?.find((a) => a.id === open.id)
  return (
    <div className="space-y-4">
      {q.data && <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
        {[['Agencies', q.data.length], ['Active', q.data.filter((a) => a.status === 'active').length], ['Suspended', q.data.filter((a) => a.status === 'suspended').length],
          ['Staff users', q.data.reduce((s, a) => s + Number(a.staff_users), 0)]].map(([l, v]) => (
          <div key={l} className="rounded-lg border bg-card p-4"><p className="text-xs text-muted-foreground">{l}</p><p className="mt-1 text-xl font-semibold">{v}</p></div>))}
      </div>}
      <Select aria-label="Status" className="sm:w-48" value={filter} onChange={(e) => setFilter(e.target.value)}><option value="">All agencies</option><option value="active">Active</option><option value="suspended">Suspended</option></Select>
      <Card><DataTable rows={rows} loading={q.isLoading} error={q.error ? friendlyError(q.error) : null} onRetry={q.refetch} onRowClick={setOpen}
        empty={<EmptyState title="No agencies" />} columns={[
          { key: 'n', header: 'Agency', render: (a) => <span><span className="flex items-center gap-2 font-medium">{a.name}{a.is_platform_home && <Badge tone="blue">Yours</Badge>}</span>
            <span className="text-xs text-muted-foreground">{a.founder?.email ?? a.slug}</span></span> },
          { key: 'c', header: 'Created', render: (a) => fmtDate(a.created_at) },
          { key: 'u', header: 'Users', render: (a) => `${a.staff_users}${a.max_users ? ` / ${a.max_users}` : ''}${Number(a.client_users) ? ` + ${a.client_users} client` : ''}` },
          { key: 'd', header: 'Usage', render: (a) => <span className="text-xs text-muted-foreground">{a.clients} clients · {a.projects} projects · {a.invoices} invoices</span> },
          { key: 'l', header: 'Last activity', render: (a) => fmtDate(a.last_activity) },
          { key: 'p', header: 'Plan', render: (a) => <Badge tone="slate">{a.plan}</Badge> },
          { key: 's', header: 'Status', render: (a) => <Badge tone={a.status === 'active' ? 'green' : 'red'}>{a.status === 'active' ? 'Active' : 'Suspended'}</Badge> },
        ]} /></Card>
      {current && <AgencyDialog key={current.id + current.status} a={current} onClose={() => setOpen(null)} />}
    </div>
  )
}

function SignUps() {
  const qc = useQueryClient()
  const { session } = useAuth()
  const q = useQuery({ queryKey: ['platform', 'settings'], queryFn: async () => unwrap(await supabase.rpc('platform_get_settings')) as PlatformSettings })
  const [f, setF] = useState<{ mode: string; plan: string; max: string } | null>(null)
  const [inv, setInv] = useState({ email: '', plan: '', max: '', note: '' }); const [adminEmail, setAdminEmail] = useState('')
  const refresh = () => qc.invalidateQueries({ queryKey: ['platform'] })
  const s = q.data?.settings
  const v = f ?? (s ? { mode: s.org_creation, plan: s.default_plan, max: s.default_max_users != null ? String(s.default_max_users) : '' } : null)
  const save = useMutation({ mutationFn: async () => unwrap(await supabase.rpc('platform_save_settings', { p_org_creation: v!.mode, p_default_plan: v!.plan, p_default_max_users: v!.max ? Number(v!.max) : null })),
    onSuccess: () => { toast.success('Sign-up rules saved'); setF(null); refresh() } })
  const invite = useMutation({ mutationFn: async () => unwrap(await supabase.rpc('platform_invite', { p_email: inv.email, p_plan: inv.plan || null, p_max_users: inv.max ? Number(inv.max) : null, p_note: inv.note || null })),
    onSuccess: () => { toast.success(`Invitation saved. Ask ${inv.email} to sign up at ${window.location.origin} with this e-mail.`); setInv({ email: '', plan: '', max: '', note: '' }); refresh() } })
  const revoke = useMutation({ mutationFn: async (id: string) => unwrap(await supabase.rpc('platform_revoke_invite', { p_invite: id })), onSuccess: refresh })
  const addAdmin = useMutation({ mutationFn: async () => unwrap(await supabase.rpc('platform_add_admin', { p_email: adminEmail })), onSuccess: () => { toast.success('Platform admin added'); setAdminEmail(''); refresh() } })
  const removeAdmin = useMutation({ mutationFn: async (id: string) => unwrap(await supabase.rpc('platform_remove_admin', { p_user: id })), onSuccess: refresh })
  if (q.isLoading) return <Spinner />
  if (q.error || !q.data || !v) return <ErrorState message={friendlyError(q.error)} onRetry={q.refetch} />
  const okEmail = (e: string) => /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(e)
  return (
    <div className="space-y-6">
      <Card><CardHeader title="Who can create a new agency?" description="People invited by an existing agency can always join that agency; this only controls creating new ones." />
        <CardBody className="space-y-4">
          <fieldset className="space-y-2">{(Object.keys(CREATION) as (keyof typeof CREATION)[]).map((k) => (
            <label key={k} className="flex items-start gap-2 text-sm"><input type="radio" className="mt-1" name="mode" checked={v.mode === k} onChange={() => setF({ ...v, mode: k })} />
              <span><span className="font-medium">{CREATION[k].label}</span><span className="block text-muted-foreground">{CREATION[k].hint}</span></span></label>))}</fieldset>
          <div className="grid max-w-lg gap-4 sm:grid-cols-2">
            <Field label="Plan for new agencies">{(p) => <Input {...p} value={v.plan} onChange={(e) => setF({ ...v, plan: e.target.value.toLowerCase().replace(/[^a-z0-9_]/g, '') })} />}</Field>
            <Field label="User limit for new agencies" hint="Blank = unlimited">{(p) => <Input {...p} type="number" min={1} value={v.max} onChange={(e) => setF({ ...v, max: e.target.value })} />}</Field>
          </div>
          <Button disabled={!f || v.plan.length < 2} loading={save.isPending} onClick={() => save.mutate()}>Save</Button>
        </CardBody></Card>

      <Card><CardHeader title="Agency invitations" description="Used when sign-ups are invitation-only. Each invitation creates one agency." />
        <CardBody className="grid gap-3 border-b sm:grid-cols-[2fr_1fr_1fr_2fr_auto] sm:items-end">
          <Field label="E-mail">{(p) => <Input {...p} type="email" value={inv.email} onChange={(e) => setInv({ ...inv, email: e.target.value })} />}</Field>
          <Field label="Plan">{(p) => <Input {...p} placeholder={v.plan} value={inv.plan} onChange={(e) => setInv({ ...inv, plan: e.target.value.toLowerCase().replace(/[^a-z0-9_]/g, '') })} />}</Field>
          <Field label="User limit">{(p) => <Input {...p} type="number" min={1} value={inv.max} onChange={(e) => setInv({ ...inv, max: e.target.value })} />}</Field>
          <Field label="Note">{(p) => <Input {...p} value={inv.note} onChange={(e) => setInv({ ...inv, note: e.target.value })} />}</Field>
          <Button disabled={!okEmail(inv.email)} loading={invite.isPending} onClick={() => invite.mutate()}><MailPlus />Invite</Button>
        </CardBody>
        <DataTable rows={q.data.invites} empty={<EmptyState title="No invitations" />} columns={[
          { key: 'e', header: 'E-mail', render: (i) => <span><span className="block">{i.email}</span>{i.note && <span className="text-xs text-muted-foreground">{i.note}</span>}</span> },
          { key: 'p', header: 'Plan / limit', render: (i) => `${i.plan ?? 'default'} · ${i.max_users ?? 'default'}` },
          { key: 's', header: 'Status', render: (i) => (i.used_at ? <Badge tone="green">Agency created {fmtDate(i.used_at)}</Badge>
            : new Date(i.expires_at) < new Date() ? <Badge tone="slate">Expired</Badge> : <Badge tone="blue">Waiting · expires {fmtDate(i.expires_at)}</Badge>) },
          { key: 'x', header: '', render: (i) => !i.used_at && <Button size="icon" variant="ghost" aria-label="Revoke invitation" onClick={() => revoke.mutate(i.id)}><Trash2 /></Button> },
        ]} /></Card>

      <Card><CardHeader title="Platform admins" description="Can see every agency, suspend agencies and change these settings. Keep this list short." />
        <ul className="divide-y">{q.data.admins.map((a) => (
          <li key={a.user_id} className="flex items-center justify-between px-5 py-2.5 text-sm"><span className="flex items-center gap-2"><ShieldCheck className="size-4 text-primary" />{a.name || a.email}
            <span className="text-muted-foreground">{a.email}</span></span>
            {a.user_id !== session?.user.id && <Button size="sm" variant="ghost" onClick={() => { if (confirm(`Remove ${a.email} as platform admin?`)) removeAdmin.mutate(a.user_id) }}>Remove</Button>}</li>))}</ul>
        <CardBody className="flex flex-col gap-2 border-t sm:flex-row"><Input aria-label="E-mail of an existing account" placeholder="E-mail of an existing account" value={adminEmail} onChange={(e) => setAdminEmail(e.target.value)} />
          <Button variant="outline" disabled={!okEmail(adminEmail)} loading={addAdmin.isPending} onClick={() => addAdmin.mutate()}><UserPlus />Add admin</Button></CardBody></Card>
    </div>
  )
}

export default function PlatformPage() {
  const [tab, setTab] = useState<'agencies' | 'signups'>('agencies')
  return (
    <div className="space-y-6">
      <PageHeader title="Platform" description="Every agency on this Agency OS installation. You see summaries and members, not their clients' or employees' data." />
      <Tabs tabs={[{ value: 'agencies', label: 'Agencies' }, { value: 'signups', label: 'Sign-ups & admins' }]} value={tab} onChange={setTab} />
      {tab === 'agencies' ? <Agencies /> : <SignUps />}
    </div>
  )
}
