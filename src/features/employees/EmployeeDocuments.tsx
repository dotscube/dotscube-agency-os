import { useRef, useState } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { toast } from 'sonner'
import { Download, FileText, Trash2, Upload } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { unwrap } from '@/lib/query'
import { friendlyError } from '@/lib/errors'
import { fmtDate, titleCase } from '@/lib/utils'
import type { Employee, EmploymentDocument } from '@/lib/types'
import { useAuth } from '@/features/auth/AuthProvider'
import { DataTable } from '@/components/DataTable'
import { Button, Card, CardBody, CardHeader, EmptyState, Select } from '@/components/ui'

const DOC_TYPES = ['offer_letter', 'appointment_letter', 'id_proof', 'address_proof', 'education', 'experience', 'contract', 'relieving_letter', 'other'] as const
const MAX_BYTES = 20 * 1024 * 1024
const ALLOWED = /\.(pdf|png|jpe?g|webp|docx?)$/i

/** Private HR documents. Readable by the employee and HR (employees.view_sensitive); only HR can upload/delete. */
export function EmployeeDocuments({ emp, canManage }: { emp: Employee; canManage: boolean }) {
  const { org, session } = useAuth()
  const qc = useQueryClient()
  const fileRef = useRef<HTMLInputElement>(null)
  const [type, setType] = useState<(typeof DOC_TYPES)[number]>('id_proof')
  const [busy, setBusy] = useState(false)
  const key = ['employee', emp.id, 'documents']
  const docs = useQuery({ queryKey: key,
    queryFn: async () => unwrap(await supabase.from('employment_documents').select('*').eq('employee_id', emp.id).order('created_at', { ascending: false })) as EmploymentDocument[] })
  const upload = async (file: File) => {
    if (file.size > MAX_BYTES) return toast.error('Documents must be 20 MB or smaller')
    if (!ALLOWED.test(file.name)) return toast.error('Upload a PDF, image or Word document')
    setBusy(true)
    try {
      const safe = file.name.replace(/[^\w.\-]+/g, '_').slice(-120)
      const path = `${org!.id}/employees/${emp.id}/${crypto.randomUUID()}-${safe}`
      // upload the file first (storage policy checks HR permissions), then record it; remove the file if recording fails
      const up = await supabase.storage.from('agency-files').upload(path, file, { contentType: file.type || undefined })
      if (up.error) return toast.error(friendlyError(up.error))
      const meta = await supabase.from('employment_documents').insert({ org_id: org!.id, employee_id: emp.id, doc_type: type, file_name: file.name,
        storage_path: path, uploaded_by: session!.user.id })
      if (meta.error) { await supabase.storage.from('agency-files').remove([path]); return toast.error(friendlyError(meta.error)) }
      toast.success('Document uploaded'); qc.invalidateQueries({ queryKey: key })
    } finally { setBusy(false) }
  }
  const open = async (d: EmploymentDocument) => {
    const { data, error } = await supabase.storage.from('agency-files').createSignedUrl(d.storage_path, 60)
    if (error) return toast.error(friendlyError(error))
    window.open(data.signedUrl, '_blank', 'noopener')
  }
  const remove = async (d: EmploymentDocument) => {
    if (!window.confirm(`Delete ${d.file_name}? This cannot be undone.`)) return
    const { error } = await supabase.from('employment_documents').delete().eq('id', d.id)
    if (error) return toast.error(friendlyError(error))
    await supabase.storage.from('agency-files').remove([d.storage_path])
    qc.invalidateQueries({ queryKey: key })
  }
  return (
    <Card>
      <CardHeader title="Documents" description="Private: visible only to this employee and HR." />
      {canManage && <CardBody className="flex flex-col gap-2 border-b sm:flex-row">
        <Select aria-label="Document type" className="sm:w-56" value={type} onChange={(e) => setType(e.target.value as typeof type)}>
          {DOC_TYPES.map((t) => <option key={t} value={t}>{titleCase(t)}</option>)}</Select>
        <input ref={fileRef} type="file" className="hidden" accept=".pdf,.png,.jpg,.jpeg,.webp,.doc,.docx" onChange={(e) => { const f = e.target.files?.[0]; if (f) upload(f); e.target.value = '' }} />
        <Button loading={busy} onClick={() => fileRef.current?.click()}><Upload />Upload</Button>
      </CardBody>}
      <DataTable rows={docs.data} loading={docs.isLoading} error={docs.error ? friendlyError(docs.error) : null} empty={<EmptyState icon={<FileText />} title="No documents yet" />} columns={[
        { key: 'n', header: 'Document', render: (d) => <span><span className="block font-medium">{d.file_name}</span><span className="text-xs text-muted-foreground">{titleCase(d.doc_type)}</span></span> },
        { key: 'd', header: 'Uploaded', render: (d) => fmtDate(d.created_at) },
        { key: 'x', header: '', render: (d) => <span className="flex justify-end gap-1">
          <Button size="icon" variant="ghost" aria-label={`Open ${d.file_name}`} onClick={() => open(d)}><Download /></Button>
          {canManage && <Button size="icon" variant="ghost" aria-label={`Delete ${d.file_name}`} onClick={() => remove(d)}><Trash2 /></Button>}</span> },
      ]} />
    </Card>
  )
}
