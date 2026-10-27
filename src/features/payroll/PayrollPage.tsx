import { useState } from 'react'
import { Link, useNavigate, useSearchParams } from 'react-router-dom'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { toast } from 'sonner'
import { AlertTriangle, ArrowLeft, CheckCircle2, Download, Plus, RefreshCw, RotateCcw, Trash2, Wallet } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { unwrap } from '@/lib/query'
import { friendlyError } from '@/lib/errors'
import { downloadCsv, fmtDate, toCsv } from '@/lib/utils'
import { bankSheet, fmtAmount } from '@/lib/finance'
import type { PayrollRun, Payslip, PayslipAdjustment } from '@/lib/types'
import { useAuth } from '@/features/auth/AuthProvider'
import { DataTable } from '@/components/DataTable'
import { Badge, Button, Card, CardBody, CardHeader, Dialog, EmptyState, ErrorState, Field, Input, PageHeader, Select, Spinner, Tabs } from '@/components/ui'

const STATUS_TONE = { draft: 'slate', finalized: 'blue', paid: 'green' } as const
const month = (d: string) => fmtDate(d, 'MMMM yyyy')
const todayIso = () => new Date().toISOString().slice(0, 10)

function RunBadge({ s }: { s: PayrollRun['status'] }) {
  return <Badge tone={STATUS_TONE[s]}>{s === 'finalized' ? 'Finalized' : s === 'paid' ? 'Paid' : 'Draft'}</Badge>
}

function NewRunDialog({ open, onClose }: { open: boolean; onClose: () => void }) {
  const [, setParams] = useSearchParams()
  const qc = useQueryClient()
  const last = new Date(); last.setDate(1); last.setMonth(last.getMonth() - 1)
  const [m, setM] = useState(last.toISOString().slice(0, 7)); const [absent, setAbsent] = useState(false)
  const create = useMutation({
    mutationFn: async () => unwrap(await supabase.rpc('create_payroll_run', { p_month: `${m}-01`, p_absent_as_lop: absent })) as string,
    onSuccess: (id) => { qc.invalidateQueries({ queryKey: ['payroll'] }); onClose(); setParams({ run: id }) },
  })
  return (
    <Dialog open={open} onClose={onClose} title="Run payroll" description="Creates a draft with a payslip for everyone employed that month who has a salary structure."
      footer={<><Button variant="outline" onClick={onClose}>Cancel</Button><Button disabled={!m} loading={create.isPending} onClick={() => create.mutate()}>Calculate</Button></>}>
      <div className="space-y-4 text-sm">
        <Field label="Month">{(p) => <Input {...p} type="month" max={todayIso().slice(0, 7)} value={m} onChange={(e) => setM(e.target.value)} />}</Field>
        <label className="flex items-start gap-2"><input type="checkbox" className="mt-0.5" checked={absent} onChange={(e) => setAbsent(e.target.checked)} />
          <span>Also deduct working days with no attendance and no approved leave<span className="block text-xs text-muted-foreground">
            Leave without pay is always deducted. Turn this on only if everyone checks in daily.</span></span></label>
        <p className="text-xs text-muted-foreground">Pay = monthly component × payable days ÷ days in the month. PF, ESI, PT and TDS aren't calculated automatically: put them in the salary structure or add them as deductions, and have your accountant check them.</p>
      </div>
    </Dialog>
  )
}

