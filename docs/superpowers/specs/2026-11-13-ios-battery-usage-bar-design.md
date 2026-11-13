# iOS 电池样式用量条 · 设计文档

- 日期：2026-11-13
- 分支：`feat/ios-battery-usage-bar`（基于 `main` @ `7447bc77c`）
- 状态：待审阅
- 决策来源：用户在方案对比图中选定「方案 B：电池外形 + iOS 电量配色」+「加设置开关，默认关闭」

## 1. 目标

给菜单卡里的用量进度条增加一种可选的 **iOS 电池外观**：描边外壳 + 右侧正极帽 + 内芯填充，填充色按剩余量分档（绿 / 黄 / 红），让用户扫一眼就能判断哪条配额快耗尽。

通过新设置 `usageBarStyle` 切换，**默认 `capsule`（现有胶囊外观）**，老用户外观与 provider 品牌色完全不变。

### 非目标

- 不改菜单栏状态栏图标本体（`IconRenderer` 的品牌图标 / 百分比排版）。**范围追加**：菜单栏的图形用量条（`MenuBarLayoutRenderer` 的 `.progressBar` token）原为非目标，用户在看到设置页截图后指出「菜单栏的没有改」，并选定「彩色电池」，故纳入本次范围，规格见 §4.8。字符条 `.usageBar`（`▮▮▯`）仍不改。
- 不改 Widget 的 `QuotaBar`。
- 不改紧凑账号行的 mini 胶囊条（`MenuCardCompactAccountRow`）。
- 不改进度条承载的数据语义、pace 计算、告警阈值逻辑。

## 2. 硬约束

**单 Canvas 约束（issue #805）**：`UsageProgressBar.body` 的注释（`Sources/CodexBar/Menu/UsageProgressBar.swift:71-74`）明确要求全部绘制留在一个 `Canvas` 内，禁止引入 SwiftUI 的 `.compositingGroup` / `.blendMode` 修饰符——它们会在 macOS 26.x 触发 Metal/RenderBox shader 编译，导致状态栏图标消失。

电池外壳、正极帽、内芯、pace 条纹、两类刻度**全部用 `context.fill` / `context.stroke` 在这同一个 Canvas 内绘制**。现有 `context.blendMode = .destinationOut` 是 Canvas 内部的 Core Graphics 混合模式，不是 SwiftUI 修饰符，可继续使用。

**语义标记必须保留**：pace 配速条纹（含 deficit 红色）、配额告警刻度、工作日边界刻度（`hidden` / `subtle` / `highContrast`）在电池样式下功能不变，只是坐标映射到内芯区域。

**AGENTS.md 约束**：4 空格缩进、120 字符行宽、显式 `self` 不可移除；Swift Testing 用反引号句子名；测试模型名只用已发布或明显虚构的名称。

## 3. 设置定义与管线

新枚举严格镜像 `WorkdayTickAppearance`（`Sources/CodexBar/Settings/SettingsStore.swift:155-171`）的既有模式。

```swift
enum UsageBarStyle: String, CaseIterable, Identifiable {
    case capsule
    case battery

    var id: String { self.rawValue }

    var label: String {
        switch self {
        case .capsule: L("usage_bar_style_capsule")
        case .battery: L("usage_bar_style_battery")
        }
    }
}
```

### 3.1 持久化

| 文件 | 锚点 | 改动 |
|---|---|---|
| `Sources/CodexBar/Settings/SettingsStore.swift` | `:155-171` 之后 | 新增 `UsageBarStyle` 枚举 |
| `Sources/CodexBar/Settings/SettingsStoreState.swift` | `:34` 旁 | `var usageBarStyleRaw: String` |
| `Sources/CodexBar/Settings/SettingsStore.swift` | `:619-620` 旁 | `usageBarStyleRaw: userDefaults.string(forKey: "usageBarStyle") ?? UsageBarStyle.capsule.rawValue,` |
| `Sources/CodexBar/Settings/SettingsStore+Defaults.swift` | `:294-297` 旁 | 类型化访问器，getter 回退 `.capsule`，setter 走 `setDefault(\.usageBarStyleRaw, newValue.rawValue, key: "usageBarStyle")` |

仓库**不存在** `register(defaults:)` / Defaults plist / 静态默认字典（全仓 grep 确认）。上面两处 UserDefaults 读取回退就是唯一的默认值注册点。

### 3.2 菜单观察（必须）

`Sources/CodexBar/Settings/SettingsStore+MenuObservation.swift:30` 旁追加 `_ = self.usageBarStyle`。

原因：`SettingsStore` 是 `@Observable`，`menuObservationToken` 靠逐个读取 getter 在 `withObservationTracking` 中注册依赖（消费点 `Sources/CodexBar/StatusItem/StatusItemController.swift:575`）。**漏掉这一行，切换设置不会触发菜单重建**——这是本改动最容易静默失效的地方。

### 3.3 同步

