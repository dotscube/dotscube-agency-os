import { useRef, useState } from 'react'
import { Link, useNavigate, useParams } from 'react-router-dom'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { toast } from 'sonner'
import { ArrowLeft, CalendarPlus, FileText, FileUp, Printer, Star, UserCheck } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { unwrap } from '@/lib/query'
import { friendlyError } from '@/lib/errors'
import { fmtDate, fmtMoney, titleCase } from '@/lib/utils'
import { nameOf, useDepartments, useEmployeesLite, usePeople } from '@/lib/lookups'
import { offerLetter } from '@/lib/finance'
import type { Candidate, CandidateStage, Interview, JobOpening, Offer } from '@/lib/types'
import { useAuth } from '@/features/auth/AuthProvider'
import { Badge, Button, Card, CardBody, CardHeader, DescriptionList, Dialog, EmptyState, ErrorState, Field, Input, Select, Spinner, Textarea } from '@/components/ui'
import { RECOMMENDATION, STAGES, StageBadge, openResume, uploadResume } from './shared'

const OFFER_TONE = { draft: 'slate', sent: 'blue', accepted: 'green', declined: 'red', withdrawn: 'slate' } as const

function ScheduleDialog({ c, iv, onClose }: { c: Candidate; iv?: Interview; onClose: () => void }) {
  const qc = useQueryClient()
  const { org } = useAuth()
  const { data: people } = usePeople()
  const local = (d?: string) => (d ? new Date(new Date(d).getTime() - new Date().getTimezoneOffset() * 60_000).toISOString().slice(0, 16) : '')
  const [f, setF] = useState({ round_name: iv?.round_name ?? 'Interview', when: local(iv?.scheduled_at), duration: String(iv?.duration_minutes ?? 45), mode: iv?.mode ?? 'video',
    location: iv?.location ?? '', interviewer: iv?.interviewer_id ?? '' })
  const set = (k: keyof typeof f) => (e: { target: { value: string } }) => setF({ ...f, [k]: e.target.value })
  const save = useMutation({
    mutationFn: async () => {
      const row = { round_name: f.round_name.trim(), scheduled_at: new Date(f.when).toISOString(), duration_minutes: Number(f.duration), mode: f.mode,
        location: f.location.trim() || null, interviewer_id: f.interviewer }
      return iv ? unwrap(await supabase.from('interviews').update(row).eq('id', iv.id))
        : unwrap(await supabase.from('interviews').insert({ ...row, org_id: org!.id, candidate_id: c.id }))
    },
    onSuccess: () => { qc.invalidateQueries({ queryKey: ['recruitment'] }); toast.success(iv ? 'Interview updated' : 'Interview scheduled — the interviewer has been notified'); onClose() },
  })
  return (
    <Dialog open onClose={onClose} title={iv ? 'Reschedule interview' : 'Schedule interview'}
      footer={<><Button variant="outline" onClick={onClose}>Cancel</Button><Button disabled={!f.when || !f.interviewer || f.round_name.trim().length < 2} loading={save.isPending} onClick={() => save.mutate()}>Save</Button></>}>
      <div className="grid gap-4 sm:grid-cols-2">
        <Field label="Round">{(p) => <Input {...p} value={f.round_name} onChange={set('round_name')} placeholder="HR / Technical / Final" />}</Field>
        <Field label="Interviewer">{(p) => <Select {...p} value={f.interviewer} onChange={set('interviewer')}><option value="">Choose…</option>
          {people?.filter((x) => x.is_active).map((x) => <option key={x.id} value={x.id}>{x.full_name || x.email}</option>)}</Select>}</Field>
        <Field label="Date & time">{(p) => <Input {...p} type="datetime-local" value={f.when} onChange={set('when')} />}</Field>
        <Field label="Duration (minutes)">{(p) => <Input {...p} type="number" min={15} max={480} step={15} value={f.duration} onChange={set('duration')} />}</Field>
        <Field label="Mode">{(p) => <Select {...p} value={f.mode} onChange={set('mode')}><option value="video">Video call</option><option value="phone">Phone</option><option value="in_person">In person</option></Select>}</Field>
        <Field label={f.mode === 'in_person' ? 'Address' : 'Meeting link / number'}>{(p) => <Input {...p} value={f.location} onChange={set('location')} />}</Field>
      </div>
    </Dialog>
  )
}

