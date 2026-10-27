import { useRef, useState } from 'react'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { toast } from 'sonner'
import { FileUp } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { unwrap } from '@/lib/query'
import { friendlyError } from '@/lib/errors'
import { titleCase } from '@/lib/utils'
import { useDepartments, useEmployeesLite } from '@/lib/lookups'
import type { CandidateStage, JobOpening } from '@/lib/types'
import { useAuth } from '@/features/auth/AuthProvider'
import { Badge, Button, Dialog, Field, Input, Select, Textarea, type BadgeTone } from '@/components/ui'

export const STAGES: { value: CandidateStage; label: string; tone: BadgeTone }[] = [
  { value: 'applied', label: 'Applied', tone: 'slate' }, { value: 'screening', label: 'Screening', tone: 'blue' },
  { value: 'interview', label: 'Interview', tone: 'blue' }, { value: 'offer', label: 'Offer', tone: 'amber' },
  { value: 'hired', label: 'Hired', tone: 'green' }, { value: 'rejected', label: 'Rejected', tone: 'red' }, { value: 'withdrawn', label: 'Withdrawn', tone: 'slate' },
]
export const SOURCES = ['referral', 'linkedin', 'naukri', 'indeed', 'website', 'walk_in', 'agency', 'other']
export const OPENING_STATUS: Record<JobOpening['status'], BadgeTone> = { draft: 'slate', open: 'green', on_hold: 'amber', closed: 'slate', filled: 'blue' }
export const RECOMMENDATION: Record<string, { label: string; tone: BadgeTone }> = {
  strong_yes: { label: 'Strong yes', tone: 'green' }, yes: { label: 'Yes', tone: 'green' }, no: { label: 'No', tone: 'red' }, strong_no: { label: 'Strong no', tone: 'red' },
}

export function StageBadge({ stage }: { stage: CandidateStage }) {
  const s = STAGES.find((x) => x.value === stage)!
  return <Badge tone={s.tone}>{s.label}</Badge>
}

/** Uploads a résumé to {org}/recruitment/{candidate}/… (storage policy: recruiters only) and returns the path. */
export async function uploadResume(orgId: string, candidateId: string, file: File): Promise<{ path: string; name: string }> {
  if (file.size > 10 * 1024 * 1024) throw new Error('Résumés must be 10 MB or smaller')
  if (!/\.(pdf|docx?|rtf|odt|png|jpe?g)$/i.test(file.name)) throw new Error('Upload a PDF, Word document or image')
  const safe = file.name.replace(/[^\w.-]+/g, '_').slice(-80)
  const path = `${orgId}/recruitment/${candidateId}/${crypto.randomUUID()}-${safe}`
  const { error } = await supabase.storage.from('agency-files').upload(path, file, { contentType: file.type || undefined })
  if (error) throw error
  return { path, name: file.name }
}

export async function openResume(path: string) {
  const { data, error } = await supabase.storage.from('agency-files').createSignedUrl(path, 60)
  if (error || !data) return toast.error(friendlyError(error) || 'Could not open the file')
  window.open(data.signedUrl, '_blank', 'noopener')
}

