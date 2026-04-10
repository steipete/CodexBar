# 仓库指南

## 项目结构与模块
- `Sources/CodexBar`：Swift 6 菜单栏应用（用量/配额探测、图标渲染、设置界面）。改动要尽量小，优先复用现有辅助方法。
- `Sources/CodexBarCore`：共享核心逻辑（Provider 探测、缓存、日志、Sparkle/更新链路辅助、身份迁移）。涉及 bundle id、app group、keychain、更新源时优先检查这里。
- `Tests/CodexBarTests`：XCTest 覆盖用量解析、状态探测、图标模式等；新增逻辑需补充聚焦测试。
- `Scripts`：构建/打包辅助脚本（`package_app.sh`、`sign-and-notarize.sh`、`make_appcast.sh`、`build_icon.sh`、`compile_and_run.sh`、`release_config.sh`、`sync_localizable.py`）。
- `.github/workflows`：macOS CI、upstream 同步、l10n 同步、自动 release。若改动发版/更新链路，必须同步检查 workflow。
- `.agents`：仓库内代理辅助说明与检查清单；变更工作流或发布链路时要同步更新。
- `docs`：发版说明与流程（`docs/RELEASING.md`、截图等）。根目录 zip/appcast 为构建产物，除发版外不要手改。

## 构建、测试、运行
- 开发闭环：`./Scripts/compile_and_run.sh` 会杀掉旧进程、执行 `swift build` + `swift test`、打包、重启 `CodexBar.app` 并确认进程存活。
- 快速构建/测试：`swift build`（debug）或 `swift build -c release`；`swift test` 执行全量 XCTest。
- 本地打包：`./Scripts/package_app.sh` 生成最新 `CodexBar.app`，然后重启：
  `pkill -x CodexBar || pkill -f CodexBar.app || true; cd '/Users/shawnrain/Library/Mobile Documents/com~apple~CloudDocs/Shawn Rain/Vibe-Coding/CodexBar' && open -n '/Users/shawnrain/Library/Mobile Documents/com~apple~CloudDocs/Shawn Rain/Vibe-Coding/CodexBar/CodexBar.app'`
- 发版流程：`./Scripts/sign-and-notarize.sh`（arm64 notarized zip）+ `./Scripts/make_appcast.sh <zip> <feed-url>`；校验步骤见 `docs/RELEASING.md`。
- 更新/发布配置集中在 `Scripts/release_config.sh` 与 `Sources/CodexBarCore/AppIdentity.swift`；不要再把 `steipete/CodexBar`、旧 appcast URL、旧 bundle/app group/keychain id 重新写回散落脚本或 UI。

## 代码风格与命名
- 强制 SwiftFormat/SwiftLint：运行 `swiftformat Sources Tests` 与 `swiftlint --strict`。4 空格缩进，120 列限制，保留显式 `self`。
- 倾向小型、强类型的 struct/enum；保持现有 `MARK` 组织；命名语义化并与现有提交风格一致。

## 测试规范
- 在 `Tests/CodexBarTests/*Tests.swift` 下新增/扩展 XCTest（`FeatureNameTests`，方法形如 `test_caseDescription`）。
- 交付前必须运行 `swift test`（或 `./Scripts/compile_and_run.sh`），并为新增解析/格式化场景补充夹具。
- 任意代码改动后需运行 `pnpm check` 并修复全部格式/静态检查问题。
- macOS CI 对 headless AppKit 状态栏/菜单测试较脆弱；除非要验证 AppKit 接线本身，否则优先覆盖稳定的状态/模型层（如 `MenuDescriptor`、`ProvidersPane`、`CodexAccountsSectionState`），避免强依赖真实 `NSStatusBar` / `NSMenu` 生命周期。

## 提交与 PR 规范
- 提交信息使用简短祈使句（例如：“Improve usage probe”“Fix icon dimming”），每次提交聚焦单一主题。
- PR/补丁应包含：变更摘要、执行命令、UI 变更截图/GIF、相关 issue 或参考链接。

