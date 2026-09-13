import type { VercelRequest, VercelResponse } from '@vercel/node'
import { stripe } from '../lib/stripe.js'
import { keyForSubscription } from '../lib/store.js'

/**
 * The thank-you page's lookup: hands back the licence key for a checkout
 * session that has actually been paid.
 *
 * The session id is unguessable and is only ever in the hands of the person who
 * just completed that checkout, which is the same authority the emailed copy
 * carries. It exists so that a mail failure is never a failed delivery.
 */
export default async function handler(req: VercelRequest, res: VercelResponse) {
  const sessionId = req.query.session_id
  if (typeof sessionId !== 'string' || !sessionId.startsWith('cs_')) {
    return res.status(400).json({ error: 'Missing session_id.' })
  }

  const session = await stripe().checkout.sessions.retrieve(sessionId)
  if (session.payment_status !== 'paid') {
    return res.status(402).json({ error: 'That checkout has not been paid.' })
  }

  const subscriptionId =
    typeof session.subscription === 'string' ? session.subscription : session.subscription?.id
  if (!subscriptionId) return res.status(404).json({ error: 'No subscription on that checkout.' })

  // The webhook mints the key, and Stripe can deliver it a second or two after
  // the browser lands here. The page polls; this just says "not yet".
  const key = await keyForSubscription(subscriptionId)
  if (!key) return res.status(202).json({ pending: true })

  res.setHeader('Cache-Control', 'no-store')
  res.status(200).json({ key, email: session.customer_details?.email ?? null })
}
