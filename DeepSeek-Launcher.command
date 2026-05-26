#!/usr/bin/env bash
set -euo pipefail

# ============================================================
#  DeepSeek CLI Launcher for macOS
#  Codex CLI + Claude Code + Codex App through DeepSeek API
#  Interactive menu + direct launch with model picker.
# ============================================================

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/local/sbin:$PATH"

if [[ ! -t 0 ]] && [[ -e /dev/tty ]]; then
    exec < /dev/tty
fi

if ! command -v python3 &>/dev/null; then
    echo "ERROR: python3 required. Install Xcode CLI tools: xcode-select --install"
    exit 1
fi

# Resolve script/config directory
if [[ "$0" == "bash" || "$0" == "-bash" || "$0" == "sh" || "$0" == "-sh" || "$0" == "" ]]; then
    SCRIPT_DIR="$HOME/.cli-launchers"
    mkdir -p "$SCRIPT_DIR"
else
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
fi

CONFIG_FILE="$SCRIPT_DIR/DeepSeek-Launcher.config.json"
VERSION_CACHE="$SCRIPT_DIR/DeepSeek-Launcher.versions.json"
CACHE_TTL_MINUTES=60

DEFAULT_MODEL="deepseek-v4-pro"
DEFAULT_KEY=""
DEFAULT_SKIPPERMS="true"

# --- Colors ---
CLR_RESET='\033[0m'; CLR_RED='\033[1;31m'; CLR_GREEN='\033[1;32m'
CLR_YELLOW='\033[1;33m'; CLR_CYAN='\033[1;36m'; CLR_MAGENTA='\033[1;35m'
CLR_WHITE='\033[1;37m'; CLR_GRAY='\033[0;37m'

lc() { echo "$1" | tr '[:upper:]' '[:lower:]'; }
ask() { printf -v "$2" '%s' ''; read -rp "$1" "$2" || true; }

# --- JSON Helpers ---
json_read() {
    local file="$1" key="$2" default="${3:-}"
    [[ ! -f "$file" ]] && echo "$default" && return
    python3 -c "import json,sys
try:
 with open('$file') as f: d=json.load(f)
 v=d.get('$key'); print(v if v is not None else '$default')
except: print('$default')" 2>/dev/null || echo "$default"
}

config_get() { json_read "$CONFIG_FILE" "$1" "$2"; }
config_set() {
    local key="$1" val="$2"
    python3 -c "import json,os
d={}
if os.path.exists('$CONFIG_FILE'):
 try:
  with open('$CONFIG_FILE') as f: d=json.load(f)
 except: d={}
d['$key']='$val'
with open('$CONFIG_FILE','w') as f: json.dump(d,f,indent=2)" 2>/dev/null
}

cache_get() { json_read "$VERSION_CACHE" "$1" "$2"; }
cache_set() {
    local key="$1" val="$2"
    python3 -c "import json,os
d={}
if os.path.exists('$VERSION_CACHE'):
 try:
  with open('$VERSION_CACHE') as f: d=json.load(f)
 except: d={}
d['$key']='$val'
with open('$VERSION_CACHE','w') as f: json.dump(d,f,indent=2)" 2>/dev/null
}

ensure_config() {
    [[ -f "$CONFIG_FILE" ]] && return
    python3 -c "import json
d={'deepseekModel':'$DEFAULT_MODEL','deepseekApiKey':'$DEFAULT_KEY','skipPermissions':True}
with open('$CONFIG_FILE','w') as f: json.dump(d,f,indent=2)" 2>/dev/null
}

cache_stale() {
    local last="$1"
    [[ -z "$last" ]] && return 0
    python3 -c "import datetime
try:
 t=datetime.datetime.fromisoformat('$last'.replace('Z','+00:00'))
 delta=datetime.datetime.now(t.tzinfo)-t
 print('1' if delta.total_seconds()>$CACHE_TTL_MINUTES*60 else '0')
except: print('1')" 2>/dev/null | grep -q '1'
}

version_greater() {
    local inst="$1" lat="$2"
    [[ -z "$inst" || -z "$lat" ]] && return 1
    python3 -c "import sys
try: from packaging.version import Version as V
except: from distutils.version import LooseVersion as V
print('1' if V('$lat')>V('$inst') else '0')" 2>/dev/null | grep -q '1'
}

# --- Version Checkers ---
get_codex_version() {
    command -v codex &>/dev/null || return
    local ver; ver=$(codex --version 2>/dev/null || true)
    [[ "$ver" =~ ([0-9]+\.[0-9]+\.[0-9]+) ]] && echo "${BASH_REMATCH[1]}" || echo ""
}

