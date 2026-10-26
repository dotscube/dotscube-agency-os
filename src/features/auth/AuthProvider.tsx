import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from 'react'
import type { Session } from '@supabase/supabase-js'
import { supabase } from '@/lib/supabase'
import { queryClient } from '@/lib/query'
import { can as canFn, type Audience, type Permission, type PermissionSet } from '@/lib/permissions'
import type { Employee, Organization, Profile } from '@/lib/types'

interface AuthState {
  session: Session | null
  profile: Profile | null
  org: Organization | null
  employee: Employee | null
  perms: PermissionSet
  audience: Audience
  loading: boolean
  error: string | null
  can: (p: Permission | Permission[], mode?: 'all' | 'any') => boolean
  refresh: () => Promise<void>
  signOut: () => Promise<void>
}

const AuthContext = createContext<AuthState | null>(null)

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null)
  const [profile, setProfile] = useState<Profile | null>(null)
  const [org, setOrg] = useState<Organization | null>(null)
  const [employee, setEmployee] = useState<Employee | null>(null)
  const [perms, setPerms] = useState<PermissionSet>(new Set())
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const load = useCallback(async (s: Session | null) => {
    setSession(s)
    if (!s) { setProfile(null); setOrg(null); setEmployee(null); setPerms(new Set()); setLoading(false); return }
    try {
      const uid = s.user.id
      const [p, pr, e] = await Promise.all([
        supabase.from('profiles').select('*').eq('id', uid).maybeSingle(),
        supabase.rpc('my_permissions'),
        supabase.from('employee_profiles').select('*').eq('profile_id', uid).maybeSingle(),
      ])
      if (p.error) throw p.error
      setProfile(p.data as Profile | null)
      setPerms(new Set(((pr.data as string[] | null) ?? []).map((x) => (typeof x === 'string' ? x : Object.values(x as object)[0] as string))))
      setEmployee((e.data as Employee | null) ?? null)
      if (p.data?.org_id) {
        const o = await supabase.from('organizations').select('*').eq('id', p.data.org_id).maybeSingle()
        setOrg((o.data as Organization | null) ?? null)
      } else setOrg(null)
      setError(null)
    } catch (err) {
      setError((err as Error).message ?? 'Could not load your account')
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => load(data.session))
    const { data: sub } = supabase.auth.onAuthStateChange((event, s) => {
      if (event === 'SIGNED_OUT') queryClient.clear()
      if (event === 'SIGNED_IN' || event === 'SIGNED_OUT' || event === 'USER_UPDATED') { setLoading(true); load(s) }
      else setSession(s)
    })
    return () => sub.subscription.unsubscribe()
  }, [load])

  const value = useMemo<AuthState>(() => ({
    session, profile, org, employee, perms, loading, error,
    audience: profile?.client_id ? 'client' : 'internal',
    can: (p, mode) => canFn(perms, p, mode),
    refresh: async () => { const { data } = await supabase.auth.getSession(); await load(data.session) },
    signOut: async () => { await supabase.auth.signOut() },
  }), [session, profile, org, employee, perms, loading, error, load])

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>
}

export function useAuth(): AuthState {
  const ctx = useContext(AuthContext)
  if (!ctx) throw new Error('useAuth must be used inside AuthProvider')
  return ctx
}
