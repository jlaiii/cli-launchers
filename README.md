# CLI Launchers

Two launchers organized by **provider**: pick Ollama or DeepSeek, and launch any supported AI coding assistant from a single menu.

- **Ollama Launcher** — Codex CLI + Claude Code + Codex App via Ollama
- **DeepSeek Launcher** — Codex CLI + Claude Code + Codex App via DeepSeek API

Each launcher is a single-file script (.bat / .command / .ps1). At startup it **auto-updates** all tools to the latest versions from npm — fully automatic, no prompts. Then it gives you a simple menu to launch. Every operation is logged to `Documents\cli-launchers\launcher.log` for easy debugging.

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
:: DeepSeek Launcher
DeepSeek-Launcher.bat claude         :: launch Claude Code
DeepSeek-Launcher.bat codex          :: launch Codex CLI
DeepSeek-Launcher.bat codex-app      :: launch Codex App
DeepSeek-Launcher.bat claude-desktop :: launch Claude Desktop

:: Ollama Launcher
Ollama-Launcher.bat claude           :: launch Claude Code
Ollama-Launcher.bat codex            :: launch Codex CLI
Ollama-Launcher.bat codex-app        :: launch Codex App
Ollama-Launcher.bat claude-desktop   :: launch Claude Desktop
```

---

## Auto-Update

At every launch, the launcher automatically:

1. Checks npm registry for the latest versions of Claude Code (`@anthropic-ai/claude-code`) and Codex CLI (`@openai/codex`)
2. Checks GitHub releases for the latest Ollama version (Ollama launcher only)
3. **Auto-installs or updates** any tool that doesn't match the latest version
4. Skips silently if offline (uses 60-minute version cache)

No prompts, no decisions. You always run the latest version.

---

## Logging

All launchers write to `Documents\cli-launchers\launcher.log` with timestamps. Log entries include:
- Startup and shutdown
- Version checks and npm/GitHub queries
- Auto-update decisions and install attempts
- Launch operations
- Any errors encountered

Press **L** in the menu to view the last 40 lines of the log. If you encounter a crash, check the log for details.

---

## DeepSeek Launcher

Launches **Claude Code**, **Codex CLI**, **Codex App**, and **Claude Desktop** through the DeepSeek API.

**What it handles:**
- Auto-updates Claude Code & Codex CLI at startup (checks npm for latest)
- DeepSeek model picker — V4 Pro, V4 Flash, or manual entry
- API key setup and persistence
- Sets correct environment variables for each tool
- Claude Desktop: writes 3p gateway config, enables developer mode, clears OAuth session

**Menu:**

| # | Option |
|---|--------|
| 1 | Launch Claude Code |
| 2 | Launch Codex CLI |
| 3 | Launch Codex App |
| 4 | Launch Claude Desktop |
| 5 | Set DeepSeek API Key |
| 6 | Pick Model |
| T | Toggle Permission Bypass |
| L | View Log |
| Q | Quit |

---

## Ollama Launcher

Launches **Codex CLI**, **Claude Code**, **Codex App**, and **Claude Desktop** through Ollama.

**What it handles:**
- Auto-updates Ollama, Claude Code & Codex CLI at startup
- Ollama server auto-start
- Model browser — cloud (newest 10), local, or manual entry
- Pull models from Ollama registry
- Claude Desktop: writes 3p gateway config, enables developer mode, clears OAuth session

**Menu:**

| # | Option |
|---|--------|
| 1 | Launch Codex CLI (via Ollama) |
| 2 | Launch Claude Code (via Ollama) |
| 3 | Launch Codex App (via Ollama) |
| 4 | Launch Claude Desktop (via Ollama) |
| 5 | Pick / Browse Models |
| 6 | Check Ollama Sign-in |
| T | Toggle Permission Bypass |
| L | View Log |
| Q | Quit |

---

## Requirements

- **Windows:** Windows 10/11 with PowerShell 5.1+
- **macOS:** macOS 11+ (Big Sur or later), `python3` pre-installed
- Internet connection (for auto-updates and model browsing)
- **Ollama account** (for Ollama cloud models like `kimi-k2.6:cloud`)
- **DeepSeek API key** (for DeepSeek Launcher — get one at [platform.deepseek.com/api_keys](https://platform.deepseek.com/api_keys))

---

## Files

| File | Platform | Description |
|------|----------|-------------|
| `DeepSeek-Launcher.bat` | Windows | Self-extracting launcher (double-click to run) |
| `DeepSeek-Launcher.ps1` | Windows | Standalone PowerShell script |
| `DeepSeek-Launcher.command` | macOS | Bash launcher |
| `Ollama-Launcher.bat` | Windows | Self-extracting launcher (double-click to run) |
| `Ollama-Launcher.ps1` | Windows | Standalone PowerShell script |
| `Ollama-Launcher.command` | macOS | Bash launcher |

---

## Config

- Launchers create `*.config.json` files in your Documents folder (`Documents\cli-launchers`) to remember your settings
- Version caches (npm latest) are stored in the same config files with 60-minute TTL
- Log file: `Documents\cli-launchers\launcher.log`
- API keys are stored locally and only used as environment variables at launch
- If npm/ollama installs fail on Windows, try running as Administrator
- On macOS, `.command` files from the web may require right-click > Open the first time (Gatekeeper)
- The `.bat` files are self-extracting — they embed the full PowerShell script and clean up the temp file when done
- The `.command` files use `python3` for JSON persistence

---

## License

MIT — use, share, modify freely.
