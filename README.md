# Ruf

A lightweight macOS app and window switcher with a matrix layout and
keyboard-first window controls.

![Ruf showing applications and windows in its matrix switcher](.github/assets/screenshot.jpg)

## Features

- Switch between applications and individual windows in a compact, spatial
  matrix ordered by recent use.
- Open a new window when the selected app exposes a compatible menu command,
  or quit the selected app without activating it first.
- Smoothly move the focused non-full-screen window to the spatially adjacent
  display while preserving its size and relative position.

> Open Ruf Settings for the complete keyboard shortcut reference.

## Requirements

- macOS 26 or later
- Accessibility permission, used to capture global keyboard shortcuts and
  enumerate, activate, and move application windows

## Build and run

```sh
swift test
./script/build_and_run.sh
```

To create an optimized universal build without launching Ruf, run
`./script/build_and_run.sh --package`. This produces ad-hoc-signed local
artifacts at `dist/Ruf.app` and `dist/Ruf.dmg`.

Without a Developer ID, import the pinned self-signed Code Signing identity
named `Ruf Release Code Signing` into the login Keychain. The release maintainer
must back up its certificate and private key as a password-protected `.p12`
outside the repository. Then run:

```sh
./script/build_and_run.sh --release-self-signed
```

This gives Ruf a stable identity across releases, but it does not satisfy
Gatekeeper or support notarization. Users must explicitly allow Ruf on first
launch. Moving from an older ad-hoc-signed release may also require granting
Accessibility permission one final time.

For standard public distribution, store a `notarytool` profile in Keychain,
then run:

```sh
RUF_DEVELOPER_ID_APPLICATION="Developer ID Application: NAME (TEAM_ID)" \
RUF_NOTARY_PROFILE="ruf-notary" \
./script/build_and_run.sh --release-notarized
```

Generating the signed Sparkle feed is a separate release step:

```sh
./script/build_and_run.sh --appcast
```

This updates `dist/appcast.xml` from validated release artifacts and may ask for
access to the Sparkle signing key in Keychain.