| 文件 | 锚点 | 改动 |
|---|---|---|
| `Sources/CodexBar/Settings/SettingsStore+Sync.swift` | `:46` | 导出 `usageBarStyle: self.usageBarStyle.rawValue,` |
| `Sources/CodexBar/Settings/SettingsStore+Sync.swift` | `:83-86` | 导入：可选绑定 + `UsageBarStyle(rawValue:)` 校验，无效值静默忽略 |
| `Sources/CodexBarCore/Sync/SyncModels.swift` | `:314` | `public var usageBarStyle: String?` |
| `Sources/CodexBarCore/Sync/SyncModels.swift` | `:348` | init 参数 `usageBarStyle: String? = nil,` |
| `Sources/CodexBarCore/Sync/SyncModels.swift` | `:381` | init 赋值 |

**不需要 bump schema 版本**：`SyncedPreferences` 用合成 Codable，无自定义 `CodingKeys` / `init(from:)`；`CodexBarSyncSchema.currentVersion = 1`（`SyncModels.swift:3-8`）。新增可选 `String?` 向后兼容——旧 payload 缺 key 解码为 `nil`，新 payload 多 key 被旧解码器忽略。`Tests/CodexBarTests/CloudSyncSettingsTests.swift:55-67` 的 legacy 测试已证明该模式。

### 3.4 便携配置校验（两处都要改）

| 文件 | 锚点 | 改动 |
|---|---|---|
| `Sources/CodexBarCore/Config/PreferencesDocument.swift` | `:45` | `stringChoices` 追加 `"usageBarStyle": ["capsule", "battery"],` |
| `Sources/CodexBarCore/Config/PreferencesDocument.swift` | `:116` | 可选键 union 追加 `"usageBarStyle"` |

- `:45` 是允许值白名单。`validate()`（`:140-167`）对不在白名单的 key 直接 `throw Error.invalid`，整份文档拒绝。
- `:52-57` 的 `keys` 自动 union `stringChoices.keys`，所以新 key 自动成为可导出/导入的便携键，无需单独维护列表。
- **`:116` 是关键易漏点**：`usageBarStyle` 是可选 String，值为 nil 时 JSONEncoder 省略该 key；若不加入这个 union，`applying(to:)` 的 CLI 导入合并会丢弃该字段。

`docs/configuration.md:316` 只泛述便携字段、不逐键列举，无需改文档。

### 3.5 设置 UI

| 文件 | 锚点 | 改动 |
|---|---|---|
| `Sources/CodexBar/Settings/PreferencesMenuPicker.swift` | `:103` 旁 | `static let usageBarStyles = UsageBarStyle.allCases` |
| `Sources/CodexBar/Settings/PreferencesMenuPane.swift` | `:42-53` 之后、`:55` 之前 | 在 `section_usage` 内加兄弟 `SettingsMenuPicker` 行 |

新行复用 `SettingsMenuPicker`（`PreferencesMenuPicker.swift:5-21`），`selection: self.$settings.usageBarStyle`，label 用 `SettingsRowLabel(L("usage_bar_style_title"), subtitle: L("usage_bar_style_subtitle"))`，optionLabel `Text(style.label)`。

**不加 `.disabled`**：workday 行依赖 `weeklyProgressWorkDays != nil`，新设置无此依赖。

### 3.6 模型管线（Settings → Input → Model → Row → Bar）

**关键设计决定**：样式是**卡片级单一设置**，因此放在 `UsageMenuCardView.Model` 上，完全镜像既有的 `progressColor`（`MenuCardView.swift:208` 声明、`:1023` 构造、`:657` 注入 row）。**不放进 `Metric`**，也**绝不放进 `CodexBarCore.ProviderDetailSection`**——后者是 Codable 的 provider 数据契约，不应承载 UI 样式。

| 文件 | 锚点 | 改动 |
|---|---|---|
| `Sources/CodexBar/Menu/MenuCardView+ModelInput.swift` | `:50` / `:101` / `:151` | `Input` 字段 + init 参数（默认 `.capsule`）+ 赋值 |
| `Sources/CodexBar/UsageStore/UsageStore+MenuCardModel.swift` | `:179` 旁 | `usageBarStyle: self.settings.usageBarStyle,` |
| `Sources/CodexBar/Menu/MenuCardView.swift` | `:208` 旁 | `Model` 新增 `let usageBarStyle: UsageBarStyle` |
| `Sources/CodexBar/Menu/MenuCardView.swift` | `:1023` | 构造处 `usageBarStyle: input.usageBarStyle,`（紧邻 `progressColor`） |
| `Sources/CodexBar/Menu/MenuCardMetricRow.swift` | `:8` 旁 / `:48` | `MetricRow` 新增注入属性（镜像 `progressColor`）；传给 bar |
| `Sources/CodexBar/Menu/MenuCardView.swift` | `:657` | `MetricRow(... usageBarStyle: self.model.usageBarStyle)` |
| `Sources/CodexBar/Settings/PreferencesProviderDetailView.swift` | `ProviderMetricInlineRow` / `:691` | 同样新增注入属性并传给 bar |

