# QueueMaster

A native macOS app for managing CUPS printers, built because macOS 27 removed
the CUPS web interface (`cupsctl WebInterface=yes` no longer works). The CUPS
scheduler and its command-line tools are unchanged, and QueueMaster is a UI on
top of them: every change it makes is a normal `lpadmin` / `lpoptions` /
`cupsctl` command, shown before it runs and logged in **Activity**.

## What it does

- **Printers**: live status, pause/resume with a reason ("Out of labels"),
  accept/reject jobs, make default, share, rename or duplicate, delete.
- **Queue**: waiting and completed jobs; hold, release, cancel, cancel all,
  move to another printer, print again.
- **Options**: every PPD option with its real labels (media size, darkness,
  print mode, cutter, trays, duplex…), including custom label sizes. Save as
  the **queue default** for everyone (`lpadmin -o`) or as **my defaults only**
  (`lpoptions -o`); per-user overrides are flagged and can be cleared.
- **Settings**: description, location, device URI (with templates for IPP,
  AppSocket/9100, LPD, SMB), driver changes, sharing.
- **Add Printer**: discovers devices (`lpinfo -v`), searchable driver list
  (`lpinfo -m`) ranked against the device, driverless/AirPrint, raw queues for
  ZPL/EPL/ESC-POS, or your own PPD file.
- **Test printing**: test page, a short text test for label/receipt printers,
  or any file.
- **Server settings**: printer sharing, remote access, debug logging, error
  policy (`cupsctl`).
- **Logs**: `error_log`, `access_log`, `page_log`, with filtering and an
  "as administrator" read.
- **Console**: run CUPS commands directly (CUPS tools only), optionally as admin.

## Permissions

Reads run as you. Changes are tried as you first; if CUPS refuses, QueueMaster
re-runs the command through the standard macOS administrator prompt (macOS
remembers it for a few minutes). Settings → "Always ask for the administrator
password" skips the first attempt. Per-user defaults (`lpoptions`) never run as
root, since that would change root's settings instead of yours.

## Building

Needs Xcode (Swift 5.10+), macOS 14+.

```sh
swift test                       # parser tests against real CUPS output
ci/build-app.sh 0.1.0 1          # -> build/QueueMaster.app (unsigned)
open build/QueueMaster.app
```

Or open `Package.swift` in Xcode and run the `QueueMaster` scheme.

### Installing and updating

Each release has `QueueMaster-<version>.pkg` (installs to /Applications) and
`QueueMaster.zip`. QueueMaster checks the latest GitHub release once a day
(QueueMaster → Check for Updates… any time). It only installs an update
whose .pkg is signed by the same Apple Developer team as the running app and
accepted by Gatekeeper (signed and notarized); the install uses the normal
administrator prompt, then the app relaunches.

To publish a release: `git tag v0.2.0 && git push origin v0.2.0`.

### CI

`.github/workflows/build.yml` runs on the hoods-goods Mac mini runner
(`self-hosted, refurb-build`): tests and builds on every push and PR; on `main`
and tags it signs the app, builds and signs the .pkg, notarizes it and uploads both. Pushing a tag such
as `v1.0.0` publishes a GitHub release.

Signing uses the same secrets as RefurbStation; add them to this repo (or as
organization secrets): `MAC_CERTS_P12`, `MAC_CERTS_P12_2`, `MAC_CERTS_PASSWORD`,
`NOTARY_KEY_P8`, `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID`. Without them the build is
ad-hoc signed (right-click → Open the first time).

## Layout

- `Sources/CupsKit` – runs the CUPS tools and parses their output and PPDs.
- `Sources/QueueMaster` – the SwiftUI app.
- `Tests/CupsKitTests` – parser tests; `Fixtures/` is real output captured from CUPS 2.4.
- `ci/` – app bundling, signing and notarization.
