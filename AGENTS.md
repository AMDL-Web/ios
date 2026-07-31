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

## Auth: the credential is Apple's own token, and it cannot be renewed

`GatewayAuth.swift` is the whole of it. The app signs in natively, keeps the
Apple identity token, and sends **that token itself** as
`Authorization: Bearer` — the gatehouse (oauth2-proxy behind nginx) verifies it
against Apple's JWKS and checks an email allow-list. It issues nothing of its
own and does not report who the caller is, because there is one user and
nothing downstream has anywhere to put a name.

**There is no silent way to mint another Apple identity token** —
`getCredentialState` reports that the authorization still stands, it does not
issue a token. So the app re-prompts when the current one expires. That is a
known, accepted cost, not a bug to fix here:

**Do not write a lifetime into any comment or any string.** The repo said "about
24 hours", someone "corrected" it to "about 10 minutes" as an observation error,
and the 10 minutes then propagated into four documents and one user-facing
label. Reading `exp` off the real token on 2026-07-30 gave **~23.4 hours** — the
"correction" was the error. The code parses `exp` precisely so nobody has to
believe a number in a comment; leave it that way.

- `amdl-portal` existed to remove it (identity token → its own access/refresh
  pair, 1 hour / 60 days). The portal was deleted when the system went back to
  single-user, and the cost came back with it.
- The only real fix is a **server** that mints a durable token, which is a
  server-side session however thin you write it. Don't try to work around it in
  the app — the one thing you could do here is keep the token longer, which just
  sends a credential that is certain to be refused.
- So `GatewayHTTP` has no refresh and no 401 retry. A 401 throws
  `needsSignIn` and the UI asks. `isSignedIn` checks the credential is still
  *usable*, not just present — otherwise the UI would claim you are signed in
  while every request 401s.

The 10-minute fallback in `GatewayCredential.init` is a deliberately pessimistic
floor for an unparsable token, **not** an estimate of the real lifetime.

The credential lives in the **Keychain** (`GatewayCredentialStore`), access
group = the App Group id, `AfterFirstUnlock` so the notification extension can
read it on a locked screen. `ShareViewController` hand-copies the decoder
because extensions can't see the main target — `identityToken` and `expiresAt`
are a **cross-target contract**, and a test pins them.

Two things a startup path still cleans up: the plaintext identity token an old
build left in the App Group's UserDefaults, and the portal's 60-day refresh
token in the `com.lyjw131.amdl.portal` Keychain item. Both issuers are gone.

**`BackendEndpoint`'s "portal" names are deliberate leftovers.** The host name
is injected at build time from `AMDL_PORTAL_HOST` (`Config/Portal.xcconfig`,
not in the repo), and renaming that key would silently empty a user's local
config — it compiles, installs, and never connects. The file says so at the top.

## Don't reach for MusicKit to fill gaps in the job

Animated album covers are the cautionary tale. `editorialVideo` is not available
to third-party apps at all — MusicKit's `MusicDataRequest` goes to
`api.music.apple.com`, which never returns it, on a real device with a paid
subscription. Only the backend can get it, from Apple's internal amp-api with a
scraped web-player token, so it arrives as `motion_artwork_url` on the job.

Before adding a MusicKit lookup for anything the backend could carry instead,
check that Apple actually exposes it to third parties. `PrivatePlaylistArtworkStore`
is the one case that genuinely needs on-device MusicKit: it resolves a private
playlist's cover with the *user's own* token, which the backend does not have.

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