`CreditsBarContent`（`MenuCardView.swift:816`）、`ProviderCostContent`（`MenuCardView+Costs.swift:7`）、`ProviderDetailSectionsContent`（`ProviderDetailSectionsContent.swift:6`）都已有注入式 `progressColor` / `chartColor`，按同样方式并列新增 `usageBarStyle`，由 `self.model.usageBarStyle` 传入（构造点 `MenuCardView.swift:698` 等）。

新设置**不参与 marker 计算**，只透传。`MenuCardView.swift:1509`、`+SessionEquivalent.swift:56`、`Metric` 的 workday 相关字段与逻辑全部不动。

## 4. 渲染规格

### 4.1 新增参数

`UsageProgressBar` 增加两个存储属性 + init 参数（均带默认值，保证现有调用点与测试零改动）：

```swift
let usageBarStyle: UsageBarStyle   // init 默认 .capsule
let showsUsed: Bool                // init 默认 false
```

`showsUsed` 用于把显示方向换算回「剩余量」再决定颜色。现有组件只拿到 `accessibilityLabel`，拿不到方向，必须显式传入。

### 4.2 高度

```swift
.frame(height: self.usageBarStyle == .battery ? 10 : 6)
```

胶囊保持 6pt；电池 10pt（外壳需要描边 + 内芯边距，6pt 画不出可辨识的电池）。启用后每个 metric 行 +4pt。

### 4.3 电池几何（H = 10，W = 可用宽度）

全部为可单测的 `nonisolated static` 纯函数：

```
nubWidth   = 2.5
nubGap     = 1
nubHeight  = H * 0.4                     // 4
bodyWidth  = W - nubWidth - nubGap
bodyRect   = CGRect(x: 0.5, y: 0.5, width: bodyWidth - 1, height: H - 1)
bodyRadius = 3
innerInset = 2
innerRect  = CGRect(x: innerInset, y: innerInset,
                    width: bodyWidth - 2 * innerInset, height: H - 2 * innerInset)
innerRadius = 1.5
nubRect    = CGRect(x: bodyWidth + nubGap, y: (H - nubHeight) / 2,
                    width: nubWidth, height: nubHeight)   // radius 1
fillWidth  = innerRect.width * renderedFillPercent(clamped) / 100
```

`bodyRect` 内缩 0.5 是为了让 1pt 描边完整落在 Canvas  bounds 内（Canvas 的 stroke 以路径为中心线）。

绘制顺序：内芯轨道 → 内芯填充 → 刻度 → pace 条纹 → 外壳描边 → 正极帽。外壳最后画，保证描边不被填充覆盖。

### 4.4 坐标映射

现有 marker / pace 静态助手（`warningMarkerRect(x:size:scale:)`、`workdayMarkerRect`、`paceStripePaths(size:scale:)`）**签名不变**，改为传入 `innerRect.size`，再把结果平移 `innerRect.origin`：

- marker：`x = innerRect.minX + innerRect.width * marker.percent / 100`
- pace：`paceWidth` 基于 `innerRect.width`，最终 shift 额外加 `innerRect.minX`

这样复用全部既有几何逻辑与测试，语义零变化。

**实现细节**：`GraphicsContext` 是值类型。电池分支用 `var content = context` 复制一份并 `clip` 到内芯圆角矩形，track/fill/刻度/pace 全画在副本里，外壳与正极帽画在原 `context` 上。这样 pace 条纹的垂直溢出被限制在内芯内（否则会在外壳上下画出绿/红线），且不需要 `drawLayer` 的离屏透明层。胶囊分支保持原来的整矩形 clip，逐像素不变。

### 4.5 配色

```
remaining = showsUsed ? 100 - clamped : clamped

remaining >= 50  → Color(nsColor: .systemGreen)   // #34C759
20 <= remaining < 50 → Color(nsColor: .systemYellow)  // #FFCC00
remaining < 20   → Color(nsColor: .systemRed)     // #FF3B30
```

用 iOS 系统色而非硬编码 hex，自动适配明暗外观。

**高亮态必须保持对比度**：填充色继续走 `MenuHighlightStyle.progressTint(isHighlighted, fallback: severityColor)`——菜单行 hover/选中时仍为 `selectionText`（白），与现有胶囊行为一致。

外壳与内芯轨道色：

```
shellColor = isHighlighted ? selectionText.opacity(0.55) : .primary.opacity(0.34)
innerTrack = isHighlighted ? selectionText.opacity(0.18) : .primary.opacity(0.07)
```

**电池样式覆盖 provider 品牌色**（这是方案 B 的核心）。因为默认 `capsule`，`ProviderAccentPalette` / `progressColor(for:)` 与全部现有配色测试不受影响。

### 4.6 各调用点的方向与样式

