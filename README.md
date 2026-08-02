# Ruf

A simple macOS app switcher with a matrix-style layout.

![Ruf screenshot](.github/assets/screenshot.png)

## Requirements

- macOS 26 or later
- Accessibility permission, used to capture `Command-Tab` and enumerate and
  activate application windows

## Build and run

```sh
swift test
./script/build_and_run.sh
```

To create an optimized universal release build without launching Ruf, run
`./script/build_and_run.sh --package`. The app, disk image, and Sparkle appcast
are written to `dist/Ruf.app`, `dist/Ruf.dmg`, and
`dist/appcast.xml`.
