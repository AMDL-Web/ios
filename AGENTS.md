# AMDL iOS Agent Guide

## Scope

This guide applies to the entire iOS project in this directory. The repository-level
`../AGENTS.md` remains the routing guide for work that crosses subprojects.

Keep iOS-only changes inside this project. If a task also changes backend or frontend
behavior, read the corresponding subproject guide before editing those files.

## Project Overview

AMDL is a SwiftUI iOS app for creating and monitoring Apple Music download jobs.
The Xcode project contains five targets:

- `amdl-ios`: main SwiftUI application.
- `DownloadLiveActivity`: WidgetKit and ActivityKit extension.
- `ShareDownloadExtension`: UIKit share extension for Apple Music links.
- `amdl-iosTests`: unit tests using Swift Testing.
- `amdl-iosUITests`: UI tests using XCTest.

Shared Live Activity models and artwork storage live in `LiveActivityShared/`.

## Toolchain and Language Rules

- Use the Xcode version selected by `xcode-select`; do not change the selected
  developer directory as part of routine project work.
- All targets compile in Swift 6 language mode.
- The app and extension targets use `MainActor` as their default actor isolation.
- Preserve complete Swift 6 concurrency checking. Fix isolation and `Sendable`
  errors at their source instead of weakening build settings.
- Do not add `@unchecked Sendable` or `nonisolated(unsafe)` merely to silence a
  diagnostic. Use either only when a reviewed invariant cannot be expressed safely.
- Keep `@preconcurrency` imports narrow and document why the imported SDK requires
  the compatibility boundary.

## Architecture and Concurrency

- SwiftUI and UIKit state belongs on `MainActor` unless there is a concrete reason
  to isolate it elsewhere.
- Use actors for mutable state that is accessed by multiple tasks. Disk cache I/O is
  serialized by `ImageDiskStore`; preserve its generation-based clear semantics.
- Values crossing actor or task boundaries must be `Sendable`. Convert Objective-C
  callback values to a sendable representation before resuming a continuation.
- Respect task cancellation after every meaningful suspension point before updating
  UI state or committing downloaded data.
- Avoid unstructured `Task` blocks when the caller can make the operation `async`
  and await it.
- Keep ActivityKit reference types inside the isolation domain where they are used.
  Pass activity IDs and sendable content across isolation boundaries.
- Route MusicKit token access through `AppleMusicTokenService` so access to the SDK's
  shared token provider remains serialized.

## Source Organization

- Put main-app code in `amdl-ios/`.
- Put share-extension-only code in `ShareDownloadExtension/`.
- Put Live Activity UI in `DownloadLiveActivity/` and models shared with the app in
  `LiveActivityShared/`.
- Add unit tests to `amdl-iosTests/` and UI tests to `amdl-iosUITests/`.
- Do not duplicate shared ActivityKit types independently across targets.
- Preserve existing Chinese user-facing copy unless the task explicitly changes it.

## Build and Test

Run commands from this directory. Use a temporary Derived Data directory so local
Xcode state does not affect verification.

Debug simulator build:

```sh
build_dir=$(mktemp -d /tmp/amdl-ios-debug.XXXXXX)
xcodebuild \
  -project amdl-ios.xcodeproj \
  -scheme amdl-ios \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4.1' \
  -derivedDataPath "$build_dir" \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Release simulator build:

```sh
build_dir=$(mktemp -d /tmp/amdl-ios-release.XXXXXX)
xcodebuild \
  -project amdl-ios.xcodeproj \
  -scheme amdl-ios \
  -configuration Release \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$build_dir" \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Unit tests:

```sh
test_dir=$(mktemp -d /tmp/amdl-ios-tests.XXXXXX)
xcodebuild \
  -project amdl-ios.xcodeproj \
  -scheme amdl-ios \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4.1' \
  -derivedDataPath "$test_dir" \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:amdl-iosTests \
  test
```

If that exact simulator runtime is unavailable, choose an installed iPhone simulator
from `xcodebuild -project amdl-ios.xcodeproj -scheme amdl-ios -showdestinations`.

UI tests require a working Simulator test runner. A local Xcode debugger/runtime
failure is not a test assertion failure; report it separately and still verify that
the UI test target compiles.

## Verification Expectations

- For a localized source edit, build the affected target at minimum.
- For concurrency, model, API, or project-setting changes, build the full `amdl-ios`
  scheme in Debug.
- Do not run unit tests during iterative development; run them only right before a
  commit, or when the user explicitly asks for them.
- For release-sensitive or cross-target changes, also perform a Release build.
- Treat every Swift concurrency warning as actionable.
- `Metadata extraction skipped. No AppIntents.framework dependency found` from a
  target without App Intents is an Xcode metadata warning, not a Swift 6 diagnostic.
- Run `git diff --check` before handing work off.

## Project File and Signing Safety

- Edit `amdl-ios.xcodeproj/project.pbxproj` only when target membership or build
  settings genuinely require it.
- Keep Debug and Release settings aligned unless a difference is intentional.
- Do not change bundle identifiers, entitlements, App Group identifiers, signing
  teams, provisioning settings, or deployment targets without explicit authorization.
- Do not commit personal Xcode state such as `xcuserdata` or `*.xcuserstate`.

## Change Discipline

- Preserve unrelated local modifications and avoid broad mechanical rewrites.
- Keep fixes scoped to the requested behavior and add tests for parsing, state
  transitions, or request encoding when practical.
- Do not commit, push, or open a pull request unless the user requests it.
- In the handoff, list changed files, builds/tests performed, remaining warnings,
  and any verification blocked by local Xcode or Simulator state.