| 调用点 | `showsUsed` | 样式来源 |
|---|---|---|
| `MenuCardMetricRow.swift:40` | `metric.percentStyle == .used` | 注入属性 ← `model.usageBarStyle` |
| `MenuCardView.swift:825`（Credits） | `false`（Credits remaining） | 注入属性 ← `model.usageBarStyle` |
| `MenuCardView+Costs.swift:39` | `section.percentStyle == .used` | 注入属性 ← `model.usageBarStyle` |
| `ProviderDetailSectionsContent.swift:74` | `true`（`progress.usedPercent`） | 注入属性 ← `model.usageBarStyle` |
| `PreferencesProviderDetailView.swift:683` | `metric.percentStyle == .used` | 注入属性 ← `model.usageBarStyle` |
| `PreferencesProviderDetailView.swift:782` | `true`（`percentUsed` / "Usage used"） | 注入属性 ← settings |
| `StatusItemController+UserPlugins.swift:366` | `self.showUsed` | 注入到 `UserPluginMenuCardView` |

插件条位于 `struct UserPluginMenuCardView: View`（注入式属性 `tint` / `paceVisible` / `showUsed`），按同样方式新增 `usageBarStyle` 属性并在其构造点传入。**实现期更正**：`UserPluginMenuCardView` 已有 `showUsed`（来自 `settings.usageBarsShowUsed`，并传给 `UserPluginQuotaPresentation.make`），因此方向是真实元数据，不需要「按剩余处理」的假设。同一视图内的 `ProviderDetailSectionsContent` 也一并注入样式。

**范围决定**：电池样式应用到全部 7 个生产调用点，保证视觉语言一致（避免「一半电池一半胶囊」）。两个测试调用点（`ProviderPaletteRenderingTests.swift:81`、`ProviderAccentColorScreenshotRenderTests.swift:85`）不传参数，走默认 `.capsule`，**不改**。

### 4.7 高度指纹（必须，否则缓存失效）

`Sources/CodexBar/Menu/MenuCardHeightFingerprint.swift` 的指纹只含文本内容，不含条高度。电池把 6pt 变 10pt 后指纹不变 → 菜单高度缓存返回旧值 → 布局错位。

因为样式是**卡片级单一值**（§3.6），只需在顶层 `heightFingerprint(section:additional:)` 的 join 数组（`:9-39`）里加**一行**：

```swift
"usageBarStyle=\(self.usageBarStyle.rawValue)",
```

这一行即覆盖该卡片内所有 bar（metric / credits / cost / provider detail）。**不需要**改 `Metric.heightFingerprint`（`:114`）、`ProviderCostSection.heightFingerprint`（`:141`）或 provider detail row 指纹（`:52-57`）——尤其不能把 UI 样式写进 `CodexBarCore.ProviderDetailSection` 的 Codable 数据契约。

### 4.8 菜单栏图形用量条（追加范围）

**Surface**：`MenuBarLayoutToken.progressBar(window:)` 渲染的图形条（`progressBarToken` → `progressBarImage`），以 `NSTextAttachment` 嵌进状态栏标题。字符条 `.usageBar` 是纯文本，保持不变。

**彩色而非模板**：图形条附件本来就不设 `isTemplate`（AppKit 不会给附件做模板着色），tint 取 `style.foregroundColor`，因此电量分档色能直接显示在菜单栏。这与 `paceIndicator(color:style:isMonochrome:)` 的彩色附件先例一致。用户明确选择「彩色电池」。

**几何必须按高度比例缩放**：菜单栏条高只有 `max(5, capHeight * 0.55)` ≈ 5–7pt、宽 32/36/44pt（`progressBarSize`）。菜单卡那套固定常量（内缩 2pt、正极帽 2.5pt、高 10pt）在这个尺寸下会把内芯压没。故菜单栏用独立的比例几何：

| 量 | 公式 |
|---|---|
| 正极帽宽 | `max(1.5, round(H * 0.25))` |
| 帽间距 | `1` |
| 外壳 rect | `x=0.5, y=0.5, w=bodyWidth-1, h=H-1`（描边 1pt 留在画布内） |
| 内缩 | `max(1, round(H * 0.18))` |
| 内芯 rect | 外壳再内缩上述值 |
| 正极帽高 | `max(2, round(H * 0.4))`，垂直居中 |
| 外壳圆角 | `min(2, H * 0.3)`；内芯圆角 `max(0.5, H * 0.15)` |

**语义复用**：填充宽度走 `UsageProgressBar.renderedFillPercent`（<0.5% 空、≥99.5% 满），分档走 `UsageProgressBar.batteryLevel` / 阈值 ≥50 绿 / ≥20 黄 / 其余红，保证两个 surface 语义一致。`remainingPercent` 始终取窗口的剩余量，与 `showUsed` 无关——即使用户选择「显示已用」，颜色仍按剩余量分档（和菜单卡一致）。

