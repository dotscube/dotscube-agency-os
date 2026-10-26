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
import { nameOf, useEmployeesLite } from '@/lib/lookups'
import type { Client, ClientStatus } from '@/lib/types'
import { useAuth } from '@/features/auth/AuthProvider'
import { DataTable, SearchBox, useTableState } from '@/components/DataTable'
import { Badge, Button, Card, Dialog, Field, Input, PageHeader, Select, StatusBadge, Textarea } from '@/components/ui'

export const CLIENT_STATUSES: ClientStatus[] = ['lead', 'onboarding', 'active', 'paused', 'churned']

export const clientSchema = z.object({
  name: z.string().trim().min(2, 'Required').max(160),
  legal_name: z.string().max(200).optional(), industry: z.string().max(80).optional(), city: z.string().max(80).optional(),
  website: z.string().trim().url('Enter a full URL, e.g. https://example.com').optional().or(z.literal('')),
  status: z.enum(['lead', 'onboarding', 'active', 'paused', 'churned']),
  account_manager_id: z.string().optional(), brand_guidelines: z.string().max(5000).optional(),
})
export type ClientForm = z.infer<typeof clientSchema>
export const toClientRow = (v: ClientForm) => Object.fromEntries(Object.entries(v).map(([k, x]) => [k, x === '' || x === undefined ? null : x]))

export function ClientFormFields({ form }: { form: ReturnType<typeof useForm<ClientForm>> }) {
  const { data: people } = useEmployeesLite()
  const e = form.formState.errors
  const r = form.register
  return (
    <div className="grid gap-4 sm:grid-cols-2">
      <Field label="Client name" error={e.name?.message}>{(p) => <Input {...p} {...r('name')} />}</Field>
      <Field label="Legal name">{(p) => <Input {...p} {...r('legal_name')} />}</Field>
      <Field label="Industry">{(p) => <Input {...p} {...r('industry')} />}</Field>
      <Field label="City">{(p) => <Input {...p} {...r('city')} />}</Field>
      <Field label="Website" error={e.website?.message}>{(p) => <Input {...p} placeholder="https://" {...r('website')} />}</Field>
      <Field label="Status">{(p) => <Select {...p} {...r('status')}>{CLIENT_STATUSES.map((s) => <option key={s} value={s}>{titleCase(s)}</option>)}</Select>}</Field>
      <Field label="Account manager" className="sm:col-span-2">{(p) => <Select {...p} {...r('account_manager_id')}><option value="">—</option>
        {people?.map((x) => <option key={x.id} value={x.id}>{x.full_name}</option>)}</Select>}</Field>
      <Field label="Brand guidelines / notes for the team" className="sm:col-span-2">{(p) => <Textarea rows={4} {...p} {...r('brand_guidelines')} />}</Field>
    </div>
  )
}

function CreateClientDialog({ open, onClose }: { open: boolean; onClose: () => void }) {
  const { org, session } = useAuth()
  const qc = useQueryClient()
  const navigate = useNavigate()
  const form = useForm<ClientForm>({ resolver: zodResolver(clientSchema), defaultValues: { status: 'onboarding' } })
  const submit = form.handleSubmit(async (v) => {
    const { data, error } = await supabase.from('clients').insert({ ...toClientRow(v), org_id: org!.id, created_by: session!.user.id }).select('id').single()
    if (error) return toast.error(friendlyError(error))
    toast.success('Client created with onboarding checklist')
    qc.invalidateQueries({ queryKey: ['clients'] }); qc.invalidateQueries({ queryKey: ['clients-lite'] })
    form.reset(); onClose(); navigate(`/clients/${data.id}`)
  })
  return (
    <Dialog open={open} onClose={onClose} title="New client" wide
      footer={<><Button variant="outline" onClick={onClose}>Cancel</Button><Button onClick={submit} loading={form.formState.isSubmitting}>Create client</Button></>}>
      <form onSubmit={submit}><ClientFormFields form={form} /></form>
    </Dialog>
  )
}

