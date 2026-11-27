# 个人版 CodexBar

个人构建只有一个菜单栏图标。打开菜单可查看 Codex、Kimi 和 Antigravity 的额度与重置时间。菜单每五分钟刷新一次，也可点「刷新」。全局「显示已用额度」沿用原来的设置。

在「设置」连接订阅：

- **Codex** 选择「使用 ChatGPT 登录」，在 OpenAI 页面输入 CodexBar 显示的一次性代码。账号需要允许设备码登录。
- **Kimi** 选择签发密钥的地区，输入 Kimi Code 订阅的 API Key。月额度与核心额度来自同一次请求。
- **Antigravity** 选择「使用 Google 登录」。首次登录沿用 CodexBar 的 Google OAuth 流程，可以使用已安装 Antigravity 的客户端配置，也可使用既有的 OAuth 客户端环境配置。后台查询只读取 CodexBar 保存的 Google 授权。原版 CodexBar 已保存的直接 Google 授权也可使用。

CodexBar 将自己的 Codex 授权和 Kimi Key 保存到 `~/.codexbar/personal-quotas/`，Google 授权沿用 `~/.codexbar/antigravity/oauth_creds.json`。凭据文件仅当前用户可读写。「断开连接」会删除对应的本地授权。

[个人版工作流](../.github/workflows/personal-macos.yml) 使用本目录的 SwiftPM 包构建和验证菜单应用。共享文件链接到仓库中的原实现。个人产物只包含菜单应用和图标。
