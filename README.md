# CLI Launchers

Three launchers: **Codex CLI**, **Codex App**, and **Claude CLI**. Each is a single-file script that sets up and runs the AI coding assistant through [Ollama](https://ollama.com) or the [DeepSeek API](https://platform.deepseek.com) -- pick any provider and model from the built-in menu.

Instead of manually installing Node.js, npm, the CLI tools, and Ollama, then configuring models and launch flags, you download one file -- a `.bat` for Windows or a `.command` for macOS -- run it, and the launcher handles everything.

**Who is it for:** Developers on Windows or macOS who want to use cutting-edge AI CLI tools without spending time on setup, dependency hell, or keeping tools up to date. If you want to run Codex CLI, Codex App, or Claude CLI with any Ollama model or DeepSeek model -- this gets you there in one click.

## Quick Start

### One-liner (copy-paste into your terminal)

**Windows (PowerShell)**
```powershell
# Codex CLI
irm https://raw.githubusercontent.com/jlaiii/cli-launchers/main/Codex-Launcher.ps1 | iex

# Codex App
irm https://raw.githubusercontent.com/jlaiii/cli-launchers/main/Codex-App-Launcher.ps1 | iex

# Claude CLI
irm https://raw.githubusercontent.com/jlaiii/cli-launchers/main/Claude-Ollama-Launcher.ps1 | iex
```

**macOS (Terminal)**
```bash
# Codex CLI
curl -fsSL https://raw.githubusercontent.com/jlaiii/cli-launchers/main/Codex-Launcher.command | bash

# Codex App
curl -fsSL https://raw.githubusercontent.com/jlaiii/cli-launchers/main/Codex-App-Launcher.command | bash

# Claude CLI
curl -fsSL https://raw.githubusercontent.com/jlaiii/cli-launchers/main/Claude-Ollama-Launcher.command | bash
```

### Or download and run

1. **Download** the launcher you want for your OS:
   - [**Codex CLI Launcher**](https://jlaiii.github.io/cli-launchers/#download-codex) -- OpenAI Codex CLI + Ollama or DeepSeek
   - [**Codex App Launcher**](https://jlaiii.github.io/cli-launchers/#download-codex-app) -- OpenAI Codex App + Ollama or DeepSeek
   - [**Claude CLI Launcher**](https://jlaiii.github.io/cli-launchers/#download-claude) -- Anthropic Claude Code + Ollama or DeepSeek
2. **Run it**
   - **Windows:** Double-click the `.bat` file (or run it from Command Prompt / PowerShell)
   - **macOS:** Right-click the `.command` file and choose **Open** (required the first time because it was downloaded from the web), or run it from Terminal
3. Follow the on-screen menu -- install, update, pick a model, and launch

No terminal expertise required. Everything is self-contained inside the script.

---

## Codex CLI

Launches OpenAI Codex CLI through Ollama or directly via the DeepSeek API. Choose your provider and model from the built-in menu and switch anytime.

**What it does:**
- Checks if Node.js / npm is installed (auto-installs via winget/MSI on Windows, or brew/pkg on macOS if missing)
- Checks if Codex CLI is installed (auto-installs/updates via `npm install -g @openai/codex`)
- Checks if Ollama is installed (auto-installs/updates via official install script)
- Checks for updates against npm (Codex) and GitHub releases (Ollama)
- Verifies Ollama sign-in status (`ollama list`)
- Lets you browse cloud/local models or enter one manually
- Auto-starts the Ollama server if it is not running
- **Provider:** Ollama (cloud/local models) or DeepSeek API (bring your own key)
- With Ollama: launches `ollama launch codex --model <model> -- --yolo`
- With DeepSeek: launches `codex` directly using the DeepSeek API via `OPENAI_BASE_URL`

**Default config:**
- Provider: Ollama
- Model: `kimi-k2.6:cloud`
- Full-auto (`--yolo`): **ON**
- Source: cloud
- DeepSeek model: `deepseek-chat` (V4)

**Menu options:**
| # | Option |
|---|--------|
| 1 | Install / Update Codex CLI |
| 2 | Install / Update Ollama |
| 3 | Pick / Change Model (includes provider switch) |
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
# Windows — Ollama
Codex-Launcher.bat launch --model o4-mini
Codex-Launcher.bat launch --model kimi-k2.6:cloud -- --yolo
Codex-Launcher.bat --model gpt-4.1 --yolo

# macOS — Ollama
./Codex-Launcher.command launch --model o4-mini
./Codex-Launcher.command launch --model kimi-k2.6:cloud -- --yolo
./Codex-Launcher.command --model gpt-4.1 --yolo
```

To use the DeepSeek provider, switch via the menu first (option 3 → provider switch) to set your API key and model, then launch as usual.

---

## Codex App

Launches Codex App (the interactive TUI) through Ollama or directly via the DeepSeek API. Installs/updates Codex CLI alongside Ollama and lets you pick a provider and model from the built-in menu.

**What it does:**
- Checks if Node.js / npm is installed (auto-installs via winget/MSI on Windows, or brew/pkg on macOS if missing)
- Checks if Codex CLI is installed (auto-installs/updates via `npm install -g @openai/codex`)
- Checks if Ollama is installed (auto-installs/updates via official install script)
- Checks for updates against npm (Codex) and GitHub releases (Ollama)
- Verifies Ollama sign-in status (`ollama list`)
- Lets you browse cloud/local models or enter one manually
- Auto-starts the Ollama server if it is not running
- With Ollama: launches `ollama launch codex-app --model <model>`
- With DeepSeek: launches `codex-app` directly using the DeepSeek API via `OPENAI_API_KEY` and `OPENAI_BASE_URL`

**Provider options:**
- **Ollama** — use any Ollama cloud or local model
- **DeepSeek** — bring your own API key and connect directly to the DeepSeek API

**DeepSeek model options:**
- **DeepSeek V4 (Recommended)** — `deepseek-chat` — latest flagship chat model, best for general coding
- **DeepSeek R1 (Flash)** — `deepseek-reasoner` — fast reasoning model, best for complex logic
- **Manual entry** — type any DeepSeek model ID

**Menu options:**
| # | Option |
|---|--------|
| 1 | Install / Update Codex CLI |
| 2 | Install / Update Ollama |
| 3 | Pick / Change Provider & Model |
| 4 | Pull Ollama Model Locally |
| 5 | Set Custom Launch Arguments |
| 6 | Launch Codex App |
| C | Clear Version Cache |
| Q | Quit |

**Direct launch (skip the menu):**
```batch
# Windows
Codex-App-Launcher.bat launch
Codex-App-Launcher.bat launch --model o4-mini

# macOS
./Codex-App-Launcher.command launch
./Codex-App-Launcher.command launch --model o4-mini
```

To use DeepSeek, switch the provider from the menu first to set your API key, then launch.

---

## Claude CLI

Launches Anthropic Claude Code through Ollama or directly via the DeepSeek API. Choose your provider and model from the built-in menu and switch anytime.

**What it does:**
- Checks if Claude Code is installed (auto-installs/updates via `claude.ai/install.ps1` on Windows or `claude.ai/install.sh` on macOS)
- Checks if Ollama is installed (auto-installs/updates via official install script)
- Checks for updates against npm (Claude Code) and GitHub releases (Ollama)
- Verifies Ollama sign-in status
- Lets you browse cloud/local models or enter one manually
- Auto-starts the Ollama server if it is not running
- With Ollama: launches `ollama launch claude --model <model> -- --dangerously-skip-permissions`
- With DeepSeek: launches `claude` directly using the DeepSeek API via `OPENAI_API_KEY` and `OPENAI_BASE_URL`

**Default config:**
- Provider: Ollama
- Model: `kimi-k2.6:cloud`
- Skip permissions: **ON**
- Source: cloud
- DeepSeek model: `deepseek-chat` (V4)

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
| 8 | Switch Provider (Ollama / DeepSeek) |
| C | Set Custom Launch Command |
| T | Toggle Permission Bypass |
| Q | Quit |

**Direct launch (skip the menu):**
```batch
# Windows — Ollama
Claude-Ollama-Launcher.bat launch --model ollama/llama3

# macOS — Ollama
./Claude-Ollama-Launcher.command launch --model ollama/llama3
```

To use the DeepSeek provider, switch via the menu first (option 8) to set your API key and model, then launch as usual.

---

## Requirements

- **Windows:** Windows 10/11 with PowerShell 5.1+
- **macOS:** macOS 11+ (Big Sur or later) with Terminal / bash / zsh
- Internet connection (for installs and model browsing)
- Ollama account (for cloud models like `kimi-k2.6:cloud`)
- **DeepSeek API key** (required only when using the DeepSeek provider — get one at [platform.deepseek.com/api_keys](https://platform.deepseek.com/api_keys))

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
- When using the DeepSeek provider, your API key is stored locally in the launcher's config file and is only used to set `OPENAI_API_KEY` at launch time.

---

## License

MIT -- use, share, modify freely.
