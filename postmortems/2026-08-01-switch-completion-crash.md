# Postmortem: Ruf crashed after completing an app switch

**Date:** 2026-08-01  
**Status:** Resolved and manually verified in commit `cbbe0d6`  
**Affected build:** Ruf 0.1.0, release configuration

## Summary

Ruf terminated immediately after the user completed a `Command-Tab` switch. The
switcher opened and accepted input, but releasing Command cleared the model while
SwiftUI was still updating cells from the previous render transaction. A retained
cell closure then used an old grid index to subscript the newly emptied application
array. Swift trapped on the out-of-range access and macOS terminated Ruf with
`SIGTRAP`.

The fix makes every grid render use one immutable application snapshot for both
its layout indices and its cell values. The same change set also gives the AppKit
delegate an explicit process-lifetime owner; that was a separate latent lifetime
bug, not the cause of this incident.

## Impact

- Ruf crashed after a switch was committed.
- The global keyboard event tap disappeared with the process, so Ruf no longer
  handled subsequent `Command-Tab` input.
- No application or user data was modified or lost.
- Relaunching Ruf did not provide a durable workaround because the same render
  sequence could crash again.

## Detection and evidence

The incident was reported after the installed release build exited following one
app switch. Process inspection confirmed that Ruf was no longer running.

macOS recorded three symbolicated reports for the same failure:

| Time (Europe/Berlin) | Signal | Failure |
| --- | --- | --- |
| 21:34:40 | `SIGTRAP` | `Swift runtime failure: Index out of range` |
| 22:52:57 | `SIGTRAP` | `Swift runtime failure: Index out of range` |
| 22:53:21 | `SIGTRAP` | `Swift runtime failure: Index out of range` |

All three reports identified the main thread and the same pre-fix location:
`SwitcherView.swift:46`, where a cell read `model.applications[index]`. The
AttributeGraph and SwiftUI frames above it showed that the access happened during
a deferred view-graph update, rather than directly inside the keyboard event-tap
callback.

RunningBoard and launchd independently recorded that the process exited from
`SIGTRAP`; this ruled out normal app termination, automatic termination, and the
application merely becoming hidden.

## Root cause

The view read two related values with different lifetimes:

```swift
let navigation = model.navigation

ForEach(navigation.indices(inRow: row), id: \.self) { index in
    let item = model.applications[index]
    // ...
}
```

`navigation` was a value captured when the body was evaluated, while
`model.applications` was read from the observable model when a retained cell
closure was updated.

The failure sequence was:

1. Releasing Command produced a `.commit` action.
2. `AppDelegate.commitSelection()` called `SwitcherModel.finish()`.
3. `SwitcherSession.finish()` cleared the session's item count and selection.
4. `SwitcherModel.finish()` then cleared `applications`.
5. SwiftUI flushed a pending update for a cell created from the previous grid.
6. That cell still had its previous index, but it read the current empty
   `applications` array.
7. Swift's checked array subscript trapped, terminating Ruf.

The individual states were valid in isolation. The defect was that a single
render closure combined an index from one state generation with an array from
another.

## Resolution

[SwitcherView.swift](../Sources/Ruf/Views/SwitcherView.swift) now captures the
application array once and derives the grid from that same value:

```swift
let applications = model.applications
let navigation = GridNavigation(itemCount: applications.count)

ForEach(navigation.indices(inRow: row), id: \.self) { index in
    let item = applications[index]
    // ...
}
```

Old SwiftUI closures therefore retain both the old index and the matching old
array. New renders receive both the new array and its matching grid geometry.
This fixes the state-generation mismatch at its source; it does not hide the
problem with an optional subscript, bounds guard, delay, or fallback.

[RufMain.swift](../Sources/Ruf/RufMain.swift) also stores `AppDelegate` in a
static strong reference. `NSApplication.delegate` is weak, so the previous local
variable did not express the required process-long lifetime. No crash evidence
implicated delegate deallocation in this incident, but leaving that lifetime
implicit would have created an independent reliability risk.

## Validation

After the fix:

- Debug compilation succeeded.
- Release compilation succeeded.
- All 18 core tests passed in debug configuration.
- All 18 core tests passed in release configuration.
- A new release app bundle was built and installed at `/Applications/Ruf.app`.
- The installed bundle passed strict code-signature verification.
- The installed executable matched the packaged release executable byte for
  byte.
- Manual verification of the installed build confirmed that completing a
  `Command-Tab` switch no longer crashed Ruf.

The existing unit tests intentionally cover the grid and input state machines;
they cannot reproduce SwiftUI's deferred AttributeGraph transaction. Manual
interaction testing therefore completed the incident validation. No synthetic
unit-only abstraction or unrequested UI test was added merely to create
coverage.

## Lessons and follow-up

- When a SwiftUI `ForEach` uses indices, its closures must capture the same
  collection snapshot from which those indices were derived.
- Related observable values being individually valid does not make a render
  transaction consistent; a view needs one coherent state generation.
- Symbolicated release crash reports are essential for distinguishing an AppKit
  lifecycle issue from a SwiftUI state-consistency failure.
- Packaging, unit tests, and signature verification cannot replace an
  interaction-level smoke check. Future release checks should include several
  completed and cancelled switch cycles whenever launching the app is authorized.
- AppKit delegate ownership should be explicit when the framework property is
  weak.

The code fix is recorded in `cbbe0d6` (`fix(app): prevent switch completion crash
and retain delegate`).