get_codex_latest() {
    local last; last=$(cache_get "codexLastChecked" "")
    cache_stale "$last" || { cache_get "codexLatestVersion" ""; return; }
    local resp; resp=$(curl -fsSL --max-time 15 "https://registry.npmjs.org/@openai/codex/latest" 2>/dev/null || true)
    [[ -z "$resp" ]] && return
    local ver; ver=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('version',''))" 2>/dev/null || true)
    [[ -n "$ver" ]] || return
    cache_set "codexLatestVersion" "$ver"
    cache_set "codexLastChecked" "$(python3 -c 'import datetime; print(datetime.datetime.now().isoformat())')"
    echo "$ver"
}

get_claude_version() {
    command -v claude &>/dev/null || return
    local ver; ver=$(claude --version 2>/dev/null || true)
    [[ "$ver" =~ ([0-9]+\.[0-9]+\.[0-9]+) ]] && echo "${BASH_REMATCH[1]}" || echo ""
}

get_claude_latest() {
    local last; last=$(cache_get "claudeLastChecked" "")
    cache_stale "$last" || { cache_get "claudeLatestVersion" ""; return; }
    local resp; resp=$(curl -fsSL --max-time 15 "https://registry.npmjs.org/@anthropic-ai/claude-code/latest" 2>/dev/null || true)
    [[ -z "$resp" ]] && return
    local ver; ver=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('version',''))" 2>/dev/null || true)
    [[ -n "$ver" ]] || return
    cache_set "claudeLatestVersion" "$ver"
    cache_set "claudeLastChecked" "$(python3 -c 'import datetime; print(datetime.datetime.now().isoformat())')"
    echo "$ver"
}

# --- Installers ---
install_codex() {
    if ! command -v npm &>/dev/null; then
        echo -e "${CLR_YELLOW}Node.js/npm required.${CLR_RESET}"
        ask "Install Node.js via Homebrew? (y/n) " ans
        [[ "$(lc "$ans")" != "y" ]] && return
        command -v brew &>/dev/null || { echo -e "${CLR_RED}Homebrew not found. Install from https://brew.sh${CLR_RESET}"; return; }
        brew install node 2>/dev/null || { echo -e "${CLR_RED}Failed.${CLR_RESET}"; return; }
    fi
    echo -e "${CLR_CYAN}Installing Codex CLI via npm...${CLR_RESET}"
    npm install -g @openai/codex 2>/dev/null && echo -e "${CLR_GREEN}Done.${CLR_RESET}" || echo -e "${CLR_RED}Failed.${CLR_RESET}"
    read -rp "Press Enter" || true
}

install_claude() {
    echo -e "${CLR_CYAN}Installing/Updating Claude Code...${CLR_RESET}"
    curl -fsSL https://claude.ai/install.sh | sh 2>/dev/null && echo -e "${CLR_GREEN}Done.${CLR_RESET}" || echo -e "${CLR_RED}Failed.${CLR_RESET}"
    read -rp "Press Enter" || true
}

# --- DeepSeek Config ---
set_api_key() {
    clear
    echo -e "${CLR_GREEN}=============================================${CLR_RESET}"
    echo -e "${CLR_GREEN}   Set DeepSeek API Key${CLR_RESET}"
    echo -e "${CLR_GREEN}=============================================${CLR_RESET}"
    echo ""
    local current; current=$(config_get "deepseekApiKey" "$DEFAULT_KEY")
    if [[ -n "$current" ]]; then
        echo -e "${CLR_CYAN}Current: ${current:0:4}****${CLR_RESET}"
    else
        echo -e "${CLR_YELLOW}No API key set.${CLR_RESET}"
    fi
    echo ""
    echo -e "${CLR_CYAN}Get your key at: https://platform.deepseek.com/api_keys${CLR_RESET}"
    echo ""
    ask "Enter DeepSeek API key (or blank to keep current): " newKey
    [[ -n "$newKey" ]] && { config_set "deepseekApiKey" "$newKey"; echo -e "${CLR_GREEN}Saved.${CLR_RESET}"; } || echo -e "${CLR_GRAY}Unchanged.${CLR_RESET}"
    sleep 1
}

