# Ruf

A simple macOS app switcher with a matrix-style layout.

![Ruf screenshot](.github/assets/screenshot.png)

## Requirements

- macOS 26 or later
- Accessibility permission, used to capture global keyboard shortcuts and
  enumerate, activate, and move application windows

## Build and run

```sh
swift test
./script/build_and_run.sh
```

To create an optimized universal release build without launching Ruf, run
`./script/build_and_run.sh --package`. The app and disk image are written to
`dist/Ruf.app` and `dist/Ruf.dmg`.

Generating the signed Sparkle feed is a separate release step:

```sh
./script/build_and_run.sh --appcast
```

This updates `dist/appcast.xml` from the existing release artifacts and may ask
for access to the Sparkle signing key in Keychain. If signing fails or is
interrupted, an existing appcast is left unchanged.