function AdjustDialog({ slip, editable, onClose }: { slip: Payslip; editable: boolean; onClose: () => void }) {
  const qc = useQueryClient()
  const [rows, setRows] = useState<PayslipAdjustment[]>(slip.adjustments ?? [])
  const save = useMutation({
    mutationFn: async () => unwrap(await supabase.rpc('set_payslip_adjustments', { p_payslip: slip.id, p_adjustments: rows.map((r) => ({ ...r, amount: Number(r.amount) })) })),
    onSuccess: () => { toast.success('Payslip updated'); qc.invalidateQueries({ queryKey: ['payroll'] }); onClose() },
  })
  const set = (i: number, patch: Partial<PayslipAdjustment>) => setRows(rows.map((r, j) => (j === i ? { ...r, ...patch } : r)))
  const valid = rows.every((r) => r.label.trim().length >= 2 && Number(r.amount) > 0)
  return (
    <Dialog open onClose={onClose} wide title={`${slip.employee_name} · ${month(slip.period_month)}`}
      description={`${slip.payable_days} of ${slip.days_in_month} days payable${Number(slip.lop_days) ? ` · ${slip.lop_days} unpaid (${slip.unpaid_leave_days} leave, ${slip.absent_days} absent)` : ''}`}
      footer={<><Link to={`/payroll/payslips/${slip.id}`} className="mr-auto self-center text-sm text-primary hover:underline">Open payslip</Link>
        <Button variant="outline" onClick={onClose}>Close</Button>{editable && <Button disabled={!valid} loading={save.isPending} onClick={() => save.mutate()}>Save</Button>}</>}>
      <div className="space-y-4 text-sm">
        <div className="grid gap-4 sm:grid-cols-2">
          {(['earnings', 'deductions'] as const).map((k) => (
            <div key={k}><p className="mb-1 font-medium capitalize">{k}</p>
              <ul className="divide-y rounded-md border">{slip[k].length ? slip[k].map((c) => (
                <li key={c.code} className="flex justify-between px-3 py-1.5"><span>{c.name}<span className="block text-xs text-muted-foreground">of {fmtAmount(c.full)}</span></span>
                  <span className="tabular-nums">{fmtAmount(c.amount)}</span></li>)) : <li className="px-3 py-1.5 text-muted-foreground">None</li>}</ul></div>))}
        </div>
        <div>
          <p className="mb-1 font-medium">One-off adjustments</p>
          <p className="mb-2 text-xs text-muted-foreground">Bonus, incentive, reimbursement, advance recovery, TDS…</p>
          <div className="space-y-2">{rows.map((r, i) => (
            <div key={i} className="grid grid-cols-[1fr_8rem_8rem_auto] gap-2">
              <Input aria-label="Label" placeholder="Label" disabled={!editable} value={r.label} onChange={(e) => set(i, { label: e.target.value })} />
              <Select aria-label="Type" disabled={!editable} value={r.kind} onChange={(e) => set(i, { kind: e.target.value as PayslipAdjustment['kind'] })}><option value="earning">Earning</option><option value="deduction">Deduction</option></Select>
              <Input aria-label="Amount" type="number" min={0} step="0.01" disabled={!editable} value={r.amount} onChange={(e) => set(i, { amount: e.target.value as unknown as number })} />
              {editable && <Button variant="ghost" size="icon" aria-label="Remove adjustment" onClick={() => setRows(rows.filter((_, j) => j !== i))}><Trash2 /></Button>}
            </div>))}</div>
          {editable && rows.length < 20 && <Button className="mt-2" size="sm" variant="outline" onClick={() => setRows([...rows, { label: '', kind: 'earning', amount: 0 }])}><Plus />Add adjustment</Button>}
        </div>
        <p className="text-right">Gross {fmtAmount(slip.gross)} · Deductions {fmtAmount(slip.total_deductions)} · <strong>Net {fmtAmount(slip.net_pay)}</strong>
          {editable && <span className="block text-xs text-muted-foreground">Totals refresh after you save.</span>}</p>
      </div>
    </Dialog>
  )
}

