// Permission keys mirror public.permissions. UI checks are for convenience only:
// the database enforces every rule independently.
export const PERMISSIONS = [
  'org.manage', 'roles.manage', 'users.manage', 'audit.view', 'departments.manage',
  'employees.view', 'employees.create', 'employees.edit', 'employees.delete', 'employees.export', 'employees.view_sensitive',
  'salary.view', 'salary.edit',
  'attendance.view_all', 'attendance.approve', 'attendance.manage_policy', 'attendance.export',
  'leave.view_all', 'leave.approve', 'leave.manage_policy', 'leave.export', 'holidays.manage',
  'clients.view', 'clients.create', 'clients.edit', 'clients.delete', 'clients.export', 'clients.view_billing',
  'projects.view_all', 'projects.create', 'projects.edit', 'projects.delete', 'projects.export',
  'tasks.view_all', 'tasks.create', 'tasks.edit_all', 'tasks.delete', 'tasks.manage_statuses',
  'announcements.manage', 'reports.view',
  'projects.manage_templates', 'time.view_all', 'timesheets.approve', 'content.view_all', 'content.manage',
  'campaigns.view', 'campaigns.manage',
] as const

export type Permission = (typeof PERMISSIONS)[number]

export type PermissionSet = ReadonlySet<string>

/** true if the set contains every listed permission (`all`) or at least one (`any`). */
export function can(perms: PermissionSet, required: Permission | Permission[] | undefined, mode: 'all' | 'any' = 'all'): boolean {
  if (!required) return true
  const list = Array.isArray(required) ? required : [required]
  if (list.length === 0) return true
  return mode === 'all' ? list.every((p) => perms.has(p)) : list.some((p) => perms.has(p))
}

export type Audience = 'internal' | 'client'

export interface NavItem {
  to: string
  label: string
  icon: string
  audience: Audience[]
  anyOf?: Permission[]
  /** shown to everyone internal who has an employee record */
  employeeOnly?: boolean
}

export const NAV_ITEMS: NavItem[] = [
  { to: '/', label: 'Dashboard', icon: 'LayoutDashboard', audience: ['internal', 'client'] },
  { to: '/tasks', label: 'My Tasks', icon: 'CheckSquare', audience: ['internal'] },
  { to: '/projects', label: 'Projects', icon: 'FolderKanban', audience: ['internal', 'client'] },
  { to: '/calendar', label: 'Calendar', icon: 'CalendarRange', audience: ['internal'] },
  { to: '/time', label: 'Time', icon: 'Timer', audience: ['internal'] },
  { to: '/content', label: 'Content', icon: 'Megaphone', audience: ['internal', 'client'] },
  { to: '/campaigns', label: 'Campaigns', icon: 'ChartColumn', audience: ['internal', 'client'], anyOf: ['campaigns.view', 'campaigns.manage'] },
  { to: '/clients', label: 'Clients', icon: 'Building2', audience: ['internal'], anyOf: ['clients.view'] },
  { to: '/employees', label: 'Employees', icon: 'Users', audience: ['internal'], anyOf: ['employees.view'] },
  { to: '/attendance', label: 'Attendance', icon: 'Clock', audience: ['internal'], employeeOnly: true },
  { to: '/leave', label: 'Leave', icon: 'CalendarDays', audience: ['internal'], employeeOnly: true },
  { to: '/notifications', label: 'Notifications', icon: 'Bell', audience: ['internal', 'client'] },
  // every internal user can reach Settings (e.g. notification preferences); tabs inside are permission-filtered
  { to: '/templates', label: 'Templates', icon: 'LayoutTemplate', audience: ['internal'], anyOf: ['projects.manage_templates'] },
  { to: '/settings', label: 'Settings', icon: 'Settings', audience: ['internal'] },
]

export function visibleNav(perms: PermissionSet, audience: Audience, hasEmployee: boolean): NavItem[] {
  return NAV_ITEMS.filter((item) =>
    item.audience.includes(audience) &&
    (!item.employeeOnly || hasEmployee) &&
    (audience === 'client' || can(perms, item.anyOf, 'any')))
}

export type DashboardKind = 'admin' | 'hr' | 'manager' | 'employee' | 'client'

/** Picks the most relevant dashboard; users can still switch to others they're entitled to. */
export function dashboardKinds(perms: PermissionSet, audience: Audience): DashboardKind[] {
  if (audience === 'client') return ['client']
  const kinds: DashboardKind[] = []
  if (can(perms, ['org.manage'])) kinds.push('admin')
  if (can(perms, ['employees.edit', 'leave.approve'], 'any') && can(perms, 'attendance.view_all')) kinds.push('hr')
  if (can(perms, ['projects.view_all', 'tasks.view_all'], 'any')) kinds.push('manager')
  kinds.push('employee')
  return kinds
}
