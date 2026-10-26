// Local smoke-test stack: serves dist/ and proxies /rest/v1 -> PostgREST (Supabase-compatible paths).
// Auth is not emulated: tests inject a signed session into localStorage. Storage and Edge Functions are not emulated.
import http from 'node:http'
import { readFile } from 'node:fs/promises'
import { extname, join } from 'node:path'
const PORT = Number(process.env.PORT ?? 8787), PGRST = process.env.PGRST ?? 'http://127.0.0.1:3001', DIST = process.env.DIST ?? 'dist'
const types = { '.js': 'text/javascript', '.css': 'text/css', '.html': 'text/html', '.svg': 'image/svg+xml' }
http.createServer(async (req, res) => {
  const cors = { 'access-control-allow-origin': '*', 'access-control-allow-headers': '*', 'access-control-allow-methods': '*', 'access-control-expose-headers': 'content-range' }
  if (req.method === 'OPTIONS') { res.writeHead(204, cors); return res.end() }
  if (req.url.startsWith('/rest/v1')) {
    const body = await new Promise((r) => { const c = []; req.on('data', (d) => c.push(d)); req.on('end', () => r(Buffer.concat(c))) })
    const headers = { ...req.headers }; delete headers.host; delete headers['content-length']
    const up = await fetch(PGRST + req.url.slice('/rest/v1'.length), { method: req.method, headers, body: ['GET', 'HEAD'].includes(req.method) ? undefined : body })
    const out = Buffer.from(await up.arrayBuffer())
    const h = { ...cors }; up.headers.forEach((v, k) => { if (!['content-encoding', 'transfer-encoding', 'connection'].includes(k)) h[k] = v })
    res.writeHead(up.status, h); return res.end(out)
  }
  if (req.url.startsWith('/auth/v1')) { res.writeHead(200, { ...cors, 'content-type': 'application/json' }); return res.end('{}') }
  if (req.url.startsWith('/functions/v1')) { res.writeHead(501, { ...cors, 'content-type': 'application/json' }); return res.end('{"message":"functions not emulated"}') }
  if (req.url.startsWith('/storage/v1')) { res.writeHead(501, { ...cors, 'content-type': 'application/json' }); return res.end('{"message":"storage not emulated"}') }
  let file = join(DIST, decodeURIComponent(req.url.split('?')[0]))
  try { const data = await readFile(file); res.writeHead(200, { 'content-type': types[extname(file)] ?? 'application/octet-stream' }); res.end(data) }
  catch { res.writeHead(200, { 'content-type': 'text/html' }); res.end(await readFile(join(DIST, 'index.html'))) }
}).listen(PORT, () => console.log(`e2e server on http://localhost:${PORT}`))
