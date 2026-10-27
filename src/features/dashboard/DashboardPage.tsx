import { useState, type ReactNode } from 'react'
import { Link } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { Bar, BarChart, CartesianGrid, Cell, ResponsiveContainer, Tooltip, XAxis, YAxis } from 'recharts'
import { AlertTriangle, Briefcase, Building2, IndianRupee, Wallet, CalendarClock, CalendarDays, CheckSquare, Clock, Eye, FolderKanban, Hourglass, ListChecks, UserCheck, Users } from 'lucide-react'
import { serviceLabel } from '@/lib/types'
import { useAuth } from '@/features/auth/AuthProvider'
import { dashboardKinds, type DashboardKind } from '@/lib/permissions'
import { supabase } from '@/lib/supabase'
import { unwrap } from '@/lib/query'
import { friendlyError } from '@/lib/errors'
import { fmtDate } from '@/lib/utils'
import type { Announcement, DashboardMetrics, FinanceSummary, LeaveBalance, OpeningPipeline, PayrollRun, ProjectOverview } from '@/lib/types'
import { fmtMoney } from '@/lib/utils'
import { useLeaveTypes } from '@/lib/lookups'
import { Card, CardBody, CardHeader, EmptyState, ErrorState, PageHeader, Skeleton, StatusBadge, Tabs } from '@/components/ui'
import { TodayAttendanceCard } from '@/features/attendance/TodayAttendanceCard'

function Stat({ label, value, to, icon, tone }: { label: string; value: number | undefined; to: string; icon: ReactNode; tone?: 'warn' | 'bad' }) {
  return (
    <Link to={to} className="group rounded-lg border bg-card p-4 shadow-sm transition-colors hover:border-primary/40 hover:bg-accent/30">
      <div className="flex items-center justify-between text-muted-foreground">
        <span className="text-sm">{label}</span><span aria-hidden className="[&_svg]:size-4">{icon}</span>
      </div>
      <p className={`mt-2 text-2xl font-semibold tabular-nums ${tone === 'bad' && value ? 'text-destructive' : tone === 'warn' && value ? 'text-amber-600' : ''}`}>
        {value ?? <Skeleton className="h-7 w-10" />}
      </p>
      <span className="text-xs text-primary opacity-0 transition-opacity group-hover:opacity-100">View records →</span>
    </Link>
  )
}

function Grid({ children }: { children: ReactNode }) {
  return <div className="grid grid-cols-2 gap-3 md:grid-cols-3 xl:grid-cols-4">{children}</div>
}

function WorkloadChart({ data }: { data: DashboardMetrics['team_workload'] }) {
  if (!data.length) return <EmptyState title="No open assigned tasks" />
  return (
    <div className="h-64" role="img" aria-label="Open tasks per team member">
      <ResponsiveContainer>
        <BarChart data={data} layout="vertical" margin={{ left: 8, right: 16 }}>
          <CartesianGrid horizontal={false} strokeDasharray="3 3" />
          <XAxis type="number" allowDecimals={false} fontSize={12} />
          <YAxis type="category" dataKey="name" width={110} fontSize={12} />
          <Tooltip />
          <Bar dataKey="open_tasks" name="Open" fill="#2563eb" radius={[0, 3, 3, 0]} />
          <Bar dataKey="overdue" name="Overdue" fill="#dc2626" radius={[0, 3, 3, 0]} />
        </BarChart>
      </ResponsiveContainer>
    </div>
  )
}

function StatusChart({ data }: { data: DashboardMetrics['tasks_by_status'] }) {
  if (!data.some((d) => d.count)) return <EmptyState title="No tasks yet" />
  return (
    <div className="h-64" role="img" aria-label="Tasks by status">
      <ResponsiveContainer>
        <BarChart data={data} margin={{ left: -16, right: 8 }}>
          <CartesianGrid vertical={false} strokeDasharray="3 3" />
          <XAxis dataKey="name" fontSize={11} interval={0} />
          <YAxis allowDecimals={false} fontSize={12} />
          <Tooltip />
          <Bar dataKey="count" name="Tasks" radius={[3, 3, 0, 0]}>{data.map((d) => <Cell key={d.name} fill={d.color} />)}</Bar>
        </BarChart>
      </ResponsiveContainer>
    </div>
  )
}

