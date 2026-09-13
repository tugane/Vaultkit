import type { VercelRequest, VercelResponse } from '@vercel/node'
import { SITE_URL } from '../lib/env.js'
import { validKey } from '../lib/licence.js'
import { stripe } from '../lib/stripe.js'
import { getLicence } from '../lib/store.js'

/**
 * Sends someone to Stripe's billing portal, where cards, receipts, invoices and
 * cancellation live. Stripe hosts all of it, so none of that has to be built
 * here and no card detail ever touches this service.
 *
 * The licence key is the credential. That is deliberate: it is the one thing
 * every customer has to hand, and the portal Stripe opens shows only their own
 * billing. Anyone holding the key already holds the subscription.
 */
export default async function handler(req: VercelRequest, res: VercelResponse) {
  const key = req.method === 'POST' ? (req.body?.key as unknown) : req.query.key
  if (!validKey(key)) {
    return res.status(400).json({ error: 'Provide your licence key to open the billing portal.' })
  }

  const licence = await getLicence(key)
  if (!licence) return res.status(404).json({ error: 'That key is not on file.' })

  const session = await stripe().billingPortal.sessions.create({
    customer: licence.customerId,
    return_url: `${SITE_URL}/account`,
  })

  if (req.method === 'GET') return res.redirect(303, session.url)
  res.status(200).json({ url: session.url })
}
