# Ruf Repository Guide

This file applies to the entire repository. Keep it repository-specific; the
general working rules supplied by the user still apply and should not be
duplicated here.

## Product and toolchain

- Ruf is a keyboard-first macOS application and window switcher. It is an
  `LSUIElement` app, so it can run without a Dock icon or ordinary app menu.
- The minimum supported system is macOS 26. The package uses Swift tools 6.2,
  SwiftPM, AppKit, SwiftUI, Accessibility APIs, Core Graphics, and Sparkle.
- Ruf captures global keyboard input, reads and mutates other applications'
  windows, and moves windows between displays. A successful unit build alone
  does not validate these system integrations.

## Start with the real state

Before editing:

1. Inspect `git status --short --branch` and the relevant diff. Preserve
   unrelated user changes.
2. Trace the affected behavior through `RufCore`, the AppKit integration, its
   persisted preferences, and the packaging or release path when relevant.
3. Check the existing abstraction before adding a wrapper, fallback, or new
   source of truth.

Do not launch, quit, or replace the user's installed Ruf unless the user asks
for a runtime check. In particular, `./script/build_and_run.sh` without
`--package` builds and launches `dist/Ruf.app`; the `--debug`, `--logs`,
`--telemetry`, and `--verify` modes also launch it. Multiple Ruf processes with
the same bundle identifier make runtime evidence unreliable.

## Architecture map

- `Sources/RufCore`: deterministic policy, state machines, geometry, input
  interpretation, and persisted preference models. Keep testable behavior here
  when it does not require AppKit or Accessibility objects.
- `Sources/Ruf/App/AppDelegate.swift`: application lifecycle and orchestration
  for the event tap, switcher, settings, actions, and Sparkle.
- `Sources/Ruf/Services/KeyboardEventTap.swift`: global event-tap bridge. The
  durable input semantics belong to `Sources/RufCore/KeyboardInput.swift`.
- `Sources/Ruf/Stores/ApplicationCatalog.swift` and
  `Sources/Ruf/Services/ApplicationWindowService.swift`: application/window
  discovery and switch-target construction.
- `Sources/Ruf/Stores/SwitcherModel.swift` and
  `Sources/RufCore/SwitcherSession.swift`: presentation state and
  selection/session semantics.
- `Sources/Ruf/Services/FocusedWindowMover.swift` and
  `Sources/RufCore/WindowMovement.swift`: real window mutation and deterministic
  cross-display planning.
- `Sources/Ruf/Support/WindowMovementOutlineController.swift`: Ghost movement
  preview window.
- `Sources/Ruf/Support/SwitcherPanelController.swift` and
  `Sources/Ruf/Views/SwitcherView.swift`: switcher window lifecycle, sizing, and
  rendering.
- `Sources/Ruf/Support/SettingsWindowController.swift` and
  `Sources/Ruf/Views/SettingsView.swift`: AppKit-hosted settings window and
  SwiftUI content.
- `Sources/RufCore/SoftwareUpdateAvailability.swift`: cached update availability
  for Ruf's UI. Sparkle remains the update detector, validator, and installer.
- `Resources/Info.plist`: bundle identity, version/build, system requirement,
  app mode, and Sparkle configuration used by packaged artifacts.
- `script/build_and_run.sh`: the canonical local build, bundle, signing, DMG,
  debugging, telemetry, and release-packaging entry point.

## Contracts that must stay consistent

### Keyboard and switcher lifecycle

- `KeyboardInputSession` is the source of truth for event consumption and
  gesture state. Keep the event tap a narrow bridge rather than duplicating
  shortcuts or release behavior in AppKit code.
- Selection commits, New Window, and Quit are release-driven actions. Preserve
  their ordering and cancellation behavior across repeated keys and modifier
  release.
- AppKit presentation stays on the main actor. AX discovery uses its existing
  bounded detached-query path, and movement writes are serialized by
  `FocusedWindowMover`'s `windowWriter`. Do not introduce another concurrency
  boundary or access the same AX handle concurrently.

### Application and window discovery

- No single API is a complete window inventory. Ruf intentionally reconciles
  `NSWorkspace`, Accessibility, WindowServer, Dock, and other-Space evidence.
  Do not simplify this to one source based on a happy-path test.
- Private AX and SkyLight entry points are isolated behind runtime resolution.
  Their unavailable path is intentional; do not spread private API use or turn
  an unavailable answer into a definite "no windows" answer.
- Minimized, ordered-out, full-screen, and other-Space windows are distinct
  states. Preserve those distinctions when changing filtering or reopen logic.

