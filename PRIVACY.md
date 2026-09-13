# Privacy

Vaultkit handles SSH keys, encrypted vaults and the contents of your work. The
short version: none of that leaves your Mac, and the only thing Vaultkit sends
anywhere is what it takes to check that your licence is current.

## What never leaves your Mac

Your code. Your vault contents and passphrases. Your SSH keys — the private half
is inside the Secure Enclave and cannot be exported by anyone, including us. Your
git identities, emails, hostnames and organisation names. Doctor findings.
Scanner findings, quarantined files and scan history. The process and login-item
list the Activity view reads.

There is no telemetry, no analytics, no crash reporting and no account.

## What Vaultkit sends, and when

Only to the licensing service at `licence.vaultkit.app`, over TLS, and only on
these three occasions:

| When | What is sent |
|---|---|
| You activate a licence key | The key, a machine fingerprint, a machine label, the Vaultkit version |
| Roughly every 7 days after that | The key, the machine fingerprint, the Vaultkit version |
| You deactivate a machine | The key, the machine fingerprint |

That is the complete list. Nothing else in this application opens a network
connection on its own.

**The machine fingerprint** is a SHA-256 hash of your Mac's hardware UUID mixed
with a fixed Vaultkit salt. It is a stable opaque identifier used to count and
release seats. The hardware UUID itself is never transmitted, and the hash cannot
be reversed into it.

**The machine label** is the computer name you gave your Mac (the one in System
Settings → General → About), sent once at activation so that the list of your
activated machines is readable when you need to free a seat. If you would rather
not send it, rename the Mac first; activation works with any string.

**The licence key** is tied to the email address you paid with. That is what
connects an activation to a customer.

What the service records: the key, the fingerprints activated against it, the
machine labels, and the time of each check. It does not record IP addresses
beyond the transient logs of the hosting provider, and those are not joined to
licence records.

## The trial

The 14-day trial runs entirely offline. Its start date is stored in your login
keychain. Nothing is sent during a trial, and no payment details are needed to
start one.

## Payment

Payments are processed by Stripe, which acts as the data controller for your
payment details. Vaultkit never sees, handles or stores your card number. Stripe
tells us your email address, your country (for tax), and whether the subscription
is paid. See <https://stripe.com/privacy>.

## Your rights

Write to tooamiel@gmail.com to get a copy of what is held against your licence,
correct it, or have it deleted. Deleting it cancels the licence, since the record
*is* the licence.

Licence records are kept for as long as the subscription is active and for seven
years after, which is how long tax law requires the underlying transaction
records to be retained.

## Network traffic Vaultkit causes, but does not make

Cloning a repository and testing a key open an SSH connection to the forge you
named, because that is what you asked for. Those go straight to your forge; they
do not pass through us and we learn nothing about them.

## Changes

Material changes to this document will be announced in the release notes of the
version that introduces them. It forms part of the End User License Agreement in
LICENSE.

Last updated: 2026-09-14