**高对比度退回单色**：`highContrast` 是菜单栏既有的「去色」开关——`TokenStyle.foregroundColor` 在该模式下返回 `labelColor`（`:1220`），pace 指示器也据此走 `isMonochrome`（`:827-836`）。电池分档色必须尊重它：`progressBarImage` 增加 `highContrast` 参数，为真时填充用 `tint` 而非分档色，否则依赖该设置的用户会失去单色高对比效果。`isStale` 仍按 0.55 alpha 整体压暗，与胶囊条一致。

**缓存键必须同步**：标题缓存的键是独立结构 `MenuBarLayoutRenderKey`，不是直接用 options。只给 `MenuBarLayoutRenderOptions` 加字段不会让缓存失效，必须同时给键加 `usageBarStyle` 并在 `render` 的键构造处传入，否则切样式后菜单栏仍显示旧条。

**注入点**：`StatusItemController+MenuBarLayout.swift` 的 `menuBarLayoutRenderOptions(forInstanceID:button:now:forceStackedStyle:)` 与 `MenuBarLayoutEditor.swift` 的设置实时预览，各加一行 `usageBarStyle: self.settings.usageBarStyle`。`MenuBarLayoutNativeProof` 的固定 layout 只含 percent / pace / runsOut，没有图形条，不需要注入。设置观察无需新增：`SettingsStore+MenuObservation.swift:31` 已有 `usageBarStyle`。

**文件落点（lint 约束）**：电池几何 / 分档 / 绘制放在新文件 `Sources/CodexBar/Menu/MenuBarBatteryMeter.swift`（`MenuBarBatteryMeter` + `MenuBarMeterSpec`）。原因有二：`MenuBarLayoutRenderer.swift` 加入电池代码后超过 `file_length` 的 1500 行上限；`progressBarImage` 展平参数会超过 `function_parameter_count` 的 5 个上限。渲染器只保留一个接收 `MenuBarMeterSpec` 的分发入口（电池 → `MenuBarBatteryMeter.image`，胶囊 → 原 5 段绘制）。

**文案**：`usage_bar_style_subtitle` 原写「菜单中」，追加范围后需覆盖菜单与菜单栏，23 个 locale 同步更新。（二次追加范围 §4.9 又将其收回为仅「菜单中」，菜单栏改由独立 key 承载。）

### 4.9 菜单栏独立样式开关（二次追加范围）

**决策来源**：用户看到设置→菜单栏的布局编辑器后指出「菜单里不支持选择呢」——编辑器只摆放 token，不提供样式选择；全局 `usageBarStyle` 的选择器在「菜单」分页。经 AskUserQuestion 选定「菜单栏独立开关」，并明确「确认，按默认胶囊实现」。

**设计**：新增独立设置 `menuBarUsageBarStyle`（复用 `UsageBarStyle` 枚举，**默认 `.capsule`**），只驱动菜单栏状态项 + 菜单栏布局编辑器的实时预览。全局 `usageBarStyle` 收回为仅驱动菜单卡 + 设置预览。两者完全解耦：可菜单栏电池 / 菜单卡胶囊，或反之。

**设置链路**（镜像 §3，全部新增并列字段，不改既有 `usageBarStyle`）：

| 文件 | 改动 |
|---|---|
| `SettingsStoreState.swift` | `var menuBarUsageBarStyleRaw: String` |
| `SettingsStore+Defaults.swift` | 类型化访问器 `menuBarUsageBarStyle`，getter 回退 `.capsule`，key `"menuBarUsageBarStyle"` |
| `SettingsStore.swift` | load `menuBarUsageBarStyleRaw: userDefaults.string(forKey: "menuBarUsageBarStyle") ?? .capsule.rawValue` |
| `SettingsStore+MenuObservation.swift` | `_ = self.menuBarUsageBarStyle` |
| `SettingsStore+Sync.swift` | 导出 + 导入（可选绑定 + rawValue 校验，无效静默忽略） |
| `CodexBarCore/Sync/SyncModels.swift` | `public var menuBarUsageBarStyle: String?` + init 参数 + 赋值（合成 Codable，旧 payload 解码 nil，无需 bump schema） |
| `CodexBarCore/Config/PreferencesDocument.swift` | `stringChoices` 追加 `"menuBarUsageBarStyle": ["capsule","battery"]`；`applying(to:)` union 追加该 key |

**注入点改向**（渲染器/几何/缓存键零改动，只换源设置）：
- `StatusItemController+MenuBarLayout.swift:205`：`usageBarStyle: self.settings.menuBarUsageBarStyle`
- `MenuBarLayoutEditor.swift:969`（实时预览）：同上
- `MenuBarLayoutRenderOptions.usageBarStyle` 字段名不变；`MenuBarLayoutRenderKey` 已含该字段，缓存自动失效。

