# Contributing

Thanks for contributing to AMDL iOS. This document covers the commit and pull
request conventions. Project-specific engineering rules (toolchain, Swift 6
concurrency, build/test commands) live in [AGENTS.md](AGENTS.md).

## Branching and pull requests

- Branch off `dev` for feature work and open pull requests into `dev`.
- `dev` is promoted into `main` for releases; keep `main` shippable.
- CI (`.github/workflows/ci.yml`) builds and tests every push to `main`/`dev`
  and every pull request on a macOS runner via `xcodebuild`.
- iOS releases ship through App Store Connect / TestFlight — there is no
  container image or automated GHCR/Docker publish in this repository.

## Conventional Commit titles

All non-merge commits MUST follow the
[Conventional Commits](https://www.conventionalcommits.org/) specification:

```
<type>[optional scope]: <description>
```

Common types: `feat`, `fix`, `refactor`, `perf`, `docs`, `test`, `build`, `ci`,
`chore`. Add a scope when it clarifies the change, for example:

```
feat(detail): show download and decrypt speed
fix(share): guard against empty Apple Music link
```

## Developer Certificate of Origin (DCO)

All commits must be signed off under the
[Developer Certificate of Origin](https://developercertificate.org/). By signing
off, you certify that you wrote the change or otherwise have the right to submit
it under this project's license.

Sign off every commit with the `-s` flag:

```sh
git commit -s -m "feat: your commit message"
```

This appends a `Signed-off-by` trailer using your configured `git config
user.name` / `user.email`:

```
Signed-off-by: Your Name <you@example.com>
```

If you forgot to sign off a commit, amend it:

```sh
git commit --amend -s
```

For multiple commits in a branch, sign them all off against the base branch:

```sh
git rebase --signoff origin/dev
```

Pull requests are checked by the [DCO GitHub App](https://github.com/apps/dco)
and will fail if any commit is missing a valid `Signed-off-by` trailer that
matches the commit's author or committer.

## Automated review

Opening a pull request triggers automated review bots (Claude and Codex). They
post advisory comments; address or acknowledge their findings before requesting
human review. To temporarily disable them, set the repository variables
`CLAUDE_AUTO_REVIEW` / `CODEX_AUTO_REVIEW` to `false`.