show_model_picker() {
    while true; do
        clear
        echo -e "${CLR_GREEN}=============================================${CLR_RESET}"
        echo -e "${CLR_GREEN}   DeepSeek Model Selection${CLR_RESET}"
        echo -e "${CLR_GREEN}=============================================${CLR_RESET}"
        echo ""
        echo -e "Current: ${CLR_CYAN}$(config_get 'deepseekModel' "$DEFAULT_MODEL")${CLR_RESET}"
        echo ""
        echo -e "  [1] DeepSeek V4 Pro (Recommended)  deepseek-v4-pro"
        echo -e "  [2] DeepSeek V4 Flash               deepseek-v4-flash"
        echo -e "  [M] Manual entry"
        echo -e "  [K] Set API Key"
        echo -e "  [B] Back"
        echo ""
        ask "Enter choice: " choice
        case "$(lc "$choice")" in
            1) config_set "deepseekModel" "deepseek-v4-pro"; echo -e "${CLR_GREEN}Selected: deepseek-v4-pro (V4 Pro)${CLR_RESET}"; sleep 1; return ;;
            2) config_set "deepseekModel" "deepseek-v4-flash"; echo -e "${CLR_GREEN}Selected: deepseek-v4-flash (Flash)${CLR_RESET}"; sleep 1; return ;;
            m) ask "Enter model ID: " m; [[ -n "$m" ]] && { config_set "deepseekModel" "$m"; echo -e "${CLR_GREEN}Model: $m${CLR_RESET}"; read -rp "Press Enter" || true; }; return ;;
            k) set_api_key ;;
            b) return ;;
        esac
    done
}

# --- Launch ---
require_key() {
    local k; k=$(config_get "deepseekApiKey" "$DEFAULT_KEY")
    [[ -n "$k" ]] && return 0
    echo -e "${CLR_RED}ERROR: DeepSeek API key not set. Use option 4.${CLR_RESET}"
    read -rp "Press Enter" || true
    return 1
}

launch_codex_cli() {
    require_key || return
    command -v codex &>/dev/null || { echo -e "${CLR_YELLOW}Codex CLI not installed.${CLR_RESET}"; ask "Install? (y/n) " a; [[ "$(lc "$a")" == "y" ]] && install_codex || return; }
    local model; model=$(config_get "deepseekModel" "$DEFAULT_MODEL")
    export OPENAI_API_KEY="$(config_get 'deepseekApiKey' "$DEFAULT_KEY")"
    export OPENAI_BASE_URL="https://api.deepseek.com/v1"
    local -a cmd=("codex")
    [[ "$(config_get 'skipPermissions' "$DEFAULT_SKIPPERMS")" == "True" ]] && cmd+=("--yolo")
    clear
    echo -e "\n${CLR_GREEN}>>> ${cmd[*]} (DeepSeek: $model)${CLR_RESET}"
    "${cmd[@]}" || echo -e "${CLR_YELLOW}Codex exited with non-zero code.${CLR_RESET}"
    read -rp "Session ended. Press Enter" || true
}

launch_claude_code() {
    require_key || return
    local model; model=$(config_get "deepseekModel" "$DEFAULT_MODEL")
    export ANTHROPIC_BASE_URL="https://api.deepseek.com/anthropic"
    export ANTHROPIC_API_KEY="$(config_get 'deepseekApiKey' "$DEFAULT_KEY")"
    local -a cmd=("claude")
    [[ "$(config_get 'skipPermissions' "$DEFAULT_SKIPPERMS")" == "True" ]] && cmd+=("--dangerously-skip-permissions")
    clear
    echo -e "\n${CLR_GREEN}>>> ${cmd[*]} (DeepSeek: $model)${CLR_RESET}"
    "${cmd[@]}" || echo -e "${CLR_YELLOW}Claude Code exited with non-zero code.${CLR_RESET}"
    read -rp "Session ended. Press Enter" || true
}

launch_codex_app() {
    require_key || return
    command -v codex &>/dev/null || { echo -e "${CLR_YELLOW}Codex CLI not installed.${CLR_RESET}"; ask "Install? (y/n) " a; [[ "$(lc "$a")" == "y" ]] && install_codex || return; }
    local model; model=$(config_get "deepseekModel" "$DEFAULT_MODEL")
    local codexHome="$HOME/.codex"
    mkdir -p "$codexHome"
    local profileFile="$codexHome/cli-launcher-deepseek.config.toml"
    cat > "$profileFile" << TOML
model = "$model"
model_provider = "deepseek"
wire_api = "chat"

[model_providers.deepseek]
name = "DeepSeek"
base_url = "https://api.deepseek.com/v1"
env_key = "DEEPSEEK_API_KEY"
TOML
    export DEEPSEEK_API_KEY="$(config_get 'deepseekApiKey' "$DEFAULT_KEY")"
    local -a cmd=("codex" "app" "--profile" "cli-launcher-deepseek")
    clear
    echo -e "\n${CLR_GREEN}>>> ${cmd[*]} (DeepSeek: $model)${CLR_RESET}"
    "${cmd[@]}" || echo -e "${CLR_YELLOW}Codex App exited with non-zero code.${CLR_RESET}"
    rm -f "$profileFile"
    read -rp "Session ended. Press Enter" || true
}