function RunDetail({ id }: { id: string }) {
  const { can } = useAuth()
  const runner = can('payroll.run')
  const qc = useQueryClient()
  const [, setParams] = useSearchParams()
  const [slip, setSlip] = useState<Payslip | null>(null)
  const [paidOn, setPaidOn] = useState(todayIso()); const [paying, setPaying] = useState(false)
  const q = useQuery({ queryKey: ['payroll', 'run', id], queryFn: async () => {
    const run = unwrap(await supabase.from('payroll_runs').select('*').eq('id', id).single()) as PayrollRun
    const slips = unwrap(await supabase.from('payslips').select('*').eq('run_id', id).order('employee_code')) as Payslip[]
    return { run, slips }
  } })
  const inv = () => qc.invalidateQueries({ queryKey: ['payroll'] })
  const act = useMutation({
    mutationFn: async (fn: 'recalculate_payroll_run' | 'finalize_payroll_run' | 'reopen_payroll_run' | 'delete_payroll_run' | 'mark_payroll_paid') =>
      unwrap(await supabase.rpc(fn, fn === 'mark_payroll_paid' ? { p_run: id, p_paid_on: paidOn } : { p_run: id })),
    onSuccess: (_, fn) => {
      inv()
      if (fn === 'delete_payroll_run') { setParams({}); toast.success('Draft deleted') }
      else toast.success({ recalculate_payroll_run: 'Recalculated', finalize_payroll_run: 'Finalized — employees can now see their payslips', reopen_payroll_run: 'Reopened as draft', mark_payroll_paid: 'Marked as paid' }[fn])
      setPaying(false)
    },
  })
  if (q.isLoading) return <Spinner />
  if (q.error || !q.data) return <ErrorState message={friendlyError(q.error)} onRetry={q.refetch} />
  const { run, slips } = q.data
  const draft = run.status === 'draft'
  const exportRegister = () => downloadCsv(`payroll-${run.period_month.slice(0, 7)}.csv`, toCsv(slips.map((s) => ({ ...s,
    earnings: s.earnings.map((e) => `${e.code} ${e.amount}`).join('; '), deductions: s.deductions.map((e) => `${e.code} ${e.amount}`).join('; '),
    adjustments: s.adjustments.map((a) => `${a.kind === 'deduction' ? '-' : '+'}${a.amount} ${a.label}`).join('; ') })), [
    { key: 'employee_code', label: 'Code' }, { key: 'employee_name', label: 'Name' }, { key: 'designation', label: 'Designation' }, { key: 'days_in_month', label: 'Days' },
    { key: 'payable_days', label: 'Payable days' }, { key: 'lop_days', label: 'Unpaid days' }, { key: 'earnings', label: 'Earnings' }, { key: 'deductions', label: 'Deductions' },
    { key: 'adjustments', label: 'Adjustments' }, { key: 'gross', label: 'Gross' }, { key: 'total_deductions', label: 'Total deductions' }, { key: 'net_pay', label: 'Net pay' }]))
  const sheet = bankSheet(slips)
  const exportBank = () => downloadCsv(`salary-transfer-${run.period_month.slice(0, 7)}.csv`, toCsv(sheet, [
    { key: 'employee_code', label: 'Employee code' }, { key: 'employee_name', label: 'Beneficiary name' }, { key: 'bank_name', label: 'Bank' },
    { key: 'account_number', label: 'Account number' }, { key: 'ifsc', label: 'IFSC' }, { key: 'amount', label: 'Amount' }, { key: 'missing_bank', label: 'Bank details missing' }]))
  const missingBank = sheet.filter((r) => r.missing_bank).length
  return (
    <div className="space-y-6">
      <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <div className="flex items-center gap-3">
          <Button variant="ghost" size="icon" aria-label="All payroll runs" onClick={() => setParams({})}><ArrowLeft /></Button>
          <div><h2 className="text-lg font-semibold">{month(run.period_month)}</h2>
            <p className="flex items-center gap-2 text-sm text-muted-foreground"><RunBadge s={run.status} />{run.paid_on && `paid ${fmtDate(run.paid_on)}`}{run.absent_as_lop && ' · absences deducted'}</p></div>
        </div>
        <div className="flex flex-wrap gap-2">
          <Button variant="outline" onClick={exportRegister}><Download />Register</Button>
          {!draft && <Button variant="outline" onClick={exportBank}><Download />Bank transfer sheet</Button>}
          {runner && draft && <>
            <Button variant="outline" onClick={() => { if (confirm('Delete this draft run?')) act.mutate('delete_payroll_run') }}><Trash2 />Delete</Button>
            <Button variant="outline" loading={act.isPending && act.variables === 'recalculate_payroll_run'} onClick={() => act.mutate('recalculate_payroll_run')}><RefreshCw />Recalculate</Button>
            <Button disabled={!slips.length} onClick={() => { if (confirm('Finalize? Employees will be able to see their payslips.')) act.mutate('finalize_payroll_run') }}><CheckCircle2 />Finalize</Button></>}
          {runner && run.status === 'finalized' && <>
            <Button variant="outline" onClick={() => act.mutate('reopen_payroll_run')}><RotateCcw />Reopen</Button>
            <Button onClick={() => setPaying(true)}><Wallet />Mark as paid</Button></>}
        </div>
      </div>
      <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
        {[['Employees', String(run.employees_count)], ['Gross', fmtAmount(run.gross_total)], ['Deductions', fmtAmount(run.deductions_total)], ['Net pay', fmtAmount(run.net_total)]].map(([l, v]) => (
          <div key={l} className="rounded-lg border bg-card p-4"><p className="text-xs text-muted-foreground">{l}</p><p className="mt-1 text-xl font-semibold tabular-nums">{v}</p></div>))}
      </div>
      {run.missing_salary.length > 0 && <Card className="border-amber-300"><CardBody className="flex gap-3 text-sm">
        <AlertTriangle className="size-5 shrink-0 text-amber-600" />
        <div><p className="font-medium">Not included: no salary structure</p><p className="text-muted-foreground">{run.missing_salary.map((m) => `${m.name} (${m.code})`).join(', ')}.
          Add a salary revision on their employee page{draft ? ', then Recalculate' : ''}.</p></div></CardBody></Card>}
      {!draft && missingBank > 0 && <p className="text-sm text-amber-700">{missingBank} employee(s) have no bank account or IFSC in their private details; the transfer sheet marks them.</p>}
      <Card><DataTable rows={slips} onRowClick={setSlip} empty={<EmptyState title="No payslips" description="Nobody employed this month has a salary structure yet." />} columns={[
        { key: 'e', header: 'Employee', render: (s) => <span><span className="block font-medium">{s.employee_name}</span><span className="text-xs text-muted-foreground">{s.employee_code}{s.designation ? ` · ${s.designation}` : ''}</span></span> },
        { key: 'd', header: 'Payable days', render: (s) => <span className="tabular-nums">{s.payable_days}/{s.days_in_month}{Number(s.lop_days) > 0 && <Badge tone="amber" className="ml-2">{s.lop_days} unpaid</Badge>}</span> },
        { key: 'g', header: 'Gross', className: 'text-right', render: (s) => <span className="tabular-nums">{fmtAmount(s.gross)}</span> },
        { key: 'x', header: 'Deductions', className: 'text-right', render: (s) => <span className="tabular-nums">{fmtAmount(s.total_deductions)}</span> },
        { key: 'n', header: 'Net pay', className: 'text-right', render: (s) => <span className={`font-medium tabular-nums ${Number(s.net_pay) < 0 ? 'text-destructive' : ''}`}>{fmtAmount(s.net_pay)}</span> },
        { key: 'a', header: '', render: (s) => s.adjustments.length > 0 && <Badge tone="blue">{s.adjustments.length} adj.</Badge> },
      ]} /></Card>
      {slip && <AdjustDialog slip={slip} editable={runner && draft} onClose={() => setSlip(null)} />}
      <Dialog open={paying} onClose={() => setPaying(false)} title="Mark payroll as paid" footer={<><Button variant="outline" onClick={() => setPaying(false)}>Cancel</Button>
        <Button loading={act.isPending} onClick={() => act.mutate('mark_payroll_paid')}>Mark paid</Button></>}>
        <Field label="Salaries paid on">{(p) => <Input {...p} type="date" max={todayIso()} value={paidOn} onChange={(e) => setPaidOn(e.target.value)} />}</Field>
      </Dialog>
    </div>
  )
}

