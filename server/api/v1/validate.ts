import type { VercelRequest, VercelResponse } from '@vercel/node'
import { fail, readPost } from '../../lib/http.js'
import {
  entitlementFor,
  signEntitlement,
  validKey,
  validMachine,
  type Entitlement,
} from '../../lib/licence.js'
import { statusOf, stripe } from '../../lib/stripe.js'
import { getLicence, touchSeat } from '../../lib/store.js'

/**
 * The weekly re-check. Unlike activation, a negative answer here is returned
 * *signed* rather than as an error: the app caches it and lapses on the spot,
 * instead of coasting to the end of its offline budget. A "no" it can verify
 * is worth more than a 403 it has to guess about.
 */
export default async function handler(req: VercelRequest, res: VercelResponse) {
  const body = readPost(req, res)
  if (!body) return

  const { key, machine } = body
  if (!validKey(key) || !validMachine(machine)) {
    return fail(res, 400, 'Malformed request.', { code: 'malformed' })
  }

  const licence = await getLicence(key)
  if (!licence) return res.status(200).json(signEntitlement(revoked(key, machine)))

  // A seat released from the account page revokes that Mac and only that Mac.
  const stillSeated = await touchSeat(key, machine)
  if (!stillSeated) {
    return res.status(200).json(signEntitlement(revoked(key, machine, licence.email)))
  }

  const subscription = await stripe().subscriptions.retrieve(licence.subscriptionId)
  const entitlement = entitlementFor(licence, subscription, machine)
  // statusOf already folds past_due into a warning rather than a revocation;
  // this is only here to make the intent legible at the call site.
  void statusOf(subscription)
  res.status(200).json(signEntitlement(entitlement))
}

function revoked(key: string, machine: string, email = ''): Entitlement {
  const now = Math.floor(Date.now() / 1000)
  return {
    key,
    machine,
    email,
    plan: 'annual',
    status: 'cancelled',
    periodEnd: now,
    issuedAt: now,
    recheckAfter: now,
  }
}