## 代理备注
- 使用仓库内既有脚本与 SwiftPM；未确认前不要新增依赖或工具链。
- 验证时始终基于最新构建包；用上面的 `pkill+open` 重启，避免跑到旧二进制。
- 任何影响应用行为的改动后，都要先 `Scripts/package_app.sh` 再重启应用进行验证。
- 若编辑了代码，交付前必须跑 `./Scripts/compile_and_run.sh`。
- 按用户要求：每次编辑（代码或文档）后都执行 `./Scripts/compile_and_run.sh`，确保当前运行版本同步更新。
- 若变更发布、Sparkle、bundle 标识、本地化、GitHub Actions，也要同步更新 `AGENTS.md` 和 `.agents` 下对应说明，避免说明与现状脱节。
- 发版脚本必须前台运行，禁止后台执行。
- 若缺少发版密钥，从 `~/.profile` 查找（Sparkle + App Store Connect）。
- 优先现代 SwiftUI/Observation：使用 `@Observable` + `@State` + `@Bindable`；避免 `ObservableObject`、`@ObservedObject`、`@StateObject`。
- 重构时优先 macOS 15+ API（Observation、新显示链路 API、新菜单样式等），避免继续扩散旧/弃用 API。
- 提供商数据必须隔离：展示某提供商（如 Claude/Codex）信息时，禁止混入其他提供商的身份或套餐字段。
- Claude CLI 状态行是用户可定制文本，禁止依赖其做用量解析。
- Cookie 导入默认优先 Chrome-only，减少其他浏览器权限弹窗；仅在需要时开放浏览器列表覆盖。

### 签名与打包（本机约定）
- 先检查可用签名身份：`security find-identity -v -p codesigning`（沙箱环境建议提权执行）。
- 仅有 CA 证书（如 `Developer ID Certification Authority`）不等于可用签名身份。
- 本机默认优先签名身份：`Apple Development: shawnrain@foxmail.com (ZQG28N5AK8)`；仅在存在有效 `Developer ID Application` 时再切换。
- 仓库位于 iCloud Drive（`Mobile Documents/...`）路径下；`Scripts/package_app.sh` 已改为在临时目录 staging 签名，再回写 `CodexBar.app`，避免 Sparkle `Updater.app` 因扩展属性导致 `codesign` 失败。不要移除这层 staging。
- `Scripts/package_app.sh` 使用 identity 签名时会带 `--timestamp`；若时间戳服务不可用：
  1. `CODEXBAR_SIGNING=adhoc ./Scripts/package_app.sh release`
  2. `codesign --force --deep --options runtime --sign 'Apple Development: shawnrain@foxmail.com (ZQG28N5AK8)' '/Users/shawnrain/Library/Mobile Documents/com~apple~CloudDocs/Shawn Rain/Vibe-Coding/CodexBar/CodexBar.app'`
- 安装到系统 Applications：
  `ditto '/Users/shawnrain/Library/Mobile Documents/com~apple~CloudDocs/Shawn Rain/Vibe-Coding/CodexBar/CodexBar.app' /Applications/CodexBar.app`

### 更新与发布链路（当前）
- fork 是唯一 source of truth：`ShawnRn/CodexBar`、`https://raw.githubusercontent.com/ShawnRn/CodexBar/main/appcast.xml`。
- Sparkle 公钥、GitHub 仓库地址、发布下载地址统一从集中配置读取；改动时同时检查脚本、Info.plist 注入和 About/Preferences 链接。
- 当前工作流：
  - `ci.yml`：macOS 基础校验 + l10n drift 检查，并保留 Linux CLI 构建/冒烟测试；macOS job 设有显式超时，避免 GitHub 6 小时后才强制取消。
  - `release-cli.yml`：独立的 Linux CLI 手动发布流程；不参与常规 app CI / release。
  - `upstream-sync.yml`：定时/手动同步 `steipete/CodexBar`；无冲突时直接 merge 到 `main` 并触发后续 CI / prerelease，冲突时 workflow 失败并输出冲突文件；`quotio` 仅输出 summary 供审查，不创建 issue，并自动探测默认分支。
  - `l10n-sync.yml`：从 `en.lproj/Localizable.strings` 同步 `zh-Hans`。
  - `release-app.yml`：单一发布通道；`main` 上 prerelease 版本会自动发 prerelease，其他版本可手动触发正式发布；必须同步更新 `appcast.xml`，否则 workflow 直接失败，避免发出 app 内不可检测的“假成功” release。
- `SPARKLE_PRIVATE_KEY` 是 release-app 的硬依赖；缺少该 secret 时禁止发布成功，因为 Sparkle 客户端无法仅靠 GitHub Release 检测更新。
- 应用内不再暴露 stable/beta 切换；`SUPublicEDKey`、`SUFeedURL`、GitHub release 链接若不一致，会直接影响“检查更新”。

### 本地环境已知事项
- 当前环境可能缺少 `pnpm`（表现为 `pnpm: command not found`）；若遇到该问题，需先安装/配置后再执行 `pnpm check`。

### 中文文案术语约定（当前）
- `Credits` 统一翻译为“配额”。
- `Buy Credits` 统一翻译为“购买配额”。
- `Pace` 在菜单栏显示模式中统一翻译为“消耗速率”。
