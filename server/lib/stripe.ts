import Stripe from 'stripe'
import { required } from './env.js'

let client: Stripe | undefined

export function stripe(): Stripe {
  client ??= new Stripe(required('STRIPE_SECRET_KEY'), {
    // Pinned: an API version that moves under a licensing service is a
    // licensing service that breaks on someone else's release schedule.
    apiVersion: '2025-02-24.acacia',
    // Vercel functions are short-lived; one retry covers a cold DNS blip
    // without making an activation hang past the app's 15s timeout.
    maxNetworkRetries: 1,
  })
  return client
}

/** The statuses that mean "this person has paid and may use the app". */
export function statusOf(subscription: Stripe.Subscription): 'active' | 'pastDue' | 'cancelled' {
  switch (subscription.status) {
    case 'active':
    case 'trialing':
      return 'active'
    // Stripe keeps retrying a failed card for days. Cutting someone off on the
    // first failure locks a security tool over an expired card, so this is a
    // warning in the app, not a revocation.
    case 'past_due':
    case 'unpaid':
      return 'pastDue'
    default:
      return 'cancelled'
  }
}
