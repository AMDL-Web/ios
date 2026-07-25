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

## TestFlight 发版

合并 `dev` → `main` 的 pull request 会触发
[`.github/workflows/testflight.yml`](.github/workflows/testflight.yml)：归档、
导出 ipa、上传 App Store Connect、打 tag。也可以在 Actions 页手动触发
（`workflow_dispatch`）并指定版本号。

版本号取自工程的 `MARKETING_VERSION`（PR 标题里写了 `vX.Y.Z` 则优先用它），
构建号使用 GitHub 的 `run_number`，保证同一版本号下唯一且递增。

上传成功后，构建在 App Store Connect 处理完（几分钟到半小时）会自动出现在
TestFlight。**内部测试组**的成员会直接收到，无需 Beta 审核；外部测试组才需要
提交审核。

### 一次性前置配置

发版前需要在 Apple 侧和 GitHub 侧各做一次配置：

**Apple 侧**

1. 在开发者门户注册 App ID：`com.lyjw131.amdl.amdl-ios` 及两个扩展
   （`.DownloadLiveActivity`、`.ShareDownloadExtension`），并按 entitlements
   开启 App Groups、Push Notifications、iCloud/CloudKit 能力。
   （`xcodebuild -allowProvisioningUpdates` 配合下面的 API 密钥通常能自动
   创建，但 App Group `group.com.lyjw131.amdl.amdl-ios` 建议先手动建好。）
2. 在 App Store Connect 新建 App 记录，bundle ID 选 `com.lyjw131.amdl.amdl-ios`。
   没有这条记录时上传会以 “No suitable application record was found” 失败。
3. 创建 **Apple Distribution** 证书，并从钥匙串导出为 `.p12`（含私钥）。
4. 在 App Store Connect → 用户和访问 → 集成 → App Store Connect API 创建密钥
   （角色至少 App Manager），记下 Issuer ID、Key ID，并下载 `.p8`（只能下载一次）。

**GitHub 侧** —— 在仓库 Settings → Secrets and variables → Actions 添加：

| Secret | 内容 |
| --- | --- |
| `APPSTORE_ISSUER_ID` | API 的 Issuer ID（UUID） |
| `APPSTORE_KEY_ID` | API 密钥的 Key ID |
| `APPSTORE_PRIVATE_KEY` | `.p8` 文件的完整内容 |
| `BUILD_CERTIFICATE_BASE64` | 分发证书 `.p12` 的 base64（`base64 -i cert.p12 \| pbcopy`） |
| `P12_PASSWORD` | 导出 `.p12` 时设置的密码 |
| `KEYCHAIN_PASSWORD` | runner 临时钥匙串的密码，任意自定字符串 |

缺任意一个，工作流会在第一步就明确报错，不会浪费一次归档。

## Automated review

Opening a pull request triggers automated review bots (Claude and Codex). They
post advisory comments; address or acknowledge their findings before requesting
human review. To temporarily disable them, set the repository variables
`CLAUDE_AUTO_REVIEW` / `CODEX_AUTO_REVIEW` to `false`.
