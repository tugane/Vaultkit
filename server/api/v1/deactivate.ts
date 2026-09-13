import type { VercelRequest, VercelResponse } from '@vercel/node'
import { fail, readPost } from '../../lib/http.js'
import { validKey, validMachine } from '../../lib/licence.js'
import { releaseSeat } from '../../lib/store.js'

/**
 * Frees this Mac's seat. Deliberately forgiving: a seat that is already gone,
 * or a key that is not on file, both answer 200. Someone wiping a machine they
 * are about to sell should never be told "no".
 */
export default async function handler(req: VercelRequest, res: VercelResponse) {
  const body = readPost(req, res)
  if (!body) return

  const { key, machine } = body
  if (!validKey(key) || !validMachine(machine)) {
    return fail(res, 400, 'Malformed request.', { code: 'malformed' })
  }

  await releaseSeat(key, machine)
  res.status(200).json({ released: true })
}
