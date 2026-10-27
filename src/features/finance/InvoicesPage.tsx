import { useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { toast } from 'sonner'
import { FilePlus2, FileText } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { unwrap } from '@/lib/query'
import { friendlyError } from '@/lib/errors'
import { fmtDate, fmtMoney } from '@/lib/utils'
import { nameOf, useClientsLite } from '@/lib/lookups'
import { GST_RATES, GST_STATES, daysPastDue, fmtAmount, isValidGstin } from '@/lib/finance'
import type { BillingSettings, Contract, FinanceSummary, Invoice, InvoiceStatus } from '@/lib/types'
import { useAuth } from '@/features/auth/AuthProvider'
import { DataTable } from '@/components/DataTable'
import { Badge, Button, Card, CardBody, CardHeader, Dialog, EmptyState, ErrorState, Field, Input, PageHeader, Select, Spinner, Tabs, Textarea } from '@/components/ui'

export const INVOICE_STATUS: Record<InvoiceStatus, { label: string; tone: 'slate' | 'blue' | 'amber' | 'green' | 'red' }> = {
  draft: { label: 'Draft', tone: 'slate' }, issued: { label: 'Issued', tone: 'blue' }, partially_paid: { label: 'Part paid', tone: 'amber' },
  paid: { label: 'Paid', tone: 'green' }, cancelled: { label: 'Cancelled', tone: 'slate' },
}

export function InvoiceStatusBadge({ inv, today }: { inv: Pick<Invoice, 'status' | 'due_date' | 'balance'>; today?: string }) {
  const overdue = today && inv.due_date && ['issued', 'partially_paid'].includes(inv.status) && daysPastDue(inv.due_date, today) > 0
  if (overdue) return <Badge tone="red">Overdue {daysPastDue(inv.due_date!, today!)}d</Badge>
  const s = INVOICE_STATUS[inv.status]
  return <Badge tone={s.tone}>{s.label}</Badge>
}

const todayIso = () => new Date().toISOString().slice(0, 10)

function Stat({ label, value, hint, tone }: { label: string; value: string; hint?: string; tone?: 'red' }) {
  return <div className="rounded-lg border bg-card p-4"><p className="text-xs text-muted-foreground">{label}</p>
    <p className={`mt-1 text-xl font-semibold tabular-nums ${tone === 'red' ? 'text-destructive' : ''}`}>{value}</p>
    {hint && <p className="text-xs text-muted-foreground">{hint}</p>}</div>
}

function NewInvoiceDialog({ open, onClose }: { open: boolean; onClose: () => void }) {
  const { org } = useAuth()
  const navigate = useNavigate()
  const { data: clients } = useClientsLite(open)
  const [mode, setMode] = useState<'contract' | 'blank'>('contract')
  const [client, setClient] = useState(''); const [contract, setContract] = useState('')
  const [period, setPeriod] = useState(todayIso().slice(0, 7)); const [adSpend, setAdSpend] = useState(true)
  const contracts = useQuery({ queryKey: ['contracts', client], enabled: open && Boolean(client),
    queryFn: async () => unwrap(await supabase.from('contracts').select('*').eq('client_id', client).order('start_date', { ascending: false })) as Contract[] })
  const create = useMutation({
    mutationFn: async () => {
      if (mode === 'contract') return unwrap(await supabase.rpc('create_invoice_from_contract', { p_contract: contract, p_period: period, p_include_ad_spend: adSpend })) as string
      const row = unwrap(await supabase.from('invoices').insert({ org_id: org!.id, client_id: client }).select('id').single()) as { id: string }
      return row.id
    },
    onSuccess: (id) => { onClose(); navigate(`/invoices/${id}`) },
  })
  return (
    <Dialog open={open} onClose={onClose} title="New invoice" description="Invoices start as drafts. Numbers are given only when you issue them."
      footer={<><Button variant="outline" onClick={onClose}>Cancel</Button>
        <Button disabled={!client || (mode === 'contract' && (!contract || !period))} loading={create.isPending} onClick={() => create.mutate()}>Create draft</Button></>}>
      <div className="space-y-4 text-sm">
        <fieldset className="flex flex-wrap gap-4"><legend className="sr-only">Start from</legend>
          <label className="flex items-center gap-2"><input type="radio" checked={mode === 'contract'} onChange={() => setMode('contract')} />From a contract (monthly fee)</label>
          <label className="flex items-center gap-2"><input type="radio" checked={mode === 'blank'} onChange={() => setMode('blank')} />Blank invoice</label>
        </fieldset>
        <Field label="Client">{(p) => <Select {...p} value={client} onChange={(e) => { setClient(e.target.value); setContract('') }}>
          <option value="">Choose…</option>{clients?.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</Select>}</Field>
        {mode === 'contract' && <>
          <Field label="Contract" hint={client && contracts.data?.length === 0 ? 'This client has no contracts. Add one on the client page, or use a blank invoice.' : undefined}>
            {(p) => <Select {...p} value={contract} disabled={!client} onChange={(e) => setContract(e.target.value)}><option value="">Choose…</option>
              {contracts.data?.map((k) => <option key={k.id} value={k.id}>{k.title} · {fmtMoney(k.management_fee)} / {k.billing_cycle.replace('_', ' ')}</option>)}</Select>}</Field>
          <Field label="Billing month">{(p) => <Input {...p} type="month" value={period} onChange={(e) => setPeriod(e.target.value)} />}</Field>
          <label className="flex items-start gap-2"><input type="checkbox" className="mt-0.5" checked={adSpend} onChange={(e) => setAdSpend(e.target.checked)} />
            <span>Add that month's ad spend from imported campaign data<span className="block text-xs text-muted-foreground">One line per platform, kept separate from your management fee.</span></span></label>
        </>}
      </div>
    </Dialog>
  )
}

function InvoiceList({ manage, internal }: { manage: boolean; internal: boolean }) {
  const navigate = useNavigate()
  const { data: clients } = useClientsLite(internal)
  const [status, setStatus] = useState(''); const [client, setClient] = useState('')
  const today = todayIso()
  const q = useQuery({ queryKey: ['invoices', 'list', status, client], queryFn: async () => {
    let s = supabase.from('invoices').select('id, client_id, invoice_number, status, issue_date, due_date, total, balance, fee_subtotal, ad_spend_subtotal, currency, billing_period, created_at')
      .order('created_at', { ascending: false }).limit(300)
    if (status === 'overdue') s = s.in('status', ['issued', 'partially_paid']).lt('due_date', today)
    else if (status === 'open') s = s.in('status', ['issued', 'partially_paid'])
    else if (status) s = s.eq('status', status)
    if (client) s = s.eq('client_id', client)
    return unwrap(await s) as Invoice[]
  } })
  return (
    <div className="space-y-4">
      <div className="flex flex-col gap-2 sm:flex-row">
        <Select aria-label="Status" className="sm:w-48" value={status} onChange={(e) => setStatus(e.target.value)}>
          <option value="">All invoices</option><option value="open">Unpaid</option><option value="overdue">Overdue</option>
          {internal && <option value="draft">Drafts</option>}<option value="paid">Paid</option><option value="cancelled">Cancelled</option></Select>
        {internal && <Select aria-label="Client" className="sm:w-56" value={client} onChange={(e) => setClient(e.target.value)}><option value="">All clients</option>
          {clients?.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</Select>}
      </div>
      <Card><DataTable rows={q.data} loading={q.isLoading} error={q.error ? friendlyError(q.error) : null} onRetry={q.refetch}
        onRowClick={(r) => navigate(`/invoices/${r.id}`)}
        empty={<EmptyState icon={<FileText className="size-8" />} title="No invoices yet" description={manage ? 'Create one from a client contract or start a blank invoice.' : undefined} />}
        columns={[
          { key: 'n', header: 'Invoice', render: (r) => <span><span className="block font-medium">{r.invoice_number ?? 'Draft'}</span>
            <span className="text-xs text-muted-foreground">{internal ? nameOf(clients, r.client_id) : (r.billing_period ?? '')}</span></span> },
          { key: 'd', header: 'Date', render: (r) => fmtDate(r.issue_date ?? r.created_at) },
          { key: 'due', header: 'Due', render: (r) => fmtDate(r.due_date) },
          { key: 't', header: 'Total', className: 'text-right', render: (r) => <span className="tabular-nums">{fmtAmount(r.total, r.currency)}</span> },
          { key: 'b', header: 'Balance', className: 'text-right', render: (r) => <span className="tabular-nums">{r.status === 'cancelled' || r.status === 'draft' ? '—' : fmtAmount(r.balance, r.currency)}</span> },
          { key: 's', header: 'Status', render: (r) => <InvoiceStatusBadge inv={r} today={today} /> },
        ]} /></Card>
    </div>
  )
}

function Collections() {
  const navigate = useNavigate()
  const q = useQuery({ queryKey: ['invoices', 'summary'], queryFn: async () => unwrap(await supabase.rpc('get_finance_summary')) as FinanceSummary })
  if (q.isLoading) return <Spinner />
  if (q.error) return <ErrorState message={friendlyError(q.error)} onRetry={q.refetch} />
  const s = q.data!
  const aging = [['Not yet due', s.aging.current], ['1–30 days', s.aging.d1_30], ['31–60 days', s.aging.d31_60], ['61–90 days', s.aging.d61_90], ['90+ days', s.aging.d90_plus]] as const
  const max = Math.max(1, ...aging.map(([, v]) => Number(v)))
  return (
    <div className="space-y-6">
      <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
        <Stat label="Outstanding" value={fmtMoney(s.outstanding)} hint={`${s.open_count} unpaid invoice(s)`} />
        <Stat label="Overdue" value={fmtMoney(s.overdue)} hint={`${s.overdue_count} invoice(s)`} tone={s.overdue > 0 ? 'red' : undefined} />
        <Stat label="Invoiced this month" value={fmtMoney(s.invoiced_this_month)} hint={`Fees ${fmtMoney(s.fees_this_month)} · ad spend ${fmtMoney(s.ad_spend_this_month)}`} />
        <Stat label="Collected this month" value={fmtMoney(s.collected_this_month)} />
      </div>
      <div className="grid gap-6 lg:grid-cols-2">
        <Card><CardHeader title="Ageing" description="Unpaid balances by days past the due date." />
          <CardBody className="space-y-3">{aging.map(([label, v]) => (
            <div key={label} className="grid grid-cols-[7rem_1fr_6rem] items-center gap-3 text-sm">
              <span className="text-muted-foreground">{label}</span>
              <span className="h-2.5 rounded-full bg-muted"><span className="block h-2.5 rounded-full bg-primary" style={{ width: `${(Number(v) / max) * 100}%` }} /></span>
              <span className="text-right tabular-nums">{fmtMoney(Number(v))}</span>
            </div>))}</CardBody></Card>
        <Card><CardHeader title="Who owes the most" />
          <DataTable rows={s.by_client} rowKey={(r) => r.client_id} onRowClick={(r) => navigate(`/clients/${r.client_id}`)} empty={<EmptyState title="Nothing outstanding" />} columns={[
            { key: 'c', header: 'Client', render: (r) => r.name },
            { key: 'n', header: 'Invoices', render: (r) => r.invoices },
            { key: 'o', header: 'Oldest due', render: (r) => fmtDate(r.oldest_due) },
            { key: 'b', header: 'Balance', className: 'text-right', render: (r) => <span className="tabular-nums">{fmtMoney(Number(r.balance))}</span> },
          ]} /></Card>
      </div>
    </div>
  )
}

export function BillingSettingsForm() {
  const { org, can } = useAuth()
  const qc = useQueryClient()
  const editable = can('invoices.manage')
  const q = useQuery({ queryKey: ['billing_settings'], queryFn: async () => unwrap(await supabase.from('billing_settings').select('*').maybeSingle()) as BillingSettings | null })
  const [f, setF] = useState<Partial<BillingSettings> | null>(null)
  const v = f ?? q.data ?? null
  const save = useMutation({
    mutationFn: async () => {
      const row = { legal_name: v?.legal_name || null, gstin: v?.gstin?.trim().toUpperCase() || null, pan: v?.pan?.trim().toUpperCase() || null,
        state_code: v?.state_code || null, address: v?.address || null, email: v?.email || null, phone: v?.phone || null,
        invoice_prefix: (v?.invoice_prefix || 'INV').toUpperCase(), default_sac: v?.default_sac || '998361', default_gst_rate: Number(v?.default_gst_rate ?? 18),
        ad_spend_gst_rate: Number(v?.ad_spend_gst_rate ?? 0), bank_details: v?.bank_details || null, terms: v?.terms || null }
      // the row is created with the organization (and by the Phase 5 upgrade), so this is always an update
      return unwrap(await supabase.from('billing_settings').update(row).eq('org_id', org!.id))
    },
    onSuccess: () => { toast.success('Billing settings saved'); setF(null); qc.invalidateQueries({ queryKey: ['billing_settings'] }) },
  })
  if (q.isLoading) return <Spinner />
  if (q.error) return <ErrorState message={friendlyError(q.error)} />
  const set = (k: keyof BillingSettings) => (e: { target: { value: string } }) => setF({ ...(v ?? {}), [k]: e.target.value })
  const gstinBad = Boolean(v?.gstin) && !isValidGstin(v!.gstin!)
  return (
    <Card><CardHeader title="Billing settings" description="Your agency's details as printed on every invoice. Issued invoices keep the details they were issued with." />
      <CardBody className="grid max-w-3xl gap-4 sm:grid-cols-2">
        <Field label="Legal name" className="sm:col-span-2">{(p) => <Input {...p} disabled={!editable} value={v?.legal_name ?? ''} onChange={set('legal_name')} />}</Field>
        <Field label="GSTIN" error={gstinBad ? '15 characters, e.g. 08ABCDE1234F1Z5' : undefined} hint="Your state is taken from the first two digits">
          {(p) => <Input {...p} disabled={!editable} value={v?.gstin ?? ''} maxLength={15} onChange={set('gstin')} />}</Field>
        <Field label="State (if no GSTIN)">{(p) => <Select {...p} disabled={!editable || Boolean(v?.gstin)} value={v?.gstin ? v.gstin.slice(0, 2) : v?.state_code ?? ''} onChange={set('state_code')}>
          <option value="">—</option>{Object.entries(GST_STATES).map(([k, n]) => <option key={k} value={k}>{n} ({k})</option>)}</Select>}</Field>
        <Field label="PAN">{(p) => <Input {...p} disabled={!editable} value={v?.pan ?? ''} maxLength={10} onChange={set('pan')} />}</Field>
        <Field label="Invoice prefix" hint="Numbers look like PREFIX/2026-27/0001">{(p) => <Input {...p} disabled={!editable} value={v?.invoice_prefix ?? 'INV'} maxLength={10} onChange={set('invoice_prefix')} />}</Field>
        <Field label="Email on invoices">{(p) => <Input {...p} type="email" disabled={!editable} value={v?.email ?? ''} onChange={set('email')} />}</Field>
        <Field label="Phone">{(p) => <Input {...p} disabled={!editable} value={v?.phone ?? ''} onChange={set('phone')} />}</Field>
        <Field label="Address" className="sm:col-span-2">{(p) => <Textarea {...p} disabled={!editable} value={v?.address ?? ''} onChange={set('address')} />}</Field>
        <Field label="Default SAC code" hint="998361 = advertising services">{(p) => <Input {...p} disabled={!editable} value={v?.default_sac ?? '998361'} maxLength={8} onChange={set('default_sac')} />}</Field>
        <Field label="GST on management fees">{(p) => <Select {...p} disabled={!editable} value={String(v?.default_gst_rate ?? 18)} onChange={set('default_gst_rate')}>
          {GST_RATES.map((r) => <option key={r} value={r}>{r}%</option>)}</Select>}</Field>
        <Field label="GST on ad spend" hint="0% when you pass ad spend through at cost as the client's agent. Check with your CA.">
          {(p) => <Select {...p} disabled={!editable} value={String(v?.ad_spend_gst_rate ?? 0)} onChange={set('ad_spend_gst_rate')}>{GST_RATES.map((r) => <option key={r} value={r}>{r}%</option>)}</Select>}</Field>
        <Field label="Bank details" className="sm:col-span-2" hint="Account name, number, IFSC, UPI ID">{(p) => <Textarea {...p} disabled={!editable} value={v?.bank_details ?? ''} onChange={set('bank_details')} />}</Field>
        <Field label="Terms printed on invoices" className="sm:col-span-2">{(p) => <Textarea {...p} disabled={!editable} value={v?.terms ?? ''} onChange={set('terms')} />}</Field>
        {editable && <div className="sm:col-span-2"><Button disabled={gstinBad || !f} loading={save.isPending} onClick={() => save.mutate()}>Save</Button></div>}
      </CardBody></Card>
  )
}

export default function InvoicesPage() {
  const { audience, can } = useAuth()
  const internal = audience === 'internal'
  const manage = internal && can('invoices.manage')
  const [tab, setTab] = useState<'invoices' | 'collections' | 'settings'>('invoices')
  const [creating, setCreating] = useState(false)
  return (
    <div className="space-y-6">
      <PageHeader title="Invoices" description={internal ? 'GST invoices, payments and collections. Management fees and ad spend are shown separately.' : 'Your invoices and payments.'}
        actions={manage && <Button onClick={() => setCreating(true)}><FilePlus2 />New invoice</Button>} />
      {internal && <Tabs tabs={[{ value: 'invoices', label: 'Invoices' }, { value: 'collections', label: 'Collections' }, { value: 'settings', label: 'Billing settings' }]} value={tab} onChange={setTab} />}
      {tab === 'invoices' && <InvoiceList manage={manage} internal={internal} />}
      {tab === 'collections' && <Collections />}
      {tab === 'settings' && <BillingSettingsForm />}
      {manage && <NewInvoiceDialog open={creating} onClose={() => setCreating(false)} />}
    </div>
  )
}