function Runs() {
  const { can } = useAuth()
  const [params, setParams] = useSearchParams()
  const [creating, setCreating] = useState(false)
  const runId = params.get('run')
  const q = useQuery({ queryKey: ['payroll', 'runs'], enabled: !runId,
    queryFn: async () => unwrap(await supabase.from('payroll_runs').select('*').order('period_month', { ascending: false })) as PayrollRun[] })
  if (runId) return <RunDetail id={runId} />
  return (
    <div className="space-y-4">
      {can('payroll.run') && <div className="flex justify-end"><Button onClick={() => setCreating(true)}><Plus />Run payroll</Button></div>}
      <Card><DataTable rows={q.data} loading={q.isLoading} error={q.error ? friendlyError(q.error) : null} onRowClick={(r) => setParams({ run: r.id })}
        empty={<EmptyState title="No payroll runs yet" description={can('payroll.run') ? 'Run payroll for last month to get started.' : undefined} />} columns={[
          { key: 'm', header: 'Month', render: (r) => <span className="font-medium">{month(r.period_month)}</span> },
          { key: 's', header: 'Status', render: (r) => <RunBadge s={r.status} /> },
          { key: 'e', header: 'Employees', render: (r) => r.employees_count },
          { key: 'g', header: 'Gross', className: 'text-right', render: (r) => <span className="tabular-nums">{fmtAmount(r.gross_total)}</span> },
          { key: 'n', header: 'Net pay', className: 'text-right', render: (r) => <span className="tabular-nums">{fmtAmount(r.net_total)}</span> },
          { key: 'p', header: 'Paid on', render: (r) => fmtDate(r.paid_on) },
        ]} /></Card>
      <NewRunDialog open={creating} onClose={() => setCreating(false)} />
    </div>
  )
}

