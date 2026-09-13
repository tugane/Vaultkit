import type { VercelRequest, VercelResponse } from '@vercel/node'
import { required, SEATS, SITE_URL } from '../lib/env.js'
import { stripe } from '../lib/stripe.js'

/**
 * Starts a subscription. A GET redirects straight into Stripe Checkout, so the
 * Subscribe buttons in the app and on the site can be plain links; a POST
 * returns the URL as JSON for anything that would rather navigate itself.
 */
export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (req.method !== 'GET' && req.method !== 'POST') {
    return res.status(405).json({ error: 'Method not allowed.' })
  }

  const session = await stripe().checkout.sessions.create({
    mode: 'subscription',
    line_items: [{ price: required('STRIPE_PRICE_ID'), quantity: 1 }],
    // Stripe Tax works out VAT and sales tax per country. It does NOT register
    // you anywhere: you still owe the registrations your sales volume triggers.
    automatic_tax: { enabled: true },
    // Required for automatic_tax to have an address to work from, and it is
    // what appears on the invoice.
    billing_address_collection: 'required',
    allow_promotion_codes: true,
    subscription_data: {
      description: `Vaultkit — annual, up to ${SEATS} Macs`,
    },
    success_url: `${SITE_URL}/thanks?session_id={CHECKOUT_SESSION_ID}`,
    cancel_url: `${SITE_URL}/buy`,
  })

  if (!session.url) {
    return res.status(502).json({ error: 'Stripe did not return a checkout URL.' })
  }
  if (req.method === 'GET') return res.redirect(303, session.url)
  res.status(200).json({ url: session.url })
}
