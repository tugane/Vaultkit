# Privacy

Vaultkit handles SSH keys, encrypted vaults and the contents of your work. The
short version: none of it leaves your Mac, because Vaultkit makes no network
requests of its own at all.

## What never leaves your Mac

Your code. Your vault contents and passphrases. Your SSH keys: the private half
is inside the Secure Enclave and cannot be exported by anyone, including us.
Your git identities, emails, hostnames and organisation names. Doctor findings.
Scanner findings, quarantined files and scan history. The process and login-item
list the Activity view reads.

There is no telemetry, no analytics, no crash reporting, no update check and no
account. Vaultkit is free, so there is nothing to activate and no licence to
check.

## What Vaultkit sends

Nothing. There is no server, and no request Vaultkit makes on its own behalf.

## Network traffic Vaultkit causes, but does not make

Cloning a repository and testing a key open an SSH connection to the forge you
named, because that is what you asked for. Those go straight to your forge, and
nothing about them passes through anyone else.

## Changes

Material changes to this document will be announced in the release notes of the
version that introduces them.

Last updated: 2026-10-21
