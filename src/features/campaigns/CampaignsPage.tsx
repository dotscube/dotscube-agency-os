import { useMemo, useRef, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { toast } from 'sonner'
import { Bar, BarChart, CartesianGrid, ResponsiveContainer, Tooltip, XAxis, YAxis } from 'recharts'
import { FileUp, Plus } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { unwrap } from '@/lib/query'
import { friendlyError } from '@/lib/errors'
import { fmtDate, fmtMoney, titleCase } from '@/lib/utils'
import { nameOf, useClientsLite, usePeople } from '@/lib/lookups'
import { decodeFile, parseCampaignCsv, sha256Hex, type ParseResult } from '@/lib/campaignCsv'
import type { CampaignImport, CampaignMetric, CampaignPlatform, CampaignSummary } from '@/lib/types'
import { useAuth } from '@/features/auth/AuthProvider'
import { DataTable } from '@/components/DataTable'
import { Badge, Button, Card, CardBody, CardHeader, Dialog, EmptyState, ErrorState, Field, Input, PageHeader, Select, Spinner, StatusBadge, Tabs } from '@/components/ui'

const PLATFORM: Record<CampaignPlatform, string> = { google_ads: 'Google Ads', meta_ads: 'Meta Ads', other: 'Other' }
const num = (n?: number | null) => (n == null ? '—' : new Intl.NumberFormat('en-IN').format(Number(n)))

function Stat({ label, value, hint }: { label: string; value: string; hint?: string }) {
  return <div className="rounded-lg border bg-card p-4"><p className="text-xs text-muted-foreground">{label}</p><p className="mt-1 text-xl font-semibold tabular-nums">{value}</p>
    {hint && <p className="text-xs text-muted-foreground">{hint}</p>}</div>
}

function ImportDialog({ open, onClose }: { open: boolean; onClose: () => void }) {
  const qc = useQueryClient()
  const { data: clients } = useClientsLite(true)
  const fileRef = useRef<HTMLInputElement>(null)
  const [client, setClient] = useState(''); const [platform, setPlatform] = useState<CampaignPlatform>('google_ads')
  const [mode, setMode] = useState<'skip' | 'overwrite'>('skip')
  const [file, setFile] = useState<{ name: string; sha: string; parsed: ParseResult } | null>(null)
  const pick = async (f: File) => {
    if (f.size > 10 * 1024 * 1024) return toast.error('Files must be 10 MB or smaller')
    const buf = await f.arrayBuffer()
    const parsed = parseCampaignCsv(decodeFile(buf))
    setFile({ name: f.name, sha: await sha256Hex(buf), parsed })
    if (/meta|facebook/i.test(f.name)) setPlatform('meta_ads')
  }
  const summary = useMemo(() => {
    const rows = file?.parsed.rows ?? []
    if (!rows.length) return null
    const dates = rows.map((r) => r.date).sort()
    return { campaigns: new Set(rows.map((r) => r.campaign_id ?? r.campaign)).size, from: dates[0], to: dates.at(-1), spend: rows.reduce((s, r) => s + r.spend, 0) }
  }, [file])
  const run = useMutation({
    mutationFn: async () => unwrap(await supabase.rpc('import_campaign_metrics', { p_client: client, p_platform: platform, p_file_name: file!.name,
      p_file_sha256: file!.sha, p_rows: file!.parsed.rows, p_mode: mode })) as CampaignImport,
    onSuccess: (r) => {
      qc.invalidateQueries({ queryKey: ['campaigns'] })
      toast.success(`Imported: ${r.rows_inserted} new day(s), ${r.rows_updated} updated, ${r.rows_skipped} already present${r.campaigns_created ? `, ${r.campaigns_created} new campaign(s)` : ''}`)
      setFile(null); onClose()
    },
  })
  const blocking = file && (file.parsed.rows.length === 0 || file.parsed.errors.length > 0)
  return (
    <Dialog open={open} onClose={onClose} title="Import campaign data" wide description="Export a report from Google Ads or Meta Ads Manager with one row per campaign per day, as CSV."
      footer={<><Button variant="outline" onClick={onClose}>Cancel</Button><Button disabled={!client || !file || Boolean(blocking)} loading={run.isPending} onClick={() => run.mutate()}>Import</Button></>}>
      <div className="space-y-4 text-sm">
        <div className="grid gap-4 sm:grid-cols-2">
          <Field label="Client">{(p) => <Select {...p} value={client} onChange={(e) => setClient(e.target.value)}><option value="">Choose…</option>{clients?.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</Select>}</Field>
          <Field label="Platform">{(p) => <Select {...p} value={platform} onChange={(e) => setPlatform(e.target.value as CampaignPlatform)}>{Object.entries(PLATFORM).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</Select>}</Field>
        </div>
        <input ref={fileRef} type="file" accept=".csv,.tsv,text/csv" className="hidden" onChange={(e) => { const f = e.target.files?.[0]; if (f) pick(f); e.target.value = '' }} />
        <Button variant="outline" onClick={() => fileRef.current?.click()}><FileUp />{file ? `Change file (${file.name})` : 'Choose CSV file'}</Button>
        {file && <div className="space-y-2 rounded-md border p-3">
          {summary && <p><strong>{file.parsed.rows.length}</strong> day rows · <strong>{summary.campaigns}</strong> campaign(s) · {fmtDate(summary.from)} – {fmtDate(summary.to)} · spend <strong>{fmtMoney(summary.spend)}</strong></p>}
          <p className="text-xs text-muted-foreground">Columns found: {Object.entries(file.parsed.columns).map(([k, v]) => `${titleCase(k)} ← “${v}”`).join(', ') || 'none'}
            {file.parsed.skipped ? ` · ${file.parsed.skipped} total/blank row(s) ignored` : ''}</p>
          {file.parsed.errors.length > 0 && <ul className="list-disc space-y-0.5 pl-5 text-destructive">{file.parsed.errors.slice(0, 8).map((e) => <li key={e}>{e}</li>)}
            {file.parsed.errors.length > 8 && <li>…and {file.parsed.errors.length - 8} more</li>}</ul>}
        </div>}
        <fieldset className="space-y-1.5"><legend className="text-sm font-medium">If a campaign already has data for a day</legend>
          <label className="flex items-center gap-2"><input type="radio" checked={mode === 'skip'} onChange={() => setMode('skip')} />Keep the existing numbers (safe)</label>
          <label className="flex items-center gap-2"><input type="radio" checked={mode === 'overwrite'} onChange={() => setMode('overwrite')} />Replace them with this file (for corrected exports)</label>
        </fieldset>
        <p className="text-xs text-muted-foreground">The same file can't be imported twice, and a campaign never gets two rows for the same day.</p>
      </div>
    </Dialog>
  )
}

function NewCampaignDialog({ open, onClose }: { open: boolean; onClose: () => void }) {
  const { org, session } = useAuth()
  const qc = useQueryClient()
  const { data: clients } = useClientsLite(true)
  const [f, setF] = useState({ client: '', platform: 'google_ads', name: '', external_id: '', budget: '', start: '' })
  const save = useMutation({
    mutationFn: async () => unwrap(await supabase.from('campaigns').insert({ org_id: org!.id, client_id: f.client, platform: f.platform, name: f.name.trim(),
      external_id: f.external_id.trim() || null, monthly_budget: f.budget ? Number(f.budget) : null, start_date: f.start || null, created_by: session!.user.id })),
    onSuccess: () => { qc.invalidateQueries({ queryKey: ['campaigns'] }); onClose(); toast.success('Campaign added') },
  })
  const set = (k: keyof typeof f) => (e: { target: { value: string } }) => setF({ ...f, [k]: e.target.value })
  return (
    <Dialog open={open} onClose={onClose} title="New campaign"
      footer={<><Button variant="outline" onClick={onClose}>Cancel</Button><Button disabled={!f.client || f.name.trim().length < 2} loading={save.isPending} onClick={() => save.mutate()}>Save</Button></>}>
      <div className="grid gap-4 sm:grid-cols-2">
        <Field label="Client" className="sm:col-span-2">{(p) => <Select {...p} value={f.client} onChange={set('client')}><option value="">Choose…</option>{clients?.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</Select>}</Field>
        <Field label="Campaign name" className="sm:col-span-2">{(p) => <Input {...p} value={f.name} onChange={set('name')} />}</Field>
        <Field label="Platform">{(p) => <Select {...p} value={f.platform} onChange={set('platform')}>{Object.entries(PLATFORM).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</Select>}</Field>
        <Field label="Campaign ID" hint="From the ad platform (optional)">{(p) => <Input {...p} value={f.external_id} onChange={set('external_id')} />}</Field>
        <Field label="Monthly ad budget" hint="Client's ad spend, not your fee">{(p) => <Input {...p} type="number" min={0} value={f.budget} onChange={set('budget')} />}</Field>
        <Field label="Start date">{(p) => <Input {...p} type="date" value={f.start} onChange={set('start')} />}</Field>
      </div>
    </Dialog>
  )
}

function CampaignDetail({ c, onClose }: { c: CampaignSummary; onClose: () => void }) {
  const metrics = useQuery({ queryKey: ['campaigns', c.campaign_id, 'metrics'],
    queryFn: async () => unwrap(await supabase.from('campaign_metrics_daily').select('*').eq('campaign_id', c.campaign_id).order('metric_date', { ascending: false }).limit(366)) as CampaignMetric[] })
  const chart = useMemo(() => [...(metrics.data ?? [])].reverse().map((m) => ({ day: fmtDate(m.metric_date, 'dd MMM'), spend: Number(m.spend), clicks: m.clicks })), [metrics.data])
  return (
    <Dialog open onClose={onClose} title={c.name} wide description={`${PLATFORM[c.platform]} · ${fmtDate(c.first_date)} – ${fmtDate(c.last_date)}`}>
      <div className="space-y-4">
        <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
          <Stat label="Ad spend" value={fmtMoney(c.spend, c.currency)} /><Stat label="Clicks" value={num(c.clicks)} hint={c.ctr_pct != null ? `CTR ${c.ctr_pct}%` : undefined} />
          <Stat label="Cost per click" value={c.cpc != null ? fmtMoney(c.cpc, c.currency) : '—'} /><Stat label="Conversions" value={num(c.conversions)} hint={c.cpa != null ? `${fmtMoney(c.cpa, c.currency)} each` : undefined} />
        </div>
        {metrics.isLoading ? <Spinner /> : chart.length > 1 && <div className="h-56" aria-label="Daily ad spend chart">
          <ResponsiveContainer><BarChart data={chart} margin={{ left: -8, right: 8 }}>
            <CartesianGrid strokeDasharray="3 3" vertical={false} /><XAxis dataKey="day" tick={{ fontSize: 11 }} interval="preserveStartEnd" /><YAxis tick={{ fontSize: 11 }} />
            <Tooltip formatter={(v) => fmtMoney(Number(v), c.currency)} /><Bar dataKey="spend" name="Ad spend" fill="#2563eb" radius={[3, 3, 0, 0]} />
          </BarChart></ResponsiveContainer></div>}
        <DataTable rows={metrics.data} loading={metrics.isLoading} rowKey={(m) => m.metric_date} empty={<EmptyState title="No daily data yet" />} columns={[
          { key: 'd', header: 'Day', render: (m) => fmtDate(m.metric_date, 'EEE dd MMM') },
          { key: 'i', header: 'Impr.', render: (m) => num(m.impressions) }, { key: 'c', header: 'Clicks', render: (m) => num(m.clicks) },
          { key: 's', header: 'Spend', render: (m) => fmtMoney(Number(m.spend), c.currency) }, { key: 'v', header: 'Conv.', render: (m) => num(m.conversions) },
        ]} />
      </div>
    </Dialog>
  )
}

export default function CampaignsPage() {
  const { audience, can } = useAuth()
  const internal = audience === 'internal'
  const manage = internal && can('campaigns.manage')
  const { data: clients } = useClientsLite(internal)
  const { data: people } = usePeople()
  const [tab, setTab] = useState<'campaigns' | 'imports'>('campaigns')
  const [client, setClient] = useState(''); const [platform, setPlatform] = useState('')
  const [importing, setImporting] = useState(false); const [adding, setAdding] = useState(false)
  const [open, setOpen] = useState<CampaignSummary | null>(null)
  const list = useQuery({ queryKey: ['campaigns', 'summary', client, platform],
    queryFn: async () => {
      let q = supabase.from('campaign_summary').select('*').order('spend', { ascending: false })
      if (client) q = q.eq('client_id', client)
      if (platform) q = q.eq('platform', platform)
      return unwrap(await q) as CampaignSummary[]
    } })
  const imports = useQuery({ queryKey: ['campaigns', 'imports'], enabled: internal && tab === 'imports',
    queryFn: async () => unwrap(await supabase.from('campaign_imports').select('*').order('created_at', { ascending: false }).limit(100)) as CampaignImport[] })
  const t = useMemo(() => (list.data ?? []).reduce((a, c) => ({ spend: a.spend + Number(c.spend), clicks: a.clicks + Number(c.clicks), conv: a.conv + Number(c.conversions),
    value: a.value + Number(c.conversion_value), impr: a.impr + Number(c.impressions) }), { spend: 0, clicks: 0, conv: 0, value: 0, impr: 0 }), [list.data])
  return (
    <div className="space-y-6">
      <PageHeader title="Campaigns" description={internal ? 'Ad performance by client. Ad spend is the client\'s money and is kept separate from your management fees.' : 'How your ad campaigns are performing.'}
        actions={manage && <><Button variant="outline" onClick={() => setAdding(true)}><Plus />Campaign</Button><Button onClick={() => setImporting(true)}><FileUp />Import CSV</Button></>} />
      {internal && <Tabs tabs={[{ value: 'campaigns', label: 'Campaigns' }, { value: 'imports', label: 'Import history' }]} value={tab} onChange={setTab} />}
      {tab === 'campaigns' && <>
        <div className="flex flex-col gap-2 sm:flex-row">
          {internal && <Select aria-label="Client" className="sm:w-56" value={client} onChange={(e) => setClient(e.target.value)}><option value="">All clients</option>{clients?.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</Select>}
          <Select aria-label="Platform" className="sm:w-44" value={platform} onChange={(e) => setPlatform(e.target.value)}><option value="">All platforms</option>{Object.entries(PLATFORM).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</Select>
        </div>
        {list.error ? <ErrorState message={friendlyError(list.error)} onRetry={list.refetch} /> : list.isLoading ? <Spinner /> : <>
          {!!list.data?.length && <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
            <Stat label="Ad spend" value={fmtMoney(t.spend)} /><Stat label="Clicks" value={num(t.clicks)} hint={t.impr ? `CTR ${((t.clicks / t.impr) * 100).toFixed(2)}%` : undefined} />
            <Stat label="Conversions" value={num(Math.round(t.conv * 100) / 100)} hint={t.conv ? `${fmtMoney(t.spend / t.conv)} per conversion` : undefined} />
            <Stat label="Return on ad spend" value={t.spend ? `${(t.value / t.spend).toFixed(2)}×` : '—'} hint={t.value ? `${fmtMoney(t.value)} conversion value` : undefined} />
          </div>}
          <Card><DataTable rows={list.data} rowKey={(c) => c.campaign_id} onRowClick={setOpen}
            empty={<EmptyState title="No campaigns yet" description={manage ? 'Import a CSV export from Google Ads or Meta to get started.' : undefined}
              action={manage && <Button onClick={() => setImporting(true)}><FileUp />Import CSV</Button>} />} columns={[
              { key: 'n', header: 'Campaign', render: (c) => <span><span className="block font-medium">{c.name}</span>
                <span className="text-xs text-muted-foreground">{PLATFORM[c.platform]}{internal ? ` · ${nameOf(clients, c.client_id)}` : ''}</span></span> },
              { key: 's', header: 'Spend', render: (c) => <span className="tabular-nums">{fmtMoney(Number(c.spend), c.currency)}</span> },
              { key: 'cl', header: 'Clicks', render: (c) => num(c.clicks) },
              { key: 'ctr', header: 'CTR', render: (c) => (c.ctr_pct != null ? `${c.ctr_pct}%` : '—') },
              { key: 'cpc', header: 'CPC', render: (c) => (c.cpc != null ? fmtMoney(c.cpc, c.currency) : '—') },
              { key: 'cv', header: 'Conv.', render: (c) => num(c.conversions) },
              { key: 'roas', header: 'ROAS', render: (c) => (c.roas != null ? `${c.roas}×` : '—') },
              { key: 'b', header: 'Budget / mo', render: (c) => fmtMoney(c.monthly_budget, c.currency) },
              { key: 'st', header: 'Status', render: (c) => <StatusBadge value={c.status} /> },
            ]} /></Card>
        </>}
      </>}
      {tab === 'imports' && <Card><CardHeader title="Imports" description="Every CSV import, with what it changed." />
        <DataTable rows={imports.data} loading={imports.isLoading} empty={<EmptyState title="No imports yet" />} columns={[
          { key: 'd', header: 'When', render: (r) => fmtDate(r.created_at, 'dd MMM yyyy, hh:mm a') },
          { key: 'f', header: 'File', render: (r) => <span><span className="block">{r.file_name}</span><span className="text-xs text-muted-foreground">{nameOf(clients, r.client_id)} · {PLATFORM[r.platform as CampaignPlatform] ?? r.platform}</span></span> },
          { key: 'r', header: 'Result', render: (r) => <span className="flex flex-wrap gap-1"><Badge tone="green">{r.rows_inserted} new</Badge>{r.rows_updated > 0 && <Badge tone="blue">{r.rows_updated} updated</Badge>}
            {r.rows_skipped > 0 && <Badge tone="slate">{r.rows_skipped} skipped</Badge>}</span> },
          { key: 'b', header: 'By', render: (r) => nameOf(people, r.created_by) },
        ]} />
        <CardBody className="text-xs text-muted-foreground">Skipped rows were days already in the system (kept unchanged).</CardBody></Card>}
      {manage && <ImportDialog open={importing} onClose={() => setImporting(false)} />}
      {manage && <NewCampaignDialog open={adding} onClose={() => setAdding(false)} />}
      {open && <CampaignDetail c={open} onClose={() => setOpen(null)} />}
    </div>
  )
}