function MyLeaveBalances() {
  const { employee } = useAuth()
  const { data: types } = useLeaveTypes()
  const year = new Date().getFullYear()
  const { data } = useQuery({
    queryKey: ['leave_balances', employee?.id, year], enabled: Boolean(employee),
    queryFn: async () => unwrap(await supabase.from('leave_balances').select('*').eq('employee_id', employee!.id).eq('year', year)) as LeaveBalance[],
  })
  return (
    <Card>
      <CardHeader title="Leave balance" description={String(year)} action={<Link className="text-sm text-primary" to="/leave">Apply</Link>} />
      <CardBody className="space-y-2">
        {types?.filter((t) => t.annual_quota != null && t.is_active).map((t) => {
          const b = data?.find((x) => x.leave_type_id === t.id)
          const avail = b ? b.allocated + b.adjusted - b.used : t.annual_quota!
          return <div key={t.id} className="flex justify-between text-sm"><span>{t.name}</span><span className="font-medium tabular-nums">{avail} days</span></div>
        })}
      </CardBody>
    </Card>
  )
}

function Announcements() {
  const { data } = useQuery({
    queryKey: ['announcements'],
    queryFn: async () => unwrap(await supabase.from('announcements').select('*').order('pinned', { ascending: false }).order('created_at', { ascending: false }).limit(5)) as Announcement[],
  })
  return (
    <Card>
      <CardHeader title="Announcements" />
      {!data?.length ? <EmptyState title="No announcements" /> : (
        <ul className="divide-y">{data.map((a) => (
          <li key={a.id} className="px-5 py-3"><p className="text-sm font-medium">{a.title}</p>
            <p className="mt-0.5 whitespace-pre-line text-sm text-muted-foreground">{a.body}</p>
            <p className="mt-1 text-xs text-muted-foreground">{fmtDate(a.created_at)}</p></li>
        ))}</ul>
      )}
    </Card>
  )
}

function ClientOverview() {
  const { data, isLoading, error, refetch } = useQuery({
    queryKey: ['projects', 'client-overview'],
    queryFn: async () => unwrap(await supabase.from('project_overview').select('*').order('due_date')) as ProjectOverview[],
  })
  if (error) return <ErrorState message={friendlyError(error)} onRetry={refetch} />
  if (isLoading) return <Skeleton className="h-40" />
  if (!data?.length) return <EmptyState title="No shared projects yet" description="Your account manager will share project progress here." />
  return (
    <div className="grid gap-4 md:grid-cols-2">
      {data.map((p) => (
        <Link key={p.id} to={`/projects/${p.id}`}><Card className="hover:border-primary/40"><CardBody>
          <div className="flex items-start justify-between gap-2"><p className="font-medium">{p.name}</p><StatusBadge value={p.status} /></div>
          <p className="mt-1 text-sm text-muted-foreground">{serviceLabel(p.service)} · due {fmtDate(p.due_date)}</p>
          <div className="mt-3 h-2 rounded-full bg-muted"><div className="h-2 rounded-full bg-primary" style={{ width: `${p.progress_pct}%` }} /></div>
          <p className="mt-1 text-xs text-muted-foreground">{p.progress_pct}% complete overall</p>
        </CardBody></Card></Link>
      ))}
    </div>
  )
}

function Money({ label, value, to, tone, hint }: { label: string; value: number | undefined; to: string; tone?: 'bad'; hint?: string }) {
  return (
    <Link to={to} className="rounded-lg border bg-card p-4 shadow-sm transition-colors hover:border-primary/40 hover:bg-accent/30">
      <p className="text-sm text-muted-foreground">{label}</p>
      <p className={`mt-2 text-2xl font-semibold tabular-nums ${tone === 'bad' && value ? 'text-destructive' : ''}`}>{value == null ? <Skeleton className="h-7 w-20" /> : fmtMoney(value)}</p>
      {hint && <p className="text-xs text-muted-foreground">{hint}</p>}
    </Link>
  )
}

/** Billing & collections (needs an invoices permission; numbers are RLS-scoped). */
function FinanceCards() {
  const { data: f } = useQuery({ queryKey: ['invoices', 'summary'], queryFn: async () => unwrap(await supabase.rpc('get_finance_summary')) as FinanceSummary })
  return (
    <Card><CardHeader title="Billing & collections" action={<Link to="/invoices" className="text-sm text-primary hover:underline">Invoices →</Link>} />
      <CardBody><Grid>
        <Money label="Outstanding" value={f?.outstanding} to="/invoices" hint={f ? `${f.open_count} unpaid invoice(s)` : undefined} />
        <Money label="Overdue" value={f?.overdue} to="/invoices" tone="bad" hint={f ? `${f.overdue_count} invoice(s)` : undefined} />
        <Money label="Invoiced this month" value={f?.invoiced_this_month} to="/invoices" hint={f ? `Fees ${fmtMoney(f.fees_this_month)}` : undefined} />
        <Money label="Collected this month" value={f?.collected_this_month} to="/invoices" />
      </Grid></CardBody></Card>
  )
}

