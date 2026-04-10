# Release And Update Checklist

## 集中配置
- GitHub 仓库、release、appcast、Sparkle 公钥统一来源：
  - `Scripts/release_config.sh`
  - `Sources/CodexBarCore/AppIdentity.swift`
- 不要重新引入硬编码的 `steipete/CodexBar`、旧 appcast URL、旧 bundle/app group/keychain id。

## Sparkle / 应用内更新
- `SUFeedURL` 必须指向 fork 的 `appcast.xml`。
- `SUPublicEDKey` 必须与当前 Sparkle 私钥配对。
- `CodexbarApp.swift` 里保留了 Sparkle 可用性判断；改更新逻辑时优先在现有结构上修，不要绕开。
- 应用内没有 stable/beta 切换；所有用户统一走一个 Sparkle 通道。
- 兼容迁移策略是：
  - 新身份写入 `com.shawnrn.codexbar*`
  - 旧身份 `com.steipete.codexbar*` 仅作读取/迁移 fallback

## GitHub Actions
- `ci.yml`：跑 macOS 基础检查 + l10n drift 检查，并保留 Linux CLI 构建/冒烟测试；macOS job 有显式超时，避免 6 小时后才被 GitHub 强制取消。
- `release-cli.yml`：独立的 Linux CLI 手动发布流程，不参与常规 app CI / release。
- `upstream-sync.yml`：
  - `upstream` 目标为 `steipete/CodexBar`
  - 无冲突时直接 merge 到 `main`，随后由现有 release workflow 按当前版本号自动发 prerelease / release
  - 有冲突时 workflow 失败并在 summary 输出冲突文件
  - `quotio` 只输出审查 summary，不创建 issue，不自动合并，并自动探测默认分支（当前不是 `main`）
- `l10n-sync.yml`：
  - `en.lproj/Localizable.strings` 是唯一源
  - 缺失中文 key 自动补英文 fallback，并带 TODO 注释
- `release-app.yml`：
  - 单一发布通道
  - `main` 上 prerelease 版本自动发 GitHub prerelease
  - 其他版本可手动触发正式发布
  - 不做 notarization / App Store Connect 公证
  - 必须生成并提交 `appcast.xml`，否则 workflow 失败
  - `SPARKLE_PRIVATE_KEY` 是硬依赖；没有它就不允许发出“app 内不可检测”的 release

## 本机打包现实约束
- 仓库路径位于 iCloud Drive（`Mobile Documents/...`）。
- `Scripts/package_app.sh` 采用临时目录 staging 签名，再把产物同步回仓库，以避开 file provider 扩展属性导致的 Sparkle `Updater.app` 签名失败。
- 若有人想删掉 staging，请先实测 Sparkle framework 的 nested app 是否还能稳定通过 `codesign`。

## 交付前最少验证
- `pnpm check`
- 相关最小测试
- `./Scripts/compile_and_run.sh`
- 若改了更新/发布链路，至少手动检查：
  - `CodexBar.app/Contents/Info.plist`
  - `appcast.xml`
  - workflow YAML 中仓库名、branch、secret 名
