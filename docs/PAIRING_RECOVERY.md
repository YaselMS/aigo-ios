# Pairing recovery (#113)

The selected PC's ID stays the same after pairing again, but its token changes.
Previously `activate` reused the existing API client and socket for that ID, so a
successful pairing immediately retried the revoked token. `installPairing` now
disconnects the previous client before activating the newly saved credentials.
Legacy address-keyed entries are replaced by certificate identity as well.

Pairing HTTP 401 means a wrong code, not a revoked device. Pairing errors now
distinguish wrong, expired/stopped and rate-limited codes. Authenticated API 401
still requires pairing again. Complete incoming pairing links initiate pairing;
the recovery screen no longer offers a futile Retry for revoked credentials.

LAN and Tailscale share one pairing. A successful pairing keeps the supplied
endpoint list, and regular connection failover remains certificate-pinned.

Regression tests: `ios/AigoTests/PairingRecoveryTests.swift`, run on an isolated
iOS simulator in CI before packaging. Covers replacement of the selected client's
token/address, persistence, legacy deduplication and error classification.

Device acceptance remains separate: install v0.4.1, scan a fresh pairing QR from
the PC and confirm Connected. Then test cellular with Tailscale enabled. No test
here accesses the user's live host, credentials or installed app.
