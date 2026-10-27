// Minimal PostgREST stand-in for local end-to-end tests when the PostgREST binary isn't available.
// Serves dist/ and answers /rest/v1 by running real SQL against the test database AS THE SIGNED-IN USER
// (role authenticated + request.jwt.claims), so row-level security, triggers and RPCs behave exactly as in Supabase.
// Supports what the app uses: select with column lists and embedded relations (to-one, to-many, count),
// eq/neq/gt/gte/lt/lte/in/is/not.is/ilike filters, or=(…ilike…), order, limit/offset, count=exact, single object,
// insert/upsert/update/delete with return=representation, and rpc/<function> with named arguments.
// Not emulated: Auth (tests inject a session), Storage, Edge Functions.
// Usage: npm i --no-save pg && DATABASE_URL=postgres://postgres@/agency_os_test?host=/tmp&port=54329 PORT=8787 node scripts/e2e/sql-rest.mjs
import http from 'node:http'
import { readFile } from 'node:fs/promises'
import { extname, join } from 'node:path'
import pg from 'pg'

const PORT = Number(process.env.PORT ?? 8787), DIST = process.env.DIST ?? 'dist'
const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL, max: 8 })
const types = { '.js': 'text/javascript', '.css': 'text/css', '.html': 'text/html', '.svg': 'image/svg+xml', '.png': 'image/png' }
const cors = { 'access-control-allow-origin': '*', 'access-control-allow-headers': '*', 'access-control-allow-methods': '*', 'access-control-expose-headers': 'content-range' }
const ident = (s) => { if (!/^[a-z_][a-z0-9_]*$/.test(s)) throw httpError(400, 'PGRST100', `bad identifier ${s}`); return `"${s}"` }
function httpError(status, code, message) { return Object.assign(new Error(message), { status, code }) }

// ---------- catalog (cached) ----------
let catalog
async function loadCatalog() {
  const q = async (sql) => (await pool.query(sql)).rows
  const fks = await q(`select c.conrelid::regclass::text as src, c.confrelid::regclass::text as dst,
      (select array_agg(a.attname::text order by k.n) from unnest(c.conkey) with ordinality k(attnum, n) join pg_attribute a on a.attrelid = c.conrelid and a.attnum = k.attnum) as src_cols,
      (select array_agg(a.attname::text order by k.n) from unnest(c.confkey) with ordinality k(attnum, n) join pg_attribute a on a.attrelid = c.confrelid and a.attnum = k.attnum) as dst_cols
    from pg_constraint c where c.contype = 'f' and c.connamespace = 'public'::regnamespace`)
  const pks = await q(`select c.conrelid::regclass::text as tbl, array_agg(a.attname::text order by a.attnum) as cols from pg_constraint c
    join pg_attribute a on a.attrelid = c.conrelid and a.attnum = any (c.conkey) where c.contype = 'p' and c.connamespace = 'public'::regnamespace group by 1`)
  const fns = await q(`select p.proname, p.proretset, p.prorettype::regtype::text as rettype, t.typtype,
      coalesce(p.proargnames::text[], '{}') as argnames, coalesce(array(select format_type(x, null) from unnest(p.proargtypes) x), '{}') as argtypes
    from pg_proc p join pg_type t on t.oid = p.prorettype where p.pronamespace = 'public'::regnamespace`)
  // views: borrow the FKs of the base table they are built on (good enough for the app's embeds)
  catalog = { fks: fks.map((f) => ({ ...f, src: f.src.replace(/^public\./, ''), dst: f.dst.replace(/^public\./, '') })),
    pks: Object.fromEntries(pks.map((p) => [p.tbl.replace(/^public\./, ''), p.cols])), fns: Object.fromEntries(fns.map((f) => [f.proname, f])) }
}

// ---------- select parsing ----------
function parseSelect(s) {
  const out = []; let depth = 0, cur = ''
  for (const ch of s ?? '*') {
    if (ch === '(') depth++
    if (ch === ')') depth--
    if (ch === ',' && depth === 0) { out.push(cur.trim()); cur = '' } else cur += ch
  }
  if (cur.trim()) out.push(cur.trim())
  return out.map((item) => {
    const m = item.match(/^([a-z_][a-z0-9_]*)(?:!inner)?\((.*)\)$/s)
    if (m) return { embed: m[1], children: parseSelect(m[2]) }
    const alias = item.match(/^([a-z_][a-z0-9_]*):([a-z_][a-z0-9_]*)$/)
    if (alias) return { col: alias[2], as: alias[1] }
    return { col: item }
  })
}

