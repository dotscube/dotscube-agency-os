import { useNavigate } from 'react-router-dom'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { CheckCheck } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { unwrap } from '@/lib/query'
import { friendlyError } from '@/lib/errors'
import { cn, fmtDate } from '@/lib/utils'
import type { Notification } from '@/lib/types'
import { Button, Card, EmptyState, ErrorState, PageHeader, Spinner } from '@/components/ui'

export const NOTIFICATION_TYPES: Record<string, string> = {
  task_assigned: 'Task assigned to me', review_requested: 'Review requested', changes_requested: 'Changes requested on my task',
  task_approved: 'My task approved', mention: 'Mentioned in a comment', client_feedback: 'Client feedback',
  task_due_soon: 'Task due soon', task_overdue: 'Task overdue', leave_request: 'Leave requests to approve', leave_decision: 'Decision on my leave',
  attendance_correction: 'Attendance corrections to approve', attendance_correction_decision: 'Decision on my correction', contract_renewal: 'Contract renewals',
  timesheet_submitted: 'Timesheets to approve', timesheet_decided: 'Decision on my timesheet', content_review: 'Content to review', content_reviewed: 'Client decision on content',
  invoice_reminder: 'Invoice due / overdue reminders', payslip_ready: 'My payslip is ready',
  interview_scheduled: 'Interviews assigned to me', interview_feedback: 'Interview feedback submitted',
}

export default function NotificationsPage() {
  const qc = useQueryClient()
  const navigate = useNavigate()
  const q = useQuery({ queryKey: ['notifications', 'list'],
    queryFn: async () => unwrap(await supabase.from('notifications').select('*').order('created_at', { ascending: false }).limit(100)) as Notification[] })
  const inv = () => qc.invalidateQueries({ queryKey: ['notifications'] })
  const markRead = useMutation({ mutationFn: async (ids: string[]) => unwrap(await supabase.from('notifications').update({ read_at: new Date().toISOString() }).in('id', ids)), onSuccess: inv })
  const unread = q.data?.filter((n) => !n.read_at) ?? []
  return (
    <div>
      <PageHeader title="Notifications" actions={<Button variant="outline" disabled={!unread.length} onClick={() => markRead.mutate(unread.map((n) => n.id))}><CheckCheck />Mark all read</Button>} />
      <Card>
        {q.isLoading ? <Spinner /> : q.error ? <ErrorState message={friendlyError(q.error)} onRetry={q.refetch} /> : !q.data?.length ? <EmptyState title="You're all caught up" /> : (
          <ul className="divide-y">{q.data.map((n) => (
            <li key={n.id}>
              <button className={cn('flex w-full items-start gap-3 px-5 py-3 text-left hover:bg-muted/40', !n.read_at && 'bg-accent/30')}
                onClick={() => { if (!n.read_at) markRead.mutate([n.id]); if (n.link) navigate(n.link) }}>
                <span aria-hidden className={cn('mt-1.5 size-2 shrink-0 rounded-full', n.read_at ? 'bg-transparent' : 'bg-primary')} />
                <span className="min-w-0 flex-1"><span className={cn('block text-sm', !n.read_at && 'font-medium')}>{n.title}</span>
                  {n.body && <span className="block text-sm text-muted-foreground">{n.body}</span>}
                  <span className="text-xs text-muted-foreground">{fmtDate(n.created_at, 'dd MMM, hh:mm a')}</span></span>
                {!n.read_at && <span className="sr-only">Unread</span>}
              </button>
            </li>))}</ul>
        )}
      </Card>
    </div>
  )
}
