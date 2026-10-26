import { QueryClient } from '@tanstack/react-query'
import { toast } from 'sonner'
import { friendlyError } from './errors'

export const queryClient = new QueryClient({
  defaultOptions: {
    queries: { staleTime: 30_000, retry: (count, err) => count < 2 && !/permission|not found/i.test(String((err as Error)?.message)), refetchOnWindowFocus: false },
    mutations: { onError: (err) => toast.error(friendlyError(err)) },
  },
})

/** Unwraps a Supabase response, throwing its error so React Query can handle it. */
export function unwrap<T>(res: { data: T | null; error: unknown; count?: number | null }): T {
  if (res.error) throw res.error
  return res.data as T
}

export function unwrapPage<T>(res: { data: T[] | null; error: unknown; count?: number | null }): { rows: T[]; total: number } {
  if (res.error) throw res.error
  return { rows: res.data ?? [], total: res.count ?? 0 }
}

/** Escapes user input for use inside a PostgREST ilike/or filter. */
export function ilikeTerm(q: string): string {
  return `%${q.replace(/[%_,()\\*]/g, ' ').trim()}%`
}

/**
 * Creates an invitation row (RLS-checked) and asks the `send-invite` Edge Function to e-mail it.
 * If the function isn't deployed yet the invitation still works: the person signs up with that e-mail.
 */
export async function createInvitation(row: Record<string, unknown>): Promise<{ emailed: boolean }> {
  const { supabase } = await import('./supabase')
  const inv = unwrap(await supabase.from('invitations').insert(row).select('id').single()) as { id: string }
  const { error } = await supabase.functions.invoke('send-invite', { body: { invitation_id: inv.id } })
  return { emailed: !error }
}

export const inviteToast = (email: string, emailed: boolean) => emailed
  ? `Invitation e-mailed to ${email}.`
  : `Invitation saved. E-mail sending isn't set up yet, so ask ${email} to sign up at ${window.location.origin} with this address.`
