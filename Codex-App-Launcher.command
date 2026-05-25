#!/usr/bin/env bash
set -euo pipefail

# ============================================================
#  Codex App Launcher for macOS
#  Interactive menu + direct launch for Codex App
#  through Ollama or DeepSeek API with model picker.
# ============================================================

# macOS PATH often misses Homebrew bins when opened via double-click
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/local/sbin:$PATH"

# If piped (curl | bash), re-attach stdin to the terminal so read works
if [[ ! -t 0 ]] && [[ -e /dev/tty ]]; then
    exec < /dev/tty
fi

# Check python3 is available (used for JSON persistence)
if ! command -v python3 &>/dev/null; then
    echo "ERROR: python3 is required but not found."
    echo "Install Xcode Command Line Tools:  xcode-select --install"
    exit 1
fi

# Resolve script/config directory
if [[ "$0" == "bash" || "$0" == "-bash" || "$0" == "sh" || "$0" == "-sh" || "$0" == "" ]]; then
    SCRIPT_DIR="$HOME/.cli-launchers"
    mkdir -p "$SCRIPT_DIR"
else
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
fi

CONFIG_FILE="$SCRIPT_DIR/Codex-App-Launcher.config.json"
VERSION_CACHE="$SCRIPT_DIR/Codex-App-Launcher.versions.json"
CACHE_TTL_MINUTES=60

# --- Defaults ---
DEFAULT_PROVIDER="ollama"
DEFAULT_OLLAMA_MODEL="kimi-k2.6:cloud"
DEFAULT_SOURCE="cloud"
DEFAULT_DEEPSEEK_MODEL="deepseek-chat"
DEFAULT_DEEPSEEK_KEY=""
DEFAULT_CUSTOMARGS=""
DEFAULT_AUTOUPDATE="false"
DEFAULT_SKIPUPDATE="false"

# --- Colors ---
CLR_RESET='\033[0m'
CLR_RED='\033[1;31m'
CLR_GREEN='\033[1;32m'
CLR_YELLOW='\033[1;33m'
CLR_CYAN='\033[1;36m'
CLR_MAGENTA='\033[1;35m'
CLR_WHITE='\033[1;37m'
CLR_GRAY='\033[0;37m'

# --- Lowercase helper (bash 3.2 compatible) ---
lc() { echo "$1" | tr '[:upper:]' '[:lower:]'; }

# --- Safe read helper ---
ask() {
    printf -v "$2" '%s' ''
    read -rp "$1" "$2" || true
}

# ============================================================
#  JSON Helpers
# ============================================================
function json_read() {
    local file="$1" key="$2" default="${3:-}"
    if [[ ! -f "$file" ]]; then echo "$default"; return; fi
    python3 -c "
import json, sys
try:
    with open('$file') as f: d=json.load(f)
    v=d.get('$key')
    print(v if v is not None else '$default')
except: print('$default')
" 2>/dev/null || echo "$default"
}

function config_get() { json_read "$CONFIG_FILE" "$1" "$2"; }
function config_set() {
    local key="$1" val="$2"
    python3 -c "
import json, os
d={}
if os.path.exists('$CONFIG_FILE'):
    try:
        with open('$CONFIG_FILE') as f: d=json.load(f)
    except: d={}
d['$key']='$val'
with open('$CONFIG_FILE','w') as f: json.dump(d,f,indent=2)
" 2>/dev/null
}

function cache_get() { json_read "$VERSION_CACHE" "$1" "$2"; }
function cache_set() {
    local key="$1" val="$2"
    python3 -c "
import json, os
d={}
if os.path.exists('$VERSION_CACHE'):
    try:
        with open('$VERSION_CACHE') as f: d=json.load(f)
    except: d={}
d['$key']='$val'
with open('$VERSION_CACHE','w') as f: json.dump(d,f,indent=2)
" 2>/dev/null
}

function ensure_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        python3 -c "
import json
d={'provider':'$DEFAULT_PROVIDER','ollamaModel':'$DEFAULT_OLLAMA_MODEL','source':'$DEFAULT_SOURCE','deepseekModel':'$DEFAULT_DEEPSEEK_MODEL','deepseekApiKey':'','customArgs':'','autoUpdate':False,'skipUpdateCheck':False}
with open('$CONFIG_FILE','w') as f: json.dump(d,f,indent=2)
" 2>/dev/null
    else
        local missing=0
        for key in provider ollamaModel source deepseekModel deepseekApiKey customArgs autoUpdate skipUpdateCheck; do
            local val
            val=$(json_read "$CONFIG_FILE" "$key" "__MISSING__")
            if [[ "$val" == "__MISSING__" ]]; then missing=1; fi
        done
        if [[ "$missing" == "1" ]]; then
            python3 -c "
import json, os
d={'provider':'$DEFAULT_PROVIDER','ollamaModel':'$DEFAULT_OLLAMA_MODEL','source':'$DEFAULT_SOURCE','deepseekModel':'$DEFAULT_DEEPSEEK_MODEL','deepseekApiKey':'','customArgs':'','autoUpdate':False,'skipUpdateCheck':False}
if os.path.exists('$CONFIG_FILE'):
    try:
        with open('$CONFIG_FILE') as f: old=json.load(f)
        for k,v in d.items():
            if k not in old: old[k]=v
        d=old
    except: pass
with open('$CONFIG_FILE','w') as f: json.dump(d,f,indent=2)
" 2>/dev/null
        fi
    fi
}

function ensure_cache() {
    if [[ ! -f "$VERSION_CACHE" ]]; then
        python3 -c "
import json
d={'codexLatestVersion':'','codexLastChecked':'','ollamaLatestVersion':'','ollamaLastChecked':''}
with open('$VERSION_CACHE','w') as f: json.dump(d,f,indent=2)
" 2>/dev/null
    fi
}

