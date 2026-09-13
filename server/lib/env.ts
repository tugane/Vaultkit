/** Fails loudly at cold start rather than mysteriously at checkout. */
export function required(name: string): string {
  const value = process.env[name]
  if (!value) throw new Error(`${name} is not set. See server/.env.example.`)
  return value
}

export const optional = (name: string): string | undefined => process.env[name] || undefined

export const SITE_URL = process.env.SITE_URL ?? 'https://vaultkit.app'

/** Seats per subscription. Mirrors Licensing.seats in the app. */
export const SEATS = 3

/** How long an entitlement is good for before the app must ask again. */
export const RECHECK_DAYS = 7