**设置 UI**：`PreferencesMenuBarPane.swift` 在 `menuBarIconStyle` 选择器后新增兄弟 `SettingsMenuPicker`，`selection: $settings.menuBarUsageBarStyle`，options 复用 `MenuSettingsMenuOptions.usageBarStyles`，label 用 `menu_bar_usage_bar_style_title` / `_subtitle`，`.disabled(!layoutEditorEnabled(for: menuBarIconStyle))`（与同 Section 兄弟一致，仅「图标+百分比」样式可编辑布局）。`PreferencesMenuPane.swift` 的全局选择器不变。

**文案**：新增 2 个 key（`menu_bar_usage_bar_style_title` / `menu_bar_usage_bar_style_subtitle`）×23 locale 真实翻译；`usage_bar_style_subtitle` ×23 收回为仅「菜单中」（撤销 §4.8 的「菜单与菜单栏」覆盖）。capsule/battery 选项标签两个选择器共用。

**测试**（TDD，先 RED 后 GREEN）：
- `SettingsStoreAdditionalTests`：默认 capsule、与全局独立持久化、重载保持、未知值回退。
- `MenuBarPaceColorSettingsTests`：`menuBarUsageBarStyle` 单独触发 menuObservationToken（隔离观察，不与全局合并断言）。
- `CloudSyncSettingsTests`：独立 apply、legacy 缺 key 解码 nil、未知 raw 忽略。
- `PreferencesDocumentTests`：app/CLI 转移、`"neon"` 拒绝。
- `UserFacingLocalizationCoverageTests`：2 新 key ×23 非空。

**落点更正**：观察测试原拟加进 `SettingsStoreTests.swift:1536`，但该文件已贴 `file_length` 1500 上限，+1 行即 1501 触发 `swiftlint --strict`。改为落到有余量且主题契合的 `MenuBarPaceColorSettingsTests`（同步 `withObservationTracking` + `InMemoryUserDefaults` 套路），`SettingsStoreTests` 还原为 1500 行。

## 5. 本地化

新增 4 个 key，加到**全部 23 个** `Sources/CodexBar/Resources/<locale>.lproj/Localizable.strings`：

```
usage_bar_style_title
usage_bar_style_subtitle
usage_bar_style_capsule
usage_bar_style_battery
```

格式 `"key" = "value";`，建议紧邻 workday 块之后（en 在 `:647-651`，zh-Hans 在 `:1059-1063`）。

23 个 locale：ar, ca, de, en, es, fa, fr, gl, id, it, ja, ko, nl, pl, pt-BR, ru, sv, th, tr, uk, vi, zh-Hans, zh-Hant。共 92 条新字符串，**全部需真实翻译**，不得用英文占位（仓库现有 workday key 在 23 个 locale 均已翻译，须保持一致）。

英文文案：
- title: `Usage bar style`
- subtitle: `Choose how usage bars render in the menu.`
- capsule: `Capsule`
- battery: `Battery`

简体中文：
- title: `用量条样式`
- subtitle: `选择菜单中用量条的显示样式。`
- capsule: `胶囊`
- battery: `电池`

`L()` 定义在 `Sources/CodexBar/Localization.swift:185`，经 `localizedBundle()` 解析 `.lproj`，回退 en。

## 6. 测试计划

全部用 Swift Testing、反引号句子名，走纯数据/几何 seam，不构造 live `NSStatusBar` / `NSMenu`（AGENTS.md：macOS CI 对 headless AppKit 菜单测试脆弱）。

### 新增

| 测试文件 | 覆盖 |
|---|---|
| `UsageBarBatteryGeometryTests.swift` | body/inner/nub rect 在多种宽度下的值；inner 宽度 > 0；nub 不越界；fillWidth 随 percent 单调；0% → 0、100% → 满内芯；`renderedFillPercent` 的 <0.5% 空 / ≥99.5% 满边界在电池下同样成立 |
| `UsageBarBatteryColorTests.swift` | remaining 100/50/49.9/20/19.9/0 → 绿/绿/黄/黄/红/红；`showsUsed` 翻转（used 80 → remaining 20 → 黄；used 95 → remaining 5 → 红）；高亮态回退 selectionText |
| `MenuBarBatteryRenderTests.swift`（追加范围，XCTest） | 菜单栏比例几何在 5/6/7pt 高度下内芯不塌；fillWidth 边界；分档阈值；电池位图像素为分档色、未填充尾部透明；胶囊 5 段不变；options 默认 `.capsule`；同 renderer 切样式后标题位图不同（缓存键生效）；标题内电池按剩余量上色；highContrast 下填充单色；字符条 `.usageBar` 不受样式影响 |

### 扩展既有

