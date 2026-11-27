# Agy — Antigravity 地区限制绕行工具集

让 Google Antigravity（CLI / 桌面端 / CodeBuddy 扩展面板）用自购 Google AI 订阅账号正常工作。仅 macOS Apple Silicon 下验证过。

## 背景

Antigravity 的地区限制有两层，只有第一层能本地解决：

1. **客户端本地资格检查**（"Account ineligible: ...not currently available in your location"）——登录后客户端比较资格状态字符串并锁定界面。通过二进制补丁绕过：把二进制里所有 `ineligible`（10 字节）等长替换为 `inexigible`，本地比较永远失配。
2. **服务端 IP 风控**（`FAILED_PRECONDITION (code 400): User location is not supported for the API use`）——Google 按**网络出口 IP** 拒绝请求，本地无解。大厂机房 IP（AWS/GCP/Azure 等）基本必被拒，需住宅/家宽类出口节点。

**为什么有效**：CLI/桌面端/扩展共用同一后端和同一份钥匙串凭据（`svce=gemini, acct=antigravity`），补丁只改客户端判定逻辑，服务端发的订阅额度照常生效。Gemini App 内置的 Agy 无需处理（它走 `--use_host_auth` 用宿主凭据，本来就没限制）。

## 文件说明

| 文件 | 用途 |
|---|---|
| `ag_patcher_zh.sh` | 补丁工具（中文版，源自 [Quenary/antigravity-patcher](https://github.com/Quenary/antigravity-patcher)）。自动扫描并补丁 `~/.local/bin/agy`、`~/.gemini/bin/agy`、Antigravity.app 内 `language_server` 等目标，macOS 上自动 ad-hoc 重签名 |
| `agyx` | CLI 启动器：设置 `AGY_CLI_DISABLE_AUTO_UPDATE=1`（防更新覆盖补丁）后透传参数给 `agy` |

## 日常使用

```sh
# CLI（首次运行会用浏览器登录 Google 账号）
~/Workspaces/01-codespaces/experimental/Agy/agyx

# 桌面端 / CodeBuddy 扩展面板：直接打开，登录一次即可
```

## 维护（重要）

**agy 或客户端升级后补丁会被覆盖**（CLI 有启动器兜底，主要是 Antigravity 客户端和扩展下载的后端会自动更新）：

```sh
AG_YES=1 bash ~/Workspaces/01-codespaces/experimental/Agy/ag_patcher_zh.sh patch
```

打完补丁后**必须完全重启 CodeBuddy**（`Cmd+Q` 后重开，Reload Window 不够——扩展的后端进程要换成新补丁的二进制），桌面端同理重新打开。

其他子命令：

```sh
bash ag_patcher_zh.sh status    # 查看各目标补丁状态
bash ag_patcher_zh.sh unpatch   # 完整还原
```

## 故障排查

| 现象 | 原因 | 处理 |
|---|---|---|
| `Account ineligible` / 登录页卡住 | 补丁被更新覆盖 | 重跑 patch，然后完全重启 CodeBuddy / 客户端 |
| `400: User location is not supported for the API use` | 出口 IP 是机房 IP | 换代理节点（住宅 IP），可用 `curl -s https://ipwho.is` 查 ASN 确认 |
| 补丁后应用无法启动 | 签名问题 | 重跑 patch（内含 codesign）；或 `codesign --force --sign - <文件>` |

## 注意事项

- 绕过资格检查违反 Google 服务条款，存在账号风控风险，自行权衡；
- 补丁是字节级等长替换，agy 大版本重编译后若 `unpatch`/`patch` 报"未找到特征"，需等上游工具适配；
- 想彻底还原：`bash ag_patcher_zh.sh unpatch`（并把 CodeBuddy 扩展 `package.json` 里的 `secondarySidebar` 改回 `activitybar`，若你当初也改过侧边栏位置）。