export function OpeningDialog({ opening, onClose }: { opening?: JobOpening | null; onClose: () => void }) {
  const { org, session } = useAuth()
  const qc = useQueryClient()
  const { data: depts } = useDepartments()
  const { data: emps } = useEmployeesLite()
  const [f, setF] = useState({
    title: opening?.title ?? '', department_id: opening?.department_id ?? '', employment_type: opening?.employment_type ?? 'full_time', location: opening?.location ?? '',
    positions: String(opening?.positions ?? 1), salary_min: opening?.salary_min != null ? String(opening.salary_min) : '', salary_max: opening?.salary_max != null ? String(opening.salary_max) : '',
    hiring_manager_id: opening?.hiring_manager_id ?? '', target_date: opening?.target_date ?? '', status: opening?.status ?? 'open',
    description: opening?.description ?? '', requirements: opening?.requirements ?? '',
  })
  const set = (k: keyof typeof f) => (e: { target: { value: string } }) => setF({ ...f, [k]: e.target.value })
  const save = useMutation({
    mutationFn: async () => {
      const row = { title: f.title.trim(), department_id: f.department_id || null, employment_type: f.employment_type, location: f.location.trim() || null,
        positions: Number(f.positions) || 1, salary_min: f.salary_min ? Number(f.salary_min) : null, salary_max: f.salary_max ? Number(f.salary_max) : null,
        hiring_manager_id: f.hiring_manager_id || null, target_date: f.target_date || null, status: f.status,
        description: f.description.trim() || null, requirements: f.requirements.trim() || null }
      return opening ? unwrap(await supabase.from('job_openings').update(row).eq('id', opening.id))
        : unwrap(await supabase.from('job_openings').insert({ ...row, org_id: org!.id, created_by: session!.user.id }))
    },
    onSuccess: () => { qc.invalidateQueries({ queryKey: ['recruitment'] }); toast.success(opening ? 'Opening updated' : 'Opening created'); onClose() },
  })
  const badRange = f.salary_min !== '' && f.salary_max !== '' && Number(f.salary_max) < Number(f.salary_min)
  return (
    <Dialog open onClose={onClose} wide title={opening ? 'Edit opening' : 'New job opening'}
      footer={<><Button variant="outline" onClick={onClose}>Cancel</Button><Button disabled={f.title.trim().length < 2 || badRange} loading={save.isPending} onClick={() => save.mutate()}>Save</Button></>}>
      <div className="grid gap-4 sm:grid-cols-2">
        <Field label="Job title" className="sm:col-span-2">{(p) => <Input {...p} value={f.title} onChange={set('title')} />}</Field>
        <Field label="Department">{(p) => <Select {...p} value={f.department_id} onChange={set('department_id')}><option value="">—</option>{depts?.map((d) => <option key={d.id} value={d.id}>{d.name}</option>)}</Select>}</Field>
        <Field label="Type">{(p) => <Select {...p} value={f.employment_type} onChange={set('employment_type')}>{['full_time', 'part_time', 'contract', 'intern', 'consultant'].map((t) => <option key={t} value={t}>{titleCase(t)}</option>)}</Select>}</Field>
        <Field label="Hiring manager" hint="Sees this opening's candidates">{(p) => <Select {...p} value={f.hiring_manager_id} onChange={set('hiring_manager_id')}><option value="">—</option>
          {emps?.map((e) => <option key={e.id} value={e.id}>{e.full_name}</option>)}</Select>}</Field>
        <Field label="Location">{(p) => <Input {...p} value={f.location} placeholder="Jaipur / Remote" onChange={set('location')} />}</Field>
        <Field label="Positions">{(p) => <Input {...p} type="number" min={1} max={100} value={f.positions} onChange={set('positions')} />}</Field>
        <Field label="Fill by">{(p) => <Input {...p} type="date" value={f.target_date} onChange={set('target_date')} />}</Field>
        <Field label="Budget: min annual CTC">{(p) => <Input {...p} type="number" min={0} value={f.salary_min} onChange={set('salary_min')} />}</Field>
        <Field label="Budget: max annual CTC" error={badRange ? 'Must be at least the minimum' : undefined}>{(p) => <Input {...p} type="number" min={0} value={f.salary_max} onChange={set('salary_max')} />}</Field>
        <Field label="Status">{(p) => <Select {...p} value={f.status} onChange={set('status')}>{Object.keys(OPENING_STATUS).map((s) => <option key={s} value={s}>{titleCase(s)}</option>)}</Select>}</Field>
        <Field label="Role description" className="sm:col-span-2">{(p) => <Textarea {...p} value={f.description} onChange={set('description')} />}</Field>
        <Field label="Requirements" className="sm:col-span-2">{(p) => <Textarea {...p} value={f.requirements} onChange={set('requirements')} />}</Field>
      </div>
    </Dialog>
  )
}