function FeedbackDialog({ iv, onClose }: { iv: Interview; onClose: () => void }) {
  const qc = useQueryClient()
  const [rating, setRating] = useState(iv.rating ?? 0); const [rec, setRec] = useState<string>(iv.recommendation ?? ''); const [text, setText] = useState(iv.feedback ?? '')
  const save = useMutation({
    mutationFn: async (status: 'completed' | 'no_show') => unwrap(await supabase.rpc('submit_interview_feedback', { p_interview: iv.id, p_rating: status === 'completed' ? rating : null,
      p_recommendation: status === 'completed' ? rec : null, p_feedback: text, p_status: status })),
    onSuccess: () => { qc.invalidateQueries({ queryKey: ['recruitment'] }); toast.success('Feedback saved'); onClose() },
  })
  return (
    <Dialog open onClose={onClose} title={`Feedback · ${iv.round_name}`}
      footer={<><Button variant="outline" className="mr-auto" loading={save.isPending && save.variables === 'no_show'} onClick={() => save.mutate('no_show')}>Candidate didn't show up</Button>
        <Button variant="outline" onClick={onClose}>Cancel</Button>
        <Button disabled={!rating || !rec || text.trim().length < 10} loading={save.isPending && save.variables === 'completed'} onClick={() => save.mutate('completed')}>Submit</Button></>}>
      <div className="space-y-4 text-sm">
        <fieldset><legend className="mb-1 font-medium">Rating</legend><div className="flex gap-1">{[1, 2, 3, 4, 5].map((n) => (
          <button key={n} type="button" aria-label={`${n} of 5`} aria-pressed={rating === n} onClick={() => setRating(n)}
            className={`rounded p-1 ${n <= rating ? 'text-amber-500' : 'text-muted-foreground'}`}><Star className="size-6" fill={n <= rating ? 'currentColor' : 'none'} /></button>))}</div></fieldset>
        <fieldset><legend className="mb-1 font-medium">Recommendation</legend><div className="flex flex-wrap gap-3">{Object.entries(RECOMMENDATION).map(([k, v]) => (
          <label key={k} className="flex items-center gap-1.5"><input type="radio" name="rec" checked={rec === k} onChange={() => setRec(k)} />{v.label}</label>))}</div></fieldset>
        <Field label="Notes" hint="Strengths, concerns, and anything the next interviewer should probe">{(p) => <Textarea {...p} value={text} onChange={(e) => setText(e.target.value)} />}</Field>
      </div>
    </Dialog>
  )
}

