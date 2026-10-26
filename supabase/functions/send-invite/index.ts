// Supabase Edge Function: sends the Supabase Auth invitation e-mail for an existing invitation row.
// STATUS: written but NOT yet executed against a live project (see docs/STATUS.md).
//
// Security model
// - The caller's JWT is used to read the invitation through RLS, so only users with
//   `users.manage` in the same organization can see (and therefore send) it.
// - The service-role key is used ONLY for auth.admin.inviteUserByEmail and never leaves this function.
//
// Deploy:  supabase functions deploy send-invite
// Secrets: SUPABASE_URL, SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY are injected by Supabase.
//          Optionally set SITE_URL (where the invite link should land).
import { createClient } from 'npm:@supabase/supabase-js@2.118.0'

const cors = {
  'Access-Control-Allow-Origin': Deno.env.get('SITE_URL') ?? '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405)
  try {
    const authHeader = req.headers.get('Authorization')
    if (!authHeader) return json({ error: 'Not signed in' }, 401)
    const { invitation_id } = await req.json().catch(() => ({}))
    if (typeof invitation_id !== 'string' || !/^[0-9a-f-]{36}$/i.test(invitation_id)) return json({ error: 'invitation_id is required' }, 400)

    const asUser = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, {
      global: { headers: { Authorization: authHeader } },
    })
    // RLS: only visible to users.manage holders in the same org
    const { data: inv, error } = await asUser.from('invitations')
      .select('id, email, accepted_at, expires_at').eq('id', invitation_id).maybeSingle()
    if (error || !inv) return json({ error: 'Invitation not found or not permitted' }, 404)
    if (inv.accepted_at) return json({ error: 'Invitation already accepted' }, 409)
    if (new Date(inv.expires_at) < new Date()) return json({ error: 'Invitation expired' }, 410)

    const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)
    const { error: sendError } = await admin.auth.admin.inviteUserByEmail(inv.email, {
      redirectTo: Deno.env.get('SITE_URL') ?? undefined,
    })
    if (sendError) return json({ error: sendError.message }, 400)
    return json({ ok: true })
  } catch (_e) {
    return json({ error: 'Unexpected error' }, 500)
  }
})

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } })
}
