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

Without a Developer ID, Ruf uses the pinned self-signed Code Signing identity
named `Ruf Release Code Signing`. The release maintainer must back up its
certificate and private key as a password-protected `.p12` outside the
repository. To validate that packaging path locally, import the identity into
the login Keychain and run:

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

Public releases are automated from version tags. Before tagging a release:

1. Update `CFBundleShortVersionString` and increment `CFBundleVersion` in
   `Resources/Info.plist`.
2. Copy `.github/release-notes/TEMPLATE.md` to
   `.github/release-notes/vMAJOR.MINOR.PATCH.md` and replace its placeholder
   with concise, user-visible changes.
3. Commit those files, then push the matching tag:

   ```sh
   git tag vMAJOR.MINOR.PATCH
   git push origin vMAJOR.MINOR.PATCH
   ```

The tag triggers `.github/workflows/release.yml`, which validates the version
and previous appcast, builds and tests Ruf, creates the self-signed universal
DMG, signs the Sparkle update, and publishes both files through a draft GitHub
Release. Ordinary pushes to `main` run CI but never publish a release.

The workflow reads these secrets from the `release` GitHub environment:

- `RUF_CODESIGN_CERTIFICATE_P12`: the base64-encoded pinned self-signed `.p12`
- `RUF_CODESIGN_CERTIFICATE_PASSWORD`: the `.p12` export password
- `RUF_SPARKLE_PRIVATE_KEY`: the contents of the file written by Sparkle's
  `generate_keys --account com.qichen.ruf -x /secure/path/Ruf-Sparkle.private-key`
  command

Create that environment before pushing the first automated release tag. Keep
it approval-free for automatic publication, restrict deployments to release
tags, and limit tag creation to maintainers through a repository ruleset.

Until the release workflow moves to Developer ID signing, automated releases
remain self-signed and are not notarized.
