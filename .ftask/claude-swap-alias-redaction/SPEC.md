# SPEC — claude-swap-alias-redaction
## Done — ONE measurable sentence
- With Hide Personal Info enabled, the CodexBar menu shows every claude-swap account's non-email label (alias, or org / "Account N" fallback) on its card title and compact row, while raw email addresses remain fully redacted; proven by unit tests.

## What sunke wants (plain language)  [Objective]
- 多账号（claude-swap 4 账号）菜单在"隐藏个人信息"开启时只剩匿名数字，无法分辨哪张卡是哪个账号；要求卡片标题和紧凑行恢复显示账号标识（alias），邮箱仍然遮蔽。

## Out of scope (what we will NOT do)  [Scope]
- 不改 hidePersonalInfo 对邮箱的遮蔽行为（ emails 依旧全部遮蔽）。
- 不改菜单布局/紧凑行结构，不改 pace 行与用量数字逻辑。
- 不处理菜单栏 bar 标题、widget 的显示（仅菜单卡片与紧凑行）。

## 我拍的数 (轮数/超时/并发/范围)
- 单仓单分支；~60 行 diff；T1。Targeted tests 跑新增套件 + 既有 claude-swap 菜单套件；全量交给平台 CI（pr backend）。

## 任务类型 fix
## 根因 (fix 必填 — 不写根因就会同一个 bug 修两遍)
> 这个缺陷的真实成因是什么?在哪一层进入系统?哪些调用方共享同一个根因?
- 真实成因：`PersonalInfoRedactor.redactEmail` 在 hidePersonalInfo 开启时无条件把**整个值**替换为空串。而 claude-swap 的账号标识按设计就是非邮箱标签（投影层 `ClaudeSwapAccountProjection.displayLabel` 优先返回 alias，回退 "Account N"/"email · org"；`AccountMenuLayoutPlanner` 的紧凑行 label 同样取 `account.displayLabel`）。整值清空把 alias 一并清掉。
- 进入系统的两层调用方（共享同一根因）：
  1. `MenuCardView.redactedText` — 账号卡标题；
  2. `StatusItemController+CompactAccountMenu` 紧凑行 label。
- 修法：新增 `redactAccountLabel`（只按邮箱正则遮蔽邮箱形子串，非邮箱标签保留，"email · org" 清理孤儿分隔符），两个调用点换用之；`redactEmail` 原语义保留给纯邮箱场景。

## 拷问 — /grilling; T0/T1 可跳过
- T1，跳过（sunke 已直接下指令：给 CodexBar 提 PR）。

## How will I know it works
### Surface (pick one or more)
- [x] lib — 单元测试直接断言 redactAccountLabel 行为
- [x] cli — `swift test --filter ...` 本机跑 targeted suites
### Visual target (web: 参考图路径 / 设计稿 URL / 可视判定)
- 用户截图（2026-09-08 13:08）：Claude 分区活跃卡无标题、3 条紧凑行只有 "Fable 0% • Weekly 1%" 等匿名数字。修复后同布局每行左端显示 alias。
### Acceptance scenarios (user does X → observe Y)
- 开启 Hide Personal Info + claude-swap ≥2 账号（含 alias）→ 菜单每张卡/每个紧凑行显示 alias；纯邮箱账号标题仍为空。
- "shared@email.com · Org" 无 alias 标签 → 显示 "Org"。
### Regression guards (what must NOT break)
- 邮箱仍被完全遮蔽（`MenuCardClaudeSwapAccountTests claude swap account card respects hide personal info` 继续通过）。
- `redactEmail`/`redactEmails` 原有语义不变（Codex workspace 等既有测试不动）。
### Targeted tests (repo-relative paths; one per bullet, or `full-suite`)
- Tests/CodexBarTests/PersonalInfoRedactorAccountLabelTests.swift
- Tests/CodexBarTests/MenuCardClaudeSwapAccountTests.swift
- Tests/CodexBarTests/StatusMenuClaudeSwapCompactTests.swift
- Tests/CodexBarTests/StatusMenuCompactAccountLayoutTests.swift

## Plan (ordered steps; tick progress)
- [x] 新增 `PersonalInfoRedactor.redactAccountLabel`
- [x] 卡片标题与紧凑行两个调用点换用
- [x] 新增单元测试
- [ ] targeted suites 全绿
- [ ] ship（pr backend → fork 分支 + 上游 PR）

## Dead ends (approach → why it failed; never retry)
- 用 GitHub API 同步 fork main（/merges 与 PATCH branches 均不适用）→ 改用 `gh repo sync`，已成功，与本修复无关仅记录。