export function CandidateDialog({ openingId, onClose }: { openingId: string; onClose: () => void }) {
  const { org } = useAuth()
  const qc = useQueryClient()
  const { data: emps } = useEmployeesLite()
  const fileRef = useRef<HTMLInputElement>(null)
  const [file, setFile] = useState<File | null>(null)
  const [f, setF] = useState({ full_name: '', email: '', phone: '', source: 'linkedin', referred_by: '', current_company: '', experience_years: '', current_ctc: '',
    expected_ctc: '', notice_period_days: '', location: '', portfolio_url: '' })
  const set = (k: keyof typeof f) => (e: { target: { value: string } }) => setF({ ...f, [k]: e.target.value })
  const num = (v: string) => (v === '' ? null : Number(v))
  const save = useMutation({
    mutationFn: async () => {
      const row = unwrap(await supabase.from('candidates').insert({ org_id: org!.id, opening_id: openingId, full_name: f.full_name.trim(), email: f.email.trim() || null,
        phone: f.phone.trim() || null, source: f.source, referred_by: f.source === 'referral' ? f.referred_by || null : null, current_company: f.current_company.trim() || null,
        experience_years: num(f.experience_years), current_ctc: num(f.current_ctc), expected_ctc: num(f.expected_ctc), notice_period_days: num(f.notice_period_days),
        location: f.location.trim() || null, portfolio_url: f.portfolio_url.trim() || null }).select('id').single()) as { id: string }
      if (file) {
        try {
          const up = await uploadResume(org!.id, row.id, file)
          unwrap(await supabase.from('candidates').update({ resume_path: up.path, resume_name: up.name }).eq('id', row.id))
        } catch (err) { toast.error(`Candidate saved, but the résumé didn't upload: ${friendlyError(err)}`) }
      }
      return row.id
    },
    onSuccess: () => { qc.invalidateQueries({ queryKey: ['recruitment'] }); toast.success('Candidate added'); onClose() },
  })
  const badUrl = f.portfolio_url !== '' && !/^https?:\/\//i.test(f.portfolio_url)
  return (
    <Dialog open onClose={onClose} wide title="Add candidate"
      footer={<><Button variant="outline" onClick={onClose}>Cancel</Button><Button disabled={f.full_name.trim().length < 2 || badUrl} loading={save.isPending} onClick={() => save.mutate()}>Add</Button></>}>
      <div className="grid gap-4 sm:grid-cols-2">
        <Field label="Full name">{(p) => <Input {...p} value={f.full_name} onChange={set('full_name')} />}</Field>
        <Field label="E-mail">{(p) => <Input {...p} type="email" value={f.email} onChange={set('email')} />}</Field>
        <Field label="Phone">{(p) => <Input {...p} value={f.phone} onChange={set('phone')} />}</Field>
        <Field label="Source">{(p) => <Select {...p} value={f.source} onChange={set('source')}>{SOURCES.map((s) => <option key={s} value={s}>{titleCase(s)}</option>)}</Select>}</Field>
        {f.source === 'referral' && <Field label="Referred by">{(p) => <Select {...p} value={f.referred_by} onChange={set('referred_by')}><option value="">—</option>{emps?.map((e) => <option key={e.id} value={e.id}>{e.full_name}</option>)}</Select>}</Field>}
        <Field label="Current company">{(p) => <Input {...p} value={f.current_company} onChange={set('current_company')} />}</Field>
        <Field label="Experience (years)">{(p) => <Input {...p} type="number" min={0} step="0.5" value={f.experience_years} onChange={set('experience_years')} />}</Field>
        <Field label="Current CTC (annual)">{(p) => <Input {...p} type="number" min={0} value={f.current_ctc} onChange={set('current_ctc')} />}</Field>
        <Field label="Expected CTC (annual)">{(p) => <Input {...p} type="number" min={0} value={f.expected_ctc} onChange={set('expected_ctc')} />}</Field>
        <Field label="Notice period (days)">{(p) => <Input {...p} type="number" min={0} max={365} value={f.notice_period_days} onChange={set('notice_period_days')} />}</Field>
        <Field label="Location">{(p) => <Input {...p} value={f.location} onChange={set('location')} />}</Field>
        <Field label="Portfolio / LinkedIn URL" error={badUrl ? 'Start with https://' : undefined}>{(p) => <Input {...p} value={f.portfolio_url} onChange={set('portfolio_url')} />}</Field>
        <div className="sm:col-span-2">
          <input ref={fileRef} type="file" className="hidden" accept=".pdf,.doc,.docx,.rtf,.odt,.png,.jpg,.jpeg" onChange={(e) => { setFile(e.target.files?.[0] ?? null); e.target.value = '' }} />
          <Button type="button" variant="outline" onClick={() => fileRef.current?.click()}><FileUp />{file ? `Résumé: ${file.name}` : 'Attach résumé'}</Button>
        </div>
      </div>
    </Dialog>
  )
}
