import { lazy, Suspense, type ReactNode } from 'react'
import { BrowserRouter, Navigate, Route, Routes } from 'react-router-dom'
import { QueryClientProvider } from '@tanstack/react-query'
import { Toaster } from 'sonner'
import { queryClient } from '@/lib/query'
import { isSupabaseConfigured } from '@/lib/supabase'
import type { Permission } from '@/lib/permissions'
import { AuthProvider, useAuth } from '@/features/auth/AuthProvider'
import { LoginPage, OnboardingPage } from '@/features/auth/AuthPages'
import { AppLayout } from '@/components/layout/AppLayout'
import { Card, CardBody, EmptyState, ErrorState, Spinner } from '@/components/ui'

const Dashboard = lazy(() => import('@/features/dashboard/DashboardPage'))
const Employees = lazy(() => import('@/features/employees/EmployeesPage'))
const EmployeeDetail = lazy(() => import('@/features/employees/EmployeeDetailPage'))
const Attendance = lazy(() => import('@/features/attendance/AttendancePage'))
const Leave = lazy(() => import('@/features/leave/LeavePage'))
const Clients = lazy(() => import('@/features/clients/ClientsPage'))
const ClientDetail = lazy(() => import('@/features/clients/ClientDetailPage'))
const Projects = lazy(() => import('@/features/projects/ProjectsPage'))
const ProjectDetail = lazy(() => import('@/features/projects/ProjectDetailPage'))
const Tasks = lazy(() => import('@/features/tasks/TasksPage'))
const TaskDetail = lazy(() => import('@/features/tasks/TaskDetailPage'))
const Calendar = lazy(() => import('@/features/calendar/CalendarPage'))
const Time = lazy(() => import('@/features/time/TimePage'))
const Content = lazy(() => import('@/features/content/ContentPage'))
const Campaigns = lazy(() => import('@/features/campaigns/CampaignsPage'))
const Templates = lazy(() => import('@/features/projects/templates'))
const Notifications = lazy(() => import('@/features/notifications/NotificationsPage'))
const Settings = lazy(() => import('@/features/settings/SettingsPage'))

function RequireAuth({ children }: { children: ReactNode }) {
  const { session, profile, loading, error } = useAuth()
  if (loading) return <Spinner label="Loading your workspace" />
  if (!session) return <Navigate to="/login" replace />
  if (error) return <ErrorState message={error} onRetry={() => window.location.reload()} />
  if (!profile?.org_id) return <Navigate to="/onboarding" replace />
  if (!profile.is_active) return <EmptyState title="Your account is deactivated" description="Contact your administrator." />
  return <>{children}</>
}

/** UI-level guard. The database enforces the same rules independently. */
function Guard({ anyOf, internal, employee, children }: { anyOf?: Permission[]; internal?: boolean; employee?: boolean; children: ReactNode }) {
  const auth = useAuth()
  const denied = (internal && auth.audience !== 'internal') || (employee && !auth.employee) || (anyOf && !auth.can(anyOf, 'any'))
  if (denied) return <EmptyState title="You don't have access to this page" description="Ask an administrator if you need access." />
  return <>{children}</>
}

/** Clients always see their own campaigns; staff need a campaigns permission. */
function CampaignsGuard({ children }: { children: ReactNode }) {
  const auth = useAuth()
  if (auth.audience === 'client') return <>{children}</>
  return <Guard internal anyOf={['campaigns.view', 'campaigns.manage']}>{children}</Guard>
}

function ConfigMissing() {
  return (
    <main className="flex min-h-full items-center justify-center p-4">
      <Card className="max-w-lg"><CardBody className="space-y-2 text-sm">
        <h1 className="text-lg font-semibold">Supabase is not configured</h1>
        <p>Copy <code>.env.example</code> to <code>.env.local</code> and set <code>VITE_SUPABASE_URL</code> and <code>VITE_SUPABASE_ANON_KEY</code>, then restart the dev server. See <code>docs/SETUP.md</code>.</p>
      </CardBody></Card>
    </main>
  )
}

export default function App() {
  if (!isSupabaseConfigured) return <ConfigMissing />
  const page = (el: ReactNode) => <Suspense fallback={<Spinner />}>{el}</Suspense>
  return (
    <QueryClientProvider client={queryClient}>
      <AuthProvider>
        <BrowserRouter>
          <Routes>
            <Route path="/login" element={<LoginPage />} />
            <Route path="/onboarding" element={<OnboardingPage />} />
            <Route element={<RequireAuth><AppLayout /></RequireAuth>}>
              <Route index element={page(<Dashboard />)} />
              <Route path="tasks" element={page(<Guard internal><Tasks /></Guard>)} />
              <Route path="tasks/:id" element={page(<TaskDetail />)} />
              <Route path="projects" element={page(<Projects />)} />
              <Route path="projects/:id" element={page(<ProjectDetail />)} />
              <Route path="calendar" element={page(<Guard internal><Calendar /></Guard>)} />
              <Route path="time" element={page(<Guard internal><Time /></Guard>)} />
              <Route path="content" element={page(<Content />)} />
              <Route path="campaigns" element={page(<CampaignsGuard><Campaigns /></CampaignsGuard>)} />
              <Route path="templates" element={page(<Guard internal anyOf={['projects.manage_templates']}><Templates /></Guard>)} />
              <Route path="clients" element={page(<Guard internal anyOf={['clients.view']}><Clients /></Guard>)} />
              <Route path="clients/:id" element={page(<Guard internal><ClientDetail /></Guard>)} />
              <Route path="employees" element={page(<Guard internal anyOf={['employees.view']}><Employees /></Guard>)} />
              <Route path="employees/:id" element={page(<Guard internal><EmployeeDetail /></Guard>)} />
              <Route path="attendance" element={page(<Guard internal employee><Attendance /></Guard>)} />
              <Route path="leave" element={page(<Guard internal employee><Leave /></Guard>)} />
              <Route path="notifications" element={page(<Notifications />)} />
              <Route path="settings" element={page(<Guard internal><Settings /></Guard>)} />
              <Route path="*" element={<EmptyState title="Page not found" />} />
            </Route>
          </Routes>
        </BrowserRouter>
        <Toaster position="top-right" richColors closeButton />
      </AuthProvider>
    </QueryClientProvider>
  )
}