function MyPayslips() {
  const { employee } = useAuth()
  const navigate = useNavigate()
  const q = useQuery({ queryKey: ['payroll', 'mine'], enabled: Boolean(employee),
    queryFn: async () => unwrap(await supabase.from('payslips').select('id, period_month, payable_days, days_in_month, gross, total_deductions, net_pay, run_id')
      .eq('employee_id', employee!.id).order('period_month', { ascending: false })) as Payslip[] })
  if (!employee) return <EmptyState title="No employee record linked to your account" />
  return (
    <Card><CardHeader title="My payslips" description="Payslips appear here once payroll for the month is finalized." />
      <DataTable rows={q.data} loading={q.isLoading} error={q.error ? friendlyError(q.error) : null} onRowClick={(r) => navigate(`/payroll/payslips/${r.id}`)}
        empty={<EmptyState title="No payslips yet" />} columns={[
          { key: 'm', header: 'Month', render: (r) => <span className="font-medium">{month(r.period_month)}</span> },
          { key: 'd', header: 'Paid days', render: (r) => `${r.payable_days}/${r.days_in_month}` },
          { key: 'g', header: 'Gross', className: 'text-right', render: (r) => <span className="tabular-nums">{fmtAmount(r.gross)}</span> },
          { key: 'n', header: 'Net pay', className: 'text-right', render: (r) => <span className="font-medium tabular-nums">{fmtAmount(r.net_pay)}</span> },
        ]} /></Card>
  )
}

export default function PayrollPage() {
  const { can } = useAuth()
  const staff = can(['payroll.view', 'payroll.run'], 'any')
  const [tab, setTab] = useState<'runs' | 'mine'>(staff ? 'runs' : 'mine')
  return (
    <div className="space-y-6">
      <PageHeader title="Payroll" description={staff ? 'Monthly payroll from salary structures, joining dates and leave without pay.' : 'Your monthly payslips.'} />
      {staff && <Tabs tabs={[{ value: 'runs', label: 'Payroll runs' }, { value: 'mine', label: 'My payslips' }]} value={tab} onChange={setTab} />}
      {tab === 'runs' && staff ? <Runs /> : <MyPayslips />}
    </div>
  )
}
