# Vaultkit licensing service

Stripe checkout, the webhook that mints licence keys, and the signed
entitlements the app verifies offline.

Setup, deployment and how to test the whole path are in
[../docs/licensing.md](../docs/licensing.md). Copy `.env.example` to `.env` to
run it locally.

```
api/
  checkout.ts      GET or POST → Stripe Checkout (annual subscription)
  webhook.ts       checkout.session.completed → mint a key, store it, email it
  key.ts           GET ?session_id= → the key for a paid checkout (thank-you page)
  portal.ts        GET or POST ?key= → Stripe's billing portal
  v1/activate.ts   claim a seat, return a signed entitlement
  v1/validate.ts   the weekly re-check; a "no" comes back signed, not as a 403
  v1/deactivate.ts release a seat
lib/
  licence.ts       key minting, Ed25519 signing, input validation
  store.ts         Upstash Redis: key → customer, key → seats
  stripe.ts        the client, and the one place subscription status is judged
scripts/keygen.mjs the release signing key
```

Nothing here ever sees a card number: Stripe Checkout and the billing portal are
hosted by Stripe.