function cache_stale() {
    local last="$1"
    [[ -z "$last" ]] && return 0
    python3 -c "
import datetime
try:
    t=datetime.datetime.fromisoformat('$last'.replace('Z','+00:00'))
    delta=datetime.datetime.now(t.tzinfo)-t
    print('1' if delta.total_seconds()>$CACHE_TTL_MINUTES*60 else '0')
except: print('1')
" 2>/dev/null | grep -q '1'
}

# ============================================================
#  Version Checkers
# ============================================================
function get_codex_installed_version() {
    if ! command -v codex &>/dev/null; then echo ""; return; fi
    local ver
    ver=$(codex --version 2>/dev/null || true)
    [[ -z "$ver" ]] && echo "" && return
    if [[ "$ver" =~ ([0-9]+\.[0-9]+\.[0-9]+) ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "$ver" | tr -d '\n'
    fi
}

function get_codex_latest_version() {
    local last
    last=$(cache_get "codexLastChecked" "")
    if ! cache_stale "$last"; then
        cache_get "codexLatestVersion" ""
        return
    fi
    local resp
    resp=$(curl -fsSL --max-time 15 "https://registry.npmjs.org/@openai/codex/latest" 2>/dev/null || true)
    [[ -z "$resp" ]] && echo "" && return
    local ver
    ver=$(echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('version',''))" 2>/dev/null || true)
    if [[ -n "$ver" ]]; then
        cache_set "codexLatestVersion" "$ver"
        cache_set "codexLastChecked" "$(python3 -c 'import datetime; print(datetime.datetime.now().isoformat())')"
    fi
    echo "$ver"
}

function get_ollama_installed_version() {
    if ! command -v ollama &>/dev/null; then echo ""; return; fi
    local ver
    ver=$(ollama --version 2>/dev/null || true)
    [[ -z "$ver" ]] && echo "" && return
    if [[ "$ver" =~ ([0-9]+\.[0-9]+\.[0-9]+) ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo ""
    fi
}

function get_ollama_latest_version() {
    local last
    last=$(cache_get "ollamaLastChecked" "")
    if ! cache_stale "$last"; then
        cache_get "ollamaLatestVersion" ""
        return
    fi
    local resp
    resp=$(curl -fsSL --max-time 15 "https://api.github.com/repos/ollama/ollama/releases/latest" 2>/dev/null || true)
    [[ -z "$resp" ]] && echo "" && return
    local tag
    tag=$(echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tag_name',''))" 2>/dev/null || true)
    local ver="${tag#v}"
    if [[ -n "$ver" ]]; then
        cache_set "ollamaLatestVersion" "$ver"
        cache_set "ollamaLastChecked" "$(python3 -c 'import datetime; print(datetime.datetime.now().isoformat())')"
    fi
    echo "$ver"
}

function version_greater() {
    local inst="$1" lat="$2"
    [[ -z "$inst" || -z "$lat" ]] && return 1
    python3 -c "
import sys
try:
    from packaging.version import Version as V
except:
    from distutils.version import LooseVersion as V
print('1' if V('$lat')>V('$inst') else '0')
" 2>/dev/null | grep -q '1'
}

# ============================================================
#  Installers
# ============================================================
function install_nodejs() {
    if command -v brew &>/dev/null; then
        echo -e "${CLR_CYAN}Installing Node.js via Homebrew...${CLR_RESET}"
        if brew install node 2>/dev/null; then
            echo -e "${CLR_GREEN}Node.js installed via brew.${CLR_RESET}"
            return 0
        fi
    fi
    echo -e "${CLR_CYAN}Downloading Node.js LTS installer...${CLR_RESET}"
    local index url ver pkg
    index=$(curl -fsSL --max-time 30 "https://nodejs.org/download/release/index.json" 2>/dev/null || true)
    [[ -z "$index" ]] && { echo -e "${CLR_RED}Failed to fetch Node.js versions. Please install manually from https://nodejs.org${CLR_RESET}"; return 1; }
    ver=$(echo "$index" | python3 -c "
import sys,json
arr=json.load(sys.stdin)
for x in arr:
    if x.get('lts') and x['lts'] not in (False,''): print(x['version']); break
else: print(arr[0]['version'] if arr else '')
" 2>/dev/null || true)
    [[ -z "$ver" ]] && { echo -e "${CLR_RED}Could not determine Node.js LTS version.${CLR_RESET}"; return 1; }
    url="https://nodejs.org/dist/$ver/node-$ver.pkg"
    pkg="/tmp/node-installer.pkg"
    if curl -fsSL --max-time 120 "$url" -o "$pkg" 2>/dev/null; then
        echo -e "${CLR_CYAN}Running Node.js installer... (may prompt for password)${CLR_RESET}"
        sudo installer -pkg "$pkg" -target / 2>/dev/null || { echo -e "${CLR_RED}PKG install failed.${CLR_RESET}"; return 1; }
        rm -f "$pkg"
        export PATH="/usr/local/bin:$PATH"
        if command -v npm &>/dev/null; then
            echo -e "${CLR_GREEN}Node.js installed successfully!${CLR_RESET}"
            return 0
        fi
    fi
    echo -e "${CLR_RED}Failed to auto-install Node.js. Please install manually from https://nodejs.org${CLR_RESET}"
    return 1
}

function install_codex_cli() {
    if ! command -v npm &>/dev/null; then
        echo -e "${CLR_YELLOW}Node.js / npm not found.${CLR_RESET}"
        ask "Install Node.js automatically? (y/n) " ans
        [[ "$(lc "$ans")" != "y" ]] && return 1
        install_nodejs || return 1
    fi
    echo -e "${CLR_CYAN}Installing / Updating Codex CLI via npm...${CLR_RESET}"
    if npm install -g @openai/codex 2>/dev/null; then
        if command -v codex &>/dev/null; then
            local ver
            ver=$(get_codex_installed_version)
            echo -e "${CLR_GREEN}Codex CLI installed / updated! Version: $ver${CLR_RESET}"
            return 0
        else
            echo -e "${CLR_YELLOW}Codex CLI command not found after install. Try restarting the launcher.${CLR_RESET}"
            return 1
        fi
    else
        echo -e "${CLR_RED}npm install failed. Try running with sudo or check permissions.${CLR_RESET}"
        return 1
    fi
}

function install_ollama() {
    echo -e "${CLR_CYAN}Installing / Updating Ollama...${CLR_RESET}"
    if curl -fsSL https://ollama.com/install.sh | sh 2>/dev/null; then
        echo -e "${CLR_GREEN}Ollama installation completed.${CLR_RESET}"
    else
        echo -e "${CLR_RED}ERROR installing Ollama. Visit https://ollama.com for manual instructions.${CLR_RESET}"
    fi
    read -rp "Press Enter to continue" || true
}

# ============================================================
#  Ollama Server Helpers
# ============================================================
function test_ollama_running() {
    curl -fsSL --max-time 3 "http://localhost:11434/api/tags" &>/dev/null && return 0 || return 1
}

function start_ollama_server() {
    test_ollama_running && return 0
    echo -e "${CLR_YELLOW}Starting Ollama server in background...${CLR_RESET}"
    nohup ollama serve &>/dev/null &
    local tries=0
    while [[ $tries -lt 30 ]]; do
        sleep 0.5
        if test_ollama_running; then
            echo -e "${CLR_GREEN}Ollama server is ready.${CLR_RESET}"
            return 0
        fi
        ((tries++))
    done
    echo -e "${CLR_RED}Ollama server did not become ready in time.${CLR_RESET}"
    return 1
}

# ============================================================
#  Model Fetchers (Ollama)
# ============================================================
function fetch_cloud_models() {
    echo -e "${CLR_GRAY}Fetching top 10 newest models from Ollama cloud registry...${CLR_RESET}"
    local resp
    resp=$(curl -fsSL --max-time 15 "https://ollama.com/api/tags" 2>/dev/null || true)
    [[ -z "$resp" ]] && { echo -e "${CLR_RED}Failed to fetch cloud models.${CLR_RESET}"; return; }
    echo "$resp" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    models=d.get('models',[])
    for m in sorted(models, key=lambda x: x.get('modified_at',''), reverse=True)[:10]:
        size=m.get('size',0)
        gb=size/1024/1024/1024
        date=m.get('modified_at','')[:10]
        print(f\"{m['name']}|{gb:.2f}|{date}\")
except: pass
" 2>/dev/null || true
}

function fetch_local_models() {
    echo -e "${CLR_GRAY}Fetching local models from Ollama...${CLR_RESET}"
    local resp
    resp=$(curl -fsSL --max-time 5 "http://localhost:11434/api/tags" 2>/dev/null || true)
    [[ -z "$resp" ]] && { echo -e "${CLR_RED}Failed to fetch local models (is Ollama running?).${CLR_RESET}"; return; }
    echo "$resp" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    models=d.get('models',[])
    for m in sorted(models, key=lambda x: x.get('modified_at',''), reverse=True):
        size=m.get('size',0)
        gb=size/1024/1024/1024
        date=m.get('modified_at','')[:10]
        print(f\"{m['name']}|{gb:.2f}|{date}\")
except: pass
" 2>/dev/null || true
}

# ============================================================
#  Provider Setup
# ============================================================
function show_provider_menu() {
    while true; do
        clear
        echo -e "${CLR_GREEN}=============================================${CLR_RESET}"
        echo -e "${CLR_GREEN}         Choose API Provider${CLR_RESET}"
        echo -e "${CLR_GREEN}=============================================${CLR_RESET}"
        echo ""
        local provider
        provider=$(config_get "provider" "$DEFAULT_PROVIDER")
        echo -e "${CLR_CYAN}Current provider: $(echo "$provider" | tr '[:lower:]' '[:upper:]')${CLR_RESET}"
        echo ""
        echo -e "${CLR_CYAN}Options:${CLR_RESET}"
        echo -e "  [1] Ollama - Use Ollama cloud/local models ${CLR_YELLOW}"
        echo -e "  [2] DeepSeek - Use DeepSeek API (bring your own key) ${CLR_YELLOW}"
        echo -e "  [B] Back to Main Menu ${CLR_MAGENTA}"
        echo ""
        ask "Enter your choice: " choice
        case "$(lc "$choice")" in
            1)
                config_set "provider" "ollama"
                echo -e "${CLR_GREEN}Provider set to: OLLAMA${CLR_RESET}"
                sleep 1
                return
                ;;
            2)
                config_set "provider" "deepseek"
                local key
                key=$(config_get "deepseekApiKey" "")
                if [[ -z "$key" ]]; then
                    echo ""
                    echo -e "${CLR_YELLOW}DeepSeek API key required.${CLR_RESET}"
                    echo -e "${CLR_CYAN}Get your key at: https://platform.deepseek.com/api_keys${CLR_RESET}"
                    ask "Enter your DeepSeek API key (starts with 'sk-'): " key
                    if [[ -n "$key" ]]; then
                        config_set "deepseekApiKey" "$key"
                    else
                        echo -e "${CLR_YELLOW}No key entered. You can set it later from the menu.${CLR_RESET}"
                        sleep 2
                    fi
                fi
                echo -e "${CLR_GREEN}Provider set to: DEEPSEEK${CLR_RESET}"
                sleep 1
                return
                ;;
            b) return ;;
            *) echo -e "${CLR_RED}Invalid choice.${CLR_RESET}"; sleep 1 ;;
        esac
    done
}

# ============================================================
#  Ollama Model Picker
# ============================================================
function show_ollama_cloud_menu() {
    while true; do
        clear
        echo -e "${CLR_GREEN}=============================================${CLR_RESET}"
        echo -e "${CLR_GREEN}   Cloud Models (Ollama Registry - Newest)${CLR_RESET}"
        echo -e "${CLR_GREEN}=============================================${CLR_RESET}"
        echo ""
        local models=()
        while IFS='|' read -r name size date; do
            [[ -n "$name" ]] && models+=("$name" "$size" "$date")
        done < <(fetch_cloud_models)
        if [[ ${#models[@]} -eq 0 ]]; then
            echo -e "${CLR_RED}No cloud models could be fetched.${CLR_RESET}"
            read -rp "Press Enter to return" || true
            return
        fi
        local i=1
        local idx=0
        while [[ $idx -lt ${#models[@]} ]]; do
            printf "  [%d] ${CLR_CYAN}%s${CLR_RESET}  (size: %s GB, updated: %s)\n" "$i" "${models[idx]}" "${models[idx+1]}" "${models[idx+2]}"
            ((idx+=3))
            ((i++))
        done
        echo ""
        echo -e "  [M] Manual entry ${CLR_YELLOW}"
        echo -e "  [B] Back ${CLR_MAGENTA}"
        echo ""
        ask "Select a cloud model by number, or M/B: " choice
        case "$(lc "$choice")" in
            b) return ;;
            m)
                ask "Enter the full model name (e.g., kimi-k2.6:cloud): " manual
                if [[ -n "$manual" ]]; then
                    config_set "ollamaModel" "$manual"
                    config_set "source" "cloud"
                    echo -e "${CLR_GREEN}Selected: $manual${CLR_RESET}"
                fi
                read -rp "Press Enter to continue" || true
                return
                ;;
        esac
        if [[ "$choice" =~ ^[0-9]+$ ]]; then
            local arr_idx=$(( (choice-1)*3 ))
            if [[ $arr_idx -ge 0 && $arr_idx -lt ${#models[@]} ]]; then
                local sel="${models[arr_idx]}"
                config_set "ollamaModel" "$sel"
                config_set "source" "cloud"
                echo -e "${CLR_GREEN}Selected: $sel${CLR_RESET}"
            else
                echo -e "${CLR_RED}Invalid selection.${CLR_RESET}"
            fi
        else
            echo -e "${CLR_RED}Invalid input.${CLR_RESET}"
        fi
        read -rp "Press Enter to continue" || true
    done
}

function show_ollama_local_menu() {
    while true; do
        clear
        echo -e "${CLR_GREEN}=============================================${CLR_RESET}"
        echo -e "${CLR_GREEN}   Local Models (Downloaded on this Mac)${CLR_RESET}"
        echo -e "${CLR_GREEN}=============================================${CLR_RESET}"
        echo ""
        local models=()
        while IFS='|' read -r name size date; do
            [[ -n "$name" ]] && models+=("$name" "$size" "$date")
        done < <(fetch_local_models)
        if [[ ${#models[@]} -eq 0 ]]; then
            echo -e "${CLR_YELLOW}No local models found.${CLR_RESET}"
            read -rp "Press Enter to return" || true
            return
        fi
        local i=1
        local idx=0
        while [[ $idx -lt ${#models[@]} ]]; do
            printf "  [%d] ${CLR_CYAN}%s${CLR_RESET}  (size: %s GB, updated: %s)\n" "$i" "${models[idx]}" "${models[idx+1]}" "${models[idx+2]}"
            ((idx+=3))
            ((i++))
        done
        echo ""
        echo -e "  [B] Back ${CLR_MAGENTA}"
        echo ""
        ask "Select a local model by number, or B: " choice
        case "$(lc "$choice")" in
            b) return ;;
        esac
        if [[ "$choice" =~ ^[0-9]+$ ]]; then
            local arr_idx=$(( (choice-1)*3 ))
            if [[ $arr_idx -ge 0 && $arr_idx -lt ${#models[@]} ]]; then
                local sel="${models[arr_idx]}"
                config_set "ollamaModel" "$sel"
                config_set "source" "local"
                echo -e "${CLR_GREEN}Selected: $sel${CLR_RESET}"
            else
                echo -e "${CLR_RED}Invalid selection.${CLR_RESET}"
            fi
        else
            echo -e "${CLR_RED}Invalid input.${CLR_RESET}"
        fi
        read -rp "Press Enter to continue" || true
    done
}

function show_ollama_model_picker() {
    while true; do
        clear
        echo -e "${CLR_GREEN}=============================================${CLR_RESET}"
        echo -e "${CLR_GREEN}    Pick Ollama Model${CLR_RESET}"
        echo -e "${CLR_GREEN}=============================================${CLR_RESET}"
        echo ""
        local model
        model=$(config_get "ollamaModel" "$DEFAULT_OLLAMA_MODEL")
        echo -e "${CLR_CYAN}Current model: $model${CLR_RESET}"
        echo ""
        echo -e "  [1] Browse Cloud Models ${CLR_YELLOW}"
        echo -e "  [2] Browse Local Models ${CLR_YELLOW}"
        echo -e "  [3] Manual Entry ${CLR_YELLOW}"
        echo -e "  [B] Back ${CLR_MAGENTA}"
        echo ""
        ask "Enter your choice: " choice
        case "$(lc "$choice")" in
            1) show_ollama_cloud_menu ;;
            2) show_ollama_local_menu ;;
            3)
                ask "Enter the full model name (e.g., kimi-k2.6:cloud): " manual
                if [[ -n "$manual" ]]; then
                    config_set "ollamaModel" "$manual"
                    config_set "source" "manual"
                    echo -e "${CLR_GREEN}Model set to: $manual${CLR_RESET}"
                    read -rp "Press Enter to continue" || true
                fi
                ;;
            b) return ;;
            *) echo -e "${CLR_RED}Invalid choice.${CLR_RESET}"; sleep 1 ;;
        esac
    done
}

# ============================================================
#  DeepSeek Model Picker
# ============================================================
function show_deepseek_model_picker() {
    while true; do
        clear
        echo -e "${CLR_GREEN}=============================================${CLR_RESET}"
        echo -e "${CLR_GREEN}    Pick DeepSeek Model${CLR_RESET}"
        echo -e "${CLR_GREEN}=============================================${CLR_RESET}"
        echo ""
        local model
        model=$(config_get "deepseekModel" "$DEFAULT_DEEPSEEK_MODEL")
        local label="$model"
        case "$model" in
            deepseek-chat) label="DeepSeek V4 (Recommended)" ;;
            deepseek-reasoner) label="DeepSeek R1 (Flash/Reasoning)" ;;
        esac
        echo -e "${CLR_CYAN}Current model: $label${CLR_RESET}"
        echo ""
        echo -e "${CLR_CYAN}Available DeepSeek models:${CLR_RESET}"
        echo -e "  [1] DeepSeek V4 (Recommended) - deepseek-chat ${CLR_YELLOW}"
        echo -e "       Latest flagship chat model. Best for general coding. ${CLR_GRAY}"
        echo -e "  [2] DeepSeek R1 (Flash)       - deepseek-reasoner ${CLR_YELLOW}"
        echo -e "       Fast reasoning model. Best for complex logic. ${CLR_GRAY}"
        echo -e "  [3] Manual Entry (type any DeepSeek model ID) ${CLR_YELLOW}"
        echo ""
        echo -e "  [S] Set / Update API Key ${CLR_WHITE}"
        echo -e "  [B] Back to Model Menu ${CLR_MAGENTA}"
        echo ""
        ask "Enter your choice: " choice
        case "$(lc "$choice")" in
            1) config_set "deepseekModel" "deepseek-chat"; echo -e "${CLR_GREEN}Selected: DeepSeek V4${CLR_RESET}"; sleep 1 ;;
            2) config_set "deepseekModel" "deepseek-reasoner"; echo -e "${CLR_GREEN}Selected: DeepSeek R1 (Flash)${CLR_RESET}"; sleep 1 ;;
            3)
                ask "Enter DeepSeek model ID (e.g., deepseek-chat): " manual
                if [[ -n "$manual" ]]; then
                    config_set "deepseekModel" "$manual"
                    echo -e "${CLR_GREEN}Model set to: $manual${CLR_RESET}"
                    read -rp "Press Enter to continue" || true
                fi
                ;;
            s) set_deepseek_key ;;
            b) return ;;
            *) echo -e "${CLR_RED}Invalid choice.${CLR_RESET}"; sleep 1 ;;
        esac
    done
}

function set_deepseek_key() {
    clear
    echo -e "${CLR_GREEN}=============================================${CLR_RESET}"
    echo -e "${CLR_GREEN}    Set DeepSeek API Key${CLR_RESET}"
    echo -e "${CLR_GREEN}=============================================${CLR_RESET}"
    echo ""
    local key
    key=$(config_get "deepseekApiKey" "")
    if [[ -n "$key" ]]; then
        local masked="${key:0:8}..."
        echo -e "${CLR_CYAN}Current key: $masked${CLR_RESET}"
    else
        echo -e "${CLR_YELLOW}No API key set.${CLR_RESET}"
    fi
    echo ""
    echo -e "${CLR_CYAN}Get your DeepSeek API key at: https://platform.deepseek.com/api_keys${CLR_RESET}"
    echo ""
    ask "Enter your DeepSeek API key (or leave blank to keep current): " key
    if [[ -n "${key:-}" ]]; then
        config_set "deepseekApiKey" "${key:-}"
        echo -e "${CLR_GREEN}API key saved.${CLR_RESET}"
    else
        echo -e "${CLR_YELLOW}API key unchanged.${CLR_RESET}"
    fi
    sleep 1
}

# ============================================================
#  Unified Model Menu
# ============================================================
function show_model_menu() {
    while true; do
        clear
        echo -e "${CLR_GREEN}=============================================${CLR_RESET}"
        echo -e "${CLR_GREEN}    Pick / Change Model${CLR_RESET}"
        echo -e "${CLR_GREEN}=============================================${CLR_RESET}"
        echo ""
        local provider
        provider=$(config_get "provider" "$DEFAULT_PROVIDER")
        echo -e "${CLR_CYAN}Provider: $(echo "$provider" | tr '[:lower:]' '[:upper:]')${CLR_RESET}"
        if [[ "$provider" == "ollama" ]]; then
            local omodel
            omodel=$(config_get "ollamaModel" "$DEFAULT_OLLAMA_MODEL")
            echo -e "Model   : $omodel"
        else
            local dmodel
            dmodel=$(config_get "deepseekModel" "$DEFAULT_DEEPSEEK_MODEL")
            local dlabel="$dmodel"
            case "$dmodel" in
                deepseek-chat) dlabel="DeepSeek V4 (Recommended)" ;;
                deepseek-reasoner) dlabel="DeepSeek R1 (Flash/Reasoning)" ;;
            esac
            echo -e "Model   : $dlabel"
            local dkey
            dkey=$(config_get "deepseekApiKey" "")
            if [[ -n "$dkey" ]]; then
                echo -e "API Key : ${dkey:0:8}..."
            else
                echo -e "${CLR_RED}API Key : NOT SET${CLR_RESET}"
            fi
        fi
        echo ""
        echo -e "  [1] Switch Provider (Ollama / DeepSeek) ${CLR_YELLOW}"
        if [[ "$provider" == "ollama" ]]; then
            echo -e "  [2] Browse Ollama Models ${CLR_YELLOW}"
        else
            echo -e "  [2] Pick DeepSeek Model ${CLR_YELLOW}"
            echo -e "  [3] Set DeepSeek API Key ${CLR_YELLOW}"
        fi
        echo -e "  [B] Back to Main Menu ${CLR_MAGENTA}"
        echo ""
        ask "Enter your choice: " choice
        case "$(lc "$choice")" in
            1) show_provider_menu ;;
            2)
                provider=$(config_get "provider" "$DEFAULT_PROVIDER")
                if [[ "$provider" == "ollama" ]]; then
                    show_ollama_model_picker
                else
                    show_deepseek_model_picker
                fi
                ;;
            3)
                provider=$(config_get "provider" "$DEFAULT_PROVIDER")
                if [[ "$provider" == "deepseek" ]]; then
                    set_deepseek_key
                fi
                ;;
            b) return ;;
            *) echo -e "${CLR_RED}Invalid choice.${CLR_RESET}"; sleep 1 ;;
        esac
    done
}

