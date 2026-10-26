import { useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { z } from 'zod'
import { toast } from 'sonner'
import { Download, Plus } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { ilikeTerm, unwrap, unwrapPage } from '@/lib/query'
import { friendlyError } from '@/lib/errors'
import { downloadCsv, fmtDate, titleCase, toCsv } from '@/lib/utils'
import { nameOf, useDepartments, useEmployeesLite } from '@/lib/lookups'
import type { Employee, EmployeeStatus } from '@/lib/types'
import { useAuth } from '@/features/auth/AuthProvider'
import { DataTable, SearchBox, useTableState } from '@/components/DataTable'
import { Avatar, Button, Card, Dialog, Field, Input, PageHeader, Select, StatusBadge } from '@/components/ui'

const STATUSES: EmployeeStatus[] = ['onboarding', 'probation', 'active', 'notice_period', 'exited']

export const employeeSchema = z.object({
  full_name: z.string().trim().min(2, 'Required').max(120),
  work_email: z.string().trim().email('Enter a valid email'),
  work_phone: z.string().trim().max(20).optional().or(z.literal('')),
  designation: z.string().trim().max(80).optional().or(z.literal('')),
  department_id: z.string().optional().or(z.literal('')),
  reporting_manager_id: z.string().optional().or(z.literal('')),
  employment_type: z.enum(['full_time', 'part_time', 'contract', 'intern', 'consultant']),
  status: z.enum(['onboarding', 'probation', 'active', 'notice_period', 'exited']),
  joining_date: z.string().min(1, 'Required'),
  probation_end_date: z.string().optional().or(z.literal('')),
  exit_date: z.string().optional().or(z.literal('')),
  exit_reason: z.string().max(500).optional().or(z.literal('')),
}).refine((v) => !v.probation_end_date || v.probation_end_date >= v.joining_date, { path: ['probation_end_date'], message: 'Must be after joining date' })
  .refine((v) => v.status !== 'exited' || Boolean(v.exit_date), { path: ['exit_date'], message: 'Exit date is required for exited employees' })
  .refine((v) => !v.exit_date || v.exit_date >= v.joining_date, { path: ['exit_date'], message: 'Must be after joining date' })
export type EmployeeForm = z.infer<typeof employeeSchema>

/** Converts empty strings from form inputs to nulls for the database. */
export function toEmployeeRow(v: EmployeeForm) {
  const n = (s?: string) => (s && s.trim() ? s.trim() : null)
  return {
    full_name: v.full_name, work_email: v.work_email.toLowerCase(), work_phone: n(v.work_phone), designation: n(v.designation),
    department_id: n(v.department_id), reporting_manager_id: n(v.reporting_manager_id), employment_type: v.employment_type, status: v.status,
    joining_date: v.joining_date, probation_end_date: n(v.probation_end_date), exit_date: n(v.exit_date), exit_reason: n(v.exit_reason),
  }
}

export function EmployeeFormFields({ form, excludeId }: { form: ReturnType<typeof useForm<EmployeeForm>>; excludeId?: string }) {
  const { data: depts } = useDepartments()
  const { data: people } = useEmployeesLite()
  const e = form.formState.errors
  const r = form.register
  return (
    <div className="grid gap-4 sm:grid-cols-2">
      <Field label="Full name" error={e.full_name?.message}>{(p) => <Input {...p} {...r('full_name')} />}</Field>
      <Field label="Work email" error={e.work_email?.message}>{(p) => <Input type="email" {...p} {...r('work_email')} />}</Field>
      <Field label="Designation" error={e.designation?.message}>{(p) => <Input {...p} {...r('designation')} />}</Field>
      <Field label="Work phone" error={e.work_phone?.message}>{(p) => <Input {...p} {...r('work_phone')} />}</Field>
      <Field label="Department">{(p) => <Select {...p} {...r('department_id')}><option value="">—</option>{depts?.map((d) => <option key={d.id} value={d.id}>{d.name}</option>)}</Select>}</Field>
      <Field label="Reporting manager">{(p) => <Select {...p} {...r('reporting_manager_id')}><option value="">—</option>
        {people?.filter((x) => x.id !== excludeId).map((x) => <option key={x.id} value={x.id}>{x.full_name}</option>)}</Select>}</Field>
      <Field label="Employment type">{(p) => <Select {...p} {...r('employment_type')}>{['full_time', 'part_time', 'contract', 'intern', 'consultant'].map((t) => <option key={t} value={t}>{titleCase(t)}</option>)}</Select>}</Field>
      <Field label="Status">{(p) => <Select {...p} {...r('status')}>{STATUSES.map((s) => <option key={s} value={s}>{titleCase(s)}</option>)}</Select>}</Field>
      <Field label="Joining date" error={e.joining_date?.message}>{(p) => <Input type="date" {...p} {...r('joining_date')} />}</Field>
      <Field label="Probation ends" error={e.probation_end_date?.message}>{(p) => <Input type="date" {...p} {...r('probation_end_date')} />}</Field>
      <Field label="Exit date" error={e.exit_date?.message}>{(p) => <Input type="date" {...p} {...r('exit_date')} />}</Field>
      <Field label="Exit reason">{(p) => <Input {...p} {...r('exit_reason')} />}</Field>
    </div>
  )
}

function CreateEmployeeDialog({ open, onClose }: { open: boolean; onClose: () => void }) {
  const { org } = useAuth()
  const qc = useQueryClient()
  const navigate = useNavigate()
  const form = useForm<EmployeeForm>({ resolver: zodResolver(employeeSchema), defaultValues: { employment_type: 'full_time', status: 'onboarding', joining_date: new Date().toISOString().slice(0, 10) } })
  const submit = form.handleSubmit(async (v) => {
    const { data, error } = await supabase.from('employee_profiles').insert({ ...toEmployeeRow(v), org_id: org!.id, employee_code: '' }).select('id, employee_code').single()
    if (error) return toast.error(friendlyError(error))
    toast.success(`Employee ${data.employee_code} created`)
    qc.invalidateQueries({ queryKey: ['employees'] }); qc.invalidateQueries({ queryKey: ['employees-lite'] })
    form.reset(); onClose(); navigate(`/employees/${data.id}`)
  })
  return (
    <Dialog open={open} onClose={onClose} title="Add employee" description="An employee ID is generated automatically." wide
      footer={<><Button variant="outline" onClick={onClose}>Cancel</Button><Button onClick={submit} loading={form.formState.isSubmitting}>Create</Button></>}>
      <form onSubmit={submit}><EmployeeFormFields form={form} /></form>
    </Dialog>
  )
}

export default function EmployeesPage() {
  const { can } = useAuth()
  const navigate = useNavigate()
  const t = useTableState({ sort: { column: 'full_name', ascending: true } })
  const status = t.params.get('status') ?? ''
  const dept = t.params.get('dept') ?? ''
  const [open, setOpen] = useState(false)
  const { data: depts } = useDepartments()
  const { data: people } = useEmployeesLite()

  const buildQuery = (count: boolean) => {
    let q = supabase.from('employee_profiles').select('*', count ? { count: 'exact' } : undefined)
    if (t.search) q = q.or(`full_name.ilike.${ilikeTerm(t.search)},employee_code.ilike.${ilikeTerm(t.search)},work_email.ilike.${ilikeTerm(t.search)}`)
    if (status) q = q.eq('status', status); else q = q.neq('status', 'exited')
    if (dept) q = q.eq('department_id', dept)
    return q.order(t.sort!.column, { ascending: t.sort!.ascending })
  }
  const list = useQuery({
    queryKey: ['employees', t.search, status, dept, t.sort, t.page],
    queryFn: async () => unwrapPage(await buildQuery(true).range((t.page - 1) * t.pageSize, t.page * t.pageSize - 1)) as { rows: Employee[]; total: number },
  })

  const exportCsv = async () => {
    const rows = unwrap(await buildQuery(false).limit(5000)) as Employee[]
    downloadCsv('employees.csv', toCsv(rows.map((r) => ({ ...r, department: nameOf(depts, r.department_id), manager: nameOf(people, r.reporting_manager_id) })), [
      { key: 'employee_code', label: 'Employee ID' }, { key: 'full_name', label: 'Name' }, { key: 'work_email', label: 'Email' }, { key: 'designation', label: 'Designation' },
      { key: 'department', label: 'Department' }, { key: 'manager', label: 'Reporting manager' }, { key: 'employment_type', label: 'Type' }, { key: 'status', label: 'Status' },
      { key: 'joining_date', label: 'Joining date' }]))
  }

  return (
    <div>
      <PageHeader title="Employees" description="Directory of everyone at the agency." actions={<>
        {can('employees.export') && <Button variant="outline" onClick={exportCsv}><Download />Export</Button>}
        {can('employees.create') && <Button onClick={() => setOpen(true)}><Plus />Add employee</Button>}</>} />
      <Card>
        <div className="flex flex-col gap-2 border-b p-3 sm:flex-row">
          <SearchBox value={t.search} onChange={t.setSearch} placeholder="Search name, ID, email" />
          <Select aria-label="Status" className="sm:w-44" value={status} onChange={(e) => t.setFilter('status', e.target.value)}>
            <option value="">Current employees</option>{STATUSES.map((s) => <option key={s} value={s}>{titleCase(s)}</option>)}</Select>
          <Select aria-label="Department" className="sm:w-48" value={dept} onChange={(e) => t.setFilter('dept', e.target.value)}>
            <option value="">All departments</option>{depts?.map((d) => <option key={d.id} value={d.id}>{d.name}</option>)}</Select>
        </div>
        <DataTable rows={list.data?.rows} total={list.data?.total} loading={list.isLoading} error={list.error ? friendlyError(list.error) : null} onRetry={list.refetch}
          page={t.page} pageSize={t.pageSize} onPageChange={t.setPage} sort={t.sort} onSortChange={t.setSort} onRowClick={(r) => navigate(`/employees/${r.id}`)}
          columns={[
            { key: 'name', header: 'Name', sortKey: 'full_name', render: (r) => <span className="flex items-center gap-3"><Avatar name={r.full_name} />
              <span><span className="block font-medium">{r.full_name}</span><span className="text-xs text-muted-foreground">{r.work_email}</span></span></span> },
            { key: 'code', header: 'ID', sortKey: 'employee_code', render: (r) => <span className="font-mono text-xs">{r.employee_code}</span> },
            { key: 'des', header: 'Designation', render: (r) => r.designation ?? '—' },
            { key: 'dept', header: 'Department', render: (r) => nameOf(depts, r.department_id) },
            { key: 'mgr', header: 'Manager', render: (r) => nameOf(people, r.reporting_manager_id) },
            { key: 'join', header: 'Joined', sortKey: 'joining_date', render: (r) => fmtDate(r.joining_date) },
            { key: 'st', header: 'Status', sortKey: 'status', render: (r) => <StatusBadge value={r.status} /> },
          ]} />
      </Card>
      <CreateEmployeeDialog open={open} onClose={() => setOpen(false)} />
    </div>
  )
}