| 文件 | 锚点 | 新增断言 |
|---|---|---|
| `SettingsStoreAdditionalTests.swift` | 末尾 extension | 默认 `.capsule`；写 `.battery` 后 UserDefaults rawValue 正确；重载保持；写 `"unknown"` 回退 `.capsule` |
| `SettingsStoreTests.swift` | `:1535` | `expectObservation { store.usageBarStyle = .battery }` 触发观察 |
| `CloudSyncSettingsTests.swift` | `:39,48` | sync round-trip |
| `CloudSyncSettingsTests.swift` | `:55-67` | legacy payload 缺 `usageBarStyle` key → 解码 nil |
| `PreferencesPaneSmokeTests.swift` | `:106` / `:117,124` | `usageBarStyles == UsageBarStyle.allCases`；持久化 |
| `UserFacingLocalizationCoverageTests.swift` | 末尾 | 4 个新 key 在 23 个 catalog 均非空 |
| `MenuCardHeightFingerprintTests.swift` | — | 改 `usageBarStyle` 会改变卡片级 `heightFingerprint` |
| `PreferencesDocumentTests.swift` | — | 接受 `capsule`/`battery`，拒绝未知值；`applying(to:)` 保留该字段 |

**不会破坏的测试**：全仓无「枚举所有设置键」或「断言设置总数」的测试（已 grep 确认）。`LocalizationLanguageCatalogTests.swift:557` 的 count 断言针对语言而非设置键。两个配色快照测试走默认 `.capsule`，不受影响。

**实现期更正（测试落点）**：原计划把设置持久化测试加进 `SettingsStoreCoverageTests`、把 catalog 测试加进 `LocalizationLanguageCatalogTests`。这两个 struct 在 HEAD 已贴近 `type_body_length` 的 800 行警告阈值，加入新测试后分别涨到 816 / 821 行；`Scripts/lint.sh` 用 `swiftlint --strict`，警告即错误，`make check` 会失败。因此改为落到有余量的同族 suite：设置测试进 `SettingsStoreAdditionalTests`（复用共享 `testSettingsStore` + `InMemoryUserDefaults`，比原方案的 50 行私有 helper 更省且不碰真实 defaults 域），catalog 测试进 `UserFacingLocalizationCoverageTests`。两个原文件已还原为与 HEAD 逐字节一致。断言内容与测试名不变。

## 7. 验证

```bash
swift build
make test-fast FILTER='UsageBarBattery'
make test-fast FILTER='SettingsStore'
make test-fast FILTER='CloudSyncSettings'
make test-fast FILTER='UserFacingLocalizationCoverage'
make test-fast FILTER='MenuCardHeightFingerprint'
make test-fast FILTER='PreferencesDocument'
swiftformat Sources Tests        # 仅触碰文件
swiftlint --strict
make check                       # 交付前一次
```

全量套件交 PR CI 或后台跑（`./Scripts/test.sh --direct-workers 8`），不在前台阻塞。

**UI 验证（AGENTS.md 要求 bundle 级）**：`./Scripts/compile_and_run.sh` → 在设置里切到 Battery → 截图菜单确认电池外形/配色/刻度 → **重点确认状态栏图标仍可见**（issue #805 回归守卫）→ 切回 Capsule 确认外观复原。

禁止任何会弹 macOS Keychain 提示的验证；不跑真实 provider 探针。

### 实现期验证记录

**focused 测试**：`swift test --filter 'UsageBarBattery|SettingsStore|CloudSyncSettings|PreferencesPaneSmoke|UserFacingLocalizationCoverage|MenuCardHeightFingerprint|PreferencesDocument|ProviderPaletteRendering'` → 273 tests / 18 suites 全绿。`ProviderPaletteRenderingTests` 是「胶囊渲染未变」的回归守卫。

**make check 的环境阻塞（非本改动引入）**：`check_swift_test_sharding` → `Scripts/test_swift_test_sharding.sh` 要求 `python3` 提供 `os.waitid` + `WNOWAIT`（`Scripts/ci_swift_test_by_suite.py:443`）。开发机只有 pyenv 3.12.7，不支持，故 `make check` 在该步退出 2。失败点之前的全部检查通过；失败点之后的步骤已逐条直接补跑并全绿：oxfmt / oxlint / tsc、repo 级 `swiftlint --strict --no-cache`（exit 0）、`swiftformat Sources Tests --lint`（0/3223）、ci_path_gate、linux CLI linkage 与 codex cost smoke、ci_build_cache、homebrew_tap_wait、repository_size、shell_scripts、documentation_links、llms_index、site_locales。未擅自安装系统 Python。

**UI 取证改用离屏渲染**：`compile_and_run.sh` 默认 adhoc 签名，脚本自身提示会弹 Keychain 权限框，与上面「禁止 Keychain 提示」冲突；且重启会打断开发机正在用的实例。改为沿用仓库既有的 `ProviderAccentColorScreenshotRenderTests` 套路，新增默认跳过的 opt-in 渲染工具 `UsageBarBatteryScreenshotRenderTests`：

```bash
CODEXBAR_BATTERY_SCREENSHOT_DIR=~/Downloads \
  swift test --filter UsageBarBatteryScreenshotRenderTests
```