/** Latest payroll run and open positions for HR. */
function PeopleOps() {
  const { can } = useAuth()
  const payroll = can(['payroll.view', 'payroll.run'], 'any'), hiring = can(['recruitment.view', 'recruitment.manage'], 'any')
  const run = useQuery({ queryKey: ['payroll', 'latest'], enabled: payroll,
    queryFn: async () => (await supabase.from('payroll_runs').select('*').order('period_month', { ascending: false }).limit(1).maybeSingle()).data as PayrollRun | null })
  const open = useQuery({ queryKey: ['recruitment', 'open-count'], enabled: hiring,
    queryFn: async () => unwrap(await supabase.from('opening_pipeline').select('id, positions, hired, active, interview, offer').eq('status', 'open')) as OpeningPipeline[] })
  if (!payroll && !hiring) return null
  const r = run.data
  return (
    <div className="grid gap-3 md:grid-cols-2">
      {payroll && <Link to={r ? `/payroll?run=${r.id}` : '/payroll'} className="rounded-lg border bg-card p-4 shadow-sm hover:border-primary/40">
        <p className="flex items-center justify-between text-sm text-muted-foreground">Payroll<Wallet className="size-4" /></p>
        {r ? <><p className="mt-2 text-lg font-semibold">{fmtDate(r.period_month, 'MMMM yyyy')} · <StatusBadge value={r.status} /></p>
          <p className="text-xs text-muted-foreground">{r.employees_count} payslips · net {fmtMoney(r.net_total)}</p></>
          : <p className="mt-2 text-sm">No payroll run yet</p>}
      </Link>}
      {hiring && <Link to="/recruitment" className="rounded-lg border bg-card p-4 shadow-sm hover:border-primary/40">
        <p className="flex items-center justify-between text-sm text-muted-foreground">Hiring<Briefcase className="size-4" /></p>
        <p className="mt-2 text-lg font-semibold">{open.data ? `${open.data.reduce((a, o) => a + Math.max(0, o.positions - Number(o.hired)), 0)} open position(s)` : '…'}</p>
        <p className="text-xs text-muted-foreground">{open.data ? `${open.data.reduce((a, o) => a + Number(o.active), 0)} active candidates · ${open.data.reduce((a, o) => a + Number(o.interview), 0)} interviewing · ${open.data.reduce((a, o) => a + Number(o.offer), 0)} at offer` : ''}</p>
      </Link>}
    </div>
  )
}

/** Client portal: what they owe, if anything. */
function ClientDues() {
  const { data: f } = useQuery({ queryKey: ['invoices', 'summary'], queryFn: async () => unwrap(await supabase.rpc('get_finance_summary')) as FinanceSummary })
  if (!f || !Number(f.outstanding)) return null
  return (
    <Link to="/invoices" className="mb-4 flex items-center justify-between gap-3 rounded-lg border bg-card p-4 shadow-sm hover:border-primary/40">
      <span className="flex items-center gap-3"><IndianRupee className="size-5 text-muted-foreground" />
        <span><span className="block font-medium">{fmtMoney(f.outstanding)} due</span>
          <span className="text-sm text-muted-foreground">{f.open_count} unpaid invoice(s){f.overdue_count ? ` · ${f.overdue_count} overdue` : ''}</span></span></span>
      <span className="text-sm text-primary">View invoices →</span>
    </Link>
  )
}

const LABELS: Record<DashboardKind, string> = { admin: 'Agency', hr: 'HR', manager: 'Projects', employee: 'My work', client: 'Overview' }

