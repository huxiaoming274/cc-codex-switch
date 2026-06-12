# cc-codex-switch

> Windows 下为 **Codex CLI** 做「官方 ChatGPT 登录 ↔ 第三方供应商（如 DeepSeek）」一键切换的小脚本。
> 配合 [CC Switch](https://github.com/farion1231/cc-switch) 使用。**仅针对 Codex**（Claude Code 不需要，它没有这个问题）。

---

## 适用版本

在以下环境验证通过（2026-06）：

| 组件 | 版本 |
|---|---|
| Codex CLI | **0.130.0-alpha.5**（0.13x 系列：强制 `responses`、禁止覆盖 `openai`） |
| CC Switch | **3.16.2** |
| sqlite3 | 3.45.x（任意近期版本即可） |
| 系统 | Windows 11 / PowerShell 5.1 |

> **版本敏感点**：本工具依赖两件事——(1) Codex CLI「强制 responses + 禁止覆盖 openai」的行为（0.13x 起出现）；
> (2) CC Switch 的本地代理端口 `15721` 与 `providers`/`proxy_config` 数据库结构。
> 这两者任一大改版都可能需要相应调整。若 CC Switch 后续版本已能自动处理官方/第三方的代理切换，
> 则可能不再需要本脚本——升级后建议先试官方功能。
> 较老的 Codex CLI（仍支持 `wire_api=chat`）本就不需要本工具。

---

## 它解决什么痛点

新版 **Codex CLI（0.13x 起）** 对供应商配置有两条互相冲突的硬性要求：

1. **强制 `wire_api = "responses"`** —— 旧的 `chat` 协议已不支持。
2. **禁止覆盖内置的 `openai` provider** —— 报错 `reserved built-in provider IDs: openai`。

而绝大多数便宜的第三方（DeepSeek、各种中转）只提供 **OpenAI Chat Completions** 接口，**不支持 Responses API**（`/responses` 直接 404）。

于是会出现：

| 你想用 | 直接配置的结果 |
|---|---|
| 官方 ChatGPT | 正常（官方原生支持 responses） |
| 第三方（chat-only） | `wire_api=chat` 被拒，改 `responses` 又 404 —— **怎么配都连不上** |

CC Switch 的「本地代理」本意是做 **responses → chat 的协议翻译**来救这个场景，但它在切换时会：
- 对**官方**误走代理 → `401 Authentication Fails`（OAuth 过不去）；
- 启动时用内部状态**覆盖** `~/.codex/config.toml`，生成的配置时好时坏。

结果就是「切来切去总有一边是坏的」。本脚本把这套流程固定下来，做到双击即切、两边都稳。

---

## 解决原理

核心洞察：**官方和第三方对「本地代理」的需求正好相反**，所以分两条路处理。

```
官方 ChatGPT          第三方 (chat-only, 如 DeepSeek)
  直连 api.openai.com      Codex ──responses──> CC Switch 本地代理(127.0.0.1:15721)
  不需要代理                                        └─转成 chat──> 第三方 API
  → 代理必须【关】                                  → 代理必须【开】
```

因此脚本：

- **切官方**：关闭 CC Switch（官方直连根本不需要它，还能避免它覆盖配置），由脚本直接写
  `model_provider=openai` + `model=<官方模型>` 的干净配置。
- **切第三方**：设好 CC Switch 状态并启动它（让本地代理跑起来并路由到该供应商），
  等代理就绪后，由脚本写入
  `model_provider=custom` + `base_url=http://127.0.0.1:15721/v1` + `wire_api=responses` 的配置，
  让 Codex 把 responses 请求发给代理、由代理翻译成 chat 转发给第三方。

脚本**完全掌控 `config.toml`**，CC Switch 只负责「跑代理进程」，从而绕开它配置输出不稳定的问题。

---

## 前置条件

- Windows + PowerShell 5.1+
- 已安装并至少正常运行过一次 [CC Switch](https://github.com/farion1231/cc-switch) 和 Codex CLI
- 在 CC Switch 的 **Codex** 标签里已经添加好「官方」和你的「第三方」供应商
- `sqlite3` 命令可用（`winget install SQLite.SQLite` 或 `scoop install sqlite`）

## 用法

```powershell
# 切到官方 ChatGPT
powershell -ExecutionPolicy Bypass -File cc-codex-switch.ps1 -Target official

# 切到第三方（只有一个第三方时自动选中）
powershell -ExecutionPolicy Bypass -File cc-codex-switch.ps1 -Target thirdparty

# 有多个第三方时用名字指定（名字即 CC Switch 里显示的供应商名）
powershell -ExecutionPolicy Bypass -File cc-codex-switch.ps1 -Target thirdparty -Provider DeepSeek
```

或直接双击 `switch-official.cmd` / `switch-thirdparty.cmd`。

> **每次切换后，请新开一个 Codex 终端/会话**——正在运行的会话不会热切换。

## 自动适配 / 无需写死

- 路径用 `%USERPROFILE%` / `%LOCALAPPDATA%` 自动拼接；
- CC Switch 可执行文件自动探测；
- 官方与第三方供应商、第三方的**模型名**，都从 CC Switch 数据库自动读取，不写死 UUID。

唯一可能要改的是脚本顶部的 `$OfficialModel`（官方登录用的模型，默认 `gpt-5.5`）。

## 注意 / 局限

- **安全**：本脚本不含任何密钥。但请**不要把** `~/.codex/auth.json`、`~/.codex/config.toml`、
  `~/.cc-switch/cc-switch.db` 一起公开——它们含有你的登录令牌和第三方 API key。
- 第三方路径假设该供应商**只支持 chat、需要代理翻译**（最常见情形）。若你的第三方原生支持
  Responses API，则不需要代理，可直接在 CC Switch 里切换。
- 依赖 CC Switch 当前的数据库结构（`providers` / `proxy_config` 表）与本地代理端口 `15721`；
  CC Switch 大改版后可能需要相应调整。
- 切换会把上一版配置备份为 `~/.codex/config.toml.switch-bak`。

## 许可

MIT。随意使用与修改。
