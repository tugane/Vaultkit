import { createPrivateKey, randomBytes, sign } from 'node:crypto'
import type Stripe from 'stripe'
import { RECHECK_DAYS, required } from './env.js'
import { statusOf } from './stripe.js'
import type { Licence } from './store.js'

// MARK: - Keys people have to type
//
// Crockford's alphabet: no I, L, O or U, so a key read off a screen and typed
// into the app cannot become a different valid key through a misread digit.
const ALPHABET = '0123456789ABCDEFGHJKMNPQRSTVWXYZ'

export function mintKey(): string {
  // 16 characters of a 32-symbol alphabet is 80 bits. Guessing one is not a
  // threat model anyone needs to worry about.
  const bytes = randomBytes(16)
  const body = Array.from(bytes, (b) => ALPHABET[b % ALPHABET.length]).join('')
  return ['VK', body.slice(0, 4), body.slice(4, 8), body.slice(8, 12), body.slice(12, 16)].join('-')
}

// MARK: - What the app verifies

export interface Entitlement {
  key: string
  machine: string
  email: string
  plan: string
  status: 'active' | 'pastDue' | 'cancelled'
  /** Seconds since the epoch: the app decodes with .secondsSince1970. */
  periodEnd: number
  issuedAt: number
  recheckAfter: number
}

export function entitlementFor(
  licence: Licence,
  subscription: Stripe.Subscription,
  machine: string,
): Entitlement {
  const now = Math.floor(Date.now() / 1000)
  return {
    key: licence.key,
    machine,
    email: licence.email,
    plan: 'annual',
    status: statusOf(subscription),
    periodEnd: subscription.current_period_end,
    issuedAt: now,
    recheckAfter: now + RECHECK_DAYS * 86_400,
  }
}

/**
 * Signs an entitlement with the release key. The app carries only the public
 * half, so neither a tampered cache on someone's Mac nor a proxy terminating
 * TLS can produce one of these.
 *
 * The signature covers the base64 payload string exactly as transmitted, not
 * the JSON it decodes to: there is no canonicalisation to disagree about.
 */
export function signEntitlement(entitlement: Entitlement): { payload: string; signature: string } {
  const pem = Buffer.from(required('LICENCE_SIGNING_KEY'), 'base64').toString('utf8')
  const key = createPrivateKey(pem)
  const payload = Buffer.from(JSON.stringify(entitlement)).toString('base64')
  // Ed25519 signs the message directly: the algorithm argument must be null.
  const signature = sign(null, Buffer.from(payload, 'utf8'), key)
  return { payload, signature: signature.toString('base64') }
}

// MARK: - Input the app sends

const KEY_SHAPE = /^VK-[0-9A-Z]{4}-[0-9A-Z]{4}-[0-9A-Z]{4}-[0-9A-Z]{4}$/
const MACHINE_SHAPE = /^[0-9a-f]{64}$/

export function validKey(value: unknown): value is string {
  return typeof value === 'string' && KEY_SHAPE.test(value)
}

/** The app sends a SHA-256 hex digest of its fingerprint, and nothing else. */
export function validMachine(value: unknown): value is string {
  return typeof value === 'string' && MACHINE_SHAPE.test(value)
}

/**
 * A name someone gave their Mac. It is displayed back to them on the account
 * page, so control characters come out and the length is capped; it is never
 * used for anything but display.
 */
export function cleanLabel(value: unknown): string {
  if (typeof value !== 'string') return 'A Mac'
  const printable = Array.from(value)
    .filter((character) => {
      const code = character.codePointAt(0) ?? 0
      return code >= 32 && code !== 127
    })
    .join('')
  return printable.trim().slice(0, 64) || 'A Mac'
}
