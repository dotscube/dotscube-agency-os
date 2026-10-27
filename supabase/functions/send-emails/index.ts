// Supabase Edge Function: delivers queued e-mails from public.email_outbox through Resend.
// Run it every few minutes (Supabase Dashboard → Integrations → Cron → "Supabase Edge Function").
//
// Security model
// - Callable only with the service-role key as the Bearer token, or with the X-Cron-Secret header
//   matching the CRON_SECRET secret. Anyone else gets 401.
// - The database functions claim_emails / complete_email are executable by service_role only.
// - Mail content is built by database code; this function only escapes it into simple HTML.
//
// Deploy:  supabase functions deploy send-emails   (or create it in Dashboard → Edge Functions and paste this file)
// Secrets: RESEND_API_KEY      (required) API key from resend.com
//          EMAIL_FROM_ADDRESS  (required) an address on a domain verified in Resend, e.g. notify@dotscube.com
//          CRON_SECRET         (optional) shared secret for the X-Cron-Secret header
//          SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are injected by Supabase.
import { createClient } from 'npm:@supabase/supabase-js@2.118.0'

interface Claimed { id: string; org_id: string; to_email: string; to_name: string | null; subject: string; body_text: string; from_name: string; reply_to: string | null }

const BATCH = 25

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405)
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
  const cronSecret = Deno.env.get('CRON_SECRET')
  const bearer = (req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '')
  const authorised = (bearer && timingSafeEqual(bearer, serviceKey)) || (cronSecret && timingSafeEqual(req.headers.get('X-Cron-Secret') ?? '', cronSecret))
  if (!authorised) return json({ error: 'Unauthorized' }, 401)

  const apiKey = Deno.env.get('RESEND_API_KEY')
  const fromAddress = Deno.env.get('EMAIL_FROM_ADDRESS')
  if (!apiKey || !fromAddress) return json({ error: 'RESEND_API_KEY and EMAIL_FROM_ADDRESS must be set' }, 500)

  const db = createClient(Deno.env.get('SUPABASE_URL')!, serviceKey, { auth: { persistSession: false } })
  const { data, error } = await db.rpc('claim_emails', { p_limit: BATCH })
  if (error) return json({ error: error.message }, 500)
  const batch = (data ?? []) as Claimed[]

  let sent = 0, failed = 0
  for (const m of batch) {
    try {
      const res = await fetch('https://api.resend.com/emails', {
        method: 'POST',
        headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json', 'Idempotency-Key': m.id },
        body: JSON.stringify({
          from: `${sanitizeName(m.from_name)} <${fromAddress}>`,
          to: [m.to_name ? `${sanitizeName(m.to_name)} <${m.to_email}>` : m.to_email],
          reply_to: m.reply_to ?? undefined,
          subject: m.subject,
          text: m.body_text,
          html: toHtml(m.body_text),
        }),
      })
      const body = await res.json().catch(() => ({}))
      if (res.ok) { sent++; await db.rpc('complete_email', { p_id: m.id, p_ok: true, p_provider_id: body?.id ?? null }) }
      else { failed++; await db.rpc('complete_email', { p_id: m.id, p_ok: false, p_error: `${res.status}: ${body?.message ?? body?.name ?? 'send failed'}` }) }
    } catch (e) {
      failed++
      await db.rpc('complete_email', { p_id: m.id, p_ok: false, p_error: String((e as Error)?.message ?? e).slice(0, 500) })
    }
  }
  return json({ claimed: batch.length, sent, failed })
})

function sanitizeName(s: string) {
  return s.replace(/[<>"\r\n]/g, '').slice(0, 80) || 'Agency OS'
}

function escapeHtml(s: string) {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;')
}

/** Plain text → minimal, safe HTML: paragraphs, line breaks and clickable http(s) links. */
export function toHtml(text: string): string {
  const paras = text.split(/\n{2,}/).map((p) => {
    const linked = escapeHtml(p).replace(/https?:\/\/[^\s<]+/g, (u) => `<a href="${u}" style="color:#2563eb">${u}</a>`)
    return `<p style="margin:0 0 14px">${linked.replace(/\n/g, '<br>')}</p>`
  })
  return `<!doctype html><html><body style="margin:0;background:#f8fafc"><div style="max-width:560px;margin:0 auto;padding:24px;font:14px/1.6 -apple-system,Segoe UI,Roboto,Arial,sans-serif;color:#0f172a;background:#ffffff">${paras.join('')}</div></body></html>`
}

function timingSafeEqual(a: string, b: string) {
  if (!a || !b || a.length !== b.length) return false
  let diff = 0
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i)
  return diff === 0
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } })
}
