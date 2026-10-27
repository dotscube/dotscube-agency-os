import { Link, useParams } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { ArrowLeft, Printer } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { unwrap } from '@/lib/query'
import { friendlyError } from '@/lib/errors'
import { fmtDate } from '@/lib/utils'
import { amountInWords, fmtAmount } from '@/lib/finance'
import type { Payslip } from '@/lib/types'
import { useAuth } from '@/features/auth/AuthProvider'
import { Button, Card, CardBody, ErrorState, Spinner } from '@/components/ui'

const mask = (acct?: string) => (acct ? `•••• ${acct.slice(-4)}` : '—')

export default function PayslipPage() {
  const { id } = useParams<{ id: string }>()
  const { org } = useAuth()
  const q = useQuery({ queryKey: ['payroll', 'payslip', id], queryFn: async () => unwrap(await supabase.from('payslips').select('*').eq('id', id!).single()) as Payslip })
  const bs = useQuery({ queryKey: ['billing_settings', 'name'], queryFn: async () => (await supabase.from('billing_settings').select('legal_name, address').maybeSingle()).data as { legal_name: string | null; address: string | null } | null })
  if (q.isLoading) return <Spinner />
  if (q.error || !q.data) return <ErrorState message={q.error ? friendlyError(q.error) : 'Payslip not found'} />
  const s = q.data
  const earnings = [...s.earnings.map((e) => ({ label: e.name, amount: e.amount })), ...s.adjustments.filter((a) => a.kind === 'earning').map((a) => ({ label: a.label, amount: a.amount }))]
  const deductions = [...s.deductions.map((e) => ({ label: e.name, amount: e.amount })), ...s.adjustments.filter((a) => a.kind === 'deduction').map((a) => ({ label: a.label, amount: a.amount }))]
  const rows = Math.max(earnings.length, deductions.length, 1)
  return (
    <div className="mx-auto max-w-3xl space-y-4">
      <div className="no-print flex items-center justify-between">
        <Link to="/payroll" className="inline-flex items-center gap-2 text-sm text-muted-foreground hover:text-foreground"><ArrowLeft className="size-4" />Payroll</Link>
        <Button variant="outline" onClick={() => window.print()}><Printer />Print / PDF</Button>
      </div>
      <Card className="print-sheet"><CardBody className="space-y-6">
        <div className="flex flex-col justify-between gap-2 border-b pb-4 sm:flex-row">
          <div><p className="text-lg font-semibold">{bs.data?.legal_name ?? org?.name}</p>{bs.data?.address && <p className="whitespace-pre-line text-xs text-muted-foreground">{bs.data.address}</p>}</div>
          <div className="sm:text-right"><p className="text-xl font-semibold">Payslip</p><p className="text-sm text-muted-foreground">{fmtDate(s.period_month, 'MMMM yyyy')}</p></div>
        </div>
        <dl className="grid grid-cols-2 gap-x-6 gap-y-2 text-sm sm:grid-cols-3">
          {[['Employee', s.employee_name], ['Employee code', s.employee_code], ['Designation', s.designation ?? '—'], ['Department', s.department ?? '—'],
            ['Date of joining', fmtDate(s.joining_date)], ['PAN', s.bank.pan ?? '—'], ['UAN', s.bank.uan ?? '—'], ['Bank', s.bank.bank_name ?? '—'],
            ['Account', mask(s.bank.account_number)], ['Days in month', String(s.days_in_month)], ['Paid days', String(s.payable_days)], ['Unpaid days', String(s.lop_days)]].map(([l, v]) => (
            <div key={l}><dt className="text-xs text-muted-foreground">{l}</dt><dd className="font-medium">{v}</dd></div>))}
        </dl>
        <table className="w-full text-sm">
          <thead><tr className="border-y bg-muted/40 text-left"><th className="px-2 py-2">Earnings</th><th className="px-2 py-2 text-right">Amount</th>
            <th className="border-l px-2 py-2">Deductions</th><th className="px-2 py-2 text-right">Amount</th></tr></thead>
          <tbody>{Array.from({ length: rows }).map((_, i) => (
            <tr key={i} className="border-b">
              <td className="px-2 py-1.5">{earnings[i]?.label ?? ''}</td><td className="px-2 py-1.5 text-right tabular-nums">{earnings[i] ? fmtAmount(earnings[i]!.amount) : ''}</td>
              <td className="border-l px-2 py-1.5">{deductions[i]?.label ?? ''}</td><td className="px-2 py-1.5 text-right tabular-nums">{deductions[i] ? fmtAmount(deductions[i]!.amount) : ''}</td>
            </tr>))}
            <tr className="border-b font-semibold"><td className="px-2 py-2">Gross earnings</td><td className="px-2 py-2 text-right tabular-nums">{fmtAmount(s.gross)}</td>
              <td className="border-l px-2 py-2">Total deductions</td><td className="px-2 py-2 text-right tabular-nums">{fmtAmount(s.total_deductions)}</td></tr>
          </tbody>
        </table>
        <div className="rounded-md bg-muted/50 p-4"><p className="flex justify-between text-base font-semibold"><span>Net pay</span><span className="tabular-nums">{fmtAmount(s.net_pay)}</span></p>
          <p className="text-xs text-muted-foreground">{amountInWords(Number(s.net_pay))}</p></div>
        <p className="text-center text-xs text-muted-foreground">This is a computer-generated payslip and does not need a signature.</p>
      </CardBody></Card>
    </div>
  )
}
