import { useQuery } from '@tanstack/react-query'
import { supabase } from './supabase'
import { unwrap } from './query'
import type { Department, LeaveType, Profile, Role, TaskStatus } from './types'
import { useAuth } from '@/features/auth/AuthProvider'

/** Internal people in the org (RLS returns only what the caller may see). */
export function usePeople() {
  const { audience } = useAuth()
  return useQuery({
    queryKey: ['people'],
    enabled: audience === 'internal',
    queryFn: async () => unwrap(await supabase.from('profiles').select('id, full_name, email, client_id, is_active')
      .is('client_id', null).order('full_name')) as Pick<Profile, 'id' | 'full_name' | 'email' | 'client_id' | 'is_active'>[],
  })
}

export function useTaskStatuses() {
  return useQuery({
    queryKey: ['task_statuses'], staleTime: 5 * 60_000,
    queryFn: async () => unwrap(await supabase.from('task_statuses').select('*').order('position')) as TaskStatus[],
  })
}

export function useDepartments() {
  return useQuery({
    queryKey: ['departments'], staleTime: 5 * 60_000,
    queryFn: async () => unwrap(await supabase.from('departments').select('id, name').order('name')) as Department[],
  })
}

export function useLeaveTypes() {
  return useQuery({
    queryKey: ['leave_types'], staleTime: 5 * 60_000,
    queryFn: async () => unwrap(await supabase.from('leave_types').select('*').order('code')) as LeaveType[],
  })
}

export function useRoles() {
  return useQuery({
    queryKey: ['roles'],
    queryFn: async () => unwrap(await supabase.from('roles').select('*').order('name')) as Role[],
  })
}

export function useEmployeesLite() {
  return useQuery({
    queryKey: ['employees-lite'],
    queryFn: async () => unwrap(await supabase.from('employee_profiles').select('id, full_name, profile_id, status, designation')
      .neq('status', 'exited').order('full_name')) as { id: string; full_name: string; profile_id: string | null; status: string; designation: string | null }[],
  })
}

export function useClientsLite(enabled = true) {
  return useQuery({
    queryKey: ['clients-lite'], enabled,
    queryFn: async () => unwrap(await supabase.from('clients').select('id, name').order('name')) as { id: string; name: string }[],
  })
}

export function nameOf<T extends { id: string; full_name?: string; name?: string }>(list: T[] | undefined, id?: string | null): string {
  if (!id) return '—'
  const x = list?.find((i) => i.id === id)
  return x?.full_name ?? x?.name ?? '—'
}