用隔离 settings store 离屏渲染 capsule / battery 对照（remaining 与 used 两种方向 + 高亮行），不读真实配置、不写 App Group、不碰 Keychain。issue #805 的机制是 SwiftUI `.compositingGroup` / `.blendMode` 触发 RenderBox shader 编译；本改动未新增任何 SwiftUI 合成修饰符，仍是单 Canvas，仅在值拷贝的 `GraphicsContext` 上加 clip，故不引入该机制。

**bundle 级实测（用户明确授权后）**：`./Scripts/compile_and_run.sh --debug-lldb` exit 0（launch smoke OK）。**偏好域更正**：PlistBuddy 实测 dev bundle 的 `CFBundleIdentifier` 为 `com.steipete.codexbar.debug`，读自己的 `.debug` 域；早期记录「与正式版共用域、写 `.debug` 无效」有误。曾误把 `usageBarStyle=battery` 写进正式版域 `com.steipete.codexbar`，dev 实例读不到而按默认 `.capsule` 渲染（菜单栏一度显示 5 段胶囊，被误判为「菜单栏没改」）；已删除该误写（正式版域恢复无此 key），改在 `.debug` 域写 `battery` 并重启 dev 实例后生效。外部 `defaults write` 不触发运行中实例重绘，需重启加载。

**菜单栏电池 live 取证**：重启后 `screencapture -x -R 1650,0,320,30` 截状态项，双行 `5h / W` 的图形条由 5 段胶囊变为连续电池填充并按剩余量上色（session 剩余低→黄、weekly 剩余高→绿），6x 放大确认填充比例；状态项完整可见，**issue #805 回归守卫通过**。离屏对照图 `menubar-usage-bar-{capsule,battery,battery-high-contrast}.png` 另行确认外壳+正极帽几何与高对比单色。打开菜单的自动化在本机受阻（menu-bar-only app 无可见窗口、快捷键菜单离屏），属环境既有问题，非本改动回归。dev 实例保持 `.debug` 域 battery 运行供人工自查。

**菜单栏独立开关 live 解耦取证（二次追加）**：重建 dev bundle（`compile_and_run.sh --debug-lldb` exit 0，新二进制含 `menuBarUsageBarStyle` 符号）后，在 `.debug` 域做两态对照，`screencapture -x -R 1640,0,200,30` + 6x 放大：
- 态 A `menuBarUsageBarStyle=battery` + `usageBarStyle=capsule` → 状态项为**连续电池填充**（5h 剩余 15%→红小填充、W 剩余 59%→绿连续条），证明菜单栏跟随独立开关而非全局。
- 态 B `menuBarUsageBarStyle=capsule` + `usageBarStyle=battery` → 状态项为**5 段胶囊**（5h 1/5 亮、W 3/5 亮），证明全局 battery 不影响菜单栏。

两态互换即证菜单栏仅由 `menuBarUsageBarStyle` 驱动，与 `usageBarStyle` 完全解耦。菜单卡侧仍走 `usageBarStyle`（代码路径未改，电池渲染由既有测试覆盖）；本机打开菜单卡的自动化受阻（menu-bar-only 无可见窗口），属环境既有问题。取证后 dev 实例恢复 `.debug` 双 battery 供人工自查。对照图 `/tmp/codexbar_proof/menubar_{A,B,final}.png`。

## 8. 风险

| 风险 | 缓解 |
|---|---|
| issue #805 图标消失 | 全部绘制留在单 Canvas；不引入 SwiftUI 合成修饰符；UI 验证显式检查图标可见 |
| 菜单高度缓存失效 | §4.7 卡片级指纹加一行样式字段 + 专项测试 |
| 切换设置菜单不重绘 | §3.2 观察 token 加一行 + `expectObservation` 测试 |
| CLI 导入丢字段 | §3.4 `:116` union 追加 + `PreferencesDocumentTests` 断言 |
| 92 条翻译质量 | 逐 locale 真实翻译；catalog 测试保证非空 |
| 电池在窄宽度下退化 | 几何测试覆盖窄宽度；`bodyWidth` 需保证 inner 宽度 > 0，必要时设最小宽度 |

## 9. 待审阅确认项

1. **范围**：电池样式应用到全部 7 个生产调用点（含 Credits / 成本 / provider 详情 / 插件 / 设置预览），而非仅截图里的 metric 行。理由是视觉语言一致。因为样式放在卡片级 Model 上，缩小范围并不能省掉设置链路或指纹改动，只能少改几个注入点。
2. **配色阈值**：≥50 绿 / 20–49 黄 / <20 红。iOS 原生黄色其实表示「低电量模式」而非固定档位，这里是三档语义的合理改编。
3. **高度 10pt**：每行 +4pt，4 行菜单共 +16pt。若嫌高可降到 8pt，但外壳描边 + 内芯边距会更局促。
4. **插件条方向**：~~无方向元数据，按「剩余」处理~~ —— 实现期核实 `UserPluginMenuCardView.showUsed` 已存在，直接用真实方向，无需假设。