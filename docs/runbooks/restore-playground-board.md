# Runbook — Restore the Playground board on a device

_Last verified: 2026-06-12 (mission #28). The live restore E2E
(`LivePlaygroundRestoreTests`) passed against the real server the same day:
32 cards into Ready, zero-delta second sync._

## State of the live board

- Board: **Playground** (account slug `1`, fizzy.bluefenix.net)
- Exactly **32 genuine cards**, all triaged into **Ready** (2026-06-12 cleanup:
  128 duplicates deleted keeping the lowest-numbered copy of each title —
  manifest on mission log issue #28).
- Columns: Ready · In Progress · Done.

## Restore on a device (iPhone / Mac)

1. Build & install FK (see device-support note below).
2. In FK: create (or keep) a local board — e.g. **FenixKanban**.
3. Settings → Board Sync → Fizzy → paste the personal access token → Verify.
4. Pair the local board with **Playground**.
5. First-sync mode: **Replace local with Fizzy** (destructive to local cards —
   confirm the alert; the local board should be fresh/empty anyway).
6. Verify: 32 cards in the Ready column. Auto-refresh then polls every 5
   minutes while the app is active; background refresh is registered on iOS.

Troubleshooting:
- 401 → token revoked: Settings → Fizzy → re-verify.
- Pairing is device-local (`FizzyCardPairings.json` sidecar); a reinstall
  re-seeds from the synced hint attributes on first sync.
- Never first-sync with **Push local** against Playground from a non-empty
  board — that's how the duplicate plague started.

## Device support (Susanoo) — current blocker

Susanoo runs **iOS 27.0 beta (24A5355q)**. The Mac mini has **Xcode 26.5**
only, which cannot mount the iOS 27 developer disk image:

```
make install DEVICE_ID=BA3D11C6-B4A3-5E64-B65F-231B6E607E0F
# → -[PersonalizedImage mountRemoteImage:…] / Error 1
#   ("Enabling developer disk image services" fails)
```

**Fix: install the Xcode 27 beta** (or at least its iOS 27 device-support
bundle) on the Mac mini, then:

```
make devices                       # confirm Susanoo's identifier
make run DEVICE_ID=<susanoo-id>    # build-device + install + launch
```

The app itself targets iOS 26 (floor unchanged); it runs fine ON iOS 27 —
only the *development install tooling* needs the newer Xcode. Simulator
verification (pinned iPhone 17, iOS 26.4) is unaffected and remains the
automated path.

## Related

- Background-refresh device verification: `docs/runbooks/background-refresh-verification.md`
- Live API harness: `make integration-test` (env-gated; `.env` at repo root)
- `fizzyctl` CLI: `xcodebuild -scheme fizzyctl build` → ad-hoc API probes