# --- Status & Menu ---
show_status() {
    local cCodex="NO"; command -v codex &>/dev/null && cCodex="YES"
    local cClaude="NO"; command -v claude &>/dev/null && cClaude="YES"
    local model keyStatus
    model=$(config_get "deepseekModel" "$DEFAULT_MODEL")
    [[ -n "$(config_get 'deepseekApiKey' "$DEFAULT_KEY")" ]] && keyStatus="${CLR_GREEN}SET${CLR_RESET}" || keyStatus="${CLR_RED}NOT SET${CLR_RESET}"

    echo -e "\n${CLR_CYAN}========== DeepSeek CLI Launcher ==========${CLR_RESET}"
    if [[ "$cCodex" == "YES" ]]; then
        local ci cl; ci=$(get_codex_version); cl=$(get_codex_latest)
        if [[ -n "$ci" && -n "$cl" ]] && version_greater "$ci" "$cl"; then
            echo -e "  Codex CLI     : ${CLR_YELLOW}v$ci (update v$cl available)${CLR_RESET}"
        else
            echo -e "  Codex CLI     : ${CLR_GREEN}v$ci (up to date)${CLR_RESET}"
        fi
    else
        echo -e "  Codex CLI     : ${CLR_GRAY}NOT INSTALLED${CLR_RESET}"
    fi
    if [[ "$cClaude" == "YES" ]]; then
        local ci cl; ci=$(get_claude_version); cl=$(get_claude_latest)
        if [[ -n "$ci" && -n "$cl" ]] && version_greater "$ci" "$cl"; then
            echo -e "  Claude Code   : ${CLR_YELLOW}v$ci (update v$cl available)${CLR_RESET}"
        else
            echo -e "  Claude Code   : ${CLR_GREEN}v$ci (up to date)${CLR_RESET}"
        fi
    else
        echo -e "  Claude Code   : ${CLR_GRAY}NOT INSTALLED${CLR_RESET}"
    fi
    echo -e "  DeepSeek Model: ${CLR_CYAN}$model${CLR_RESET}"
    echo -e "  DeepSeek Key  : $keyStatus"
    local permText
    [[ "$(config_get 'skipPermissions' "$DEFAULT_SKIPPERMS")" == "True" ]] && permText="ON" || permText="OFF"
    echo -e "  Skip-perms    : ${CLR_CYAN}$permText${CLR_RESET}"
    echo -e "${CLR_CYAN}==========================================${CLR_RESET}"
}

show_main_menu() {
    clear
    show_status
    local cCodex="NO"; command -v codex &>/dev/null && cCodex="YES"
    local cClaude="NO"; command -v claude &>/dev/null && cClaude="YES"
    local hasKey=0; [[ -n "$(config_get 'deepseekApiKey' "$DEFAULT_KEY")" ]] && hasKey=1

    echo -e "\n[1] Install / Update Codex CLI ${CLR_WHITE}"
    [[ "$cCodex" == "YES" ]] && {
        local ci cl; ci=$(get_codex_version); cl=$(get_codex_latest)
        [[ -n "$ci" && -n "$cl" ]] && version_greater "$ci" "$cl" && echo -e "${CLR_YELLOW}     ^^ UPDATE AVAILABLE${CLR_RESET}"
    }
    echo -e "[2] Install / Update Claude Code ${CLR_WHITE}"
    [[ "$cClaude" == "YES" ]] && {
        local ci cl; ci=$(get_claude_version); cl=$(get_claude_latest)
        [[ -n "$ci" && -n "$cl" ]] && version_greater "$ci" "$cl" && echo -e "${CLR_YELLOW}     ^^ UPDATE AVAILABLE${CLR_RESET}"
    }
    echo -e "[3] Pick DeepSeek Model [current: $(config_get 'deepseekModel' "$DEFAULT_MODEL")] ${CLR_WHITE}"
    echo -e "[4] Set DeepSeek API Key ${CLR_WHITE}"
    [[ "$cCodex" == "YES" && "$hasKey" == "1" ]] && echo -e "[5] Launch Codex CLI (via DeepSeek) ${CLR_GREEN}" || echo -e "[5] Launch Codex CLI [not available] ${CLR_GRAY}"
    [[ "$cClaude" == "YES" && "$hasKey" == "1" ]] && echo -e "[6] Launch Claude Code (via DeepSeek) ${CLR_GREEN}" || echo -e "[6] Launch Claude Code [not available] ${CLR_GRAY}"
    [[ "$cCodex" == "YES" && "$hasKey" == "1" ]] && echo -e "[7] Launch Codex App (via DeepSeek) ${CLR_GREEN}" || echo -e "[7] Launch Codex App [not available] ${CLR_GRAY}"
    echo -e "[C] Clear Version Cache ${CLR_WHITE}"
    local permText
    [[ "$(config_get 'skipPermissions' "$DEFAULT_SKIPPERMS")" == "True" ]] && permText="ON" || permText="OFF"
    echo -e "[T] Toggle Permission Bypass [currently: $permText] ${CLR_WHITE}"
    echo -e "[Q] Quit ${CLR_MAGENTA}"
    echo ""
}