function rowJson(table, alias, items) {
  const parts = []
  let star = false
  for (const it of items) {
    if (it.col === '*') { star = true; continue }
    if (it.col === 'count' && !it.embed) { parts.push(`'count', count(*)`); continue }
    if (it.col) { parts.push(`'${it.as ?? it.col}', ${alias}.${ident(it.col)}`); continue }
    parts.push(`'${it.embed}', ${embedSql(table, alias, it)}`)
  }
  const obj = parts.length ? `jsonb_build_object(${parts.join(', ')})` : `'{}'::jsonb`
  return star ? `(to_jsonb(${alias}) || ${obj})` : obj
}

let aliasN = 0
function embedSql(table, alias, it) {
  const e = it.embed, a = `e${++aliasN}`
  const base = table.replace(/_summary$|_overview$|_pipeline$/, (x) => ({ _summary: '', _overview: 's', _pipeline: '' }[x]))
  const toOne = catalog.fks.find((f) => (f.src === table || f.src === base || f.src === 'job_openings' && table === 'opening_pipeline') && f.dst === e)
  if (toOne) {
    const cond = toOne.src_cols.map((c, i) => `${a}.${ident(toOne.dst_cols[i])} = ${alias}.${ident(c)}`).join(' and ')
    return `(select ${rowJson(e, a, it.children)} from public.${ident(e)} ${a} where ${cond})`
  }
  const toMany = catalog.fks.find((f) => f.src === e && (f.dst === table || f.dst === base))
  if (!toMany) throw httpError(400, 'PGRST200', `no relationship between ${table} and ${e}`)
  const cond = toMany.src_cols.map((c, i) => `${a}.${ident(c)} = ${alias}.${ident(toMany.dst_cols[i])}`).join(' and ')
  if (it.children.length === 1 && it.children[0].col === 'count') return `jsonb_build_array(jsonb_build_object('count', (select count(*) from public.${ident(e)} ${a} where ${cond})))`
  return `coalesce((select jsonb_agg(${rowJson(e, a, it.children)}) from public.${ident(e)} ${a} where ${cond}), '[]'::jsonb)`
}

// ---------- filters ----------
function filterSql(params, alias, args) {
  const conds = []
  const val = (v) => { args.push(v); return `$${args.length}` }
  const one = (col, expr) => {
    const [op, ...rest] = expr.split('.'); let v = rest.join('.')
    const c = `${alias}.${ident(col)}`
    switch (op) {
      case 'eq': return `${c} = ${val(v)}`
      case 'neq': return `${c} is distinct from ${val(v)}`
      case 'gt': return `${c} > ${val(v)}`
      case 'gte': return `${c} >= ${val(v)}`
      case 'lt': return `${c} < ${val(v)}`
      case 'lte': return `${c} <= ${val(v)}`
      case 'is': return v === 'null' ? `${c} is null` : `${c} is ${v === 'true' ? 'true' : 'false'}`
      case 'not': { const [op2, ...r2] = rest; const v2 = r2.join('.'); if (op2 === 'is') return v2 === 'null' ? `${c} is not null` : `${c} is not ${v2}`
        if (op2 === 'in') return `not (${c}::text = any(${val(v2.replace(/^\(|\)$/g, '').split(','))}::text[]))`
        return `not (${one(col, `${op2}.${v2}`)})` }
      case 'in': return `${c}::text = any(${val(v.replace(/^\(|\)$/g, '').split(',').map((x) => x.replace(/^"|"$/g, '')))}::text[])`
      case 'ilike': return `${c}::text ilike ${val(v.replace(/\*/g, '%'))}`
      case 'like': return `${c}::text like ${val(v.replace(/\*/g, '%'))}`
      default: throw httpError(400, 'PGRST100', `unsupported operator ${op}`)
    }
  }
  // or=(a.eq.1,and(b.is.null,c.gte.2)) -> nested boolean logic
  const splitTop = (str) => { const out = []; let d = 0, cur = ''
    for (const ch of str) { if (ch === '(') d++; if (ch === ')') d--; if (ch === ',' && d === 0) { out.push(cur); cur = '' } else cur += ch }
    if (cur) out.push(cur); return out }
  const logic = (kind, inner) => '(' + splitTop(inner).map((x) => {
    const m = x.match(/^(and|or)\((.*)\)$/s)
    if (m) return logic(m[1], m[2])
    const [col, ...r] = x.split('.'); return one(col, r.join('.'))
  }).join(kind === 'or' ? ' or ' : ' and ') + ')'
  for (const [k, v] of params) {
    if (['select', 'order', 'limit', 'offset', 'on_conflict', 'columns'].includes(k)) continue
    if (k === 'or' || k === 'and') { conds.push(logic(k, v.replace(/^\(|\)$/g, ''))); continue }
    if (k.includes('.')) continue // filters on embedded resources: ignored
    conds.push(one(k, v))
  }
  return conds.length ? ' where ' + conds.join(' and ') : ''
}

