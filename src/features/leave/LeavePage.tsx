import { useEffect, useState } from 'react'
import { useSearchParams } from 'react-router-dom'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useForm, useWatch } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { z } from 'zod'
import { toast } from 'sonner'
import { Download, Plus } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { unwrap } from '@/lib/query'
import { friendlyError } from '@/lib/errors'
import { downloadCsv, fmtDate, titleCase, toCsv } from '@/lib/utils'
import { nameOf, useEmployeesLite, useLeaveTypes } from '@/lib/lookups'
import type { LeaveBalance, LeaveRequest } from '@/lib/types'
import { useAuth } from '@/features/auth/AuthProvider'
import { DataTable } from '@/components/DataTable'
import { Badge, Button, Card, CardBody, CardHeader, Dialog, Field, Input, PageHeader, Select, StatusBadge, Tabs, Textarea } from '@/components/ui'

type Tab = 'mine' | 'approvals' | 'team'

const applySchema = z.object({
  leave_type_id: z.string().uuid('Choose a leave type'),
  start_date: z.string().min(1, 'Required'),
  end_date: z.string().min(1, 'Required'),
  half_day: z.enum(['none', 'first_half', 'second_half']),
  reason: z.string().max(500).optional(),
}).refine((v) => v.end_date >= v.start_date, { message: 'End date is before start date', path: ['end_date'] })
  .refine((v) => v.half_day === 'none' || v.start_date === v.end_date, { message: 'Half day must be a single date', path: ['half_day'] })
type ApplyForm = z.infer<typeof applySchema>

function ApplyDialog({ open, onClose }: { open: boolean; onClose: () => void }) {
  const { data: types } = useLeaveTypes()
  const qc = useQueryClient()
  const form = useForm<ApplyForm>({ resolver: zodResolver(applySchema), defaultValues: { half_day: 'none' } })
  const [start, end, half, typeId] = useWatch({ control: form.control, name: ['start_date', 'end_date', 'half_day', 'leave_type_id'] })
  const [preview, setPreview] = useState<number | null>(null)
  const type = types?.find((t) => t.id === typeId)

  useEffect(() => {
    setPreview(null)
    if (!start || !end || end < start || (half !== 'none' && start !== end)) return
    let live = true
    supabase.rpc('preview_leave_days', { p_start: start, p_end: end, p_half: half }).then(({ data }) => { if (live) setPreview(Number(data)) })
    return () => { live = false }
  }, [start, end, half])

  const submit = form.handleSubmit(async (v) => {
    const { error } = await supabase.rpc('apply_leave', { p_leave_type: v.leave_type_id, p_start: v.start_date, p_end: v.end_date, p_half: v.half_day, p_reason: v.reason ?? null })
    if (error) return toast.error(friendlyError(error))
    toast.success('Leave request submitted')
    qc.invalidateQueries({ queryKey: ['leave'] }); qc.invalidateQueries({ queryKey: ['leave_balances'] })
    form.reset({ half_day: 'none' }); onClose()
  })
  const e = form.formState.errors
  return (
    <Dialog open={open} onClose={onClose} title="Apply for leave"
      footer={<><Button variant="outline" onClick={onClose}>Cancel</Button><Button onClick={submit} loading={form.formState.isSubmitting}>Submit request</Button></>}>
      <form className="grid gap-4 sm:grid-cols-2" onSubmit={submit}>
        <Field label="Leave type" error={e.leave_type_id?.message} className="sm:col-span-2">
          {(p) => <Select {...p} {...form.register('leave_type_id')} defaultValue=""><option value="" disabled>Select…</option>
            {types?.filter((t) => t.is_active).map((t) => <option key={t.id} value={t.id}>{t.name}{t.annual_quota == null ? ' (no balance limit)' : ''}</option>)}</Select>}
        </Field>
        <Field label="From" error={e.start_date?.message}>{(p) => <Input type="date" {...p} {...form.register('start_date')} />}</Field>
        <Field label="To" error={e.end_date?.message}>{(p) => <Input type="date" {...p} {...form.register('end_date')} />}</Field>
        <Field label="Duration" error={e.half_day?.message} className="sm:col-span-2">
          {(p) => <Select {...p} {...form.register('half_day')} disabled={type ? !type.allow_half_day : false}>
            <option value="none">Full day(s)</option><option value="first_half">First half</option><option value="second_half">Second half</option></Select>}
        </Field>
        <Field label="Reason (optional)" error={e.reason?.message} className="sm:col-span-2">{(p) => <Textarea {...p} {...form.register('reason')} />}</Field>
        {preview != null && <p className="text-sm text-muted-foreground sm:col-span-2" aria-live="polite">
          Counts as <strong className="text-foreground">{preview}</strong> working day(s) after weekly offs and holidays.</p>}
      </form>
    </Dialog>
  )
}

