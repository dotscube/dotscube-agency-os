import { useMemo, useState } from 'react'
import { Link, useNavigate, useParams } from 'react-router-dom'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { toast } from 'sonner'
import { ArrowLeft, Ban, IndianRupee, Pencil, Plus, Printer, Send, Trash2 } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { unwrap } from '@/lib/query'
import { friendlyError } from '@/lib/errors'
import { fmtDate, titleCase } from '@/lib/utils'
import { nameOf, useClientsLite, usePeople } from '@/lib/lookups'
import { GST_RATES, GST_STATES, amountInWords, fmtAmount, invoiceTotals, stateName } from '@/lib/finance'
import type { BillingSettings, ClientBilling, Invoice, InvoiceItem, InvoiceParty, Payment } from '@/lib/types'
import { useAuth } from '@/features/auth/AuthProvider'
import { DataTable } from '@/components/DataTable'
import { Button, Card, CardBody, CardHeader, Dialog, EmptyState, ErrorState, Field, Input, Select, Spinner, Textarea } from '@/components/ui'
import { InvoiceStatusBadge } from './InvoicesPage'

const KIND_LABEL: Record<InvoiceItem['kind'], string> = { management_fee: 'Management fee', ad_spend: 'Ad spend', other: 'Other' }
const METHODS = ['bank_transfer', 'upi', 'cheque', 'cash', 'card', 'other']
const todayIso = () => new Date().toISOString().slice(0, 10)

function Party({ title, p }: { title: string; p: InvoiceParty | null | undefined }) {
  return (
    <div className="text-sm">
      <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">{title}</p>
      <p className="mt-1 font-semibold">{p?.name ?? '—'}</p>
      {p?.address && <p className="whitespace-pre-line text-muted-foreground">{p.address}</p>}
      {p?.gstin && <p>GSTIN: <span className="font-mono">{p.gstin}</span></p>}
      {p?.pan && <p>PAN: <span className="font-mono">{p.pan}</span></p>}
      {p?.state_code && <p>State: {stateName(p.state_code)}</p>}
      {p?.email && <p className="text-muted-foreground">{p.email}</p>}
    </div>
  )
}

