---
name: ios-verify
description: Build or test the amdl-ios Xcode project. Use whenever a change under amdl-ios/ needs to be compiled, unit-tested, or checked in Release configuration — holds the exact xcodebuild invocations, the simulator-reuse rule, how much verification each kind of change deserves, and which warnings are false positives.
---

# Verifying amdl-ios

Run everything from the `amdl-ios/` directory.

## Choose the destination before you build

The user keeps a simulator open while working and does not want a second one
booted. Check what's already running:

```sh
xcrun simctl list devices booted
```

Target it by UDID. A `name=` destination that isn't an exact match — `iPhone 17`
against a booted `iPhone 17 Pro` — makes xcodebuild clone and boot a separate
simulator, which the user has objected to.

```sh
DEST="platform=iOS Simulator,id=<UDID from simctl>"
```

If nothing is booted, pick an installed runtime from
`xcodebuild -project amdl-ios.xcodeproj -scheme amdl-ios -showdestinations`.

## Commands

Each one uses a throwaway Derived Data directory, so stale local Xcode state
can't hide a real break.

Debug build:

```sh
build_dir=$(mktemp -d /tmp/amdl-ios-debug.XXXXXX)
xcodebuild \
  -project amdl-ios.xcodeproj \
  -scheme amdl-ios \
  -configuration Debug \
  -destination "$DEST" \
  -derivedDataPath "$build_dir" \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Unit tests (Swift Testing):

```sh
test_dir=$(mktemp -d /tmp/amdl-ios-tests.XXXXXX)
xcodebuild \
  -project amdl-ios.xcodeproj \
  -scheme amdl-ios \
  -configuration Debug \
  -destination "$DEST" \
  -derivedDataPath "$test_dir" \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:amdl-iosTests \
  test
```

Release build — no specific simulator needed:

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

## How far to go

- Localized source edit → build the affected target.
- Concurrency, model, API, or project-setting change → Debug-build the whole
  `amdl-ios` scheme, since these break sibling targets rather than the file you
  edited.
- Release-sensitive or cross-target change → add the Release build. Release
  catches optimization- and configuration-only failures Debug won't.
- Unit tests: not during iteration. Run them right before a commit, or when
  asked. They cost a simulator boot and rarely catch what a build doesn't.

## Reading the output

- Every Swift concurrency warning is actionable — the project builds in Swift 6
  language mode with complete checking, and these become errors upstream.
- `Metadata extraction skipped. No AppIntents.framework dependency found` from a
  target with no App Intents is an Xcode metadata warning, not a diagnostic.
- UI tests need a working Simulator test runner. A local Xcode debugger or
  runtime failure is not a test assertion failure — report it as an environment
  problem and still confirm the UI test target compiles.
- `git diff --check` before handing work off.