### Window movement

- `WindowMovementPlanner` owns destination-display selection and frame mapping.
  Geometry policy changes require focused `RufCoreTests` coverage.
- Continuous movement animates the real window. Ghost movement animates the
  preview and commits the real window at the end. Keep those user-visible
  semantics separate even though they share planning and final placement.
- A resize uses the tested position-size-position final mutation sequence.
  Changing the order can reintroduce the one-key resize/two-key move failure or
  leave a window outside the destination's visible frame.
- Persisted raw values remain `live` and `outline`; the user-facing names are
  `Continuous` and `Ghost`. Changing stored values requires an explicit
  migration.

### Preferences, settings, and updates

- System Command-Tab mode requires a visible menu bar item. When the menu bar
  item is hidden in Ruf mode, the switcher must retain the Ruf Settings target.
- Settings uses a content-sized SwiftUI view hosted by AppKit. Preserve its
  content-driven vertical sizing and separator-free title bar; validate visible
  changes in both appearances and on the relevant display configuration.
- Sparkle is the only update-check and installation implementation. Ruf may
  configure its schedule and consume delegate results for UI, but must not add
  a parallel appcast parser, downloader, signature validator, or installer.
- Keep the current installed-version association when persisting update
  availability. A badge discovered by one installed build must not leak into a
  different build's UI.

## Implementation and tests

Use TDD for durable policy and state behavior. Add focused tests for meaningful
regressions in `RufCore`; do not add UI tests for straightforward SwiftUI
presentation or one-line wiring.

Useful targeted commands include:

```sh
swift test --filter WindowMovementPlannerTests
swift test --filter KeyboardInputSessionTests
swift test --filter SwitcherSessionTests
swift test --filter SoftwareUpdateAvailabilityTests
```

The normal strict source gate is:

```sh
swift build -Xswiftc -warnings-as-errors
swift test -Xswiftc -warnings-as-errors
bash -n script/build_and_run.sh
git diff --check
```

After every source, resource, bundle-configuration, dependency, or packaging
change, also rebuild the distribution-shaped local artifacts:

```sh
./script/build_and_run.sh --package
codesign --verify --deep --strict --verbose=2 dist/Ruf.app
hdiutil verify dist/Ruf.dmg
lipo -archs dist/Ruf.app/Contents/MacOS/Ruf
```

`dist/` and `.build/` are generated and ignored. Never stage them. A
documentation-only edit does not make existing artifacts stale, but still
requires final diff and command review.

Runtime checks are necessary for changes involving Accessibility permission,
event capture, Dock badges, Spaces, light/dark appearance, multiple displays,
display scale or refresh rate, and movement of Ruf's own Settings window. State
exactly which configurations were and were not checked; do not treat a green
test suite as visual or hardware verification.

Use `./script/build_and_run.sh --telemetry` only for an explicitly requested
profiling session. Keep performance logging opt-in and temporary; do not add
new telemetry or persistent collection as ordinary implementation work.

## Release boundary

Follow `RELEASING.md` and `.github/workflows/release.yml`; do not improvise a
second release path.

- Update both `CFBundleShortVersionString` and the monotonically increasing
  `CFBundleVersion` in `Resources/Info.plist`.
- Add `.github/release-notes/vMAJOR.MINOR.PATCH.md` with concise user-visible
  bullets.
- Push the release commit to `main` and wait for that exact commit's CI run to
  pass before creating the matching version tag.
- The tag must point to that same commit. Pushing it invokes the publisher;
  creating or pushing a tag requires explicit user authorization.
- The current automated release is pinned self-signed and not notarized. Do
  not describe it as Developer ID signed or notarized unless that workflow has
  actually changed and been verified.

A release is complete only after checking the exact tag/SHA, workflow result,
GitHub Release assets, digests, code signature, Sparkle signature, public
appcast ordering, and final Git state.

## Git and documentation

- Do not create branches, commits, tags, pushes, PRs, or releases unless the
  user requests that specific action. A commit does not imply a push.
- Keep commits cohesive and use concise conventional messages that state both
  the change and the behavior it fixes.
- Keep public product and ordinary build guidance in `README.md`. Keep signing,
  notarization, CI ordering, secrets, and publishing mechanics in
  `RELEASING.md`.
- Treat `postmortems/` as historical evidence, not current truth. Re-check its
  claims against current source and runtime behavior before relying on them.
- Never add agent attribution, scratch artifacts, local logs, signing secrets,
  or generated bundles to the repository.