/** The invoice as printed. Draft invoices show live details; issued ones show the snapshot taken at issue. */
function InvoiceDocument({ inv, items, seller, buyer }: { inv: Invoice; items: InvoiceItem[]; seller: InvoiceParty | null; buyer: InvoiceParty | null }) {
  const cur = inv.currency
  const rows: [string, number][] = [['Management fees', inv.fee_subtotal], ['Ad spend (pass-through)', inv.ad_spend_subtotal], ['Other', inv.other_subtotal]]
  return (
    <Card className="print-sheet">
      <CardBody className="space-y-6">
        <div className="flex flex-col justify-between gap-4 sm:flex-row">
          <div><h2 className="text-2xl font-semibold tracking-tight">Tax Invoice</h2>
            <p className="text-sm text-muted-foreground">{inv.invoice_number ?? 'Draft — not yet numbered'}</p></div>
          <dl className="grid grid-cols-2 gap-x-4 gap-y-1 text-sm sm:text-right">
            <dt className="text-muted-foreground">Invoice date</dt><dd>{fmtDate(inv.issue_date)}</dd>
            <dt className="text-muted-foreground">Due date</dt><dd>{fmtDate(inv.due_date)}</dd>
            <dt className="text-muted-foreground">Place of supply</dt><dd>{stateName(inv.place_of_supply)}</dd>
            {inv.billing_period && <><dt className="text-muted-foreground">Period</dt><dd>{fmtDate(inv.billing_period + '-01', 'MMMM yyyy')}</dd></>}
          </dl>
        </div>
        <div className="grid gap-6 sm:grid-cols-2"><Party title="From" p={seller} /><Party title="Bill to" p={buyer} /></div>
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead><tr className="border-b text-left text-xs uppercase tracking-wide text-muted-foreground">
              <th className="py-2 pr-2">#</th><th className="py-2 pr-2">Description</th><th className="py-2 pr-2">SAC</th><th className="py-2 pr-2 text-right">Qty</th>
              <th className="py-2 pr-2 text-right">Rate</th><th className="py-2 pr-2 text-right">GST</th><th className="py-2 text-right">Amount</th></tr></thead>
            <tbody>{items.map((it, i) => (
              <tr key={it.id} className="border-b align-top">
                <td className="py-2 pr-2 text-muted-foreground">{i + 1}</td>
                <td className="py-2 pr-2">{it.description}<span className="block text-xs text-muted-foreground">{KIND_LABEL[it.kind]}</span></td>
                <td className="py-2 pr-2 font-mono text-xs">{it.sac ?? '—'}</td>
                <td className="py-2 pr-2 text-right tabular-nums">{Number(it.quantity)}</td>
                <td className="py-2 pr-2 text-right tabular-nums">{fmtAmount(it.unit_price, cur)}</td>
                <td className="py-2 pr-2 text-right tabular-nums">{Number(it.gst_rate)}%</td>
                <td className="py-2 text-right tabular-nums">{fmtAmount(it.amount, cur)}</td>
              </tr>))}</tbody>
          </table>
        </div>
        <div className="flex flex-col gap-6 sm:flex-row sm:justify-between">
          <div className="space-y-1 text-sm sm:max-w-sm">
            {rows.filter(([, v]) => Number(v) > 0).map(([l, v]) => <p key={l} className="flex justify-between gap-6"><span className="text-muted-foreground">{l}</span><span className="tabular-nums">{fmtAmount(v, cur)}</span></p>)}
            <p className="pt-2 text-xs text-muted-foreground">Amount in words: {amountInWords(Number(inv.total))}</p>
          </div>
          <dl className="grid min-w-64 grid-cols-2 gap-y-1 text-sm">
            <dt className="text-muted-foreground">Taxable value</dt><dd className="text-right tabular-nums">{fmtAmount(inv.taxable_total, cur)}</dd>
            {inv.tax_mode === 'intra' ? <>
              <dt className="text-muted-foreground">CGST</dt><dd className="text-right tabular-nums">{fmtAmount(inv.cgst, cur)}</dd>
              <dt className="text-muted-foreground">SGST</dt><dd className="text-right tabular-nums">{fmtAmount(inv.sgst, cur)}</dd>
            </> : <><dt className="text-muted-foreground">IGST</dt><dd className="text-right tabular-nums">{fmtAmount(inv.igst, cur)}</dd></>}
            {Number(inv.round_off) !== 0 && <><dt className="text-muted-foreground">Round off</dt><dd className="text-right tabular-nums">{fmtAmount(inv.round_off, cur)}</dd></>}
            <dt className="border-t pt-1 font-semibold">Total</dt><dd className="border-t pt-1 text-right font-semibold tabular-nums">{fmtAmount(inv.total, cur)}</dd>
            {Number(inv.amount_received) + Number(inv.tds_deducted) > 0 && <>
              <dt className="text-muted-foreground">Received</dt><dd className="text-right tabular-nums">{fmtAmount(inv.amount_received, cur)}</dd>
              {Number(inv.tds_deducted) > 0 && <><dt className="text-muted-foreground">TDS deducted</dt><dd className="text-right tabular-nums">{fmtAmount(inv.tds_deducted, cur)}</dd></>}
              <dt className="font-semibold">Balance due</dt><dd className="text-right font-semibold tabular-nums">{fmtAmount(inv.balance, cur)}</dd>
            </>}
          </dl>
        </div>
        {(inv.notes || seller?.bank_details || seller?.terms) && <div className="grid gap-4 border-t pt-4 text-sm sm:grid-cols-2">
          {seller?.bank_details && <div><p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">Payment details</p><p className="whitespace-pre-line">{seller.bank_details}</p></div>}
          {(inv.notes || seller?.terms) && <div><p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">Notes & terms</p>
            {inv.notes && <p className="whitespace-pre-line">{inv.notes}</p>}{seller?.terms && <p className="whitespace-pre-line text-muted-foreground">{seller.terms}</p>}</div>}
        </div>}
        <p className="text-center text-xs text-muted-foreground">This is a computer-generated invoice.</p>
      </CardBody>
    </Card>
  )
}

function LineDialog({ inv, line, settings, onClose }: { inv: Invoice; line: Partial<InvoiceItem> | null; settings: BillingSettings | null; onClose: () => void }) {
  const qc = useQueryClient()
  const [f, setF] = useState(() => ({ kind: line?.kind ?? 'management_fee', description: line?.description ?? '', sac: line?.sac ?? settings?.default_sac ?? '998361',
    quantity: String(line?.quantity ?? 1), unit_price: line?.unit_price != null ? String(line.unit_price) : '',
    gst_rate: String(line?.gst_rate ?? settings?.default_gst_rate ?? 18) }))
  const save = useMutation({
    mutationFn: async () => {
      const row = { kind: f.kind, description: f.description.trim(), sac: f.sac.trim() || null, quantity: Number(f.quantity), unit_price: Number(f.unit_price), gst_rate: Number(f.gst_rate) }
      return line?.id ? unwrap(await supabase.from('invoice_items').update(row).eq('id', line.id))
        : unwrap(await supabase.from('invoice_items').insert({ ...row, org_id: inv.org_id, invoice_id: inv.id, position: 99 }))
    },
    onSuccess: () => { qc.invalidateQueries({ queryKey: ['invoice', inv.id] }); onClose() },
  })
  const set = (k: keyof typeof f) => (e: { target: { value: string } }) => {
    const next = { ...f, [k]: e.target.value }
    if (k === 'kind' && !line?.id) next.gst_rate = String(e.target.value === 'ad_spend' ? settings?.ad_spend_gst_rate ?? 0 : settings?.default_gst_rate ?? 18)
    setF(next)
  }
  const valid = f.description.trim().length >= 2 && Number(f.quantity) > 0 && f.unit_price !== '' && Number(f.unit_price) >= 0
  return (
    <Dialog open onClose={onClose} title={line?.id ? 'Edit line' : 'Add line'}
      footer={<><Button variant="outline" onClick={onClose}>Cancel</Button><Button disabled={!valid} loading={save.isPending} onClick={() => save.mutate()}>Save</Button></>}>
      <div className="grid gap-4 sm:grid-cols-2">
        <Field label="Type">{(p) => <Select {...p} value={f.kind} onChange={set('kind')}>{Object.entries(KIND_LABEL).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</Select>}</Field>
        <Field label="SAC code">{(p) => <Input {...p} value={f.sac} maxLength={8} onChange={set('sac')} />}</Field>
        <Field label="Description" className="sm:col-span-2">{(p) => <Input {...p} value={f.description} maxLength={500} onChange={set('description')} />}</Field>
        <Field label="Quantity">{(p) => <Input {...p} type="number" min={0.01} step="0.01" value={f.quantity} onChange={set('quantity')} />}</Field>
        <Field label="Rate">{(p) => <Input {...p} type="number" min={0} step="0.01" value={f.unit_price} onChange={set('unit_price')} />}</Field>
        <Field label="GST rate" hint={f.kind === 'ad_spend' ? 'Ad spend passed through at cost is usually 0%' : undefined}>
          {(p) => <Select {...p} value={f.gst_rate} onChange={set('gst_rate')}>{GST_RATES.map((r) => <option key={r} value={r}>{r}%</option>)}</Select>}</Field>
        <div className="self-end text-sm text-muted-foreground">Line amount: <strong className="text-foreground">{fmtAmount(Number(f.quantity || 0) * Number(f.unit_price || 0))}</strong></div>
      </div>
    </Dialog>
  )
}

function PaymentDialog({ inv, onClose }: { inv: Invoice; onClose: () => void }) {
  const qc = useQueryClient()
  const [f, setF] = useState({ amount: String(inv.balance), tds: '0', paid_on: todayIso(), method: 'bank_transfer', reference: '', note: '' })
  const set = (k: keyof typeof f) => (e: { target: { value: string } }) => setF({ ...f, [k]: e.target.value })
  const save = useMutation({
    mutationFn: async () => unwrap(await supabase.rpc('record_payment', { p_invoice: inv.id, p_amount: Number(f.amount || 0), p_paid_on: f.paid_on, p_method: f.method,
      p_reference: f.reference || null, p_tds: Number(f.tds || 0), p_note: f.note || null })),
    onSuccess: () => { toast.success('Payment recorded'); qc.invalidateQueries({ queryKey: ['invoice', inv.id] }); qc.invalidateQueries({ queryKey: ['invoices'] }); onClose() },
  })
  const settled = Number(f.amount || 0) + Number(f.tds || 0)
  return (
    <Dialog open onClose={onClose} title="Record payment" description={`Balance due ${fmtAmount(inv.balance, inv.currency)}`}
      footer={<><Button variant="outline" onClick={onClose}>Cancel</Button><Button disabled={settled <= 0 || settled > Number(inv.balance) + 0.001} loading={save.isPending} onClick={() => save.mutate()}>Save</Button></>}>
      <div className="grid gap-4 sm:grid-cols-2">
        <Field label="Amount received">{(p) => <Input {...p} type="number" min={0} step="0.01" value={f.amount} onChange={set('amount')} />}</Field>
        <Field label="TDS deducted by client" hint="Counts towards settling the invoice">{(p) => <Input {...p} type="number" min={0} step="0.01" value={f.tds} onChange={set('tds')} />}</Field>
        <Field label="Received on">{(p) => <Input {...p} type="date" max={todayIso()} value={f.paid_on} onChange={set('paid_on')} />}</Field>
        <Field label="Method">{(p) => <Select {...p} value={f.method} onChange={set('method')}>{METHODS.map((m) => <option key={m} value={m}>{titleCase(m)}</option>)}</Select>}</Field>
        <Field label="Reference" hint="UTR / cheque number — stops the same payment being entered twice" className="sm:col-span-2">{(p) => <Input {...p} value={f.reference} maxLength={100} onChange={set('reference')} />}</Field>
        <Field label="Note" className="sm:col-span-2">{(p) => <Input {...p} value={f.note} onChange={set('note')} />}</Field>
        {settled > Number(inv.balance) + 0.001 && <p className="text-sm text-destructive sm:col-span-2">That's more than the balance due.</p>}
      </div>
    </Dialog>
  )
}

export default function InvoiceDetailPage() {
  const { id } = useParams<{ id: string }>()
  const navigate = useNavigate()
  const qc = useQueryClient()
  const { audience, can } = useAuth()
  const internal = audience === 'internal'
  const manage = internal && can('invoices.manage')
  const { data: clients } = useClientsLite(internal)
  const { data: people } = usePeople()
  const [editing, setEditing] = useState<Partial<InvoiceItem> | null>(null)
  const [paying, setPaying] = useState(false); const [issuing, setIssuing] = useState(false); const [cancelling, setCancelling] = useState(false)
  const [issueDate, setIssueDate] = useState(todayIso()); const [reason, setReason] = useState('')

  const q = useQuery({ queryKey: ['invoice', id], queryFn: async () => {
    const inv = unwrap(await supabase.from('invoices').select('*').eq('id', id!).single()) as Invoice
    const [items, payments] = await Promise.all([
      supabase.from('invoice_items').select('*').eq('invoice_id', id!).order('position').order('description'),
      supabase.from('payments').select('*').eq('invoice_id', id!).order('paid_on'),
    ])
    return { inv, items: unwrap(items) as InvoiceItem[], payments: unwrap(payments) as Payment[] }
  } })
  const inv = q.data?.inv
  const draft = inv?.status === 'draft'
  const live = useQuery({ queryKey: ['invoice', id, 'live-parties'], enabled: Boolean(draft && internal), queryFn: async () => {
    const [s, b, c] = await Promise.all([supabase.from('billing_settings').select('*').maybeSingle(), supabase.from('client_billing').select('*').eq('client_id', inv!.client_id).maybeSingle(),
      supabase.from('clients').select('name, legal_name').eq('id', inv!.client_id).single()])
    return { settings: s.data as BillingSettings | null, billing: b.data as ClientBilling | null, client: c.data as { name: string; legal_name: string | null } | null }
  } })
  const preview = useMemo(() => q.data ? invoiceTotals(q.data.items.map((i) => ({ kind: i.kind, quantity: i.quantity, unit_price: i.unit_price, gst_rate: i.gst_rate })), inv!.tax_mode) : null, [q.data, inv])
  const invalidate = () => { qc.invalidateQueries({ queryKey: ['invoice', id] }); qc.invalidateQueries({ queryKey: ['invoices'] }) }

  const updateInv = useMutation({ mutationFn: async (patch: Partial<Invoice>) => unwrap(await supabase.from('invoices').update(patch).eq('id', id!)), onSuccess: invalidate })
  const removeLine = useMutation({ mutationFn: async (lineId: string) => unwrap(await supabase.from('invoice_items').delete().eq('id', lineId)), onSuccess: invalidate })
  const issue = useMutation({ mutationFn: async () => unwrap(await supabase.rpc('issue_invoice', { p_invoice: id, p_issue_date: issueDate })),
    onSuccess: () => { toast.success('Invoice issued'); setIssuing(false); invalidate() } })
  const cancel = useMutation({ mutationFn: async () => unwrap(await supabase.rpc('cancel_invoice', { p_invoice: id, p_reason: reason })),
    onSuccess: () => { toast.success('Invoice cancelled'); setCancelling(false); invalidate() } })
  const del = useMutation({ mutationFn: async () => unwrap(await supabase.from('invoices').delete().eq('id', id!)), onSuccess: () => { toast.success('Draft deleted'); navigate('/invoices') } })
  const delPayment = useMutation({ mutationFn: async (pid: string) => unwrap(await supabase.rpc('delete_payment', { p_payment: pid })), onSuccess: invalidate })

  if (q.isLoading) return <Spinner />
  if (q.error || !inv) return <ErrorState message={q.error ? friendlyError(q.error) : 'Invoice not found'} onRetry={q.refetch} />
  const { items, payments } = q.data!
  const s = live.data?.settings
  const seller: InvoiceParty | null = draft ? (s ? { name: s.legal_name ?? undefined, gstin: s.gstin ?? undefined, pan: s.pan ?? undefined, state_code: s.state_code ?? undefined,
    address: s.address ?? undefined, email: s.email ?? undefined, bank_details: s.bank_details ?? undefined, terms: s.terms ?? undefined } : null) : inv.seller
  const b = live.data?.billing
  const buyer: InvoiceParty | null = draft ? { name: b?.billing_name || live.data?.client?.legal_name || live.data?.client?.name, gstin: b?.gst_number ?? undefined,
    address: b?.billing_address ?? undefined, email: b?.billing_email ?? undefined, state_code: inv.place_of_supply ?? undefined } : inv.buyer
  const docInv = draft && preview ? { ...inv, fee_subtotal: preview.fee, ad_spend_subtotal: preview.adSpend, other_subtotal: preview.other, taxable_total: preview.taxable,
    cgst: preview.cgst, sgst: preview.sgst, igst: preview.igst, round_off: preview.roundOff, total: preview.total } : inv
  const open = inv.status === 'issued' || inv.status === 'partially_paid'

  return (
    <div className="space-y-6">
      <div className="no-print flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <div className="flex items-center gap-3">
          <Link to="/invoices" className="inline-flex size-9 items-center justify-center rounded-md hover:bg-muted" aria-label="Back to invoices"><ArrowLeft className="size-4" /></Link>
          <div><h1 className="text-xl font-semibold tracking-tight">{inv.invoice_number ?? 'Draft invoice'}</h1>
            <p className="flex items-center gap-2 text-sm text-muted-foreground">{internal ? nameOf(clients, inv.client_id) : ''}<InvoiceStatusBadge inv={inv} today={todayIso()} /></p></div>
        </div>
        <div className="flex flex-wrap gap-2">
          {!draft && <Button variant="outline" onClick={() => window.print()}><Printer />Print / PDF</Button>}
          {manage && draft && <><Button variant="outline" onClick={() => { if (confirm('Delete this draft?')) del.mutate() }}><Trash2 />Delete draft</Button>
            <Button disabled={!items.length || !preview?.total} onClick={() => setIssuing(true)}><Send />Issue invoice</Button></>}
          {manage && open && <><Button variant="outline" disabled={payments.length > 0} title={payments.length ? 'Remove payments first' : undefined} onClick={() => setCancelling(true)}><Ban />Cancel</Button>
            <Button onClick={() => setPaying(true)}><IndianRupee />Record payment</Button></>}
        </div>
      </div>

      {inv.status === 'cancelled' && <Card className="no-print border-destructive/40"><CardBody className="text-sm">Cancelled on {fmtDate(inv.cancelled_at)}: {inv.cancel_reason}. The number stays used so your invoice series has no gaps.</CardBody></Card>}

      {manage && draft && <Card className="no-print">
        <CardHeader title="Lines" description="Management fees and ad spend are kept apart on the invoice." action={<Button size="sm" onClick={() => setEditing({})}><Plus />Add line</Button>} />
        <DataTable rows={items} empty={<EmptyState title="No lines yet" description="Add your fee, ad spend or other services." />} columns={[
          { key: 'd', header: 'Description', render: (r) => <span><span className="block">{r.description}</span><span className="text-xs text-muted-foreground">{KIND_LABEL[r.kind]}</span></span> },
          { key: 'q', header: 'Qty × rate', render: (r) => `${Number(r.quantity)} × ${fmtAmount(r.unit_price)}` },
          { key: 'g', header: 'GST', render: (r) => `${Number(r.gst_rate)}%` },
          { key: 'a', header: 'Amount', className: 'text-right', render: (r) => <span className="tabular-nums">{fmtAmount(Number(r.quantity) * Number(r.unit_price))}</span> },
          { key: 'x', header: '', className: 'text-right', render: (r) => <span className="flex justify-end gap-1">
            <Button size="icon" variant="ghost" aria-label="Edit line" onClick={() => setEditing(r)}><Pencil /></Button>
            <Button size="icon" variant="ghost" aria-label="Remove line" onClick={() => removeLine.mutate(r.id)}><Trash2 /></Button></span> },
        ]} />
        <CardBody className="grid gap-4 border-t sm:grid-cols-3">
          <Field label="Place of supply" hint={inv.tax_mode === 'inter' ? 'Different state: IGST' : 'Same state: CGST + SGST'}>
            {(p) => <Select {...p} value={inv.place_of_supply ?? ''} onChange={(e) => updateInv.mutate({ place_of_supply: e.target.value || null })}>
              <option value="">Client's state</option>{Object.entries(GST_STATES).map(([k, n]) => <option key={k} value={k}>{n} ({k})</option>)}</Select>}</Field>
          <Field label="Due date" hint="Blank = client's payment terms">{(p) => <Input {...p} type="date" value={inv.due_date ?? ''} onChange={(e) => updateInv.mutate({ due_date: e.target.value || null })} />}</Field>
          <Field label="Notes on invoice">{(p) => <Textarea {...p} className="min-h-9" defaultValue={inv.notes ?? ''} onBlur={(e) => e.target.value !== (inv.notes ?? '') && updateInv.mutate({ notes: e.target.value || null })} />}</Field>
        </CardBody>
        {!live.isLoading && !s?.gstin && !s?.state_code && <CardBody className="border-t text-sm text-amber-700">Add your GSTIN or state in Invoices → Billing settings, so the right GST (CGST+SGST or IGST) is applied.</CardBody>}
      </Card>}

      <InvoiceDocument inv={docInv} items={items} seller={seller} buyer={buyer} />

      {!draft && <Card className="no-print"><CardHeader title="Payments" />
        <DataTable rows={payments} empty={<EmptyState title="No payments recorded" />} columns={[
          { key: 'd', header: 'Date', render: (r) => fmtDate(r.paid_on) },
          { key: 'm', header: 'Method', render: (r) => <span>{titleCase(r.method)}{r.reference && <span className="block text-xs text-muted-foreground">Ref {r.reference}</span>}</span> },
          { key: 'a', header: 'Received', className: 'text-right', render: (r) => <span className="tabular-nums">{fmtAmount(r.amount, inv.currency)}</span> },
          { key: 't', header: 'TDS', className: 'text-right', render: (r) => <span className="tabular-nums">{Number(r.tds_amount) ? fmtAmount(r.tds_amount, inv.currency) : '—'}</span> },
          ...(internal ? [{ key: 'b', header: 'Recorded by', render: (r: Payment) => nameOf(people, r.recorded_by) }] : []),
          ...(manage ? [{ key: 'x', header: '', render: (r: Payment) => <Button size="icon" variant="ghost" aria-label="Remove payment"
            onClick={() => { if (confirm('Remove this payment?')) delPayment.mutate(r.id) }}><Trash2 /></Button> }] : []),
        ]} /></Card>}

      {editing && <LineDialog inv={inv} line={editing} settings={s ?? null} onClose={() => setEditing(null)} />}
      {paying && <PaymentDialog inv={inv} onClose={() => setPaying(false)} />}
      <Dialog open={issuing} onClose={() => setIssuing(false)} title="Issue invoice"
        description="It gets the next number and can't be edited afterwards. If billing e-mail is set up, the client is e-mailed."
        footer={<><Button variant="outline" onClick={() => setIssuing(false)}>Cancel</Button><Button loading={issue.isPending} onClick={() => issue.mutate()}>Issue {preview ? fmtAmount(preview.total) : ''}</Button></>}>
        <Field label="Invoice date" hint="Today, or up to 30 days back">{(p) => <Input {...p} type="date" max={todayIso()} value={issueDate} onChange={(e) => setIssueDate(e.target.value)} />}</Field>
      </Dialog>
      <Dialog open={cancelling} onClose={() => setCancelling(false)} title="Cancel invoice" description="The number stays used. Create a new invoice if you need to re-bill."
        footer={<><Button variant="outline" onClick={() => setCancelling(false)}>Keep it</Button><Button variant="destructive" disabled={reason.trim().length < 5} loading={cancel.isPending} onClick={() => cancel.mutate()}>Cancel invoice</Button></>}>
        <Field label="Reason">{(p) => <Input {...p} value={reason} onChange={(e) => setReason(e.target.value)} />}</Field>
      </Dialog>
    </div>
  )
}
