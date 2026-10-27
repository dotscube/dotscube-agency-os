import { useState } from 'react'
import { Link, useNavigate, useParams } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { ArrowLeft, Pencil, UserPlus } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { unwrap } from '@/lib/query'
import { friendlyError } from '@/lib/errors'
import { fmtDate, fmtMoney, titleCase } from '@/lib/utils'
import { nameOf, useDepartments, useEmployeesLite } from '@/lib/lookups'
import type { Candidate, JobOpening } from '@/lib/types'
import { useAuth } from '@/features/auth/AuthProvider'
import { Badge, Button, Card, CardBody, CardHeader, DescriptionList, ErrorState, Spinner } from '@/components/ui'
import { CandidateDialog, OPENING_STATUS, OpeningDialog, STAGES, StageBadge } from './shared'

const BOARD = STAGES.filter((s) => ['applied', 'screening', 'interview', 'offer', 'hired'].includes(s.value))

export default function OpeningPage() {
  const { id } = useParams<{ id: string }>()
  const navigate = useNavigate()
  const { can } = useAuth()
  const manage = can('recruitment.manage')
  const { data: depts } = useDepartments()
  const { data: emps } = useEmployeesLite()
  const [editing, setEditing] = useState(false); const [adding, setAdding] = useState(false)
  const q = useQuery({ queryKey: ['recruitment', 'opening', id], queryFn: async () => {
    const opening = unwrap(await supabase.from('job_openings').select('*').eq('id', id!).single()) as JobOpening
    const candidates = unwrap(await supabase.from('candidates').select('*').eq('opening_id', id!).order('created_at')) as Candidate[]
    return { opening, candidates }
  } })
  if (q.isLoading) return <Spinner />
  if (q.error || !q.data) return <ErrorState message={friendlyError(q.error)} onRetry={q.refetch} />
  const { opening: o, candidates } = q.data
  const closed = candidates.filter((c) => c.stage === 'rejected' || c.stage === 'withdrawn')
  return (
    <div className="space-y-6">
      <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <div className="flex items-center gap-3">
          <Link to="/recruitment" className="inline-flex size-9 items-center justify-center rounded-md hover:bg-muted" aria-label="Back to recruitment"><ArrowLeft className="size-4" /></Link>
          <div><h1 className="text-xl font-semibold tracking-tight">{o.title}</h1>
            <p className="flex items-center gap-2 text-sm text-muted-foreground"><Badge tone={OPENING_STATUS[o.status]}>{titleCase(o.status)}</Badge>
              {candidates.filter((c) => c.stage === 'hired').length}/{o.positions} hired</p></div>
        </div>
        {manage && <div className="flex gap-2"><Button variant="outline" onClick={() => setEditing(true)}><Pencil />Edit</Button>
          <Button onClick={() => setAdding(true)}><UserPlus />Add candidate</Button></div>}
      </div>

      <div className="grid gap-4 overflow-x-auto pb-2 md:grid-cols-5">
        {BOARD.map((s) => {
          const list = candidates.filter((c) => c.stage === s.value)
          return (
            <section key={s.value} aria-label={s.label} className="min-w-52 rounded-lg border bg-muted/30 p-2">
              <h2 className="mb-2 flex items-center justify-between px-1 text-sm font-medium">{s.label}<span className="text-xs text-muted-foreground">{list.length}</span></h2>
              <ul className="space-y-2">{list.map((c) => (
                <li key={c.id}><button onClick={() => navigate(`/recruitment/candidates/${c.id}`)} className="w-full rounded-md border bg-card p-2.5 text-left text-sm shadow-sm hover:border-primary">
                  <span className="block font-medium">{c.full_name}</span>
                  <span className="block text-xs text-muted-foreground">{[c.experience_years != null ? `${c.experience_years} yrs` : null, c.notice_period_days != null ? `${c.notice_period_days}d notice` : null, titleCase(c.source)].filter(Boolean).join(' · ')}</span>
                  {c.rating && <span className="text-xs text-amber-600" aria-label={`Rated ${c.rating} of 5`}>{'★'.repeat(c.rating)}{'☆'.repeat(5 - c.rating)}</span>}
                </button></li>))}
                {!list.length && <li className="px-1 py-3 text-center text-xs text-muted-foreground">—</li>}</ul>
            </section>
          )
        })}
      </div>

      {closed.length > 0 && <Card><CardHeader title="Rejected or withdrawn" />
        <ul className="divide-y">{closed.map((c) => (
          <li key={c.id}><Link to={`/recruitment/candidates/${c.id}`} className="flex items-center justify-between gap-3 px-5 py-2.5 text-sm hover:bg-muted/40">
            <span>{c.full_name}<span className="block text-xs text-muted-foreground">{c.rejection_reason}</span></span><StageBadge stage={c.stage} /></Link></li>))}</ul></Card>}

      <Card><CardHeader title="About this opening" /><CardBody className="space-y-4">
        <DescriptionList items={[
          { label: 'Department', value: nameOf(depts, o.department_id) }, { label: 'Type', value: titleCase(o.employment_type) },
          { label: 'Location', value: o.location }, { label: 'Hiring manager', value: nameOf(emps, o.hiring_manager_id) },
          { label: 'Budget (annual CTC)', value: o.salary_min || o.salary_max ? `${fmtMoney(o.salary_min)} – ${fmtMoney(o.salary_max)}` : '—' },
          { label: 'Fill by', value: fmtDate(o.target_date) },
        ]} />
        {o.description && <div><p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">Role</p><p className="whitespace-pre-line text-sm">{o.description}</p></div>}
        {o.requirements && <div><p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">Requirements</p><p className="whitespace-pre-line text-sm">{o.requirements}</p></div>}
      </CardBody></Card>
      {editing && <OpeningDialog opening={o} onClose={() => setEditing(false)} />}
      {adding && <CandidateDialog openingId={o.id} onClose={() => setAdding(false)} />}
    </div>
  )
}