# --- Main ---
ensure_config

if [[ $# -gt 0 ]]; then
    local k; k=$(config_get "deepseekApiKey" "$DEFAULT_KEY")
    [[ -z "$k" ]] && { echo -e "${CLR_RED}DeepSeek API key not set. Run launcher to configure.${CLR_RESET}"; exit 1; }
    case "$(lc "$1")" in
        codex)     launch_codex_cli; exit $? ;;
        claude)    launch_claude_code; exit $? ;;
        codex-app) launch_codex_app; exit $? ;;
    esac
fi

while true; do
    show_main_menu
    ask "Enter choice: " choice
    case "$(lc "$choice")" in
        1)
            if command -v codex &>/dev/null; then
                local ci cl; ci=$(get_codex_version); cl=$(get_codex_latest)
                [[ -n "$ci" && -n "$cl" ]] && version_greater "$ci" "$cl" && {
                    echo -e "${CLR_YELLOW}Codex update: v$ci -> v$cl${CLR_RESET}"
                    ask "Update now? (y/n) " ans; [[ "$(lc "$ans")" == "y" ]] && install_codex
                } || { ask "Codex is up to date. Reinstall? (y/n) " ans; [[ "$(lc "$ans")" == "y" ]] && install_codex; }
            else
                ask "Install Codex CLI now? (y/n) " ans; [[ "$(lc "$ans")" == "y" ]] && install_codex
            fi
            read -rp "Press Enter" || true
            ;;
        2)
            if command -v claude &>/dev/null; then
                local ci cl; ci=$(get_claude_version); cl=$(get_claude_latest)
                [[ -n "$ci" && -n "$cl" ]] && version_greater "$ci" "$cl" && {
                    echo -e "${CLR_YELLOW}Claude Code update: v$ci -> v$cl${CLR_RESET}"
                    ask "Update now? (y/n) " ans; [[ "$(lc "$ans")" == "y" ]] && install_claude
                } || { ask "Claude Code is up to date. Reinstall? (y/n) " ans; [[ "$(lc "$ans")" == "y" ]] && install_claude; }
            else
                ask "Install Claude Code now? (y/n) " ans; [[ "$(lc "$ans")" == "y" ]] && install_claude
            fi
            read -rp "Press Enter" || true
            ;;
        3) show_model_picker ;;
        4) set_api_key ;;
        5) launch_codex_cli ;;
        6) launch_claude_code ;;
        7) launch_codex_app ;;
        c)
            cache_set "codexLastChecked" ""; cache_set "claudeLastChecked" ""
            echo -e "${CLR_GREEN}Version cache cleared.${CLR_RESET}"; sleep 1
            ;;
        t)
            local sp; sp=$(config_get "skipPermissions" "$DEFAULT_SKIPPERMS")
            [[ "$sp" == "True" ]] && config_set "skipPermissions" "False" || config_set "skipPermissions" "True"
            [[ "$(config_get 'skipPermissions' "$DEFAULT_SKIPPERMS")" == "True" ]] && echo -e "${CLR_GREEN}Mode: SKIP-PERMISSIONS${CLR_RESET}" || echo -e "${CLR_GREEN}Mode: NORMAL${CLR_RESET}"
            sleep 1
            ;;
        q) echo -e "${CLR_GREEN}Goodbye!${CLR_RESET}"; exit 0 ;;
        *) echo -e "${CLR_RED}Invalid choice.${CLR_RESET}"; sleep 1 ;;
    esac
done