export default function DashboardPage() {
  const { perms, audience, profile, employee, can } = useAuth()
  const kinds = dashboardKinds(perms, audience)
  const [kind, setKind] = useState<DashboardKind>(kinds[0]!)
  const { data: m, error, refetch } = useQuery({
    queryKey: ['dashboard'], enabled: audience === 'internal', refetchInterval: 120_000,
    queryFn: async () => unwrap(await supabase.rpc('get_dashboard_metrics')) as DashboardMetrics,
  })
  const greeting = `Welcome${profile?.full_name ? `, ${profile.full_name.split(' ')[0]}` : ''}`

  if (audience === 'client') return <><PageHeader title={greeting} description="Progress on the work we're doing for you." /><ClientDues /><ClientOverview /></>

  return (
    <div className="space-y-6">
      <PageHeader title={greeting} description={m ? `Today is ${fmtDate(m.today, 'EEEE, dd MMM yyyy')}` : undefined} />
      {kinds.length > 1 && <Tabs tabs={kinds.map((k) => ({ value: k, label: LABELS[k] }))} value={kind} onChange={setKind} />}
      {error && <ErrorState message={friendlyError(error)} onRetry={refetch} />}

      {kind === 'admin' && (
        <>
          <Grid>
            <Stat label="Active clients" value={m?.active_clients} to="/clients?status=active" icon={<Building2 />} />
            <Stat label="Active projects" value={m?.active_projects} to="/projects?status=active" icon={<FolderKanban />} />
            <Stat label="Overdue tasks" value={m?.overdue_tasks} to="/tasks?scope=all&due=overdue" icon={<AlertTriangle />} tone="bad" />
            <Stat label="Projects at risk" value={m?.projects_at_risk} to="/projects?risk=1" icon={<AlertTriangle />} tone="warn" />
            <Stat label="Checked in today" value={m?.checked_in_today} to="/attendance?tab=team" icon={<UserCheck />} />
            <Stat label="Pending leave approvals" value={m?.pending_leave_approvals} to="/leave?tab=approvals" icon={<CalendarDays />} tone="warn" />
            <Stat label="Pending corrections" value={m?.pending_corrections} to="/attendance?tab=approvals" icon={<Clock />} tone="warn" />
            <Stat label="Renewals in 45 days" value={m?.upcoming_renewals} to="/clients?renewals=1" icon={<CalendarClock />} tone="warn" />
          </Grid>
          {can(['invoices.view', 'invoices.manage'], 'any') && <FinanceCards />}
          <PeopleOps />
          <div className="grid gap-4 lg:grid-cols-2">
            <Card><CardHeader title="Team workload" description="Open assigned tasks" /><CardBody>{m && <WorkloadChart data={m.team_workload} />}</CardBody></Card>
            <Card><CardHeader title="Tasks by status" /><CardBody>{m && <StatusChart data={m.tasks_by_status} />}</CardBody></Card>
          </div>
        </>
      )}

      {kind === 'hr' && (
        <Grid>
          <Stat label="Headcount" value={m?.active_employees} to="/employees" icon={<Users />} />
          <Stat label="Checked in today" value={m?.checked_in_today} to="/attendance?tab=team" icon={<UserCheck />} />
          <Stat label="Late arrivals today" value={m?.late_today} to="/attendance?tab=team&late=1" icon={<Hourglass />} tone="warn" />
          <Stat label="On leave today" value={m?.on_leave_today} to="/leave?tab=team" icon={<CalendarDays />} />
          <Stat label="Leave requests" value={m?.pending_leave_approvals} to="/leave?tab=approvals" icon={<CalendarDays />} tone="warn" />
          <Stat label="Attendance corrections" value={m?.pending_corrections} to="/attendance?tab=approvals" icon={<Clock />} tone="warn" />
          <Stat label="Probation reviews (30 days)" value={m?.probation_reviews_due} to="/employees?status=probation" icon={<ListChecks />} tone="warn" />
        </Grid>
      )}
      {kind === 'hr' && <PeopleOps />}

      {kind === 'manager' && (
        <>
          <Grid>
            <Stat label="Active projects" value={m?.active_projects} to="/projects?status=active" icon={<FolderKanban />} />
            <Stat label="Overdue tasks" value={m?.overdue_tasks} to="/tasks?scope=all&due=overdue" icon={<AlertTriangle />} tone="bad" />
            <Stat label="Tasks in review" value={m?.tasks_in_review} to="/tasks?scope=all&category=review" icon={<Eye />} />
            <Stat label="Awaiting my review" value={m?.my_reviews} to="/tasks?scope=review" icon={<Eye />} tone="warn" />
            <Stat label="Projects at risk" value={m?.projects_at_risk} to="/projects?risk=1" icon={<AlertTriangle />} tone="warn" />
          </Grid>
          <Card><CardHeader title="Team workload" description="Open assigned tasks per person" /><CardBody>{m && <WorkloadChart data={m.team_workload} />}</CardBody></Card>
        </>
      )}

      {kind === 'employee' && (
        <div className="grid gap-4 lg:grid-cols-3">
          <div className="space-y-4 lg:col-span-2">
            {employee && <TodayAttendanceCard />}
            <Grid>
              <Stat label="My open tasks" value={m?.my_open_tasks} to="/tasks" icon={<CheckSquare />} />
              <Stat label="Due today" value={m?.my_due_today} to="/tasks?due=today" icon={<CalendarClock />} tone="warn" />
              <Stat label="Overdue" value={m?.my_overdue} to="/tasks?due=overdue" icon={<AlertTriangle />} tone="bad" />
              <Stat label="Waiting for my review" value={m?.my_reviews} to="/tasks?scope=review" icon={<Eye />} />
            </Grid>
            <Announcements />
          </div>
          <div className="space-y-4">{employee && <MyLeaveBalances />}</div>
        </div>
      )}
    </div>
  )
}
