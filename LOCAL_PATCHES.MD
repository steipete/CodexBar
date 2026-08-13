# LOCAL_PATCHES — 本地未上游修改记录

> 记录本仓库相对于上游 `steipete/CodexBar` 的全部本地改动，供后续重放 / 提 PR / 迁移使用。
> 生成时间：2026-08-13

## 1. Git 分支状态（已同步上游）

| 分支 | behind origin/main | ahead | 说明 |
|---|---|---|---|
| `main` | 0 | 5 | 4 个本地提交 + 1 个 merge commit（见 §3） |
| `feature/menubar-icon-dimming` | 0 | 4 | 本地 4 个提交已 rebase 到上游 |
| `feature/codex-quota-notifications` | 0 | 0 | 已 fast-forward |

- 上游 `origin` = https://github.com/steipete/CodexBar.git
- fork `fork` = https://github.com/luantu/CodexBar.git

---

## 2. 修复：Codex 周额度重置死锁（未提交，位于工作区）

**状态**：未 commit，位于 `feature/menubar-icon-dimming` 工作区（`git diff` 可见）。

**问题**：`CodexWeeklyResetConfirmation.confirmationDecision` 在旧窗口尚未到期时观测到"提前重置"，要求证明消耗了一张手动重置券（`confirmsManualResetCreditConsumption`）。当账户**明确拥有 0 张可用重置券**（`availableCount == 0`）时该证明永远无法成立 → 每次刷新都被 `.preservePrevious` 挡住，新值永远不发布，UI 停留在旧快照。

**修复**：当上一次快照明确记录为 0 张可用重置券时，两次一致观测（initial + confirmation）本身即为充分确认，不再要求券消耗证明；未知/缺失的券信息仍保持保守。

### 2.1 `Sources/CodexBar/Providers/Codex/CodexWeeklyResetConfirmation.swift`

```diff
         let previouslyAvailableCredits = previousCredits.availableCredits(at: previousCredits.updatedAt)
-        guard !previouslyAvailableCredits.isEmpty else { return false }
+        // An explicitly observed zero-credit inventory means there was no manual reset credit to
+        // consume. Requiring consumption proof here would deadlock: the two consistent observations
+        // (initial + confirmation) are the only signal a server-side early reset has, so trust them.
+        // A nil/unknown previous inventory stays conservative and keeps demanding consumption proof.
+        guard !previouslyAvailableCredits.isEmpty else {
+            return previousCredits.availableCount == 0
+        }
         return previouslyAvailableCredits.contains { previousCredit in
```

### 2.2 `Tests/CodexBarTests/CodexWeeklyResetConfirmationTests.swift`

新增测试 `zero available reset credits confirm a server-side early weekly reset by observation`（完全复现线上时序：98%→1%，8/18→8/20，可用券 0）：

```diff
     @Test
+    func `zero available reset credits confirm a server-side early weekly reset by observation`() throws {
+        let formatter = ISO8601DateFormatter()
+        let previousCapturedAt = try #require(formatter.date(from: "2026-08-13T03:36:16Z"))
+        let previousReset = try #require(formatter.date(from: "2026-08-18T00:49:16Z"))
+        let initialCapturedAt = try #require(formatter.date(from: "2026-08-13T03:41:46Z"))
+        let initialReset = try #require(formatter.date(from: "2026-08-20T03:38:06Z"))
+        let previous = self.snapshot(
+            capturedAt: previousCapturedAt,
+            weeklyUsed: 98,
+            weeklyReset: previousReset,
+            resetCredits: self.emptyResetCredits(capturedAt: previousCapturedAt))
+        let initial = self.snapshot(
+            capturedAt: initialCapturedAt,
+            weeklyUsed: 1,
+            weeklyReset: initialReset,
+            resetCredits: self.emptyResetCredits(capturedAt: initialCapturedAt))
+        let confirmation = self.snapshot(
+            capturedAt: initialCapturedAt.addingTimeInterval(30),
+            weeklyUsed: 1,
+            weeklyReset: initialReset.addingTimeInterval(30),
+            resetCredits: self.emptyResetCredits(capturedAt: initialCapturedAt.addingTimeInterval(30)))
+
+        #expect(
+            CodexWeeklyResetConfirmation.initialDecision(previous: previous, initial: initial)
+                == .requiresConfirmation)
+        #expect(
+            CodexWeeklyResetConfirmation.confirmationDecision(
+                previous: previous,
+                initial: initial,
+                confirmation: confirmation)
+                == .publishConfirmation)
+    }
+
+    @Test
     func `one missing reset credit inventory does not confirm an early manual weekly reset`() throws {
```

### 2.3 验证

- `CodexWeeklyResetConfirmationTests` 20/20 通过（含新增用例）。
- `make check` 全仓 1846 文件 0 lint 违规。
- 已打包替换 `/Applications/CodexBar.app`，线上验证快照恢复实时刷新。

---

## 3. main 分支：merge 冲突解决（已 commit：`98c93bf96`）

同步 `main` → `origin/main` 时 3 个文件冲突，已手动解决并合并。

### 3.1 `Sources/CodexBar/MenuBarLayoutRenderer.swift`

本地 `isStale` / `verticalAdjustment` 字段 + 上游 `now` 注释并存；渲染逻辑取并集：

- `MenuBarLayoutRenderOptions` 增加 `isStale: Bool`、`verticalAdjustment: Int`（均带默认值）
- `foregroundColor` 在 stale 时用 `.secondaryLabelColor`
- baseline offset = 光学基线 + 用户 nudge

### 3.2 `Sources/CodexBar/StatusItemController+MenuBarLayout.swift`

合并决议：保留本地 `isStale` + `verticalAdjustment` 传参，`now` 采用上游的 `now: now`（精确时钟）：

```diff
-            isStale: self.store.isStale(provider: provider),
-            now: minute,
-            verticalAdjustment: self.settings.menuBarLayoutVerticalAdjustment)
+            isStale: self.store.isStale(provider: provider),
+            now: now,
+            verticalAdjustment: self.settings.menuBarLayoutVerticalAdjustment)
```

### 3.3 `Tests/CodexBarTests/MenuBarLayoutRendererTests.swift`

Helper 签名合并以兼容两侧调用点：

- `data(automaticUsedPercent:provider:automaticResetAt:)`（上游版）
- `options(verticalAdjustment:isStale:now:)`（本地参数 ∪ 上游 `now`）
- 新增 `vertical adjustment shifts single line baseline offset`、`stale title dims foreground while keeping the snapshot visible` 等测试；图标断言从 `NSTextAttachment` 改为 `leadingIcon`

---

## 4. 分支同步操作记录

1. `git fetch origin`
2. `feature/menubar-icon-dimming`：`git rebase origin/main`（4 个本地提交，MenuBarLayoutEditor.swift 自动合并无冲突）
3. `main`：`git merge origin/main`（3 文件冲突手动解决，见 §3）
4. `feature/codex-quota-notifications`：`git merge origin/main`（fast-forward）

---

## 5. 环境备注

- 默认 `swift`（CommandLineTools）release 构建缺 SwiftUI macros / Testing framework，构建与测试需：
  ```bash
  export DEVELOPER_DIR=/Volumes/ExtArchive/Applications/Xcode.app/Contents/Developer
  ```
- 打包：`CODEXBAR_SIGNING=adhoc DEVELOPER_DIR=... ./Scripts/package_app.sh`