export default function LeavePage() {
  const { employee, can } = useAuth()
  const [params, setParams] = useSearchParams()
  const tab = (params.get('tab') as Tab) ?? 'mine'
  const [open, setOpen] = useState(false)
  const { data: types } = useLeaveTypes()
  const { data: people } = useEmployeesLite()
  const qc = useQueryClient()
  const year = new Date().getFullYear()
  const today = new Date().toISOString().slice(0, 10)

  const balances = useQuery({
    queryKey: ['leave_balances', employee?.id, year], enabled: Boolean(employee),
    queryFn: async () => unwrap(await supabase.from('leave_balances').select('*').eq('employee_id', employee!.id).eq('year', year)) as LeaveBalance[],
  })
  const mine = useQuery({
    queryKey: ['leave', 'mine'], enabled: tab === 'mine' && Boolean(employee),
    queryFn: async () => unwrap(await supabase.from('leave_requests').select('*').eq('employee_id', employee!.id).order('start_date', { ascending: false }).limit(50)) as LeaveRequest[],
  })
  const approvals = useQuery({
    queryKey: ['leave', 'approvals'], enabled: tab === 'approvals',
    queryFn: async () => unwrap(await supabase.from('leave_requests').select('*').eq('status', 'pending')
      .neq('employee_id', employee?.id ?? '00000000-0000-0000-0000-000000000000').order('start_date')) as LeaveRequest[],
  })
  const team = useQuery({
    queryKey: ['leave', 'team'], enabled: tab === 'team',
    queryFn: async () => unwrap(await supabase.from('leave_requests').select('*').eq('status', 'approved').gte('end_date', today)
      .neq('employee_id', employee?.id ?? '00000000-0000-0000-0000-000000000000').order('start_date').limit(100)) as LeaveRequest[],
  })

  const invalidate = () => { qc.invalidateQueries({ queryKey: ['leave'] }); qc.invalidateQueries({ queryKey: ['leave_balances'] }); qc.invalidateQueries({ queryKey: ['dashboard'] }) }
  const decide = useMutation({
    mutationFn: async ({ id, approve }: { id: string; approve: boolean }) => unwrap(await supabase.rpc('decide_leave', { p_id: id, p_approve: approve, p_note: null })),
    onSuccess: (r, v) => { const lr = r as LeaveRequest; toast.success(!v.approve ? 'Rejected' : lr.status === 'approved' ? 'Approved' : `Approved — sent to level ${lr.current_level}`); invalidate() },
  })
  const cancel = useMutation({
    mutationFn: async (id: string) => unwrap(await supabase.rpc('cancel_leave', { p_id: id })),
    onSuccess: () => { toast.success('Leave cancelled'); invalidate() },
  })

  const typeName = (id: string) => types?.find((t) => t.id === id)?.name ?? '—'
  const dates = (r: LeaveRequest) => r.start_date === r.end_date
    ? `${fmtDate(r.start_date)}${r.half_day !== 'none' ? ` (${titleCase(r.half_day)})` : ''}` : `${fmtDate(r.start_date)} – ${fmtDate(r.end_date)}`

  const tabs: { value: Tab; label: string; count?: number }[] = [
    { value: 'mine', label: 'My leave' }, { value: 'approvals', label: 'Approvals', count: approvals.data?.length }, { value: 'team', label: 'Upcoming team leave' }]

  return (
    <div className="space-y-6">
      <PageHeader title="Leave" actions={<>
        {can('leave.export') && tab === 'team' && <Button variant="outline" disabled={!team.data?.length} onClick={() => downloadCsv('team-leave.csv', toCsv(
          (team.data ?? []).map((r) => ({ employee: nameOf(people, r.employee_id), type: typeName(r.leave_type_id), start: r.start_date, end: r.end_date, days: r.days })),
          [{ key: 'employee', label: 'Employee' }, { key: 'type', label: 'Type' }, { key: 'start', label: 'Start' }, { key: 'end', label: 'End' }, { key: 'days', label: 'Days' }]))}><Download />Export</Button>}
        <Button onClick={() => setOpen(true)}><Plus />Apply for leave</Button></>} />

      <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
        {types?.filter((t) => t.is_active && t.annual_quota != null).map((t) => {
          const b = balances.data?.find((x) => x.leave_type_id === t.id)
          const allocated = b ? b.allocated + b.adjusted : t.annual_quota!
          const used = b?.used ?? 0
          return (
            <Card key={t.id}><CardBody className="p-4">
              <p className="text-sm text-muted-foreground">{t.name}</p>
              <p className="mt-1 text-2xl font-semibold tabular-nums">{allocated - used}<span className="text-sm font-normal text-muted-foreground"> / {allocated}</span></p>
              <p className="text-xs text-muted-foreground">{used} used in {year}</p>
            </CardBody></Card>
          )
        })}
      </div>

      <Tabs tabs={tabs} value={tab} onChange={(t) => setParams({ tab: t })} />
      {tab === 'mine' && (
        <Card><DataTable rows={mine.data} loading={mine.isLoading} error={mine.error ? friendlyError(mine.error) : null} onRetry={mine.refetch} columns={[
          { key: 't', header: 'Type', render: (r) => typeName(r.leave_type_id) },
          { key: 'd', header: 'Dates', render: dates },
          { key: 'n', header: 'Days', render: (r) => r.days },
          { key: 's', header: 'Status', render: (r) => <span className="flex items-center gap-1"><StatusBadge value={r.status} />
            {r.status === 'pending' && r.required_levels > 1 && <Badge tone="slate">Level {r.current_level}/{r.required_levels}</Badge>}</span> },
          { key: 'a', header: '', render: (r) => (r.status === 'pending' || (r.status === 'approved' && r.start_date > today)) &&
            <Button size="sm" variant="ghost" onClick={() => cancel.mutate(r.id)} disabled={cancel.isPending}>Cancel</Button> },
        ]} /></Card>
      )}
      {tab === 'approvals' && (
        <Card><CardHeader title="Waiting for a decision" description="From people who report to you, or everyone if you approve leave for the agency." />
          <DataTable rows={approvals.data} loading={approvals.isLoading} error={approvals.error ? friendlyError(approvals.error) : null} columns={[
            { key: 'e', header: 'Employee', render: (r) => nameOf(people, r.employee_id) },
            { key: 't', header: 'Type', render: (r) => typeName(r.leave_type_id) },
            { key: 'd', header: 'Dates', render: dates },
            { key: 'n', header: 'Days', render: (r) => r.days },
            { key: 'r', header: 'Reason', render: (r) => <span className="line-clamp-2 max-w-xs">{r.reason ?? '—'}</span> },
            { key: 'l', header: 'Level', render: (r) => `${r.current_level}/${r.required_levels}` },
            { key: 'a', header: '', render: (r) => <div className="flex justify-end gap-2">
              <Button size="sm" variant="outline" disabled={decide.isPending} onClick={() => decide.mutate({ id: r.id, approve: false })}>Reject</Button>
              <Button size="sm" disabled={decide.isPending} onClick={() => decide.mutate({ id: r.id, approve: true })}>Approve</Button></div> },
          ]} /></Card>
      )}
      {tab === 'team' && (
        <Card><DataTable rows={team.data} loading={team.isLoading} error={team.error ? friendlyError(team.error) : null} columns={[
          { key: 'e', header: 'Employee', render: (r) => nameOf(people, r.employee_id) },
          { key: 't', header: 'Type', render: (r) => typeName(r.leave_type_id) },
          { key: 'd', header: 'Dates', render: dates },
          { key: 'n', header: 'Days', render: (r) => r.days },
          { key: 'a', header: '', render: (r) => can('leave.approve') && <Button size="sm" variant="ghost" onClick={() => cancel.mutate(r.id)}>Cancel</Button> },
        ]} /></Card>
      )}
      <ApplyDialog open={open} onClose={() => setOpen(false)} />
    </div>
  )
}
