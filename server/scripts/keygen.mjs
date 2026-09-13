#!/usr/bin/env node
//
// Generates the Ed25519 release key the licensing service signs entitlements
// with. Run it once, keep the private half in the Vercel environment, and paste
// the public half into Sources/Vaultkit/Models/License.swift.
//
// Rotating it invalidates every cached entitlement in the field: the app will
// drop them and fall back to the trial state, then re-activate on next launch.
// So rotate only if the private half leaks.

import { generateKeyPairSync } from 'node:crypto'

const { privateKey, publicKey } = generateKeyPairSync('ed25519')

const pem = privateKey.export({ type: 'pkcs8', format: 'pem' })
// The SPKI DER for an Ed25519 key is 12 bytes of prefix and then the raw 32
// bytes, which is what CryptoKit's rawRepresentation initialiser wants.
const raw = publicKey.export({ type: 'spki', format: 'der' }).subarray(12)

console.log('LICENCE_SIGNING_KEY (server env, keep secret):')
console.log(Buffer.from(pem).toString('base64'))
console.log()
console.log('Licensing.signingPublicKey (Sources/Vaultkit/Models/License.swift):')
console.log(raw.toString('base64'))
