import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Coffee, LogIn, LogOut } from 'lucide-react'
import { toast } from 'sonner'
import { supabase } from '@/lib/supabase'
import { unwrap } from '@/lib/query'
import { fmtMinutes, fmtTime } from '@/lib/utils'
import type { AttendanceBreak, AttendanceRecord } from '@/lib/types'
import { useAuth } from '@/features/auth/AuthProvider'
import { Button, Card, CardBody, CardHeader, Skeleton, StatusBadge } from '@/components/ui'

/** A completed day below the half-day threshold is shown as 'short hours' rather than 'absent'. */
export const attendanceLabel = (r: { status: string; check_out_at: string | null }) => (r.status === 'absent' && r.check_out_at ? 'short_hours' : r.status)

/** yyyy-MM-dd for "now" in the organization's timezone. */
export function orgToday(timeZone = 'Asia/Kolkata', now = new Date()): string {
  return new Intl.DateTimeFormat('en-CA', { timeZone, year: 'numeric', month: '2-digit', day: '2-digit' }).format(now)
}

export function useTodayAttendance() {
  const { employee, org } = useAuth()
  return useQuery({
    queryKey: ['attendance', 'today', employee?.id], enabled: Boolean(employee),
    queryFn: async () => {
      // an open check-in from the last 20h (mirrors the server rule), otherwise today's record in the org timezone
      const since = new Date(Date.now() - 20 * 3600_000).toISOString()
      const today = orgToday(org?.timezone)
      const recs = unwrap(await supabase.from('attendance_records').select('*').eq('employee_id', employee!.id)
        .or(`and(check_out_at.is.null,check_in_at.gte.${since}),work_date.eq.${today}`)
        .order('check_in_at', { ascending: false }).limit(2)) as AttendanceRecord[]
      const rec = recs.find((r) => !r.check_out_at) ?? recs[0] ?? null
      const breaks = rec ? unwrap(await supabase.from('attendance_breaks').select('*').eq('record_id', rec.id)) as AttendanceBreak[] : []
      return { rec, openBreak: breaks.find((b) => !b.end_at) ?? null }
    },
  })
}

export function TodayAttendanceCard() {
  const qc = useQueryClient()
  const { data, isLoading } = useTodayAttendance()
  const act = useMutation({
    mutationFn: async (fn: 'attendance_check_in' | 'attendance_check_out' | 'attendance_break_start' | 'attendance_break_end') => unwrap(await supabase.rpc(fn)),
    onSuccess: (_d, fn) => {
      toast.success({ attendance_check_in: 'Checked in', attendance_check_out: 'Checked out', attendance_break_start: 'Break started', attendance_break_end: 'Welcome back' }[fn])
      qc.invalidateQueries({ queryKey: ['attendance'] })
      qc.invalidateQueries({ queryKey: ['dashboard'] })
    },
  })
  const rec = data?.rec
  const open = rec && !rec.check_out_at
  return (
    <Card>
      <CardHeader title="Today's attendance" description="Times are recorded by the server, not your device."
        action={rec && <StatusBadge value={attendanceLabel(rec)} />} />
      <CardBody>
        {isLoading ? <Skeleton className="h-12" /> : (
          <div className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
            <dl className="grid grid-cols-3 gap-6 text-sm">
              <div><dt className="text-muted-foreground">Check-in</dt><dd className="font-medium">{rec ? fmtTime(rec.check_in_at) : '—'}</dd></div>
              <div><dt className="text-muted-foreground">Check-out</dt><dd className="font-medium">{rec?.check_out_at ? fmtTime(rec.check_out_at) : '—'}</dd></div>
              <div><dt className="text-muted-foreground">{rec?.late_minutes ? 'Late by' : 'Worked'}</dt>
                <dd className="font-medium">{rec?.late_minutes ? fmtMinutes(rec.late_minutes) : fmtMinutes(rec?.worked_minutes)}</dd></div>
            </dl>
            <div className="flex gap-2">
              {!rec && <Button onClick={() => act.mutate('attendance_check_in')} loading={act.isPending}><LogIn />Check in</Button>}
              {open && (data?.openBreak
                ? <Button variant="outline" onClick={() => act.mutate('attendance_break_end')} loading={act.isPending}><Coffee />End break</Button>
                : <Button variant="outline" onClick={() => act.mutate('attendance_break_start')} loading={act.isPending}><Coffee />Start break</Button>)}
              {open && <Button onClick={() => act.mutate('attendance_check_out')} loading={act.isPending}><LogOut />Check out</Button>}
              {rec?.check_out_at && <p className="text-sm text-muted-foreground">Done for today.</p>}
            </div>
          </div>
        )}
      </CardBody>
    </Card>
  )
}
