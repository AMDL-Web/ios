# amdl-ios

SwiftUI app for creating and monitoring Apple Music download jobs against
`amdl-backend`, plus a Live Activity widget, a share extension, and a
notification service extension. `DownloadsAPI.swift` mirrors the backend's JSON
shapes by hand — see the [repository map](../AGENTS.md) before changing them.

**Building or testing:** read `.claude/skills/ios-verify/SKILL.md`. It has the
exact `xcodebuild` invocations, which simulator to target, and how much
verification a given change deserves.

## Swift 6 concurrency is strict here, and stays strict

All targets compile in Swift 6 language mode with complete checking; the app and
extension targets default to `MainActor` isolation.

Fix isolation and `Sendable` errors at the source. Loosening a build setting,
reaching for `@unchecked Sendable` or `nonisolated(unsafe)`, or widening a
`@preconcurrency` import to make a diagnostic go away all trade a compile-time
guarantee for a runtime data race. Use the escape hatches only when a real
invariant genuinely can't be expressed in the type system, and write down which
invariant and why.

Concrete invariants worth knowing before you touch them:

- `ImageDiskStore` serializes disk cache I/O and clears by generation counter.
  Preserve those semantics — a clear that isn't generation-aware races with
  in-flight writes.
- `AppleMusicTokenService` exists so MusicKit's shared token provider is only
  reached from one place. Route token access through it rather than calling the
  SDK directly.
- ActivityKit reference types stay inside the isolation domain that owns them.
  Pass activity IDs and sendable content across boundaries, not the activity.
- Objective-C callback values need converting to a sendable representation
  before you resume a continuation with them.
- Check cancellation after meaningful suspension points, before you commit
  downloaded data or push new UI state.

Prefer making a caller `async` over spawning an unstructured `Task`.

## Cross-target details

- Types shared between the app and the widget live in `LiveActivityShared/`.
  Don't re-declare a parallel copy in a target that needs one; add the target to
  the shared file's membership.
- User-facing copy is Chinese. Keep it that way unless the task is about the
  wording.

## Project file and signing

- Touch `amdl-ios.xcodeproj/project.pbxproj` only when target membership or a
  build setting actually requires it, and keep Debug and Release aligned unless
  the difference is deliberate.
- Bundle identifiers, entitlements, App Group identifiers, signing teams,
  provisioning, and deployment targets need explicit authorization to change —
  they break TestFlight and the App Group the widget reads from.
- Never commit `xcuserdata` or `*.xcuserstate`.

## Commits

Only `main` requires a pull request, and `dev` is promoted into it for releases.
Commit to `dev` directly otherwise — a small change doesn't need its own branch.
(CONTRIBUTING.md says feature work always branches off `dev`; that's stricter
than how this repo is actually worked.)

Every commit needs a DCO `Signed-off-by` trailer (`git commit -s`) or the
[DCO app](https://github.com/apps/dco) blocks the PR, and non-merge commits
follow [Conventional Commits](https://www.conventionalcommits.org/). Rest of the
workflow in [CONTRIBUTING.md](CONTRIBUTING.md).

When amending, keep any existing agent attribution trailer alongside the
sign-off rather than replacing it.
