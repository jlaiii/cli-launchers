# CLI Launchers

Two launchers organized by **provider**: pick Ollama or DeepSeek, and launch any supported AI coding assistant from a single menu.

- **Ollama Launcher** — Codex CLI + Claude Code + Codex App via Ollama
- **DeepSeek Launcher** — Codex CLI + Claude Code + Codex App via DeepSeek API

Each launcher is a single-file script (.bat / .command / .ps1). It checks prerequisites, auto-installs missing tools, keeps everything updated, and gives you a picker for models — then launches.

## Quick Start

### One-liner (copy-paste into terminal)

**Windows (PowerShell)**
```powershell
# Ollama Launcher (Codex CLI + Claude Code + Codex App)
irm https://raw.githubusercontent.com/jlaiii/cli-launchers/main/Ollama-Launcher.ps1 | iex

# DeepSeek Launcher (Codex CLI + Claude Code + Codex App)
irm https://raw.githubusercontent.com/jlaiii/cli-launchers/main/DeepSeek-Launcher.ps1 | iex
```

**macOS (Terminal)**
```bash
# Ollama Launcher (Codex CLI + Claude Code + Codex App)
curl -fsSL https://raw.githubusercontent.com/jlaiii/cli-launchers/main/Ollama-Launcher.command | bash

# DeepSeek Launcher (Codex CLI + Claude Code + Codex App)
curl -fsSL https://raw.githubusercontent.com/jlaiii/cli-launchers/main/DeepSeek-Launcher.command | bash
```

### Direct launch (skip the menu)

```batch
:: Ollama Launcher
Ollama-Launcher.bat codex          :: launch Codex CLI
Ollama-Launcher.bat claude         :: launch Claude Code
Ollama-Launcher.bat codex-app      :: launch Codex App

:: DeepSeek Launcher
DeepSeek-Launcher.bat codex        :: launch Codex CLI
DeepSeek-Launcher.bat claude       :: launch Claude Code
DeepSeek-Launcher.bat codex-app    :: launch Codex App
```

---

## Ollama Launcher

Launches **Codex CLI**, **Claude Code**, and **Codex App** through Ollama. Browse cloud/local models, pull models, check sign-in — all from one menu.

**What it handles:**
- Detects and auto-installs Ollama
- Detects and auto-installs Node.js / npm (for Codex CLI)
- Checks for updates (Ollama via GitHub releases)
- Verifies Ollama sign-in status
- Model browser — top 10 cloud models, local models, or manual entry
- Auto-starts the Ollama server if not running
- Launches via `ollama launch codex`, `ollama launch claude`, or `ollama launch codex-app`

**Menu:**
| # | Option |
|---|--------|
| 1 | Install / Update Ollama |
| 2 | Pick / Change Model (cloud / local / manual) |
| 3 | Pull Selected Model Locally |
| 4 | Launch Codex CLI (via Ollama) |
| 5 | Launch Claude Code (via Ollama) |
| 6 | Launch Codex App (via Ollama) |
| 7 | Check / Fix Ollama Sign-in |
| 8 | Clear Version Cache |
| T | Toggle Permission Bypass |

**Config:** Model: `kimi-k2.6:cloud` · Source: cloud · Skip-perms: ON

---

## DeepSeek Launcher

Launches **Codex CLI**, **Claude Code**, and **Codex App** through the DeepSeek API. Bring your own API key, pick a model, and launch any tool.

**What it handles:**
- Detects and auto-installs Node.js / npm and Codex CLI (via `npm install -g @openai/codex`)
- Detects and auto-installs Claude Code (via official installer)
- Checks for updates against npm (Codex, Claude Code)
- DeepSeek model picker — V4 Pro (`deepseek-v4-pro`), V4 Flash (`deepseek-v4-flash`), or manual entry
- API key setup and persistence
- Codex CLI: sets `OPENAI_API_KEY` + `OPENAI_BASE_URL` for direct DeepSeek access
- Codex App: uses `-c` CLI overrides (`model_provider=deepseek`, `wire_api=chat`) — no file changes needed
- Claude Code: sets `ANTHROPIC_API_KEY` + `ANTHROPIC_BASE_URL` for Anthropic-compatible endpoint

**Menu:**
| # | Option |
|---|--------|
| 1 | Install / Update Codex CLI |
| 2 | Install / Update Claude Code |
| 3 | Pick DeepSeek Model (V4 Pro / Flash / manual) |
| 4 | Set DeepSeek API Key |
| 5 | Launch Codex CLI (via DeepSeek) |
| 6 | Launch Claude Code (via DeepSeek) |
| 7 | Launch Codex App (via DeepSeek) |
| C | Clear Version Cache |
| T | Toggle Permission Bypass |

**Config:** Model: `deepseek-v4-pro` (V4 Pro) · API key stored locally · Skip-perms: ON

---

## Requirements

- **Windows:** Windows 10/11 with PowerShell 5.1+
- **macOS:** macOS 11+ (Big Sur or later), `python3` pre-installed
- Internet connection (for installs and model browsing)
- **Ollama account** (for Ollama cloud models like `kimi-k2.6:cloud`)
- **DeepSeek API key** (for DeepSeek Launcher — get one at [platform.deepseek.com/api_keys](https://platform.deepseek.com/api_keys))

---

## Website

**[https://jlaiii.github.io/cli-launchers](https://jlaiii.github.io/cli-launchers)**

---

## Notes

- Launchers auto-create `*.config.json` and `*.versions.json` files in a `.cli-launchers` folder to remember your settings.
- If npm/ollama installs fail on Windows, try running the launcher as Administrator.
- On macOS, `.command` files downloaded from the web may require right-click > Open the first time (Gatekeeper).
- The `.bat` files are self-extracting — they embed a full PowerShell script and clean up the temp file when done.
- The `.command` files are plain bash scripts that use `python3` for JSON persistence.
- API keys are stored locally in config files and only used as environment variables at launch time.
- The DeepSeek Codex App integration uses `-c` CLI config overrides — no files in `~/.codex` are touched, so existing Ollama or OpenAI configs are unaffected.

---

## License

MIT — use, share, modify freely.