export default function ClientsPage() {
  const { can } = useAuth()
  const navigate = useNavigate()
  const t = useTableState({ sort: { column: 'name', ascending: true } })
  const status = t.params.get('status') ?? ''
  const renewals = t.params.get('renewals') === '1'
  const [open, setOpen] = useState(false)
  const { data: people } = useEmployeesLite()

  const renewalIds = useQuery({
    queryKey: ['contracts', 'renewals'], enabled: renewals,
    queryFn: async () => {
      const today = new Date(); const until = new Date(Date.now() + 45 * 86400_000)
      const rows = unwrap(await supabase.from('contracts').select('client_id, end_date').eq('status', 'active')
        .gte('end_date', today.toISOString().slice(0, 10)).lte('end_date', until.toISOString().slice(0, 10))) as { client_id: string; end_date: string }[]
      return rows
    },
  })

  const buildQuery = (count: boolean) => {
    let q = supabase.from('clients').select('*', count ? { count: 'exact' } : undefined)
    if (t.search) q = q.or(`name.ilike.${ilikeTerm(t.search)},industry.ilike.${ilikeTerm(t.search)},city.ilike.${ilikeTerm(t.search)}`)
    if (status) q = q.eq('status', status)
    if (renewals) q = q.in('id', renewalIds.data?.map((r) => r.client_id) ?? [])
    return q.order(t.sort!.column, { ascending: t.sort!.ascending })
  }
  const list = useQuery({
    queryKey: ['clients', t.search, status, renewals, renewalIds.data, t.sort, t.page], enabled: !renewals || Boolean(renewalIds.data),
    queryFn: async () => unwrapPage(await buildQuery(true).range((t.page - 1) * t.pageSize, t.page * t.pageSize - 1)) as { rows: Client[]; total: number },
  })
  const exportCsv = async () => {
    const rows = unwrap(await buildQuery(false).limit(5000)) as Client[]
    downloadCsv('clients.csv', toCsv(rows.map((r) => ({ ...r, manager: nameOf(people, r.account_manager_id) })), [
      { key: 'name', label: 'Client' }, { key: 'status', label: 'Status' }, { key: 'industry', label: 'Industry' }, { key: 'city', label: 'City' },
      { key: 'website', label: 'Website' }, { key: 'manager', label: 'Account manager' }, { key: 'created_at', label: 'Created' }]))
  }

  return (
    <div>
      <PageHeader title="Clients" actions={<>
        {can('clients.export') && <Button variant="outline" onClick={exportCsv}><Download />Export</Button>}
        {can('clients.create') && <Button onClick={() => setOpen(true)}><Plus />New client</Button>}</>} />
      <Card>
        <div className="flex flex-col gap-2 border-b p-3 sm:flex-row sm:items-center">
          <SearchBox value={t.search} onChange={t.setSearch} placeholder="Search clients" />
          <Select aria-label="Status" className="sm:w-44" value={status} onChange={(e) => t.setFilter('status', e.target.value)}>
            <option value="">All statuses</option>{CLIENT_STATUSES.map((s) => <option key={s} value={s}>{titleCase(s)}</option>)}</Select>
          {renewals && <Badge tone="amber" className="gap-2">Renewing in 45 days<button aria-label="Clear renewal filter" onClick={() => t.setFilter('renewals', null)}>×</button></Badge>}
        </div>
        <DataTable rows={list.data?.rows} total={list.data?.total} loading={list.isLoading} error={list.error ? friendlyError(list.error) : null} onRetry={list.refetch}
          page={t.page} pageSize={t.pageSize} onPageChange={t.setPage} sort={t.sort} onSortChange={t.setSort} onRowClick={(r) => navigate(`/clients/${r.id}`)}
          columns={[
            { key: 'n', header: 'Client', sortKey: 'name', render: (r) => <span><span className="block font-medium">{r.name}</span><span className="text-xs text-muted-foreground">{[r.industry, r.city].filter(Boolean).join(' · ')}</span></span> },
            { key: 'm', header: 'Account manager', render: (r) => nameOf(people, r.account_manager_id) },
            ...(renewals ? [{ key: 'r', header: 'Contract ends', render: (r: Client) => fmtDate(renewalIds.data?.find((x) => x.client_id === r.id)?.end_date) }] : []),
            { key: 'c', header: 'Since', sortKey: 'created_at', render: (r) => fmtDate(r.created_at) },
            { key: 's', header: 'Status', sortKey: 'status', render: (r) => <StatusBadge value={r.status} /> },
          ]} />
      </Card>
      <CreateClientDialog open={open} onClose={() => setOpen(false)} />
    </div>
  )
}
