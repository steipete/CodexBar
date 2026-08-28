---
summary: "为 CodexBar 增加非破坏性的全局低功耗后台刷新策略。"
read_when:
  - 实现或审阅全局低功耗模式
  - 修改自动刷新、本地成本扫描、存储扫描或 OpenAI Web 后台刷新
---

# CodexBar 全局低功耗模式设计

**状态：** 已批准（2026-07-30）

**日期：** 2026-07-30

**关联问题：** [#2508](https://github.com/steipete/CodexBar/issues/2508)

## 决策摘要

新增一个默认关闭的全局 **Low Power Mode（低功耗模式）**。开启后，CodexBar 的自动供应商刷新、
本地 Token/成本扫描和供应商存储扫描都不得短于 30 分钟；OpenAI Web 的常规后台刷新同时按现有
Battery Saver 规则处理。用户主动触发的刷新保持可用，不改写用户原有刷新频率，也不删除任何统计
选项。

## 问题与根因

现有 Codex 提供商内的 **Battery Saver** 只限制 `chatgpt.com` Dashboard 抓取。它不覆盖以下独立
后台通道：

- `UsageStore.startTimer()` 驱动的供应商用量和状态刷新；
- `UsageStore.startTokenTimer()` 驱动的本地 Token/成本历史扫描；
- `UsageStore.scheduleStorageFootprintRefresh` 驱动的本地目录占用扫描。

在刷新频率为 5 分钟、开启本地 Codex 会话账本和存储统计时，上述三个通道仍可约每 5 分钟唤醒并
遍历本地历史。因而用户即使开启了原有 Battery Saver，也可能继续看到较高能耗。

## 用户行为

在 Settings → General → Refreshing 中增加：

- 标题：`Low Power Mode`
- 说明：`Runs automatic provider, local usage, and storage refreshes no more often than every 30 minutes. Manual refresh remains available.`
- 默认：关闭

开启时：

| 通道 | 原行为 | 低功耗模式 |
| --- | --- | --- |
| 固定供应商刷新 | 使用所选的 1/2/5/15/30 分钟间隔 | 最低 30 分钟 |
| Adaptive 供应商刷新 | 按活动、电源和温度动态计算 | 保留动态决策，但结果最低 30 分钟 |
| 本地 Token/成本扫描 | 最低 5 分钟，跟随刷新策略 | 最低 30 分钟 |
| 供应商存储扫描 | 自动扫描冷却 5 分钟 | 自动扫描冷却 30 分钟 |
| OpenAI Web 常规后台刷新 | 由提供商专用 Battery Saver 控制 | 视为 Battery Saver 已开启 |
| 手动刷新 | 立即执行 | 不变 |

关闭时立即恢复原有用户设置的有效行为。实现不得把已保存的 `refreshFrequency` 改成 30 分钟，也不得
关闭本地成本或存储统计。

## 策略边界

增加一个纯策略 `BackgroundWorkPowerPolicy`，集中实现“低功耗模式下自动间隔不得短于 1800 秒”。
供应商计时器、Adaptive 计时器、Token 计时器和存储冷却必须复用同一策略，避免四处复制数值和产生
不一致。

`nil` 间隔代表手动模式或无自动工作，策略必须原样保留 `nil`。超过 30 分钟的用户间隔不得被缩短。

OpenAI Web 使用以下有效值：

```text
effectiveWebBatterySaver =
    openAIWebBatterySaverEnabled || backgroundWorkLowPowerModeEnabled
```

提供商专用开关仍独立保存；关闭全局低功耗模式后，它继续按用户原值生效。

## 设置和迁移

- 新键：`backgroundWorkLowPowerModeEnabled: Bool`
- 默认：`false`
- 不进行历史设置迁移；
- Setter 必须触发 `noteBackgroundWorkSettingsChanged()`，使现有计时器立即按新策略重建；
- 菜单观察令牌包含该设置，保证界面同步更新。

## 文案澄清

Codex 提供商中的旧标题由 `Battery Saver` 改为 `OpenAI web battery saver`，说明仍明确其只限制
`chatgpt.com` 刷新。全局设置使用 `Low Power Mode`，避免两个开关被理解为同一作用域。

首个实现至少提供英文和简体中文本地化；其他语言缺失时沿用 CodexBar 的英文回退机制，不在本修复中
批量生成未经审校的翻译。

## 非目标

- 不停止所有后台工作；
- 不改变手动刷新、菜单主动刷新或设置变更后的一次性同步；
- 不更改 Agent Sessions 的显式扫描周期；
- 不读取对话正文，也不新增遥测；
- 不增加依赖；
- 不实现动态“自动决定是否省电”的第二套策略；
- 不修改 Widget 数据结构或同步协议。

## 测试要求

- 纯策略在关闭时保持原间隔，在开启时把小于 1800 秒的自动间隔提升到 1800 秒；
- `nil` 保持 `nil`，大于 1800 秒的间隔保持不变；
- 设置默认关闭、可持久化，并触发后台工作 revision；
- 固定、Adaptive、Token 和存储自动间隔都使用同一低功耗下限；
- 手动 Token 刷新和手动存储刷新不受低功耗模式阻断；
- 全局低功耗模式会激活 OpenAI Web 的有效 Battery Saver，关闭后恢复提供商开关原值；
- 现有目标测试、格式检查和应用构建通过。

## 本地安装边界

Mac 可以安装自己编译的 CodexBar。开发包使用 ad-hoc 本地签名，自动更新关闭。由于当前机器没有完整
Xcode，首个测试包可不包含 Widget；这不影响菜单栏 App、本地用量统计或本次低功耗策略。安装前备份
现有 `/Applications/CodexBar.app`，失败时可直接恢复。

## 验收标准

1. 开启低功耗模式且原刷新频率为 5 分钟时，三个主要自动通道的有效冷却均为 30 分钟。
2. 菜单和显式刷新仍能立即取得新数据。
3. 关闭低功耗模式后无需重新设置，5 分钟配置恢复。
4. 设置界面明确区分全局低功耗模式与 OpenAI Web 专用省电开关。
5. 本地 ad-hoc 包能启动、显示菜单，并读取现有 CodexBar 设置。
