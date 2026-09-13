import { Redis } from '@upstash/redis'
import { required } from './env.js'

// Stripe is the source of truth for whether a subscription is paid. This store
// holds only what Stripe cannot: which licence key belongs to which customer,
// and which Macs have claimed a seat against it.

let client: Redis | undefined

function redis(): Redis {
  client ??= new Redis({
    url: required('UPSTASH_REDIS_REST_URL'),
    token: required('UPSTASH_REDIS_REST_TOKEN'),
  })
  return client
}

export interface Licence {
  key: string
  email: string
  customerId: string
  subscriptionId: string
  createdAt: number
}

export interface Seat {
  label: string
  activatedAt: number
  lastSeen: number
}

const licenceKey = (key: string) => `licence:${key}`
const seatsKey = (key: string) => `seats:${key}`
const bySubscription = (id: string) => `sub:${id}`

export async function putLicence(licence: Licence): Promise<void> {
  await Promise.all([
    redis().set(licenceKey(licence.key), licence),
    redis().set(bySubscription(licence.subscriptionId), licence.key),
  ])
}

export async function getLicence(key: string): Promise<Licence | null> {
  return (await redis().get<Licence>(licenceKey(key))) ?? null
}

export async function keyForSubscription(id: string): Promise<string | null> {
  return (await redis().get<string>(bySubscription(id))) ?? null
}

export async function seats(key: string): Promise<Record<string, Seat>> {
  return (await redis().hgetall<Record<string, Seat>>(seatsKey(key))) ?? {}
}

export async function claimSeat(key: string, machine: string, label: string): Promise<void> {
  const now = Date.now()
  const existing = await redis().hget<Seat>(seatsKey(key), machine)
  await redis().hset(seatsKey(key), {
    [machine]: { label, activatedAt: existing?.activatedAt ?? now, lastSeen: now } satisfies Seat,
  })
}

export async function touchSeat(key: string, machine: string): Promise<boolean> {
  const existing = await redis().hget<Seat>(seatsKey(key), machine)
  if (!existing) return false
  await redis().hset(seatsKey(key), { [machine]: { ...existing, lastSeen: Date.now() } })
  return true
}

export async function releaseSeat(key: string, machine: string): Promise<void> {
  await redis().hdel(seatsKey(key), machine)
}
