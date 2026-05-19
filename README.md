# CLI Launchers

Run top-tier AI CLI tools with any Ollama model you want. CLI Launchers are single-file scripts that set up and run [OpenAI Codex CLI](https://github.com/openai/codex) and [Anthropic Claude Code](https://github.com/anthropics/claude-code) through [Ollama](https://ollama.com).

Instead of manually installing Node.js, npm, the CLI tools, and Ollama, then configuring models and launch flags, you download one file -- a `.bat` for Windows or a `.command` for macOS -- run it, and the launcher handles everything.

**Who is it for:** Developers on Windows or macOS who want to use cutting-edge AI coding assistants without spending time on setup, dependency hell, or keeping tools up to date. If you want to run Codex or Claude with any Ollama model -- cloud or local -- this gets you there in one click.

## Quick Start

### One-liner (copy-paste into your terminal)

**Windows (PowerShell)**
```powershell
# Codex + Ollama
irm https://raw.githubusercontent.com/jlaiii/cli-launchers/main/Codex-Launcher.ps1 | iex

# Claude + Ollama
irm https://raw.githubusercontent.com/jlaiii/cli-launchers/main/Claude-Ollama-Launcher.ps1 | iex
```

**macOS (Terminal)**
```bash
# Codex + Ollama
curl -fsSL https://raw.githubusercontent.com/jlaiii/cli-launchers/main/Codex-Launcher.command | bash

# Claude + Ollama
curl -fsSL https://raw.githubusercontent.com/jlaiii/cli-launchers/main/Claude-Ollama-Launcher.command | bash
```

### Or download and run

1. **Download** the launcher you want for your OS:
   - [**Codex + Ollama Launcher**](https://jlaiii.github.io/cli-launchers/#download-codex) -- for OpenAI Codex CLI + Ollama
   - [**Claude + Ollama Launcher**](https://jlaiii.github.io/cli-launchers/#download-claude) -- for Claude Code + Ollama
2. **Run it**
   - **Windows:** Double-click the `.bat` file (or run it from Command Prompt / PowerShell)
   - **macOS:** Right-click the `.command` file and choose **Open** (required the first time because it was downloaded from the web), or run it from Terminal
3. Follow the on-screen menu -- install, update, pick a model, and launch

No terminal expertise required. Everything is self-contained inside the script.

---

## Codex + Ollama Launcher

**What it does:**
- Checks if Node.js / npm is installed (auto-installs via winget/MSI on Windows, or brew/pkg on macOS if missing)
- Checks if Codex CLI is installed (auto-installs/updates via `npm install -g @openai/codex`)
- Checks if Ollama is installed (auto-installs/updates via official install script)
- Checks for updates against npm (Codex) and GitHub releases (Ollama)
- Verifies Ollama sign-in status (`ollama list`)
- Lets you browse cloud/local models or enter one manually
- Auto-starts the Ollama server if it is not running
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
# Windows
Codex-Launcher.bat launch --model o4-mini
Codex-Launcher.bat launch --model kimi-k2.6:cloud -- --yolo
Codex-Launcher.bat --model gpt-4.1 --yolo

# macOS
./Codex-Launcher.command launch --model o4-mini
./Codex-Launcher.command launch --model kimi-k2.6:cloud -- --yolo
./Codex-Launcher.command --model gpt-4.1 --yolo
```

---

## Claude + Ollama Launcher

**What it does:**
- Checks if Claude Code is installed (auto-installs/updates via `claude.ai/install.ps1` on Windows or `claude.ai/install.sh` on macOS)
- Checks if Ollama is installed (auto-installs/updates via official install script)
- Checks for updates against npm (Claude Code) and GitHub releases (Ollama)
- Verifies Ollama sign-in status
- Lets you browse cloud/local models or enter one manually
- Auto-starts the Ollama server if it is not running
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

**Direct launch (skip the menu):**
```batch
# Windows
Claude-Ollama-Launcher.bat launch --model ollama/llama3

# macOS
./Claude-Ollama-Launcher.command launch --model ollama/llama3
```

---

## Requirements

- **Windows:** Windows 10/11 with PowerShell 5.1+
- **macOS:** macOS 11+ (Big Sur or later) with Terminal / bash / zsh
- Internet connection (for installs and model browsing)
- Ollama account (for cloud models like `kimi-k2.6:cloud`)

---

## Website

**[https://jlaiii.github.io/cli-launchers](https://jlaiii.github.io/cli-launchers)**

Visit the site for one-click downloads and a quick-setup guide.

---

## Notes

- The launchers auto-create `*.config.json` and `*.versions.json` files next to the script to remember your settings.
- If npm/ollama installs fail on Windows, try running the launcher as Administrator.
- On macOS, `.command` files downloaded from the web may require a right-click > Open the first time because of Gatekeeper.
- The `.bat` files are self-extracting -- they embed a full PowerShell script and clean up the temp file when done.
- The `.command` files are plain bash scripts that use `python3` (pre-installed on macOS) for JSON handling.

---

## License

MIT -- use, share, modify freely.
