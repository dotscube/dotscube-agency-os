import { useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { Briefcase, Plus } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { ilikeTerm, unwrap } from '@/lib/query'
import { friendlyError } from '@/lib/errors'
import { fmtDate, titleCase } from '@/lib/utils'
import { nameOf, useDepartments, useEmployeesLite } from '@/lib/lookups'
import type { Candidate, Interview, OpeningPipeline } from '@/lib/types'
import { useAuth } from '@/features/auth/AuthProvider'
import { DataTable, SearchBox } from '@/components/DataTable'
import { Badge, Button, Card, EmptyState, PageHeader, Select, Tabs } from '@/components/ui'
import { OPENING_STATUS, OpeningDialog, RECOMMENDATION, STAGES, StageBadge } from './shared'

function Openings() {
  const navigate = useNavigate()
  const { can } = useAuth()
  const { data: depts } = useDepartments()
  const { data: emps } = useEmployeesLite()
  const [status, setStatus] = useState('active'); const [creating, setCreating] = useState(false)
  const q = useQuery({ queryKey: ['recruitment', 'openings', status], queryFn: async () => {
    let s = supabase.from('opening_pipeline').select('*').order('created_at', { ascending: false })
    if (status === 'active') s = s.in('status', ['open', 'on_hold', 'draft'])
    else if (status) s = s.eq('status', status)
    return unwrap(await s) as OpeningPipeline[]
  } })
  const manage = can('recruitment.manage')
  return (
    <div className="space-y-4">
      <div className="flex flex-col justify-between gap-2 sm:flex-row">
        <Select aria-label="Status" className="sm:w-48" value={status} onChange={(e) => setStatus(e.target.value)}>
          <option value="active">Open & on hold</option><option value="filled">Filled</option><option value="closed">Closed</option><option value="">All</option></Select>
        {manage && <Button onClick={() => setCreating(true)}><Plus />New opening</Button>}
      </div>
      <Card><DataTable rows={q.data} loading={q.isLoading} error={q.error ? friendlyError(q.error) : null} onRetry={q.refetch}
        onRowClick={(r) => navigate(`/recruitment/openings/${r.id}`)}
        empty={<EmptyState icon={<Briefcase className="size-8" />} title="No openings" description={manage ? 'Create an opening to start adding candidates.' : undefined} />}
        columns={[
          { key: 't', header: 'Opening', render: (r) => <span><span className="block font-medium">{r.title}</span>
            <span className="text-xs text-muted-foreground">{[nameOf(depts, r.department_id) !== '—' ? nameOf(depts, r.department_id) : null, titleCase(r.employment_type), r.location].filter(Boolean).join(' · ')}</span></span> },
          { key: 'p', header: 'Pipeline', render: (r) => <span className="flex flex-wrap gap-1 text-xs">
            {(['applied', 'screening', 'interview', 'offer'] as const).map((k) => Number(r[k]) > 0 && <Badge key={k} tone="slate">{r[k]} {k}</Badge>)}
            {Number(r.active) === 0 && <span className="text-muted-foreground">No active candidates</span>}</span> },
          { key: 'h', header: 'Hired', render: (r) => `${r.hired}/${r.positions}` },
          { key: 'm', header: 'Hiring manager', render: (r) => nameOf(emps, r.hiring_manager_id) },
          { key: 'd', header: 'Fill by', render: (r) => fmtDate(r.target_date) },
          { key: 's', header: 'Status', render: (r) => <Badge tone={OPENING_STATUS[r.status]}>{titleCase(r.status)}</Badge> },
        ]} /></Card>
      {creating && <OpeningDialog onClose={() => setCreating(false)} />}
    </div>
  )
}

function Candidates() {
  const navigate = useNavigate()
  const [stage, setStage] = useState(''); const [search, setSearch] = useState('')
  const q = useQuery({ queryKey: ['recruitment', 'candidates', stage, search], queryFn: async () => {
    let s = supabase.from('candidates').select('*, job_openings(title)').order('created_at', { ascending: false }).limit(200)
    if (stage) s = s.eq('stage', stage)
    if (search.trim()) s = s.or(`full_name.ilike.${ilikeTerm(search)},email.ilike.${ilikeTerm(search)}`)
    return unwrap(await s) as (Candidate & { job_openings: { title: string } | null })[]
  } })
  return (
    <div className="space-y-4">
      <div className="flex flex-col gap-2 sm:flex-row">
        <SearchBox value={search} onChange={setSearch} placeholder="Search name or e-mail" />
        <Select aria-label="Stage" className="sm:w-44" value={stage} onChange={(e) => setStage(e.target.value)}><option value="">All stages</option>
          {STAGES.map((s) => <option key={s.value} value={s.value}>{s.label}</option>)}</Select>
      </div>
      <Card><DataTable rows={q.data} loading={q.isLoading} error={q.error ? friendlyError(q.error) : null} onRowClick={(r) => navigate(`/recruitment/candidates/${r.id}`)}
        empty={<EmptyState title="No candidates" />} columns={[
          { key: 'n', header: 'Candidate', render: (r) => <span><span className="block font-medium">{r.full_name}</span><span className="text-xs text-muted-foreground">{r.email ?? r.phone ?? ''}</span></span> },
          { key: 'o', header: 'Opening', render: (r) => r.job_openings?.title ?? '—' },
          { key: 's', header: 'Source', render: (r) => titleCase(r.source) },
          { key: 'e', header: 'Experience', render: (r) => (r.experience_years != null ? `${r.experience_years} yrs` : '—') },
          { key: 'st', header: 'Stage', render: (r) => <StageBadge stage={r.stage} /> },
          { key: 'd', header: 'Added', render: (r) => fmtDate(r.created_at) },
        ]} /></Card>
    </div>
  )
}

function MyInterviews() {
  const navigate = useNavigate()
  const { session } = useAuth()
  const q = useQuery({ queryKey: ['recruitment', 'my-interviews'], queryFn: async () => unwrap(await supabase.from('interviews')
    .select('*, candidates(full_name, job_openings(title))').eq('interviewer_id', session!.user.id).order('scheduled_at', { ascending: false }).limit(100)) as
    (Interview & { candidates: { full_name: string; job_openings: { title: string } | null } | null })[] })
  return (
    <Card><DataTable rows={q.data} loading={q.isLoading} error={q.error ? friendlyError(q.error) : null} onRowClick={(r) => navigate(`/recruitment/candidates/${r.candidate_id}`)}
      empty={<EmptyState title="No interviews assigned to you" />} columns={[
        { key: 'w', header: 'When', render: (r) => fmtDate(r.scheduled_at, 'EEE dd MMM, hh:mm a') },
        { key: 'c', header: 'Candidate', render: (r) => <span><span className="block font-medium">{r.candidates?.full_name}</span><span className="text-xs text-muted-foreground">{r.candidates?.job_openings?.title}</span></span> },
        { key: 'r', header: 'Round', render: (r) => r.round_name },
        { key: 'm', header: 'Mode', render: (r) => titleCase(r.mode) },
        { key: 's', header: 'Feedback', render: (r) => r.status === 'scheduled'
          ? (new Date(r.scheduled_at) < new Date() ? <Badge tone="amber">Feedback due</Badge> : <Badge tone="blue">Upcoming</Badge>)
          : r.recommendation ? <Badge tone={RECOMMENDATION[r.recommendation]!.tone}>{RECOMMENDATION[r.recommendation]!.label}</Badge> : <Badge tone="slate">{titleCase(r.status)}</Badge> },
      ]} /></Card>
  )
}

export default function RecruitmentPage() {
  const { can } = useAuth()
  const recruiter = can(['recruitment.view', 'recruitment.manage'], 'any')
  const [tab, setTab] = useState<'openings' | 'candidates' | 'interviews'>(recruiter ? 'openings' : 'interviews')
  // hiring managers and interviewers without a recruitment permission see only what involves them (RLS)
  const tabs = [{ value: 'openings' as const, label: recruiter ? 'Openings' : 'My openings' }, { value: 'candidates' as const, label: 'Candidates' },
    { value: 'interviews' as const, label: 'My interviews' }]
  return (
    <div className="space-y-6">
      <PageHeader title="Recruitment" description="Openings, candidates, interviews and offers. Hiring someone creates their employee record." />
      <Tabs tabs={tabs} value={tab} onChange={setTab} />
      {tab === 'openings' && <Openings />}
      {tab === 'candidates' && <Candidates />}
      {tab === 'interviews' && <MyInterviews />}
    </div>
  )
}
