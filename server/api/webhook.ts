import type { VercelRequest, VercelResponse } from '@vercel/node'
import type Stripe from 'stripe'
import { optional, required } from '../lib/env.js'
import { mintKey } from '../lib/licence.js'
import { stripe } from '../lib/stripe.js'
import { keyForSubscription, putLicence } from '../lib/store.js'

// Stripe signs the raw bytes. Vercel's JSON parser would re-serialise them and
// the signature would never verify again, so it is turned off here.
export const config = { api: { bodyParser: false } }

export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (req.method !== 'POST') return res.status(405).end()

  const signature = req.headers['stripe-signature']
  if (typeof signature !== 'string') return res.status(400).send('Missing signature.')

  let event: Stripe.Event
  try {
    const raw = await rawBody(req)
    event = stripe().webhooks.constructEvent(raw, signature, required('STRIPE_WEBHOOK_SECRET'))
  } catch (error) {
    // Anyone can POST here. An unverified body is not an event.
    return res.status(400).send(`Signature verification failed: ${(error as Error).message}`)
  }

  try {
    if (event.type === 'checkout.session.completed') {
      await issue(event.data.object)
    }
    // Renewals, cancellations and failed payments need nothing written here:
    // activate and validate read the subscription from Stripe every time, so
    // the change is live the moment Stripe records it.
  } catch (error) {
    // A 500 makes Stripe retry, which is what we want for a transient failure.
    console.error('webhook', event.type, error)
    return res.status(500).send('Could not process the event.')
  }

  res.status(200).json({ received: true })
}

/**
 * One licence key per subscription, minted the first time we see it. Stripe
 * retries a webhook it did not get a 200 for, so this has to be safe to run
 * twice: the subscription index is checked before anything is minted.
 */
async function issue(session: Stripe.Checkout.Session): Promise<void> {
  const subscriptionId =
    typeof session.subscription === 'string' ? session.subscription : session.subscription?.id
  const customerId = typeof session.customer === 'string' ? session.customer : session.customer?.id
  const email = session.customer_details?.email ?? session.customer_email
  if (!subscriptionId || !customerId || !email) {
    throw new Error('Checkout session had no subscription, customer or email.')
  }

  const existing = await keyForSubscription(subscriptionId)
  if (existing) return

  const key = mintKey()
  await putLicence({ key, email, customerId, subscriptionId, createdAt: Date.now() })

  // The key is also on the thank-you page, so a failure to send mail is not a
  // failure to deliver the purchase. Logged loudly, not retried.
  try {
    await email_(email, key)
  } catch (error) {
    console.error('could not email the licence key for', subscriptionId, error)
  }
}

async function email_(to: string, key: string): Promise<void> {
  const apiKey = optional('RESEND_API_KEY')
  if (!apiKey) {
    console.log(`licence key for ${to}: ${key} (no RESEND_API_KEY set, so it was not emailed)`)
    return
  }

  const response = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      from: optional('LICENCE_FROM_EMAIL') ?? 'Vaultkit <licences@vaultkit.app>',
      to,
      subject: 'Your Vaultkit licence key',
      text: [
        'Thank you for subscribing to Vaultkit.',
        '',
        `    ${key}`,
        '',
        'Open Vaultkit, click the licence line at the bottom of the sidebar, and',
        'paste it in. The key covers up to three Macs; you can free a seat from',
        'the same sheet when you retire one.',
        '',
        'Receipts, card changes and cancellation all live in your billing portal,',
        'linked from https://vaultkit.app/account.',
        '',
        'Amiel',
      ].join('\n'),
    }),
  })

  if (!response.ok) throw new Error(`Resend answered ${response.status}: ${await response.text()}`)
}

async function rawBody(req: VercelRequest): Promise<Buffer> {
  const chunks: Buffer[] = []
  for await (const chunk of req) chunks.push(typeof chunk === 'string' ? Buffer.from(chunk) : chunk)
  return Buffer.concat(chunks)
}
