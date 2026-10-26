interface PgLikeError { code?: string; message?: string; details?: string | null; hint?: string | null }

/**
 * Turns database / PostgREST errors into messages that are safe and useful to show.
 * Business-rule errors raised by our own functions already carry readable messages;
 * generic infrastructure errors are replaced so internals are never leaked.
 */
export function friendlyError(err: unknown): string {
  if (!err) return 'Something went wrong.'
  if (typeof err === 'string') return err
  const e = err as PgLikeError
  const msg = e.message ?? ''
  switch (e.code) {
    case '42501':
      if (/row-level security|permission denied/i.test(msg)) return "You don't have permission to do that."
      return msg
    case '23505':
      if (/duplicate key/i.test(msg)) return 'A record with these details already exists.'
      return msg
    case '23503':
      return 'This record is linked to other records and cannot be changed this way.'
    case '23514':
      if (/violates check constraint/i.test(msg)) return 'Some values are not valid. Please review the form.'
      return msg
    case '22023': case '23P01': case 'P0002':
      return msg
    case 'PGRST116':
      return 'Record not found or not accessible.'
    default:
      if (/Failed to fetch|NetworkError/i.test(msg)) return 'Network error. Check your connection and try again.'
      if (/Invalid login credentials/i.test(msg)) return 'Incorrect email or password.'
      return msg && msg.length < 200 && !/syntax|relation|column|function .* does not exist/i.test(msg)
        ? msg : 'Something went wrong. Please try again.'
  }
}
