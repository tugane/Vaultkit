import type { VercelRequest, VercelResponse } from '@vercel/node'

/**
 * The app renders `error` verbatim to the person at the keyboard, so it is
 * written for them and not for a log. `code` is what the app branches on.
 */
export function fail(res: VercelResponse, status: number, error: string, extra: object = {}) {
  res.status(status).json({ error, ...extra })
}

/** POST-only, JSON body. Returns null once a failure has been written. */
export function readPost(req: VercelRequest, res: VercelResponse): Record<string, unknown> | null {
  if (req.method !== 'POST') {
    fail(res, 405, 'Method not allowed.')
    return null
  }
  const body = typeof req.body === 'string' ? safeParse(req.body) : req.body
  if (!body || typeof body !== 'object') {
    fail(res, 400, 'Expected a JSON body.')
    return null
  }
  return body as Record<string, unknown>
}

function safeParse(raw: string): unknown {
  try {
    return JSON.parse(raw)
  } catch {
    return null
  }
}
