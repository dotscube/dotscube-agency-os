import { useEffect, useRef, useState } from 'react'
import { Link, NavLink, Outlet, useLocation, useNavigate } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { Bell, Building2, CalendarDays, CheckSquare, Clock, FolderKanban, LayoutDashboard, LogOut, Menu, Search, Settings, Users, X } from 'lucide-react'
import { useAuth } from '@/features/auth/AuthProvider'
import { visibleNav } from '@/lib/permissions'
import { supabase } from '@/lib/supabase'
import { ilikeTerm } from '@/lib/query'
import { cn } from '@/lib/utils'
import { Avatar, Button, Input } from '@/components/ui'

const ICONS = { LayoutDashboard, CheckSquare, FolderKanban, Building2, Users, Clock, CalendarDays, Bell, Settings } as const

function UnreadBadge() {
  const { session } = useAuth()
  const { data } = useQuery({
    queryKey: ['notifications', 'unread-count'],
    enabled: Boolean(session), refetchInterval: 60_000,
    queryFn: async () => {
      const { count } = await supabase.from('notifications').select('id', { count: 'exact', head: true }).is('read_at', null)
      return count ?? 0
    },
  })
  return (
    <Link to="/notifications" className="relative inline-flex size-9 items-center justify-center rounded-md hover:bg-muted" aria-label={`Notifications${data ? `, ${data} unread` : ''}`}>
      <Bell className="size-5" />
      {Boolean(data) && <span className="absolute right-1 top-1 min-w-4 rounded-full bg-destructive px-1 text-center text-[10px] font-semibold leading-4 text-destructive-foreground">{data! > 99 ? '99+' : data}</span>}
    </Link>
  )
}

interface SearchHit { kind: string; id: string; label: string; to: string }

