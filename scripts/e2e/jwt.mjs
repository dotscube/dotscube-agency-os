import { createHmac } from 'node:crypto'
const b64 = (o) => Buffer.from(typeof o === 'string' ? o : JSON.stringify(o)).toString('base64url')
export function sign(payload, secret) {
  const head = b64({ alg: 'HS256', typ: 'JWT' }); const body = b64(payload)
  return `${head}.${body}.${createHmac('sha256', secret).update(`${head}.${body}`).digest('base64url')}`
}
