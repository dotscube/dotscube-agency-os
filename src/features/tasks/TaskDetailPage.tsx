import { useRef, useState } from 'react'
import { Link, useNavigate, useParams } from 'react-router-dom'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { toast } from 'sonner'
import { ArrowLeft, Lock, Paperclip, Plus, Trash2, X } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { unwrap } from '@/lib/query'
import { friendlyError } from '@/lib/errors'
import { extractMentions, fmtDate, fmtMinutes } from '@/lib/utils'
import { nameOf, usePeople, useTaskStatuses } from '@/lib/lookups'
import { PRIORITIES, type TaskComment } from '@/lib/types'
import { useAuth } from '@/features/auth/AuthProvider'
import { Avatar, Badge, Button, Card, CardBody, CardHeader, EmptyState, ErrorState, Input, Label, Select, Spinner, StatusBadge, Textarea } from '@/components/ui'
import { CreateTaskDialog, isOverdue, StatusPill, TASK_SELECT, type TaskWithAssignees } from './shared'

interface Attachment { id: string; file_name: string; storage_path: string; size_bytes: number | null; is_internal: boolean; uploaded_by: string | null; created_at: string }
const MAX_BYTES = 50 * 1024 * 1024

export default function TaskDetailPage() {
  const { id } = useParams()
  const navigate = useNavigate()
  const { audience, session, org, can } = useAuth()
  const internal = audience === 'internal'
  const qc = useQueryClient()
  const { data: statuses } = useTaskStatuses()
  const { data: people } = usePeople()
  const [comment, setComment] = useState('')
  const [commentInternal, setCommentInternal] = useState(true)
  const [subOpen, setSubOpen] = useState(false)
  const [depId, setDepId] = useState('')
  const fileRef = useRef<HTMLInputElement>(null)

  const q = useQuery({ queryKey: ['tasks', 'detail', id], queryFn: async () => unwrap(await supabase.from('tasks').select(TASK_SELECT).eq('id', id!).maybeSingle()) as TaskWithAssignees | null })
  const t = q.data
  const project = useQuery({ queryKey: ['project', t?.project_id, 'name'], enabled: Boolean(t),
    queryFn: async () => unwrap(await supabase.from('projects').select('id, name, owner_id').eq('id', t!.project_id).single()) as { id: string; name: string; owner_id: string | null } })
  const comments = useQuery({ queryKey: ['tasks', 'comments', id], enabled: Boolean(t),
    queryFn: async () => unwrap(await supabase.from('task_comments').select('*').eq('task_id', id!).order('created_at')) as TaskComment[] })
  const subtasks = useQuery({ queryKey: ['tasks', 'subtasks', id], enabled: Boolean(t) && !t?.parent_task_id,
    queryFn: async () => unwrap(await supabase.from('tasks').select(TASK_SELECT).eq('parent_task_id', id!).order('created_at')) as TaskWithAssignees[] })
  const deps = useQuery({ queryKey: ['tasks', 'deps', id], enabled: Boolean(t) && internal,
    queryFn: async () => unwrap(await supabase.from('task_dependencies').select('depends_on_task_id, depends_on:tasks!task_dependencies_depends_on_task_id_fkey(id, title, status_id)').eq('task_id', id!)) as
      unknown as { depends_on_task_id: string; depends_on: { id: string; title: string; status_id: string } | null }[] })
  const siblings = useQuery({ queryKey: ['tasks', 'siblings', t?.project_id], enabled: Boolean(t) && internal,
    queryFn: async () => unwrap(await supabase.from('tasks').select('id, title').eq('project_id', t!.project_id).neq('id', t!.id).is('parent_task_id', null).order('title')) as { id: string; title: string }[] })
  const attachments = useQuery({ queryKey: ['tasks', 'attachments', id], enabled: Boolean(t),
    queryFn: async () => unwrap(await supabase.from('task_attachments').select('*').eq('task_id', id!).order('created_at')) as Attachment[] })

  const invalidate = () => { qc.invalidateQueries({ queryKey: ['tasks'] }); qc.invalidateQueries({ queryKey: ['project'] }); qc.invalidateQueries({ queryKey: ['dashboard'] }) }
  const update = useMutation({
    mutationFn: async (patch: Record<string, unknown>) => unwrap(await supabase.from('tasks').update(patch).eq('id', id!).select('id').single()),
    onSuccess: () => { toast.success('Saved'); invalidate() },
    onError: (e) => { toast.error(friendlyError(e)); invalidate() },
  })
  const assign = useMutation({
    mutationFn: async (pid: string) => unwrap(await supabase.from('task_assignees').insert({ task_id: id, profile_id: pid, org_id: org!.id, assigned_by: session!.user.id })),
    onSuccess: invalidate,
  })
  const unassign = useMutation({ mutationFn: async (pid: string) => unwrap(await supabase.from('task_assignees').delete().eq('task_id', id!).eq('profile_id', pid)), onSuccess: invalidate })
  const addDep = useMutation({ mutationFn: async () => unwrap(await supabase.from('task_dependencies').insert({ task_id: id, depends_on_task_id: depId, org_id: org!.id })),
    onSuccess: () => { setDepId(''); invalidate() } })
  const removeDep = useMutation({ mutationFn: async (d: string) => unwrap(await supabase.from('task_dependencies').delete().eq('task_id', id!).eq('depends_on_task_id', d)), onSuccess: invalidate })
  const postComment = useMutation({
    mutationFn: async () => {
      const c = unwrap(await supabase.from('task_comments').insert({ org_id: org!.id, task_id: id, author_id: session!.user.id, body: comment.trim(), is_internal: internal ? commentInternal : false }).select('id').single()) as { id: string }
      const mentioned = internal ? extractMentions(comment, (people ?? []).map((p) => ({ id: p.id, full_name: p.full_name }))).filter((m) => m !== session!.user.id) : []
      if (mentioned.length) await supabase.from('task_comment_mentions').insert(mentioned.map((pid) => ({ comment_id: c.id, profile_id: pid, org_id: org!.id })))
    },
    onSuccess: () => { setComment(''); qc.invalidateQueries({ queryKey: ['tasks', 'comments', id] }) },
  })
  const deleteComment = useMutation({ mutationFn: async (cid: string) => unwrap(await supabase.from('task_comments').delete().eq('id', cid)),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['tasks', 'comments', id] }) })

  const upload = async (file: File) => {
    if (file.size > MAX_BYTES) return toast.error('Files must be 50 MB or smaller')
    const safe = file.name.replace(/[^\w.\-]+/g, '_').slice(-120)
    const path = `${org!.id}/tasks/${id}/${crypto.randomUUID()}-${safe}`
    // metadata row first (authorises the storage path), then the file; roll back the row if the upload fails
    const meta = await supabase.from('task_attachments').insert({ task_id: id, org_id: org!.id, file_name: file.name, storage_path: path,
      size_bytes: file.size, mime_type: file.type || null, is_internal: internal, uploaded_by: session!.user.id }).select('id').single()
    if (meta.error) return toast.error(friendlyError(meta.error))
    const up = await supabase.storage.from('agency-files').upload(path, file, { contentType: file.type || undefined })
    if (up.error) { await supabase.from('task_attachments').delete().eq('id', meta.data.id); return toast.error(`Upload failed: ${friendlyError(up.error)}`) }
    toast.success('File attached'); qc.invalidateQueries({ queryKey: ['tasks', 'attachments', id] })
  }
  const download = async (a: Attachment) => {
    const { data, error } = await supabase.storage.from('agency-files').createSignedUrl(a.storage_path, 60)
    if (error) return toast.error(friendlyError(error))
    window.open(data.signedUrl, '_blank', 'noopener')
  }
  const removeAttachment = async (a: Attachment) => {
    await supabase.storage.from('agency-files').remove([a.storage_path])
    const { error } = await supabase.from('task_attachments').delete().eq('id', a.id)
    if (error) return toast.error(friendlyError(error))
    qc.invalidateQueries({ queryKey: ['tasks', 'attachments', id] })
  }
  const deleteTask = async () => {
    if (!window.confirm('Delete this task? This cannot be undone.')) return
    const { error } = await supabase.from('tasks').delete().eq('id', id!)
    if (error) return toast.error(friendlyError(error))
    toast.success('Task deleted'); invalidate(); navigate(-1)
  }

  if (q.isLoading) return <Spinner />
  if (q.error) return <ErrorState message={friendlyError(q.error)} onRetry={q.refetch} />
  if (!t) return <EmptyState title="Task not found" description="It may not exist or you may not have access." />
  const status = statuses?.find((s) => s.id === t.status_id)
  const uid = session!.user.id
  const canEdit = internal && (can('tasks.edit_all') || t.reviewer_id === uid || t.created_by === uid || t.task_assignees.some((a) => a.profile_id === uid) || project.data?.owner_id === uid)
  const assigned = new Set(t.task_assignees.map((a) => a.profile_id))

  return (
    <div className="space-y-6">
      <Link to={`/projects/${t.project_id}`} className="inline-flex items-center gap-1 text-sm text-muted-foreground hover:text-foreground"><ArrowLeft className="size-4" />{project.data?.name ?? 'Project'}</Link>
      <div className="grid gap-6 lg:grid-cols-3">
        <div className="space-y-6 lg:col-span-2">
          <Card><CardBody className="space-y-4">
            {canEdit ? <Input aria-label="Task title" defaultValue={t.title} key={t.title} className="h-auto border-transparent px-0 text-xl font-semibold shadow-none hover:border-input focus:border-input focus:px-2"
              onBlur={(e) => { const v = e.target.value.trim(); if (v && v !== t.title) update.mutate({ title: v }) }} /> : <h1 className="text-xl font-semibold">{t.title}</h1>}
            {t.parent_task_id && <Link className="text-sm text-primary" to={`/tasks/${t.parent_task_id}`}>↑ Parent task</Link>}
            {canEdit ? <Textarea aria-label="Description" defaultValue={t.description ?? ''} key={t.description ?? ''} rows={6} placeholder="Add a description…"
              onBlur={(e) => { if (e.target.value !== (t.description ?? '')) update.mutate({ description: e.target.value || null }) }} />
              : <p className="whitespace-pre-line text-sm">{t.description || 'No description.'}</p>}
          </CardBody></Card>

          {!t.parent_task_id && internal && (
            <Card><CardHeader title="Subtasks" action={canEdit && <Button size="sm" variant="outline" onClick={() => setSubOpen(true)}><Plus />Add</Button>} />
              {!subtasks.data?.length ? <EmptyState title="No subtasks" /> : <ul className="divide-y">{subtasks.data.map((s) => (
                <li key={s.id}><Link to={`/tasks/${s.id}`} className="flex items-center justify-between px-5 py-2.5 text-sm hover:bg-muted/40">
                  <span>{s.title}</span><StatusPill status={statuses?.find((x) => x.id === s.status_id)} /></Link></li>))}</ul>}
            </Card>
          )}

          <Card><CardHeader title="Comments" description={internal ? 'Type @Name to mention a teammate. Internal comments are never shown to clients.' : undefined} />
            <ul className="divide-y">{comments.data?.map((c) => (
              <li key={c.id} className="flex gap-3 px-5 py-3">
                <Avatar name={nameOf(people, c.author_id) === '—' ? 'Client' : nameOf(people, c.author_id)} />
                <div className="min-w-0 flex-1">
                  <div className="flex items-center gap-2 text-xs text-muted-foreground"><span className="font-medium text-foreground">{nameOf(people, c.author_id) === '—' ? (c.author_id === uid ? 'You' : 'Client') : nameOf(people, c.author_id)}</span>
                    {fmtDate(c.created_at, 'dd MMM, hh:mm a')}{internal && (c.is_internal ? <Badge tone="slate" className="gap-1"><Lock className="size-3" />Internal</Badge> : <Badge tone="blue">Client-visible</Badge>)}
                    {c.author_id === uid && <button className="ml-auto hover:text-destructive" aria-label="Delete comment" onClick={() => deleteComment.mutate(c.id)}><Trash2 className="size-3.5" /></button>}</div>
                  <p className="mt-1 whitespace-pre-line text-sm">{c.body}</p>
                </div>
              </li>))}</ul>
            {!comments.data?.length && <EmptyState title="No comments yet" />}
            <CardBody className="space-y-2 border-t">
              <Textarea aria-label="Write a comment" value={comment} onChange={(e) => setComment(e.target.value)} placeholder={internal ? 'Write a comment… use @Name to mention' : 'Write feedback for the team…'} />
              <div className="flex items-center justify-between">
                {internal ? <label className="flex items-center gap-2 text-sm"><input type="checkbox" checked={commentInternal} onChange={(e) => setCommentInternal(e.target.checked)} />Internal only</label> : <span />}
                <Button disabled={!comment.trim()} loading={postComment.isPending} onClick={() => postComment.mutate()}>Post</Button>
              </div>
            </CardBody>
          </Card>
        </div>

        <div className="space-y-4">
          <Card><CardBody className="space-y-4 text-sm">
            <div className="space-y-1.5"><Label htmlFor="task-status">Status</Label>
              {canEdit ? <Select id="task-status" value={t.status_id} onChange={(e) => update.mutate({ status_id: e.target.value })}>
                {statuses?.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</Select> : <div><StatusPill status={status} /></div>}
              {t.reviewer_id && status?.category !== 'done' && <p className="text-xs text-muted-foreground">Needs review by {nameOf(people, t.reviewer_id)} before completion.</p>}</div>
            <div className="space-y-1.5"><Label htmlFor="task-priority">Priority</Label>
              {canEdit ? <Select id="task-priority" value={t.priority} onChange={(e) => update.mutate({ priority: e.target.value })}>{PRIORITIES.map((p) => <option key={p} value={p}>{p}</option>)}</Select> : <div><StatusBadge value={t.priority} /></div>}</div>
            <div className="grid grid-cols-2 gap-3">
              <div className="space-y-1.5"><Label htmlFor="task-start">Start</Label>{canEdit ? <Input id="task-start" type="date" defaultValue={t.start_date ?? ''} key={`s${t.start_date}`} onBlur={(e) => e.target.value !== (t.start_date ?? '') && update.mutate({ start_date: e.target.value || null })} /> : <p>{fmtDate(t.start_date)}</p>}</div>
              <div className="space-y-1.5"><Label htmlFor="task-due">Due</Label>{canEdit ? <Input id="task-due" type="date" defaultValue={t.due_date ?? ''} key={`d${t.due_date}`} onBlur={(e) => e.target.value !== (t.due_date ?? '') && update.mutate({ due_date: e.target.value || null })} />
                : <p className={isOverdue(t, status?.category) ? 'font-medium text-destructive' : ''}>{fmtDate(t.due_date)}</p>}</div>
            </div>
            {internal && <>
              <div className="space-y-1.5"><Label>Estimate</Label><p>{fmtMinutes(t.estimated_minutes)}</p></div>
              <div className="space-y-1.5"><Label htmlFor="task-reviewer">Reviewer</Label>
                {canEdit ? <Select id="task-reviewer" value={t.reviewer_id ?? ''} onChange={(e) => update.mutate({ reviewer_id: e.target.value || null })}><option value="">No review step</option>
                  {people?.filter((p) => p.is_active).map((p) => <option key={p.id} value={p.id}>{p.full_name || p.email}</option>)}</Select> : <p>{nameOf(people, t.reviewer_id)}</p>}</div>
              <div className="space-y-1.5"><Label>Assignees</Label>
                <div className="flex flex-wrap gap-1.5">{t.task_assignees.map((a) => <Badge key={a.profile_id} tone="blue" className="gap-1">{nameOf(people, a.profile_id)}
                  {canEdit && <button aria-label={`Unassign ${nameOf(people, a.profile_id)}`} onClick={() => unassign.mutate(a.profile_id)}><X className="size-3" /></button>}</Badge>)}
                  {!t.task_assignees.length && <span className="text-muted-foreground">Unassigned</span>}</div>
                {canEdit && <Select aria-label="Add assignee" value="" onChange={(e) => e.target.value && assign.mutate(e.target.value)}><option value="">Add assignee…</option>
                  {people?.filter((p) => p.is_active && !assigned.has(p.id)).map((p) => <option key={p.id} value={p.id}>{p.full_name || p.email}</option>)}</Select>}</div>
              {canEdit && <label className="flex items-center gap-2"><input type="checkbox" checked={t.client_visible} onChange={(e) => update.mutate({ client_visible: e.target.checked })} />Visible to client</label>}
            </>}
          </CardBody></Card>

          {internal && <Card><CardHeader title="Blocked by" description="Must be completed first" />
            <CardBody className="space-y-2 text-sm">
              {deps.data?.map((d) => <div key={d.depends_on_task_id} className="flex items-center justify-between gap-2">
                <Link className="truncate text-primary" to={`/tasks/${d.depends_on_task_id}`}>{d.depends_on?.title ?? 'Hidden task'}</Link>
                <span className="flex items-center gap-2"><StatusPill status={statuses?.find((s) => s.id === d.depends_on?.status_id)} />
                  {canEdit && <button aria-label="Remove dependency" onClick={() => removeDep.mutate(d.depends_on_task_id)}><X className="size-3.5" /></button>}</span></div>)}
              {!deps.data?.length && <p className="text-muted-foreground">No dependencies</p>}
              {canEdit && <div className="flex gap-2 pt-1"><Select aria-label="Add dependency" value={depId} onChange={(e) => setDepId(e.target.value)}><option value="">Add dependency…</option>
                {siblings.data?.filter((s) => !deps.data?.some((d) => d.depends_on_task_id === s.id)).map((s) => <option key={s.id} value={s.id}>{s.title}</option>)}</Select>
                <Button size="sm" variant="outline" disabled={!depId} onClick={() => addDep.mutate()}>Add</Button></div>}
            </CardBody></Card>}

          <Card><CardHeader title="Attachments" action={<>
            <input ref={fileRef} type="file" className="hidden" onChange={(e) => { const f = e.target.files?.[0]; if (f) upload(f); e.target.value = '' }} />
            <Button size="sm" variant="outline" onClick={() => fileRef.current?.click()}><Paperclip />Attach</Button></>} />
            <CardBody className="space-y-2 text-sm">
              {attachments.data?.map((a) => <div key={a.id} className="flex items-center justify-between gap-2">
                <button className="truncate text-left text-primary hover:underline" onClick={() => download(a)}>{a.file_name}</button>
                <span className="flex items-center gap-2 text-xs text-muted-foreground">{a.size_bytes ? `${Math.ceil(a.size_bytes / 1024)} KB` : ''}
                  {(a.uploaded_by === uid || canEdit) && <button aria-label={`Delete ${a.file_name}`} onClick={() => removeAttachment(a)}><Trash2 className="size-3.5" /></button>}</span></div>)}
              {!attachments.data?.length && <p className="text-muted-foreground">No files</p>}
            </CardBody></Card>

          {internal && (can('tasks.delete') || project.data?.owner_id === uid) && <Button variant="outline" className="w-full" onClick={deleteTask}><Trash2 />Delete task</Button>}
        </div>
      </div>
      {internal && <CreateTaskDialog open={subOpen} onClose={() => { setSubOpen(false); qc.invalidateQueries({ queryKey: ['tasks', 'subtasks', id] }) }} projectId={t.project_id} parentTaskId={t.id} />}
    </div>
  )
}
