import { useMemo, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { toast } from 'sonner'
import { format, parseISO } from 'date-fns'
import { Check, ExternalLink, MessageSquareWarning, Plus } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { unwrap } from '@/lib/query'
import { friendlyError } from '@/lib/errors'
import { fmtDate, titleCase } from '@/lib/utils'
import { isoDay } from '@/lib/dates'
import { nameOf, useClientsLite, usePeople } from '@/lib/lookups'
import { CONTENT_PLATFORMS, CONTENT_STATUSES, CONTENT_TYPES, type ContentItem, type ContentStatus } from '@/lib/types'
import { useAuth } from '@/features/auth/AuthProvider'
import { DataTable } from '@/components/DataTable'
import { MonthCalendar } from '@/components/MonthCalendar'
import { Badge, Button, Card, CardBody, Dialog, EmptyState, ErrorState, Field, Input, PageHeader, Select, Spinner, StatusBadge, Tabs, Textarea } from '@/components/ui'

export const CONTENT_COLORS: Record<ContentStatus, string> = {
  idea: '#94a3b8', in_progress: '#2563eb', internal_review: '#d97706', client_review: '#f59e0b', changes_requested: '#dc2626',
  approved: '#16a34a', scheduled: '#0891b2', published: '#475569', cancelled: '#64748b',
}
const PLATFORM_LABEL: Record<string, string> = { x: 'X (Twitter)', google_business: 'Google Business', linkedin: 'LinkedIn', youtube: 'YouTube' }
export const platformLabel = (p: string) => PLATFORM_LABEL[p] ?? titleCase(p)

/** Next steps staff can move an item to. Approval itself is the client's (or a content manager's) action. */
const NEXT: Partial<Record<ContentStatus, ContentStatus[]>> = {
  idea: ['in_progress'], in_progress: ['internal_review', 'client_review'], internal_review: ['in_progress', 'client_review'],
  changes_requested: ['in_progress', 'client_review'], approved: ['scheduled', 'published', 'client_review'], scheduled: ['published', 'approved'],
}
const ACTION_LABEL: Partial<Record<ContentStatus, string>> = {
  in_progress: 'Start work', internal_review: 'Internal review', client_review: 'Send to client', scheduled: 'Mark scheduled', published: 'Mark published', approved: 'Unschedule',
}
const toLocalInput = (iso?: string | null) => (iso ? format(parseISO(iso), "yyyy-MM-dd'T'HH:mm") : '')

type Draft = Partial<ContentItem> & { scheduled_local?: string }

function ContentForm({ draft, setDraft }: { draft: Draft; setDraft: (d: Draft) => void }) {
  const { can } = useAuth()
  const { data: clients } = useClientsLite(true)
  const { data: people } = usePeople()
  const projects = useQuery({ queryKey: ['projects', 'by-client', draft.client_id], enabled: Boolean(draft.client_id),
    queryFn: async () => unwrap(await supabase.from('projects').select('id, name').eq('client_id', draft.client_id!).in('status', ['planning', 'active']).order('name')) as { id: string; name: string }[] })
  const set = (k: keyof Draft) => (e: { target: { value: string } }) => setDraft({ ...draft, [k]: e.target.value })
  return (
    <div className="grid gap-4 sm:grid-cols-2">
      <Field label="Title" className="sm:col-span-2">{(p) => <Input {...p} value={draft.title ?? ''} onChange={set('title')} placeholder="e.g. Diwali offer reel" />}</Field>
      <Field label="Client">{(p) => <Select {...p} value={draft.client_id ?? ''} disabled={Boolean(draft.id)} onChange={(e) => setDraft({ ...draft, client_id: e.target.value, project_id: null })}>
        <option value="">Choose…</option>{clients?.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</Select>}</Field>
      <Field label="Project (optional)">{(p) => <Select {...p} value={draft.project_id ?? ''} onChange={(e) => setDraft({ ...draft, project_id: e.target.value || null })}>
        <option value="">—</option>{projects.data?.map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}</Select>}</Field>
      <Field label="Platform">{(p) => <Select {...p} value={draft.platform ?? 'instagram'} onChange={set('platform')}>{CONTENT_PLATFORMS.map((x) => <option key={x} value={x}>{platformLabel(x)}</option>)}</Select>}</Field>
      <Field label="Format">{(p) => <Select {...p} value={draft.content_type ?? 'post'} onChange={set('content_type')}>{CONTENT_TYPES.map((x) => <option key={x} value={x}>{titleCase(x)}</option>)}</Select>}</Field>
      <Field label="Publish date & time">{(p) => <Input {...p} type="datetime-local" value={draft.scheduled_local ?? ''} onChange={set('scheduled_local')} />}</Field>
      <Field label="Assignee">{(p) => <Select {...p} value={draft.assignee_id ?? ''} onChange={(e) => setDraft({ ...draft, assignee_id: e.target.value || null })}>
        <option value="">Unassigned</option>{people?.filter((x) => x.is_active).map((x) => <option key={x.id} value={x.id}>{x.full_name || x.email}</option>)}</Select>}</Field>
      <Field label="Caption / copy" className="sm:col-span-2">{(p) => <Textarea {...p} rows={4} value={draft.caption ?? ''} onChange={set('caption')} />}</Field>
      <Field label="Creative link" hint="Google Drive, Canva or Dropbox link the client can open" className="sm:col-span-2">{(p) =>
        <Input {...p} type="url" value={draft.creative_url ?? ''} onChange={set('creative_url')} placeholder="https://" />}</Field>
      {!can('content.manage') && <p className="text-xs text-muted-foreground sm:col-span-2">Only the client (or a content manager) can approve content.</p>}
    </div>
  )
}

function ItemDialog({ item, onClose }: { item: ContentItem | null; onClose: () => void }) {
  const { audience, can, session } = useAuth()
  const { data: people } = usePeople()
  const { data: clients } = useClientsLite(audience === 'internal')
  const qc = useQueryClient()
  const [editing, setEditing] = useState(false)
  const [draft, setDraft] = useState<Draft>({})
  const [feedback, setFeedback] = useState('')
  const [pubUrl, setPubUrl] = useState('')
  const inv = () => qc.invalidateQueries({ queryKey: ['content'] })
  const update = useMutation({ mutationFn: async (row: Partial<ContentItem>) => unwrap(await supabase.from('content_items').update(row).eq('id', item!.id).select().single()) as ContentItem,
    onSuccess: () => { inv(); setEditing(false); toast.success('Saved') } })
  const review = useMutation({ mutationFn: async (approve: boolean) => unwrap(await supabase.rpc('review_content', { p_item: item!.id, p_approve: approve, p_feedback: feedback || null })),
    onSuccess: (_d, approve) => { inv(); setFeedback(''); toast.success(approve ? 'Approved — thank you!' : 'Change request sent to the team'); onClose() } })
  if (!item) return null
  const internal = audience === 'internal'
  const canEdit = internal && (can('content.manage') || item.assignee_id === session?.user.id || item.created_by === session?.user.id)
  const canReview = item.status === 'client_review' && (!internal || can('content.manage'))
  const locked = ['approved', 'scheduled', 'published'].includes(item.status)
  const saveEdit = () => update.mutate({ title: draft.title, platform: draft.platform, content_type: draft.content_type, caption: draft.caption || null,
    creative_url: draft.creative_url || null, project_id: draft.project_id || null, assignee_id: draft.assignee_id || null,
    scheduled_at: draft.scheduled_local ? new Date(draft.scheduled_local).toISOString() : null })
  const move = (to: ContentStatus) => {
    if (to === 'published') return update.mutate({ status: to, published_url: pubUrl || null })
    update.mutate({ status: to })
  }
  return (
    <Dialog open onClose={onClose} title={item.title} wide description={`${platformLabel(item.platform)} · ${titleCase(item.content_type)}${internal ? ` · ${nameOf(clients, item.client_id)}` : ''}`}
      footer={editing ? <><Button variant="outline" onClick={() => setEditing(false)}>Cancel</Button><Button loading={update.isPending} disabled={(draft.title ?? '').trim().length < 2} onClick={saveEdit}>Save</Button></> : undefined}>
      {editing ? <ContentForm draft={draft} setDraft={setDraft} /> : (
        <div className="space-y-4 text-sm">
          <div className="flex flex-wrap items-center gap-2"><StatusBadge value={item.status} />
            <span className="text-muted-foreground">{item.scheduled_at ? `Goes live ${fmtDate(item.scheduled_at, 'EEE dd MMM, hh:mm a')}` : 'No date set'}</span>
            {internal && <span className="text-muted-foreground">· {nameOf(people, item.assignee_id)}</span>}</div>
          <div className="whitespace-pre-line rounded-md bg-muted/50 p-3">{item.caption || <span className="text-muted-foreground">No caption yet</span>}</div>
          {item.creative_url && <a className="inline-flex items-center gap-1 text-primary hover:underline" href={item.creative_url} target="_blank" rel="noopener noreferrer"><ExternalLink className="size-4" />Open creative</a>}
          {item.published_url && <p><a className="inline-flex items-center gap-1 text-primary hover:underline" href={item.published_url} target="_blank" rel="noopener noreferrer"><ExternalLink className="size-4" />View live post</a></p>}
          {item.client_feedback && <div className="rounded-md border border-red-200 bg-red-50 p-3 text-red-800 dark:border-red-900 dark:bg-red-950/30 dark:text-red-200">
            <p className="font-medium">Client feedback</p><p className="whitespace-pre-line">{item.client_feedback}</p></div>}
          {item.reviewed_at && item.status !== 'changes_requested' && <p className="text-xs text-muted-foreground">Approved {fmtDate(item.reviewed_at, 'dd MMM, hh:mm a')}</p>}

          {canReview && <div className="space-y-2 rounded-md border p-3">
            <p className="font-medium">{internal ? 'Record the client\'s decision' : 'Your review'}</p>
            <Textarea aria-label="Feedback" rows={2} value={feedback} onChange={(e) => setFeedback(e.target.value)} placeholder="Feedback (required if you need changes)" />
            <div className="flex flex-wrap justify-end gap-2">
              <Button variant="outline" disabled={!feedback.trim()} loading={review.isPending && review.variables === false} onClick={() => review.mutate(false)}><MessageSquareWarning />Request changes</Button>
              <Button loading={review.isPending && review.variables === true} onClick={() => review.mutate(true)}><Check />Approve</Button></div>
          </div>}

          {canEdit && <div className="flex flex-wrap items-center gap-2 border-t pt-3">
            {!locked && <Button variant="outline" size="sm" onClick={() => { setDraft({ ...item, scheduled_local: toLocalInput(item.scheduled_at) }); setEditing(true) }}>Edit</Button>}
            {NEXT[item.status]?.filter((s) => s !== 'scheduled' || item.scheduled_at).map((s) => (
              <Button key={s} size="sm" variant={s === 'client_review' ? 'default' : 'outline'} loading={update.isPending && update.variables?.status === s} onClick={() => move(s)}>
                {item.status === 'approved' && s === 'client_review' ? 'Send back for review' : ACTION_LABEL[s] ?? titleCase(s)}</Button>))}
            {(item.status === 'approved' || item.status === 'scheduled') && <Input aria-label="Live post link" className="h-8 w-56" placeholder="Live post link (optional)" value={pubUrl} onChange={(e) => setPubUrl(e.target.value)} />}
            {item.status === 'approved' && !item.scheduled_at && <span className="text-xs text-muted-foreground">Send back for review to set a date.</span>}
            {item.status !== 'published' && item.status !== 'cancelled' && (can('content.manage')) &&
              <Button size="sm" variant="ghost" onClick={() => window.confirm('Cancel this content item?') && update.mutate({ status: 'cancelled' })}>Cancel item</Button>}
          </div>}
        </div>)}
    </Dialog>
  )
}

export default function ContentPage() {
  const { audience, org, session } = useAuth()
  const internal = audience === 'internal'
  const qc = useQueryClient()
  const [view, setView] = useState<'calendar' | 'list' | 'review'>(internal ? 'calendar' : 'review')
  const [month, setMonth] = useState(() => isoDay(new Date()))
  const [client, setClient] = useState(''); const [status, setStatus] = useState('')
  const [openId, setOpenId] = useState<string | null>(null)
  const [creating, setCreating] = useState(false)
  const [draft, setDraft] = useState<Draft>({ platform: 'instagram', content_type: 'post' })
  const { data: clients } = useClientsLite(internal)
  const list = useQuery({ queryKey: ['content', client, status],
    queryFn: async () => {
      let q = supabase.from('content_items').select('*').order('scheduled_at', { ascending: true, nullsFirst: false }).limit(1000)
      if (client) q = q.eq('client_id', client)
      if (status) q = q.eq('status', status)
      return unwrap(await q) as ContentItem[]
    } })
  const create = useMutation({
    mutationFn: async () => unwrap(await supabase.from('content_items').insert({ org_id: org!.id, client_id: draft.client_id, project_id: draft.project_id || null,
      title: draft.title?.trim(), platform: draft.platform, content_type: draft.content_type, caption: draft.caption || null, creative_url: draft.creative_url || null,
      assignee_id: draft.assignee_id || null, scheduled_at: draft.scheduled_local ? new Date(draft.scheduled_local).toISOString() : null, created_by: session!.user.id })),
    onSuccess: () => { qc.invalidateQueries({ queryKey: ['content'] }); setCreating(false); setDraft({ platform: 'instagram', content_type: 'post' }); toast.success('Content added') },
  })
  const items = list.data ?? []
  const toReview = items.filter((i) => i.status === 'client_review')
  const calItems = useMemo(() => items.filter((i) => i.scheduled_at && i.status !== 'cancelled').map((i) => ({
    id: i.id, day: isoDay(parseISO(i.scheduled_at!)), label: `${format(parseISO(i.scheduled_at!), 'HH:mm')} ${i.title}`,
    color: CONTENT_COLORS[i.status], onClick: () => setOpenId(i.id) })), [items])
  const opened = items.find((i) => i.id === openId) ?? null
  const tabs = [...(internal ? [] : [{ value: 'review' as const, label: 'Needs your review', count: toReview.length || undefined }]),
    { value: 'calendar' as const, label: 'Calendar' }, { value: 'list' as const, label: 'List' }]

  return (
    <div className="space-y-6">
      <PageHeader title={internal ? 'Content calendar' : 'Content'} description={internal ? 'Plan posts, send them to clients for approval and track publishing.' : 'Review and approve the posts we have prepared for you.'}
        actions={internal && <Button onClick={() => setCreating(true)}><Plus />New content</Button>} />
      <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <Tabs tabs={tabs} value={view} onChange={setView} />
        <div className="flex gap-2">
          {internal && <Select aria-label="Client" className="sm:w-48" value={client} onChange={(e) => setClient(e.target.value)}><option value="">All clients</option>
            {clients?.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</Select>}
          {view === 'list' && <Select aria-label="Status" className="sm:w-44" value={status} onChange={(e) => setStatus(e.target.value)}><option value="">All statuses</option>
            {CONTENT_STATUSES.map((s) => <option key={s} value={s}>{titleCase(s)}</option>)}</Select>}
        </div>
      </div>
      {list.error ? <ErrorState message={friendlyError(list.error)} onRetry={list.refetch} /> : list.isLoading ? <Spinner /> : <>
        {view === 'review' && (toReview.length === 0 ? <Card><EmptyState title="Nothing waiting for your review" description="We'll notify you when new content is ready." /></Card> : (
          <div className="grid gap-4 md:grid-cols-2">{toReview.map((i) => (
            <Card key={i.id}><CardBody className="space-y-2">
              <div className="flex items-start justify-between gap-2"><p className="font-medium">{i.title}</p><Badge tone="amber">Review</Badge></div>
              <p className="text-xs text-muted-foreground">{platformLabel(i.platform)} · {titleCase(i.content_type)} · {i.scheduled_at ? fmtDate(i.scheduled_at, 'EEE dd MMM, hh:mm a') : 'date to be confirmed'}</p>
              <p className="line-clamp-3 whitespace-pre-line text-sm">{i.caption}</p>
              <Button size="sm" onClick={() => setOpenId(i.id)}>Review</Button>
            </CardBody></Card>))}</div>))}
        {view === 'calendar' && <MonthCalendar month={month} onMonthChange={setMonth} items={calItems}
          toolbar={<div className="flex flex-wrap gap-2 text-xs">{(['client_review', 'changes_requested', 'approved', 'scheduled', 'published'] as ContentStatus[]).map((s) =>
            <span key={s} className="flex items-center gap-1"><span className="size-2.5 rounded-sm" style={{ backgroundColor: CONTENT_COLORS[s] }} />{titleCase(s)}</span>)}</div>} />}
        {view === 'list' && <Card><DataTable rows={items} onRowClick={(i) => setOpenId(i.id)} empty={<EmptyState title="No content yet" />} columns={[
          { key: 't', header: 'Content', render: (i) => <span><span className="block font-medium">{i.title}</span><span className="text-xs text-muted-foreground">{platformLabel(i.platform)} · {titleCase(i.content_type)}</span></span> },
          ...(internal ? [{ key: 'c', header: 'Client', render: (i: ContentItem) => nameOf(clients, i.client_id) }] : []),
          { key: 'd', header: 'Goes live', render: (i) => i.scheduled_at ? fmtDate(i.scheduled_at, 'dd MMM, hh:mm a') : '—' },
          { key: 's', header: 'Status', render: (i) => <StatusBadge value={i.status} /> },
        ]} /></Card>}
      </>}
      <ItemDialog key={openId ?? 'none'} item={opened} onClose={() => setOpenId(null)} />
      <Dialog open={creating} onClose={() => setCreating(false)} title="New content" wide
        footer={<><Button variant="outline" onClick={() => setCreating(false)}>Cancel</Button>
          <Button disabled={!draft.client_id || (draft.title ?? '').trim().length < 2} loading={create.isPending} onClick={() => create.mutate()}>Add</Button></>}>
        <ContentForm draft={draft} setDraft={setDraft} />
      </Dialog>
    </div>
  )
}
