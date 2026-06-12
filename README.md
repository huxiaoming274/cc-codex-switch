# cc-codex-switch

> One-click PowerShell script to switch **Codex CLI** between the official ChatGPT login and third-party providers (e.g., DeepSeek).
> Designed to work with [CC Switch](https://github.com/farion1231/cc-switch). **Codex only** — Claude Code does not need this.

[中文说明](README.zh.md)

---

## Supported versions

Verified on the following versions (2026-06):

| Component | Version |
|---|---|
| Codex CLI | **0.130.0-alpha.5** (0.13x series: enforces `responses`, rejects overriding `openai`) |
| CC Switch | **3.16.2** |
| sqlite3 | 3.45.x (any recent release) |
| System | Windows 11 / PowerShell 5.1 |

> **Version sensitivity**: This tool depends on two things — (1) Codex CLI enforcing `responses` + rejecting `openai` overrides (introduced in 0.13x);
> (2) CC Switch's local proxy port `15721` and the `providers` / `proxy_config` database schema.
> Major changes to either may require updates. If a future CC Switch release handles official ↔ third-party proxy switching natively,
> this script may become unnecessary — try the built-in feature first after upgrading.
> Older Codex CLI builds (which still supported `wire_api=chat`) never needed this tool.

---

## What problem does it solve?

Newer **Codex CLI (0.13x+)** imposes two conflicting hard requirements on provider configuration:

1. **Enforces `wire_api = "responses"`** — the old `chat` protocol is no longer supported.
2. **Rejects overriding the built-in `openai` provider** — error: `reserved built-in provider IDs: openai`.

Meanwhile, most affordable third-party providers (DeepSeek, various relay services) only offer **OpenAI Chat Completions** and do **not** support the Responses API (`/responses` returns 404).

The result:

| You want | Direct config result |
|---|---|
| Official ChatGPT | Works fine (official natively supports responses) |
| Third-party (chat-only) | `wire_api=chat` is rejected; switching to `responses` gets 404 — **can't connect no matter what** |

CC Switch's local proxy was meant to perform **responses → chat protocol translation** for this exact scenario, but when toggling providers it:
- Route **official** traffic through the proxy → `401 Authentication Fails` (OAuth can't pass through);
- **Overwrites** `~/.codex/config.toml` with internal state on startup, producing unreliable configs.

Net result: "Something is always broken after switching." This script hardens that workflow so both sides work reliably with a single double-click.

---

## How it works

Core insight: **official and third-party have opposite needs regarding the local proxy**, so handle them separately.

```
Official ChatGPT                Third-party (chat-only, e.g. DeepSeek)
  Direct to api.openai.com        Codex ──responses──> CC Switch proxy (127.0.0.1:15721)
  No proxy needed                                         └─translates to chat──> 3rd-party API
  → Proxy must be OFF                                    → Proxy must be ON
```

What the script does:

- **Switch to official**: Shuts down CC Switch (official doesn't need it + avoids config overwrites), then writes a clean `model_provider=openai` + `model=<official model>` config directly.
- **Switch to third-party**: Configures CC Switch state and starts it (so the local proxy routes to the chosen provider), waits for the proxy to be ready, then writes `model_provider=custom` + `base_url=http://127.0.0.1:15721/v1` + `wire_api=responses` so Codex sends responses requests to the proxy, which translates them to chat for the third-party API.

The script **fully owns `config.toml`** — CC Switch is only used to run the proxy process, side-stepping its unreliable config output.

---

## Prerequisites

- Windows + PowerShell 5.1+
- [CC Switch](https://github.com/farion1231/cc-switch) and Codex CLI installed and run at least once
- Both the "official" and your third-party provider(s) already configured under CC Switch's **Codex** tab
- `sqlite3` command available (`winget install SQLite.SQLite` or `scoop install sqlite`)

## Usage

```powershell
# Switch to official ChatGPT
powershell -ExecutionPolicy Bypass -File cc-codex-switch.ps1 -Target official

# Switch to third-party (auto-selects when only one third-party exists)
powershell -ExecutionPolicy Bypass -File cc-codex-switch.ps1 -Target thirdparty

# With multiple third-party providers, specify by name (as displayed in CC Switch)
powershell -ExecutionPolicy Bypass -File cc-codex-switch.ps1 -Target thirdparty -Provider DeepSeek
```

Or simply double-click `switch-official.cmd` / `switch-thirdparty.cmd`.

> **After each switch, open a new Codex terminal/session** — running sessions do not hot-reload.

## Auto-detection / no hardcoding

- Paths are derived from `%USERPROFILE%` / `%LOCALAPPDATA%` automatically;
- CC Switch executable is auto-discovered;
- Official and third-party provider names, plus third-party **model names**, are read from the CC Switch database — no hardcoded UUIDs.

The only setting you may want to adjust is `$OfficialModel` at the top of the script (default: `gpt-5.5`).

## Notes / limitations

- **Security**: This script contains no secrets. However, do **not** publish `~/.codex/auth.json`, `~/.codex/config.toml`, or `~/.cc-switch/cc-switch.db` — they contain your login tokens and third-party API keys.
- The third-party path assumes the provider only supports chat and requires proxy translation (the most common case). If your third-party provider natively supports the Responses API, you don't need the proxy — just switch directly in CC Switch.
- Depends on CC Switch's current database schema (`providers` / `proxy_config` tables) and local proxy port `15721`; a major CC Switch update may require adjustments.
- Switching backs up the previous config as `~/.codex/config.toml.switch-bak`.

## License

MIT. Use and modify freely.
