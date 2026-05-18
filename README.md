# CLI Launchers

Smart Windows batch launchers for AI coding assistants. Download a single `.bat` file, run it, and get an interactive menu that checks prerequisites, installs missing tools, picks models, and keeps everything up to date.

## Quick Start

1. **Download** the launcher you want:
   - [**Codex + Ollama**](https://jlaiii.github.io/cli-launchers/#download-codex) -- for OpenAI Codex CLI + Ollama
   - [**Claude + Ollama Launcher**](https://jlaiii.github.io/cli-launchers/#download-claude) -- for Claude Code + Ollama
2. Double-click the `.bat` file (or run it from the terminal)
3. Follow the on-screen menu -- install, update, pick a model, and launch

No PowerShell knowledge required. Everything is self-contained inside the `.bat`.

---

## Codex + Ollama

**What it does:**
- Checks if Node.js / npm is installed (auto-installs via winget or MSI if missing)
- Checks if Codex CLI is installed (auto-installs/updates via `npm install -g @openai/codex`)
- Checks if Ollama is installed (auto-installs/updates via official script)
- Checks for updates against npm (Codex) and GitHub releases (Ollama)
- Verifies Ollama sign-in status (`ollama list`)
- Lets you browse cloud/local models or enter one manually
- Auto-starts the Ollama server if it's not running
- Launches: `ollama launch codex --model <model> -- --yolo`

**Default config:**
- Model: `kimi-k2.6:cloud`
- Full-auto (`--yolo`): **ON**
- Source: cloud

**Menu options:**
| # | Option |
|---|--------|
| 1 | Install / Update Codex CLI |
| 2 | Install / Update Ollama |
| 3 | Pick / Change Model |
| 4 | Pull Selected Model Locally |
| 5 | Toggle Full-Auto Mode (`--yolo`) |
| 6 | Set Custom Launch Arguments |
| 7 | Check / Fix Ollama Sign-in |
| 8 | Launch Codex CLI |
| C | Clear Version Cache |
| A | Toggle Auto-Update on Direct Launch |
| Q | Quit |

**Direct launch (skip the menu):**
```batch
Codex-Launcher.bat launch --model o4-mini
Codex-Launcher.bat launch --model kimi-k2.6:cloud -- --yolo
Codex-Launcher.bat --model gpt-4.1 --yolo
```

---

## Claude + Ollama Launcher

**What it does:**
- Checks if Claude Code is installed (auto-installs/updates via `claude.ai/install.ps1`)
- Checks if Ollama is installed (auto-installs/updates via `ollama.com/install.ps1`)
- Checks for updates against npm (Claude Code) and GitHub releases (Ollama)
- Verifies Ollama sign-in status
- Lets you browse cloud/local models or enter one manually
- Auto-starts the Ollama server if it's not running
- Launches: `ollama launch claude --model <model> -- --dangerously-skip-permissions`

**Default config:**
- Model: `kimi-k2.6:cloud`
- Skip permissions: **ON**
- Source: cloud

**Menu options:**
| # | Option |
|---|--------|
| 1 | Install / Update Claude Code |
| 2 | Install / Update Ollama |
| 3 | Pick / Change Model |
| 4 | Pull Selected Model Locally |
| 5 | Launch Claude Code |
| 6 | Check / Fix Ollama Sign-in |
| 7 | Refresh Status |
| C | Set Custom Launch Command |
| T | Toggle Permission Bypass |
| Q | Quit |

---

## Requirements

- Windows 10/11 with PowerShell 5.1+
- Internet connection (for installs and model browsing)
- Ollama account (for cloud models like `kimi-k2.6:cloud`)

---

## Website

**[https://jlaiii.github.io/cli-launchers](https://jlaiii.github.io/cli-launchers)**

Visit the site for one-click downloads and a quick-setup guide.

---

## Notes

- The launchers auto-create `*.config.json` and `*.versions.json` files next to the `.bat` to remember your settings.
- If npm/ollama installs fail, try running the launcher as Administrator.
- The `.bat` files are self-extracting -- they embed a full PowerShell script and clean up the temp file when done.

---

## License

MIT -- use, share, modify freely.