function OfferCard({ c, opening, offers }: { c: Candidate; opening: JobOpening; offers: Offer[] }) {
  const qc = useQueryClient()
  const { org, can } = useAuth()
  const { data: depts } = useDepartments()
  const navigate = useNavigate()
  const manage = can('recruitment.manage')
  const current = offers.find((o) => ['draft', 'sent', 'accepted'].includes(o.status))
  const [editing, setEditing] = useState(false); const [hiring, setHiring] = useState(false); const [printing, setPrinting] = useState<Offer | null>(null)
  const [workEmail, setWorkEmail] = useState('')
  const [f, setF] = useState({ designation: opening.title, department_id: opening.department_id ?? '', annual_ctc: c.expected_ctc != null ? String(c.expected_ctc) : '',
    joining_date: '', valid_until: '', letter_text: '' })
  const set = (k: keyof typeof f) => (e: { target: { value: string } }) => setF({ ...f, [k]: e.target.value })
  const generate = () => setF((x) => ({ ...x, letter_text: offerLetter({ agency: org?.name ?? 'our agency', candidate: c.full_name, designation: x.designation,
    department: nameOf(depts, x.department_id) !== '—' ? nameOf(depts, x.department_id) : null, annualCtc: Number(x.annual_ctc || 0), joiningDate: x.joining_date || new Date().toISOString().slice(0, 10),
    validUntil: x.valid_until || null, location: opening.location }) }))
  const inv = () => qc.invalidateQueries({ queryKey: ['recruitment'] })
  const save = useMutation({
    mutationFn: async () => {
      const row = { designation: f.designation.trim(), department_id: f.department_id || null, annual_ctc: Number(f.annual_ctc), joining_date: f.joining_date,
        valid_until: f.valid_until || null, letter_text: f.letter_text.trim() || null }
      return current?.status === 'draft' ? unwrap(await supabase.from('offers').update(row).eq('id', current.id))
        : unwrap(await supabase.from('offers').insert({ ...row, org_id: org!.id, candidate_id: c.id }))
    },
    onSuccess: () => { inv(); setEditing(false); toast.success('Offer saved as draft') },
  })
  const status = useMutation({ mutationFn: async (s: string) => unwrap(await supabase.rpc('set_offer_status', { p_offer: current!.id, p_status: s })),
    onSuccess: (_, s) => { inv(); toast.success(s === 'sent' ? (c.email ? 'Offer marked as sent (e-mailed if e-mail is set up)' : 'Offer marked as sent') : `Offer ${s}`) } })
  const hire = useMutation({ mutationFn: async () => unwrap(await supabase.rpc('hire_candidate', { p_candidate: c.id, p_work_email: workEmail })) as string,
    onSuccess: (emp) => { inv(); qc.invalidateQueries({ queryKey: ['employees'] }); toast.success(`${c.full_name} is now an employee (onboarding)`); navigate(`/employees/${emp}`) } })
  const startEdit = () => {
    if (current?.status === 'draft') setF({ designation: current.designation, department_id: current.department_id ?? '', annual_ctc: String(current.annual_ctc),
      joining_date: current.joining_date, valid_until: current.valid_until ?? '', letter_text: current.letter_text ?? '' })
    setEditing(true)
  }
  const inPipeline = !['hired', 'rejected', 'withdrawn'].includes(c.stage)
  return (
    <Card>
      <CardHeader title="Offer" action={manage && <div className="flex flex-wrap gap-2">
        {inPipeline && (!current || current.status === 'draft') && <Button size="sm" variant="outline" onClick={startEdit}>{current ? 'Edit draft' : 'Create offer'}</Button>}
        {current?.status === 'draft' && <Button size="sm" onClick={() => status.mutate('sent')}>Mark as sent</Button>}
        {current?.status === 'sent' && <><Button size="sm" variant="outline" onClick={() => status.mutate('declined')}>Declined</Button><Button size="sm" onClick={() => status.mutate('accepted')}>Accepted</Button></>}
        {current && c.stage !== 'hired' && <Button size="sm" variant="ghost" onClick={() => { if (confirm('Withdraw this offer?')) status.mutate('withdrawn') }}>Withdraw</Button>}
        {current?.status === 'accepted' && c.stage !== 'hired' && can('employees.create') && <Button size="sm" onClick={() => setHiring(true)}><UserCheck />Hire</Button>}
      </div>} />
      {!offers.length ? <EmptyState title="No offer yet" /> : <ul className="divide-y">{offers.map((o) => (
        <li key={o.id} className="flex flex-col gap-1 px-5 py-3 text-sm sm:flex-row sm:items-center sm:justify-between">
          <span><span className="font-medium">{o.designation}</span> · {fmtMoney(o.annual_ctc)} / year · joining {fmtDate(o.joining_date)}
            <span className="block text-xs text-muted-foreground">Offered {fmtDate(o.offer_date)}{o.valid_until ? ` · valid until ${fmtDate(o.valid_until)}` : ''}</span></span>
          <span className="flex items-center gap-2"><Badge tone={OFFER_TONE[o.status]}>{titleCase(o.status)}</Badge>
            {o.letter_text && <Button size="sm" variant="ghost" onClick={() => setPrinting(o)}><FileText />Letter</Button>}</span>
        </li>))}</ul>}
      {editing && <Dialog open onClose={() => setEditing(false)} wide title={current ? 'Edit draft offer' : 'Create offer'}
        footer={<><Button variant="outline" onClick={() => setEditing(false)}>Cancel</Button>
          <Button disabled={f.designation.trim().length < 2 || !(Number(f.annual_ctc) > 0) || !f.joining_date} loading={save.isPending} onClick={() => save.mutate()}>Save draft</Button></>}>
        <div className="grid gap-4 sm:grid-cols-2">
          <Field label="Designation">{(p) => <Input {...p} value={f.designation} onChange={set('designation')} />}</Field>
          <Field label="Department">{(p) => <Select {...p} value={f.department_id} onChange={set('department_id')}><option value="">—</option>{depts?.map((d) => <option key={d.id} value={d.id}>{d.name}</option>)}</Select>}</Field>
          <Field label="Annual CTC" hint={c.expected_ctc ? `Expected ${fmtMoney(c.expected_ctc)}` : undefined}>{(p) => <Input {...p} type="number" min={1} value={f.annual_ctc} onChange={set('annual_ctc')} />}</Field>
          <Field label="Joining date">{(p) => <Input {...p} type="date" value={f.joining_date} onChange={set('joining_date')} />}</Field>
          <Field label="Offer valid until">{(p) => <Input {...p} type="date" value={f.valid_until} onChange={set('valid_until')} />}</Field>
          <div className="self-end"><Button type="button" variant="outline" disabled={!f.annual_ctc} onClick={generate}>Write letter from template</Button></div>
          <Field label="Offer letter" className="sm:col-span-2" hint="E-mailed to the candidate when you mark the offer as sent (if e-mail is set up)">
            {(p) => <Textarea {...p} className="min-h-64" value={f.letter_text} onChange={set('letter_text')} />}</Field>
        </div>
      </Dialog>}
      {hiring && <Dialog open onClose={() => setHiring(false)} title={`Hire ${c.full_name}`}
        description="Creates their employee record (status: onboarding) with the offer's designation, joining date and salary. You can invite them to sign in from their employee page."
        footer={<><Button variant="outline" onClick={() => setHiring(false)}>Cancel</Button><Button disabled={!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(workEmail)} loading={hire.isPending} onClick={() => hire.mutate()}>Hire</Button></>}>
        <Field label="Work e-mail" hint="The address they'll use to sign in">{(p) => <Input {...p} type="email" value={workEmail} onChange={(e) => setWorkEmail(e.target.value)} />}</Field>
        {!can('salary.edit') && <p className="mt-3 text-sm text-amber-700">You don't have salary.edit, so HR will need to add their salary structure.</p>}
      </Dialog>}
      {printing && <Dialog open onClose={() => setPrinting(null)} wide title="Offer letter" footer={<Button onClick={() => window.print()}><Printer />Print / PDF</Button>}>
        <div className="print-sheet whitespace-pre-line text-sm leading-relaxed"><p className="mb-4 text-xs text-muted-foreground">{fmtDate(printing.offer_date, 'dd MMMM yyyy')}</p>{printing.letter_text}</div>
      </Dialog>}
    </Card>
  )
}

export default function CandidatePage() {
  const { id } = useParams<{ id: string }>()
  const qc = useQueryClient()
  const { can, session, org } = useAuth()
  const manage = can('recruitment.manage')
  const seeOffers = can(['recruitment.view', 'recruitment.manage'], 'any')
  const { data: people } = usePeople()
  const { data: emps } = useEmployeesLite()
  const fileRef = useRef<HTMLInputElement>(null)
  const [scheduling, setScheduling] = useState<Interview | 'new' | null>(null); const [feedback, setFeedback] = useState<Interview | null>(null)
  const [rejecting, setRejecting] = useState<CandidateStage | null>(null); const [reason, setReason] = useState('')
  const q = useQuery({ queryKey: ['recruitment', 'candidate', id], queryFn: async () => {
    const c = unwrap(await supabase.from('candidates').select('*').eq('id', id!).single()) as Candidate
    const [o, iv, of] = await Promise.all([supabase.from('job_openings').select('*').eq('id', c.opening_id).maybeSingle(),
      supabase.from('interviews').select('*').eq('candidate_id', id!).order('scheduled_at'),
      seeOffers ? supabase.from('offers').select('*').eq('candidate_id', id!).order('created_at', { ascending: false }) : Promise.resolve({ data: [], error: null })])
    return { c, opening: o.data as JobOpening | null, interviews: unwrap(iv) as Interview[], offers: unwrap(of) as Offer[] }
  } })
  const inv = () => qc.invalidateQueries({ queryKey: ['recruitment'] })
  const update = useMutation({ mutationFn: async (patch: Partial<Candidate>) => unwrap(await supabase.from('candidates').update(patch).eq('id', id!)),
    onSuccess: () => { inv(); setRejecting(null); setReason('') } })
  const upload = useMutation({
    mutationFn: async (file: File) => { const up = await uploadResume(org!.id, id!, file); return unwrap(await supabase.from('candidates').update({ resume_path: up.path, resume_name: up.name }).eq('id', id!)) },
    onSuccess: () => { inv(); toast.success('Résumé uploaded') },
  })
  if (q.isLoading) return <Spinner />
  if (q.error || !q.data) return <ErrorState message={friendlyError(q.error)} onRetry={q.refetch} />
  const { c, opening, interviews, offers } = q.data
  const moveTo = (stage: CandidateStage) => (stage === 'rejected' || stage === 'withdrawn' ? setRejecting(stage) : update.mutate({ stage }))
  const selectable = STAGES.filter((s) => s.value !== 'hired' && (s.value !== 'offer' || c.stage === 'offer'))
  return (
    <div className="space-y-6">
      <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <div className="flex items-center gap-3">
          <Link to={opening ? `/recruitment/openings/${opening.id}` : '/recruitment'} className="inline-flex size-9 items-center justify-center rounded-md hover:bg-muted" aria-label="Back"><ArrowLeft className="size-4" /></Link>
          <div><h1 className="text-xl font-semibold tracking-tight">{c.full_name}</h1>
            <p className="flex items-center gap-2 text-sm text-muted-foreground">{opening?.title}<StageBadge stage={c.stage} /></p></div>
        </div>
        <div className="flex flex-wrap gap-2">
          {c.resume_path && <Button variant="outline" onClick={() => openResume(c.resume_path!)}><FileText />Résumé</Button>}
          {manage && c.stage !== 'hired' && <>
            <input ref={fileRef} type="file" className="hidden" accept=".pdf,.doc,.docx,.rtf,.odt,.png,.jpg,.jpeg" onChange={(e) => { const f = e.target.files?.[0]; if (f) upload.mutate(f); e.target.value = '' }} />
            <Button variant="outline" loading={upload.isPending} onClick={() => fileRef.current?.click()}><FileUp />{c.resume_path ? 'Replace résumé' : 'Upload résumé'}</Button>
            <Select aria-label="Move to stage" className="w-40" value={c.stage} onChange={(e) => moveTo(e.target.value as CandidateStage)}>
              {selectable.map((s) => <option key={s.value} value={s.value}>{s.label}</option>)}</Select></>}
          {c.employee_id && <Link to={`/employees/${c.employee_id}`} className="inline-flex h-9 items-center rounded-md border px-4 text-sm font-medium hover:bg-muted">Employee record</Link>}
        </div>
      </div>
      <div className="grid gap-6 lg:grid-cols-3">
        <div className="space-y-6 lg:col-span-2">
          <Card><CardHeader title="Interviews" action={manage && !['hired', 'rejected', 'withdrawn'].includes(c.stage) && <Button size="sm" onClick={() => setScheduling('new')}><CalendarPlus />Schedule</Button>} />
            {!interviews.length ? <EmptyState title="No interviews yet" /> : <ul className="divide-y">{interviews.map((iv) => {
              const mine = iv.interviewer_id === session?.user.id
              const due = iv.status === 'scheduled' && new Date(iv.scheduled_at).getTime() < Date.now() + 3_600_000
              return (
                <li key={iv.id} className="space-y-1 px-5 py-3 text-sm">
                  <div className="flex flex-wrap items-center justify-between gap-2">
                    <span><span className="font-medium">{iv.round_name}</span> · {fmtDate(iv.scheduled_at, 'EEE dd MMM, hh:mm a')} · {titleCase(iv.mode)} · {nameOf(people, iv.interviewer_id)}</span>
                    <span className="flex items-center gap-2">
                      {iv.recommendation ? <Badge tone={RECOMMENDATION[iv.recommendation]!.tone}>{RECOMMENDATION[iv.recommendation]!.label} · {iv.rating}/5</Badge> : <Badge tone={iv.status === 'scheduled' ? 'blue' : 'slate'}>{titleCase(iv.status)}</Badge>}
                      {(mine || manage) && due && <Button size="sm" onClick={() => setFeedback(iv)}>Give feedback</Button>}
                      {manage && iv.status === 'scheduled' && <Button size="sm" variant="ghost" onClick={() => setScheduling(iv)}>Reschedule</Button>}
                    </span>
                  </div>
                  {iv.location && iv.status === 'scheduled' && <p className="text-xs text-muted-foreground break-all">{iv.location}</p>}
                  {iv.feedback && <p className="whitespace-pre-line text-muted-foreground">{iv.feedback}</p>}
                </li>)
            })}</ul>}
          </Card>
          {seeOffers && opening && <OfferCard c={c} opening={opening} offers={offers} />}
        </div>
        <Card className="h-fit"><CardHeader title="Profile" /><CardBody className="space-y-4">
          <DescriptionList items={[
            { label: 'E-mail', value: c.email }, { label: 'Phone', value: c.phone }, { label: 'Source', value: titleCase(c.source) + (c.referred_by ? ` · ${nameOf(emps, c.referred_by)}` : '') },
            { label: 'Current company', value: c.current_company }, { label: 'Experience', value: c.experience_years != null ? `${c.experience_years} years` : null },
            { label: 'Notice period', value: c.notice_period_days != null ? `${c.notice_period_days} days` : null },
            ...(seeOffers ? [{ label: 'Current CTC', value: c.current_ctc != null ? fmtMoney(c.current_ctc) : null }, { label: 'Expected CTC', value: c.expected_ctc != null ? fmtMoney(c.expected_ctc) : null }] : []),
            { label: 'Location', value: c.location }, { label: 'Portfolio', value: c.portfolio_url && <a className="break-all text-primary hover:underline" href={c.portfolio_url} target="_blank" rel="noreferrer noopener">{c.portfolio_url}</a> },
            { label: 'Added', value: fmtDate(c.created_at) }, ...(c.rejection_reason ? [{ label: 'Reason closed', value: c.rejection_reason }] : []),
          ]} />
          {manage && <Field label="Overall rating">{(p) => <Select {...p} value={c.rating ?? ''} onChange={(e) => update.mutate({ rating: e.target.value ? Number(e.target.value) : null })}>
            <option value="">—</option>{[5, 4, 3, 2, 1].map((n) => <option key={n} value={n}>{'★'.repeat(n)}</option>)}</Select>}</Field>}
          <Field label="Recruiter notes">{(p) => <Textarea {...p} disabled={!manage} defaultValue={c.notes ?? ''} onBlur={(e) => manage && e.target.value !== (c.notes ?? '') && update.mutate({ notes: e.target.value || null })} />}</Field>
        </CardBody></Card>
      </div>
      {scheduling && <ScheduleDialog c={c} iv={scheduling === 'new' ? undefined : scheduling} onClose={() => setScheduling(null)} />}
      {feedback && <FeedbackDialog iv={feedback} onClose={() => setFeedback(null)} />}
      <Dialog open={Boolean(rejecting)} onClose={() => setRejecting(null)} title={rejecting === 'withdrawn' ? 'Candidate withdrew' : 'Reject candidate'}
        footer={<><Button variant="outline" onClick={() => setRejecting(null)}>Cancel</Button>
          <Button variant="destructive" disabled={reason.trim().length < 3} loading={update.isPending} onClick={() => update.mutate({ stage: rejecting!, rejection_reason: reason.trim() })}>Save</Button></>}>
        <Field label="Reason" hint="Kept for your records; not sent to the candidate">{(p) => <Input {...p} value={reason} onChange={(e) => setReason(e.target.value)} />}</Field>
      </Dialog>
    </div>
  )
}