function orderSql(order, alias) {
  if (!order) return ''
  return ' order by ' + order.split(',').map((o) => {
    const [col, dir, nulls] = o.split('.')
    return `${alias}.${ident(col)} ${dir === 'desc' ? 'desc' : 'asc'}${nulls === 'nullsfirst' ? ' nulls first' : nulls === 'nullslast' ? ' nulls last' : dir === 'desc' ? ' nulls last' : ''}`
  }).join(', ')
}

// ---------- request handling ----------
async function asUser(token, fn) {
  let claims = {}
  try { claims = JSON.parse(Buffer.from((token ?? '').split('.')[1] ?? '', 'base64url').toString()) } catch { /* anon */ }
  const client = await pool.connect()
  try {
    await client.query('begin')
    await client.query(`select set_config('request.jwt.claims', $1, true)`, [JSON.stringify({ sub: claims.sub, role: claims.sub ? 'authenticated' : 'anon' })])
    await client.query(claims.sub ? 'set local role authenticated' : 'set local role anon')
    const out = await fn(client)
    await client.query('commit')
    return out
  } catch (e) { await client.query('rollback').catch(() => {}); throw e } finally { client.release() }
}

function pgError(e) {
  if (e.status) return { status: e.status, body: { code: e.code, message: e.message } }
  const code = e.code ?? 'XX000'
  const status = code === '42501' ? 403 : code === 'P0002' ? 404 : code.startsWith('23') ? 409 : 400
  return { status, body: { code, message: e.message, details: e.detail ?? null, hint: e.hint ?? null } }
}