# ============================================================
#  Pull Model (Ollama)
# ============================================================
function pull_selected_model() {
    local provider
    provider=$(config_get "provider" "$DEFAULT_PROVIDER")
    if [[ "$provider" != "ollama" ]]; then
        echo -e "${CLR_YELLOW}Pull is only available when using Ollama provider.${CLR_RESET}"
        read -rp "Press Enter to continue" || true
        return
    fi
    local model
    model=$(config_get "ollamaModel" "$DEFAULT_OLLAMA_MODEL")
    echo -e "${CLR_CYAN}Pulling model '$model' into local Ollama...${CLR_RESET}"
    if ollama pull "$model" 2>/dev/null; then
        echo -e "${CLR_GREEN}Model '$model' pulled successfully.${CLR_RESET}"
    else
        echo -e "${CLR_RED}ERROR pulling model.${CLR_RESET}"
    fi
    read -rp "Press Enter to continue" || true
}

# ============================================================
#  Launch Codex App
# ============================================================
function launch_codex_app() {
    local -a passArgs=("$@")
    local provider
    provider=$(config_get "provider" "$DEFAULT_PROVIDER")

    if [[ "$provider" == "deepseek" ]]; then
        local dkey
        dkey=$(config_get "deepseekApiKey" "")
        if [[ -z "$dkey" ]]; then
            echo -e "${CLR_RED}ERROR: DeepSeek API key not set.${CLR_RESET}"
            echo -e "${CLR_YELLOW}Go to Model menu to set your key.${CLR_RESET}"
            read -rp "Press Enter to return to menu" || true
            return
        fi

        local dmodel
        dmodel=$(config_get "deepseekModel" "$DEFAULT_DEEPSEEK_MODEL")
        echo -e "${CLR_CYAN}Configuring DeepSeek API environment...${CLR_RESET}"
        export OPENAI_API_KEY="$dkey"
        export OPENAI_BASE_URL="https://api.deepseek.com/v1"
        echo -e "${CLR_CYAN}Using model: $dmodel${CLR_RESET}"

        local -a cmdParts=("codex" "--model" "$dmodel")
        if [[ ${#passArgs[@]} -gt 0 ]]; then
            cmdParts+=("${passArgs[@]}")
        fi

        local customArgs
        customArgs=$(config_get "customArgs" "")
        if [[ -n "$customArgs" ]]; then
            read -ra ca <<< "$customArgs"
            cmdParts+=("${ca[@]}")
        fi

        local cmdString
        cmdString=$(printf '%s ' "${cmdParts[@]}")
        echo -e "\n${CLR_GREEN}>>> $cmdString (DeepSeek API)${CLR_RESET}"
        echo -e "${CLR_GRAY}$(printf '%.0s-' {1..50})${CLR_RESET}"

        clear
        if "${cmdParts[@]}"; then
            :
        else
            echo -e "${CLR_YELLOW}Codex App exited with non-zero code.${CLR_RESET}"
        fi
    else
        local model
        model=$(config_get "ollamaModel" "$DEFAULT_OLLAMA_MODEL")

        if ! start_ollama_server; then
            read -rp "Press Enter to return to menu" || true
            return
        fi

        local -a cmdParts=("ollama" "launch" "codex-app")
        local hasModel=0 foundSep=0 skipNext=0
        local -a extraAfterSep=()

        for a in "${passArgs[@]}"; do
            if [[ $skipNext -eq 1 ]]; then skipNext=0; continue; fi
            if [[ "$a" == "--" ]]; then foundSep=1; continue; fi
            if [[ $foundSep -eq 1 ]]; then extraAfterSep+=("$a"); continue; fi
            if [[ "$a" == "--model" ]]; then
                hasModel=1
                cmdParts+=("--model")
                skipNext=1
            elif [[ "$a" == --model=* ]]; then
                hasModel=1
                cmdParts+=("$a")
            else
                extraAfterSep+=("$a")
            fi
        done

        if [[ $hasModel -eq 0 && -n "$model" ]]; then
            cmdParts+=("--model" "$model")
        fi
        cmdParts+=("--")

        local customArgs
        customArgs=$(config_get "customArgs" "")
        if [[ -n "$customArgs" ]]; then
            read -ra ca <<< "$customArgs"
            cmdParts+=("${ca[@]}")
        fi

        if [[ ${#extraAfterSep[@]} -gt 0 ]]; then
            cmdParts+=("${extraAfterSep[@]}")
        fi

        local cmdString
        cmdString=$(printf '%s ' "${cmdParts[@]}")
        echo -e "\n${CLR_GREEN}>>> $cmdString${CLR_RESET}"
        echo -e "${CLR_GRAY}$(printf '%.0s-' {1..50})${CLR_RESET}"

        clear
        if "${cmdParts[@]}"; then
            :
        else
            echo -e "${CLR_YELLOW}Codex App exited with non-zero code.${CLR_RESET}"
        fi
    fi
    read -rp "Codex App session ended. Press Enter to return to menu" || true
}

# ============================================================
#  Status & Menu
# ============================================================
function show_status() {
    local cExists="NO" oExists="NO" nExists="NO" appExists="NO"
    command -v codex &>/dev/null && cExists="YES"
    command -v codex-app &>/dev/null && appExists="YES"
    command -v ollama &>/dev/null && oExists="YES"
    command -v npm &>/dev/null && nExists="YES"

    local provider model
    provider=$(config_get "provider" "$DEFAULT_PROVIDER")

    local cUpdate="" oUpdate=""
    if [[ "$cExists" == "YES" ]]; then
        local cInst cLat
        cInst=$(get_codex_installed_version)
        cLat=$(get_codex_latest_version)
        if [[ -n "$cInst" && -n "$cLat" ]] && version_greater "$cInst" "$cLat"; then
            cUpdate=" (update v$cLat available)"
        fi
    fi
    if [[ "$oExists" == "YES" ]]; then
        local oInst oLat
        oInst=$(get_ollama_installed_version)
        oLat=$(get_ollama_latest_version)
        if [[ -n "$oInst" && -n "$oLat" ]] && version_greater "$oInst" "$oLat"; then
            oUpdate=" (update v$oLat available)"
        fi
    fi

    echo -e "\n${CLR_CYAN}========== Codex App Launcher ==========${CLR_RESET}"
    if [[ "$nExists" == "YES" ]]; then
        local nver
        nver=$(npm --version 2>/dev/null || true)
        echo -e "  Node.js / npm : ${CLR_GREEN}OK (npm v$nver)${CLR_RESET}"
    else
        echo -e "  Node.js / npm : ${CLR_RED}NOT FOUND${CLR_RESET}"
    fi
    if [[ "$cExists" == "YES" ]]; then
        local cInst
        cInst=$(get_codex_installed_version)
        if [[ -n "$cUpdate" ]]; then
            echo -e "  Codex CLI     : ${CLR_YELLOW}v$cInst$cUpdate${CLR_RESET}"
        else
            echo -e "  Codex CLI     : ${CLR_GREEN}v$cInst (up to date)${CLR_RESET}"
        fi
    else
        echo -e "  Codex CLI     : ${CLR_RED}NOT INSTALLED${CLR_RESET}"
    fi
    if [[ "$appExists" == "YES" ]]; then
        echo -e "  Codex App     : ${CLR_GREEN}AVAILABLE${CLR_RESET}"
    else
        echo -e "  Codex App     : ${CLR_YELLOW}NOT FOUND (installed via Codex CLI)${CLR_RESET}"
    fi
    if [[ "$oExists" == "YES" ]]; then
        local oInst
        oInst=$(get_ollama_installed_version)
        if [[ -n "$oUpdate" ]]; then
            echo -e "  Ollama        : ${CLR_YELLOW}v$oInst$oUpdate${CLR_RESET}"
        else
            echo -e "  Ollama        : ${CLR_GREEN}v$oInst (up to date)${CLR_RESET}"
        fi
    else
        echo -e "  Ollama        : ${CLR_RED}NOT INSTALLED${CLR_RESET}"
    fi
    echo -e "  Provider      : ${CLR_CYAN}$(echo "$provider" | tr '[:lower:]' '[:upper:]')${CLR_RESET}"
    if [[ "$provider" == "ollama" ]]; then
        local omodel src
        omodel=$(config_get "ollamaModel" "$DEFAULT_OLLAMA_MODEL")
        src=$(config_get "source" "$DEFAULT_SOURCE")
        echo -e "  Model         : ${CLR_CYAN}$omodel [source: $src]${CLR_RESET}"
    else
        local dmodel dkey
        dmodel=$(config_get "deepseekModel" "$DEFAULT_DEEPSEEK_MODEL")
        dkey=$(config_get "deepseekApiKey" "")
        local dlabel="$dmodel"
        case "$dmodel" in
            deepseek-chat) dlabel="DeepSeek V4 (Recommended)" ;;
            deepseek-reasoner) dlabel="DeepSeek R1 (Flash/Reasoning)" ;;
        esac
        echo -e "  Model         : ${CLR_CYAN}$dlabel${CLR_RESET}"
        if [[ -n "$dkey" ]]; then
            echo -e "  API Key       : ${CLR_GREEN}SET${CLR_RESET}"
        else
            echo -e "  API Key       : ${CLR_RED}NOT SET${CLR_RESET}"
        fi
    fi
    echo -e "${CLR_CYAN}=========================================${CLR_RESET}"
}

function show_main_menu() {
    show_status
    local cExists="NO" oExists="NO"
    command -v codex &>/dev/null && cExists="YES"
    command -v ollama &>/dev/null && oExists="YES"

    local cUpdate="" oUpdate=""
    if [[ "$cExists" == "YES" ]]; then
        local cInst cLat
        cInst=$(get_codex_installed_version)
        cLat=$(get_codex_latest_version)
        if [[ -n "$cInst" && -n "$cLat" ]] && version_greater "$cInst" "$cLat"; then
            cUpdate="     ^^ UPDATE AVAILABLE"
        fi
    fi
    if [[ "$oExists" == "YES" ]]; then
        local oInst oLat
        oInst=$(get_ollama_installed_version)
        oLat=$(get_ollama_latest_version)
        if [[ -n "$oInst" && -n "$oLat" ]] && version_greater "$oInst" "$oLat"; then
            oUpdate="     ^^ UPDATE AVAILABLE"
        fi
    fi

    local provider source
    provider=$(config_get "provider" "$DEFAULT_PROVIDER")
    source=$(config_get "source" "$DEFAULT_SOURCE")

    echo -e "\n[1] Install / Update Codex CLI ${CLR_WHITE}"
    [[ -n "$cUpdate" ]] && echo -e "${CLR_YELLOW}$cUpdate${CLR_RESET}"
    if [[ "$oExists" == "YES" ]]; then
        echo -e "[2] Install / Update Ollama ${CLR_WHITE}"
        [[ -n "$oUpdate" ]] && echo -e "${CLR_YELLOW}$oUpdate${CLR_RESET}"
    else
        echo -e "[2] Install / Update Ollama ${CLR_WHITE}"
    fi
    echo -e "[3] Pick / Change Provider & Model ${CLR_WHITE}"
    if [[ "$provider" == "ollama" && "$source" == "cloud" && "$oExists" == "YES" ]]; then
        echo -e "[4] Pull Ollama Model Locally ${CLR_WHITE}"
    else
        echo -e "[4] Pull Ollama Model Locally [not applicable] ${CLR_GRAY}"
    fi
    echo -e "[5] Set Custom Launch Arguments ${CLR_WHITE}"
    echo -e "[6] Launch Codex App ${CLR_GREEN}"
    echo -e "[C] Clear Version Cache ${CLR_WHITE}"
    echo -e "[Q] Quit ${CLR_MAGENTA}"
    echo ""
}

# ============================================================
#  Main
# ============================================================
ensure_config
ensure_cache

# --- Direct launch mode ---
if [[ $# -gt 0 ]]; then
    launchArgs=("$@")
    if [[ "${launchArgs[0]}" == "launch" ]]; then
        launchArgs=("${launchArgs[@]:1}")
    fi
    provider=""
    provider=$(config_get "provider" "$DEFAULT_PROVIDER")
    if [[ "$provider" == "deepseek" ]]; then
        dkey=""
        dkey=$(config_get "deepseekApiKey" "")
        if [[ -z "$dkey" ]]; then
            echo -e "${CLR_RED}ERROR: DeepSeek API key not set. Run launcher menu to configure.${CLR_RESET}"
            exit 1
        fi
        export OPENAI_API_KEY="$dkey"
        export OPENAI_BASE_URL="https://api.deepseek.com/v1"
        dmodel=""
        dmodel=$(config_get "deepseekModel" "$DEFAULT_DEEPSEEK_MODEL")
        clear
        cmdParts=("codex" "--model" "$dmodel")
        if [[ ${#launchArgs[@]} -gt 0 ]]; then
            cmdParts+=("${launchArgs[@]}")
        fi
        echo -e "${CLR_GREEN}>>> $(printf '%s ' "${cmdParts[@]}") (DeepSeek API)${CLR_RESET}"
        "${cmdParts[@]}"
    else
        if ! command -v codex &>/dev/null; then
            echo -e "${CLR_YELLOW}Codex CLI not found. Installing...${CLR_RESET}"
            install_codex_cli || exit 1
        fi
        if ! command -v ollama &>/dev/null; then
            echo -e "${CLR_YELLOW}Ollama not found. Installing...${CLR_RESET}"
            install_ollama || exit 1
        fi
        start_ollama_server || exit 1
        clear
        launch_codex_app "${launchArgs[@]}"
    fi
    exit $?
fi

# --- Interactive menu mode ---
while true; do
    show_main_menu
    ask "Enter your choice: " choice
    provider=""
    provider=$(config_get "provider" "$DEFAULT_PROVIDER")
    source=""
    source=$(config_get "source" "$DEFAULT_SOURCE")
    case "$(lc "$choice")" in
        1)
            if command -v codex &>/dev/null; then
                inst="" lat=""
                inst=$(get_codex_installed_version)
                lat=$(get_codex_latest_version)
                if [[ -n "$inst" && -n "$lat" ]] && version_greater "$inst" "$lat"; then
                    echo -e "${CLR_YELLOW}Codex CLI update available: v$inst installed, v$lat available.${CLR_RESET}"
                    ask "Update Codex CLI now? (y/n) " ans
                    [[ "$(lc "$ans")" == "y" ]] && install_codex_cli
                else
                    ask "Codex CLI is up to date (v$inst). Reinstall anyway? (y/n) " ans
                    [[ "$(lc "$ans")" == "y" ]] && install_codex_cli
                fi
            else
                ask "Install Codex CLI now? (y/n) " ans
                [[ "$(lc "$ans")" == "y" ]] && install_codex_cli
            fi
            read -rp "Press Enter to continue" || true
            ;;
        2)
            if command -v ollama &>/dev/null; then
                inst="" lat=""
                inst=$(get_ollama_installed_version)
                lat=$(get_ollama_latest_version)
                if [[ -n "$inst" && -n "$lat" ]] && version_greater "$inst" "$lat"; then
                    echo -e "${CLR_YELLOW}Ollama update available: v$inst installed, v$lat available.${CLR_RESET}"
                    ask "Update Ollama now? (y/n) " ans
                    [[ "$(lc "$ans")" == "y" ]] && install_ollama
                else
                    ask "Ollama is up to date (v$inst). Reinstall anyway? (y/n) " ans
                    [[ "$(lc "$ans")" == "y" ]] && install_ollama
                fi
            else
                ask "Install Ollama now? (y/n) " ans
                [[ "$(lc "$ans")" == "y" ]] && install_ollama
            fi
            read -rp "Press Enter to continue" || true
            ;;
        3)
            show_model_menu
            ;;
        4)
            if [[ "$provider" == "ollama" && "$source" == "cloud" ]] && command -v ollama &>/dev/null; then
                pull_selected_model
            else
                echo -e "${CLR_YELLOW}Pull is only available when using Ollama provider with a cloud model.${CLR_RESET}"
                read -rp "Press Enter to continue" || true
            fi
            ;;
        5)
            ca=""
            ca=$(config_get "customArgs" "")
            echo -e "${CLR_CYAN}Current custom args: $( [[ -n "$ca" ]] && echo "$ca" || echo '(none)' )${CLR_RESET}"
            ask "Enter extra args, or blank to clear: " new
            config_set "customArgs" "${new:-}"
            echo -e "${CLR_GREEN}Custom args updated.${CLR_RESET}"
            sleep 1
            ;;
        6)
            if ! command -v codex &>/dev/null; then
                echo -e "${CLR_RED}Codex CLI not installed. Install first (option 1).${CLR_RESET}"
                read -rp "Press Enter to continue" || true
            elif [[ "$provider" == "ollama" && "$oExists" == "NO" ]]; then
                echo -e "${CLR_RED}Ollama not installed. Install first (option 2).${CLR_RESET}"
                read -rp "Press Enter to continue" || true
            elif [[ "$provider" == "deepseek" ]]; then
                dkey=""
                dkey=$(config_get "deepseekApiKey" "")
                if [[ -z "$dkey" ]]; then
                    echo -e "${CLR_RED}DeepSeek API key not set. Go to option 3 to configure.${CLR_RESET}"
                    read -rp "Press Enter to continue" || true
                else
                    clear
                    launch_codex_app
                fi
            else
                clear
                launch_codex_app
            fi
            ;;
        c)
            cache_set "codexLastChecked" ""
            cache_set "ollamaLastChecked" ""
            echo -e "${CLR_GREEN}Version cache cleared.${CLR_RESET}"
            sleep 1
            ;;
        q)
            echo -e "${CLR_GREEN}Goodbye!${CLR_RESET}"
            exit 0
            ;;
        *)
            echo -e "${CLR_RED}Invalid choice.${CLR_RESET}"
            sleep 1
            ;;
    esac
done