function GlobalSearch() {
  const { can, audience } = useAuth()
  const [q, setQ] = useState('')
  const [open, setOpen] = useState(false)
  const navigate = useNavigate()
  const box = useRef<HTMLDivElement>(null)
  const term = q.trim()
  const { data, isFetching } = useQuery({
    queryKey: ['global-search', term], enabled: term.length >= 2, staleTime: 10_000,
    queryFn: async (): Promise<SearchHit[]> => {
      const like = ilikeTerm(term)
      const jobs: PromiseLike<SearchHit[]>[] = [
        supabase.from('tasks').select('id, title').ilike('title', like).limit(5).then((r) => (r.data ?? []).map((t) => ({ kind: 'Task', id: t.id, label: t.title, to: `/tasks/${t.id}` }))),
        supabase.from('projects').select('id, name').ilike('name', like).limit(5).then((r) => (r.data ?? []).map((p) => ({ kind: 'Project', id: p.id, label: p.name, to: `/projects/${p.id}` }))),
      ]
      if (audience === 'internal' && can('clients.view'))
        jobs.push(supabase.from('clients').select('id, name').ilike('name', like).limit(5).then((r) => (r.data ?? []).map((c) => ({ kind: 'Client', id: c.id, label: c.name, to: `/clients/${c.id}` }))))
      if (audience === 'internal' && can('employees.view'))
        jobs.push(supabase.from('employee_profiles').select('id, full_name, employee_code').or(`full_name.ilike.${like},employee_code.ilike.${like}`).limit(5)
          .then((r) => (r.data ?? []).map((e) => ({ kind: 'Employee', id: e.id, label: `${e.full_name} · ${e.employee_code}`, to: `/employees/${e.id}` }))))
      return (await Promise.all(jobs)).flat()
    },
  })
  useEffect(() => {
    const close = (e: MouseEvent) => { if (box.current && !box.current.contains(e.target as Node)) setOpen(false) }
    document.addEventListener('mousedown', close)
    return () => document.removeEventListener('mousedown', close)
  }, [])
  return (
    <div ref={box} className="relative w-full max-w-md">
      <Search className="pointer-events-none absolute left-2.5 top-2.5 size-4 text-muted-foreground" aria-hidden />
      <Input role="combobox" aria-expanded={open} aria-controls="global-search-results" aria-label="Search tasks, projects, clients, people"
        placeholder="Search…" className="pl-8" value={q}
        onChange={(e) => { setQ(e.target.value); setOpen(true) }} onFocus={() => setOpen(true)}
        onKeyDown={(e) => { if (e.key === 'Escape') setOpen(false) }} />
      {open && term.length >= 2 && (
        <ul id="global-search-results" role="listbox" className="absolute z-30 mt-1 max-h-80 w-full overflow-y-auto rounded-md border bg-card p-1 shadow-lg">
          {isFetching && !data && <li className="px-3 py-2 text-sm text-muted-foreground">Searching…</li>}
          {data?.length === 0 && <li className="px-3 py-2 text-sm text-muted-foreground">No results</li>}
          {data?.map((h) => (
            <li key={h.kind + h.id} role="option" aria-selected={false}>
              <button className="flex w-full items-center justify-between gap-3 rounded px-3 py-2 text-left text-sm hover:bg-muted"
                onClick={() => { setOpen(false); setQ(''); navigate(h.to) }}>
                <span className="truncate">{h.label}</span><span className="text-xs text-muted-foreground">{h.kind}</span>
              </button>
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}

export function AppLayout() {
  const { perms, audience, employee, profile, org, signOut } = useAuth()
  const [mobileOpen, setMobileOpen] = useState(false)
  const location = useLocation()
  useEffect(() => setMobileOpen(false), [location.pathname])
  const nav = visibleNav(perms, audience, Boolean(employee))

  const sidebar = (
    <nav aria-label="Main" className="flex h-full flex-col">
      <div className="flex h-14 items-center gap-2 border-b px-4">
        <div className="flex size-8 items-center justify-center rounded-md bg-primary text-sm font-bold text-primary-foreground">D</div>
        <div className="min-w-0"><p className="truncate text-sm font-semibold">{org?.name ?? 'Agency OS'}</p>
          <p className="text-xs text-muted-foreground">{audience === 'client' ? 'Client portal' : 'Agency OS'}</p></div>
      </div>
      <ul className="flex-1 space-y-0.5 overflow-y-auto p-3">
        {nav.map((item) => {
          const Icon = ICONS[item.icon as keyof typeof ICONS]
          return (
            <li key={item.to}>
              <NavLink to={item.to} end={item.to === '/'}
                className={({ isActive }) => cn('flex items-center gap-3 rounded-md px-3 py-2 text-sm font-medium transition-colors',
                  isActive ? 'bg-accent text-accent-foreground' : 'text-muted-foreground hover:bg-muted hover:text-foreground')}>
                <Icon className="size-4" aria-hidden />{audience === 'client' && item.to === '/' ? 'Overview' : item.label}
              </NavLink>
            </li>
          )
        })}
      </ul>
      <div className="flex items-center gap-3 border-t p-3">
        <Avatar name={profile?.full_name || profile?.email} />
        <div className="min-w-0 flex-1"><p className="truncate text-sm font-medium">{profile?.full_name || profile?.email}</p>
          <p className="truncate text-xs text-muted-foreground">{employee?.designation ?? profile?.email}</p></div>
        <Button variant="ghost" size="icon" onClick={signOut} aria-label="Sign out"><LogOut /></Button>
      </div>
    </nav>
  )

  return (
    <div className="flex h-full">
      <a href="#main" className="sr-only focus:not-sr-only focus:absolute focus:left-2 focus:top-2 focus:z-50 focus:rounded focus:bg-card focus:px-3 focus:py-2">Skip to content</a>
      <aside className="hidden w-60 shrink-0 border-r bg-card lg:block">{sidebar}</aside>
      {mobileOpen && (
        <div className="fixed inset-0 z-40 lg:hidden" role="dialog" aria-modal="true" aria-label="Navigation">
          <div className="absolute inset-0 bg-slate-900/40" onClick={() => setMobileOpen(false)} />
          <aside className="relative h-full w-64 bg-card shadow-xl">
            <Button variant="ghost" size="icon" className="absolute right-2 top-3" onClick={() => setMobileOpen(false)} aria-label="Close navigation"><X /></Button>
            {sidebar}
          </aside>
        </div>
      )}
      <div className="flex min-w-0 flex-1 flex-col">
        <header className="flex h-14 shrink-0 items-center gap-3 border-b bg-card px-4">
          <Button variant="ghost" size="icon" className="lg:hidden" onClick={() => setMobileOpen(true)} aria-label="Open navigation"><Menu /></Button>
          <GlobalSearch />
          <div className="ml-auto flex items-center gap-1"><UnreadBadge /></div>
        </header>
        <main id="main" className="flex-1 overflow-y-auto">
          <div className="mx-auto max-w-7xl p-4 sm:p-6 lg:p-8"><Outlet /></div>
        </main>
      </div>
    </div>
  )
}