async function handleRest(req, path, url, body) {
  const token = (req.headers.authorization ?? '').replace(/^Bearer /, '')
  const prefer = req.headers.prefer ?? ''
  const wantsObject = (req.headers.accept ?? '').includes('vnd.pgrst.object')
  if (path.startsWith('rpc/')) {
    const name = path.slice(4); const f = catalog.fns[name]
    if (!f) throw httpError(404, 'PGRST202', `function ${name} not found`)
    const input = body.length ? JSON.parse(body.toString()) : {}
    const args = []; const named = []
    f.argnames.forEach((n, i) => { if (n in input) { const v = input[n]; args.push(v == null ? null : typeof v === 'object' ? JSON.stringify(v) : String(v)); named.push(`${ident(n)} := $${args.length}::${f.argtypes[i]}`) } })
    const call = `public.${ident(name)}(${named.join(', ')})`
    const sql = f.proretset ? `select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) as r from ${call} x`
      : f.typtype === 'c' ? `select to_jsonb(x) as r from ${call} x` : f.rettype === 'void' ? `select ${call}, null::jsonb as r` : `select to_jsonb(${call}) as r`
    return asUser(token, async (c) => {
      const r = (await c.query(sql, args)).rows[0]?.r ?? null
      if (f.typtype === 'c' && r && Object.values(r).every((v) => v === null)) return { status: 200, body: null }
      return { status: 200, body: r }
    })
  }
  const table = path; ident(table)
  const params = url.searchParams; const alias = 't'
  const args = []
  if (req.method === 'GET' || req.method === 'HEAD') {
    aliasN = 0
    const items = parseSelect(params.get('select') ?? '*')
    const where = filterSql(params, alias, args)
    const lim = params.get('limit') ? ` limit ${Number(params.get('limit'))}` : ''
    const off = params.get('offset') ? ` offset ${Number(params.get('offset'))}` : ''
    const sql = `select ${rowJson(table, alias, items)} as r from public.${ident(table)} ${alias}${where}${orderSql(params.get('order'), alias)}${lim}${off}`
    return asUser(token, async (c) => {
      const rows = (await c.query(sql, args)).rows.map((x) => x.r)
      let total = rows.length
      if (prefer.includes('count=exact')) total = Number((await c.query(`select count(*) from public.${ident(table)} ${alias}${where}`, args)).rows[0].count)
      const headers = { 'content-range': `${rows.length ? `0-${rows.length - 1}` : '*'}/${total}` }
      if (wantsObject) return rows.length === 1 ? { status: 200, body: rows[0], headers } : { status: 406, body: { code: 'PGRST116', message: 'JSON object requested, multiple (or no) rows returned', details: `The result contains ${rows.length} rows` } }
      return { status: 200, body: req.method === 'HEAD' ? null : rows, headers }
    })
  }
  const payload = body.length ? JSON.parse(body.toString()) : {}
  const rows = Array.isArray(payload) ? payload : [payload]
  const returning = prefer.includes('return=representation') ? ' returning to_jsonb(t) as r' : ''
  return asUser(token, async (c) => {
    let out = []
    if (req.method === 'POST') {
      for (const row of rows) {
        const cols = Object.keys(row).map(ident)
        let sql = `insert into public.${ident(table)} as t (${cols.join(', ')}) select ${cols.join(', ')} from jsonb_populate_record(null::public.${ident(table)}, $1)`
        if (prefer.includes('resolution=merge-duplicates')) {
          const conflict = (params.get('on_conflict')?.split(',') ?? catalog.pks[table]).map(ident)
          const upd = cols.filter((c2) => !conflict.includes(c2))
          sql += ` on conflict (${conflict.join(', ')}) do ${upd.length ? `update set ${upd.map((c2) => `${c2} = excluded.${c2}`).join(', ')}` : 'nothing'}`
        }
        const r = await c.query(sql + returning, [JSON.stringify(row)])
        out.push(...r.rows.map((x) => x.r))
      }
      return { status: 201, body: returning ? out : null }
    }
    const where = filterSql(params, alias, args)
    if (req.method === 'PATCH') {
      const cols = Object.keys(payload).map(ident)
      args.push(JSON.stringify(payload))
      const sql = `update public.${ident(table)} t set (${cols.join(', ')}) = (select ${cols.join(', ')} from jsonb_populate_record(null::public.${ident(table)}, $${args.length}))${where}`
      out = (await c.query(sql + returning, args)).rows.map((x) => x.r)
    } else if (req.method === 'DELETE') {
      out = (await c.query(`delete from public.${ident(table)} t${where}${returning}`, args)).rows.map((x) => x.r)
    }
    if (wantsObject) return out.length === 1 ? { status: 200, body: out[0] } : { status: 406, body: { code: 'PGRST116', message: 'JSON object requested, multiple (or no) rows returned' } }
    return { status: returning ? 200 : 204, body: returning ? out : null }
  })
}

await loadCatalog()
http.createServer(async (req, res) => {
  if (req.method === 'OPTIONS') { res.writeHead(204, cors); return res.end() }
  const url = new URL(req.url, 'http://x')
  if (url.pathname.startsWith('/rest/v1/')) {
    const body = await new Promise((r) => { const c = []; req.on('data', (d) => c.push(d)); req.on('end', () => r(Buffer.concat(c))) })
    try {
      const out = await handleRest(req, url.pathname.slice('/rest/v1/'.length), url, body)
      res.writeHead(out.status, { ...cors, 'content-type': 'application/json', ...(out.headers ?? {}) })
      return res.end(out.body == null ? (out.status === 204 ? '' : 'null') : JSON.stringify(out.body))
    } catch (e) {
      const { status, body: b } = pgError(e)
      if (process.env.DEBUG) console.error(req.method, url.pathname, url.search, e.message)
      res.writeHead(status, { ...cors, 'content-type': 'application/json' }); return res.end(JSON.stringify(b))
    }
  }
  if (url.pathname.startsWith('/auth/v1')) { res.writeHead(200, { ...cors, 'content-type': 'application/json' }); return res.end('{}') }
  if (url.pathname.startsWith('/functions/v1') || url.pathname.startsWith('/storage/v1')) { res.writeHead(501, { ...cors, 'content-type': 'application/json' }); return res.end('{"message":"not emulated"}') }
  const file = join(DIST, decodeURIComponent(url.pathname))
  try { const data = await readFile(file); res.writeHead(200, { 'content-type': types[extname(file)] ?? 'application/octet-stream' }); res.end(data) }
  catch { res.writeHead(200, { 'content-type': 'text/html' }); res.end(await readFile(join(DIST, 'index.html'))) }
}).listen(PORT, () => console.log(`sql-rest on http://localhost:${PORT}`))
