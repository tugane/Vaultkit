import type { VercelRequest, VercelResponse } from '@vercel/node'
import { SEATS } from '../../lib/env.js'
import { fail, readPost } from '../../lib/http.js'
import {
  cleanLabel,
  entitlementFor,
  signEntitlement,
  validKey,
  validMachine,
} from '../../lib/licence.js'
import { statusOf, stripe } from '../../lib/stripe.js'
import { claimSeat, getLicence, seats } from '../../lib/store.js'

/**
 * Binds a Mac to a licence and hands back a signed entitlement.
 *
 * Stripe, not this store, decides whether the subscription is paid: the record
 * here only says which key belongs to which subscription. That way a refund or
 * a failed payment takes effect on the next activation without anything having
 * to be written back here first.
 */
export default async function handler(req: VercelRequest, res: VercelResponse) {
  const body = readPost(req, res)
  if (!body) return

  const { key, machine, label } = body
  if (!validKey(key)) {
    return fail(res, 400, 'That is not a Vaultkit licence key.', { code: 'malformed_key' })
  }
  if (!validMachine(machine)) {
    return fail(res, 400, 'Missing machine fingerprint.', { code: 'malformed_machine' })
  }

  const licence = await getLicence(key)
  if (!licence) {
    return fail(res, 404, 'That key is not on file. Check it against your receipt, or write to tooamiel@gmail.com.', {
      code: 'unknown_key',
    })
  }

  const subscription = await stripe().subscriptions.retrieve(licence.subscriptionId)
  const status = statusOf(subscription)
  if (status === 'cancelled') {
    return fail(res, 403, 'That subscription is no longer active. Renewing it re-enables this key.', {
      code: 'not_current',
    })
  }

  // Seats are counted, not licensed per-install: re-activating a Mac that
  // already holds one is free, which is what happens after a reinstall.
  const claimed = await seats(key)
  if (!(machine in claimed) && Object.keys(claimed).length >= SEATS) {
    return fail(res, 409, `This licence is already active on ${SEATS} Macs.`, {
      code: 'seats_exhausted',
      seats: SEATS,
    })
  }

  await claimSeat(key, machine, cleanLabel(label))
  res.status(200).json(signEntitlement(entitlementFor(licence, subscription, machine)))
}
