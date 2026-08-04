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
