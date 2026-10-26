import { useState } from 'react'
import { Link } from 'react-router-dom'
import { useQueryClient } from '@tanstack/react-query'
import { useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { z } from 'zod'
import { toast } from 'sonner'
import { DndContext, KeyboardSensor, PointerSensor, useDraggable, useDroppable, useSensor, useSensors, type DragEndEvent } from '@dnd-kit/core'
import { CalendarClock } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { friendlyError } from '@/lib/errors'
import { cn, fmtDate } from '@/lib/utils'
import { nameOf, usePeople } from '@/lib/lookups'
import { PRIORITIES, type Priority, type StatusCategory, type Task, type TaskStatus } from '@/lib/types'
import { useAuth } from '@/features/auth/AuthProvider'
import { Avatar, Badge, Button, Dialog, Field, Input, Select, StatusBadge, Textarea } from '@/components/ui'

export interface TaskWithAssignees extends Task { task_assignees: { profile_id: string }[] }
export const TASK_SELECT = '*, task_assignees(profile_id)'

export function isOverdue(t: Pick<Task, 'due_date'>, category: StatusCategory | undefined, today = new Date().toISOString().slice(0, 10)): boolean {
  return Boolean(t.due_date && t.due_date < today && category !== 'done' && category !== 'cancelled')
}

export function PriorityBadge({ value }: { value: Priority }) {
  return <StatusBadge value={value} />
}

export function StatusPill({ status }: { status?: TaskStatus }) {
  if (!status) return null
  return <span className="inline-flex items-center gap-1.5 text-xs font-medium"><span className="size-2 rounded-full" style={{ background: status.color }} />{status.name}</span>
}

// ---------- create / edit task ----------
const taskSchema = z.object({
  title: z.string().trim().min(2, 'Required').max(200),
  description: z.string().max(10000).optional(),
  priority: z.enum(['low', 'medium', 'high', 'urgent']),
  reviewer_id: z.string().optional(),
  assignee_id: z.string().optional(),
  start_date: z.string().optional(),
  due_date: z.string().optional(),
  estimate_hours: z.coerce.number().min(0).max(1000).optional().or(z.literal('')),
  client_visible: z.boolean(),
  parent_task_id: z.string().optional(),
}).refine((v) => !v.due_date || !v.start_date || v.due_date >= v.start_date, { path: ['due_date'], message: 'Due date is before start date' })

export function CreateTaskDialog({ open, onClose, projectId, parentTaskId, memberIds }: {
  open: boolean; onClose: () => void; projectId: string; parentTaskId?: string; memberIds?: string[]
}) {
  const { org, session } = useAuth()
  const { data: people } = usePeople()
  const qc = useQueryClient()
  const form = useForm<z.input<typeof taskSchema>, unknown, z.output<typeof taskSchema>>({
    resolver: zodResolver(taskSchema), defaultValues: { priority: 'medium', client_visible: false, parent_task_id: parentTaskId },
  })
  const choices = people?.filter((p) => p.is_active && (!memberIds || memberIds.includes(p.id))) ?? []
  const submit = form.handleSubmit(async (v) => {
    const { data, error } = await supabase.from('tasks').insert({
      org_id: org!.id, project_id: projectId, title: v.title, description: v.description || null, priority: v.priority,
      reviewer_id: v.reviewer_id || null, start_date: v.start_date || null, due_date: v.due_date || null,
      estimated_minutes: v.estimate_hours === '' || v.estimate_hours == null ? null : Math.round(Number(v.estimate_hours) * 60),
      client_visible: v.client_visible, parent_task_id: parentTaskId ?? null, created_by: session!.user.id, position: Date.now(),
    }).select('id').single()
    if (error) return toast.error(friendlyError(error))
    if (v.assignee_id) {
      const a = await supabase.from('task_assignees').insert({ task_id: data.id, profile_id: v.assignee_id, org_id: org!.id, assigned_by: session!.user.id })
      if (a.error) toast.error(`Task created, but assignment failed: ${friendlyError(a.error)}`)
    }
    toast.success('Task created')
    qc.invalidateQueries({ queryKey: ['tasks'] }); qc.invalidateQueries({ queryKey: ['project'] }); qc.invalidateQueries({ queryKey: ['dashboard'] })
    form.reset({ priority: 'medium', client_visible: false }); onClose()
  })
  const e = form.formState.errors
  return (
    <Dialog open={open} onClose={onClose} title={parentTaskId ? 'New subtask' : 'New task'} wide
      footer={<><Button variant="outline" onClick={onClose}>Cancel</Button><Button onClick={submit} loading={form.formState.isSubmitting}>Create task</Button></>}>
      <form onSubmit={submit} className="grid gap-4 sm:grid-cols-2">
        <Field label="Title" error={e.title?.message} className="sm:col-span-2">{(p) => <Input {...p} {...form.register('title')} />}</Field>
        <Field label="Description" className="sm:col-span-2">{(p) => <Textarea {...p} rows={4} {...form.register('description')} />}</Field>
        <Field label="Assignee">{(p) => <Select {...p} {...form.register('assignee_id')}><option value="">Unassigned</option>{choices.map((x) => <option key={x.id} value={x.id}>{x.full_name || x.email}</option>)}</Select>}</Field>
        <Field label="Reviewer" hint="If set, only the reviewer can mark it complete">{(p) => <Select {...p} {...form.register('reviewer_id')}><option value="">No review step</option>
          {people?.filter((x) => x.is_active).map((x) => <option key={x.id} value={x.id}>{x.full_name || x.email}</option>)}</Select>}</Field>
        <Field label="Priority">{(p) => <Select {...p} {...form.register('priority')}>{PRIORITIES.map((x) => <option key={x} value={x}>{x[0]!.toUpperCase() + x.slice(1)}</option>)}</Select>}</Field>
        <Field label="Estimate (hours)" error={e.estimate_hours?.message}>{(p) => <Input type="number" step="0.25" min={0} {...p} {...form.register('estimate_hours')} />}</Field>
        <Field label="Start date">{(p) => <Input type="date" {...p} {...form.register('start_date')} />}</Field>
        <Field label="Due date" error={e.due_date?.message}>{(p) => <Input type="date" {...p} {...form.register('due_date')} />}</Field>
        <label className="flex items-center gap-2 text-sm sm:col-span-2"><input type="checkbox" {...form.register('client_visible')} />Visible to the client in their portal</label>
      </form>
    </Dialog>
  )
}

// ---------- Kanban ----------
function KanbanCard({ task, people, overdue, disabled }: { task: TaskWithAssignees; people?: { id: string; full_name: string }[]; overdue: boolean; disabled?: boolean }) {
  const { attributes, listeners, setNodeRef, transform, isDragging } = useDraggable({ id: task.id, disabled })
  return (
    <div ref={setNodeRef} {...listeners} {...attributes} aria-roledescription="Draggable task" aria-describedby="kanban-help"
      style={transform ? { transform: `translate3d(${transform.x}px, ${transform.y}px, 0)` } : undefined}
      className={cn(disabled ? '' : 'cursor-grab active:cursor-grabbing', 'rounded-md border bg-card p-3 text-sm shadow-sm', isDragging && 'z-10 opacity-80 shadow-lg')}>
      <Link to={`/tasks/${task.id}`} className="font-medium hover:text-primary" onPointerDown={(e) => e.stopPropagation()}>{task.title}</Link>
      <div className="mt-2 flex flex-wrap items-center gap-2">
        <PriorityBadge value={task.priority} />
        {task.due_date && <span className={cn('inline-flex items-center gap-1 text-xs', overdue ? 'font-medium text-destructive' : 'text-muted-foreground')}>
          <CalendarClock className="size-3" />{fmtDate(task.due_date, 'dd MMM')}</span>}
        {task.client_visible && <Badge tone="slate">Client</Badge>}
        <span className="ml-auto flex -space-x-2">{task.task_assignees.map((a) => <Avatar key={a.profile_id} name={nameOf(people, a.profile_id)} className="size-6 text-[10px] ring-2 ring-card" />)}</span>
      </div>
    </div>
  )
}

function KanbanColumn({ status, children, count }: { status: TaskStatus; children: React.ReactNode; count: number }) {
  const { setNodeRef, isOver } = useDroppable({ id: status.id })
  return (
    <section ref={setNodeRef} aria-label={`${status.name} column`} className={cn('flex w-72 shrink-0 flex-col rounded-lg bg-muted/50 p-2', isOver && 'ring-2 ring-primary/40')}>
      <header className="flex items-center gap-2 px-1 pb-2 text-sm font-medium"><span className="size-2 rounded-full" style={{ background: status.color }} />{status.name}
        <span className="ml-auto text-xs text-muted-foreground">{count}</span></header>
      <div className="flex min-h-24 flex-col gap-2">{children}</div>
    </section>
  )
}

export function KanbanBoard({ tasks, statuses, readOnly }: { tasks: TaskWithAssignees[]; statuses: TaskStatus[]; readOnly?: boolean }) {
  const qc = useQueryClient()
  const { data: people } = usePeople()
  const [optimistic, setOptimistic] = useState<Record<string, string>>({})
  const sensors = useSensors(useSensor(PointerSensor, { activationConstraint: { distance: 5 } }), useSensor(KeyboardSensor))
  const today = new Date().toISOString().slice(0, 10)
  const catOf = (id: string) => statuses.find((s) => s.id === id)?.category

  const onDragEnd = async (e: DragEndEvent) => {
    const taskId = String(e.active.id)
    const to = e.over ? String(e.over.id) : null
    const task = tasks.find((t) => t.id === taskId)
    if (!to || !task || (optimistic[taskId] ?? task.status_id) === to) return
    setOptimistic((o) => ({ ...o, [taskId]: to }))
    const { error } = await supabase.from('tasks').update({ status_id: to }).eq('id', taskId)
    if (error) toast.error(friendlyError(error)) // server enforces review/dependency rules; card snaps back
    setOptimistic((o) => { const n = { ...o }; delete n[taskId]; return n })
    qc.invalidateQueries({ queryKey: ['tasks'] }); qc.invalidateQueries({ queryKey: ['project'] }); qc.invalidateQueries({ queryKey: ['dashboard'] })
  }

  const columns = statuses.filter((s) => s.category !== 'cancelled' || tasks.some((t) => t.status_id === s.id))
  const board = (
    <div className="flex gap-3 overflow-x-auto pb-2">
      <p id="kanban-help" className="sr-only">Press space to pick up a task, arrow keys to move it between columns, space again to drop.</p>
      {columns.map((s) => {
        const items = tasks.filter((t) => (optimistic[t.id] ?? t.status_id) === s.id).sort((a, b) => a.position - b.position)
        return (
          <KanbanColumn key={s.id} status={s} count={items.length}>
            {items.map((t) => <KanbanCard key={t.id} task={t} people={people} overdue={isOverdue(t, catOf(optimistic[t.id] ?? t.status_id), today)} disabled={readOnly} />)}
          </KanbanColumn>
        )
      })}
    </div>
  )
  return <DndContext sensors={sensors} onDragEnd={readOnly ? undefined : onDragEnd}>{board}</DndContext>
}
