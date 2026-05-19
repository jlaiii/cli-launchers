#!/usr/bin/env bash
set -euo pipefail

# ============================================================
#  Codex + Ollama Launcher for macOS
#  Interactive menu + direct launch for OpenAI Codex CLI
#  through Ollama with any cloud or local model.
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

CONFIG_FILE="$SCRIPT_DIR/Codex-Launcher.config.json"
VERSION_CACHE="$SCRIPT_DIR/Codex-Launcher.versions.json"
CACHE_TTL_MINUTES=60

# --- Defaults ---
DEFAULT_MODEL="kimi-k2.6:cloud"
DEFAULT_SOURCE="cloud"
DEFAULT_FULLAUTO="true"
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

# --- Safe read helper (prevents set -e / set -u issues on EOF) ---
ask() {
    printf -v "$2" '%s' ''
    read -rp "$1" "$2" || true
}

# ============================================================
#  JSON Helpers (python3 is pre-installed on macOS)
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
d={'selectedModel':'$DEFAULT_MODEL','source':'$DEFAULT_SOURCE','fullAuto':True,'customArgs':'','autoUpdate':False,'skipUpdateCheck':False}
with open('$CONFIG_FILE','w') as f: json.dump(d,f,indent=2)
" 2>/dev/null
    else
        local missing=0
        for key in selectedModel source fullAuto customArgs autoUpdate skipUpdateCheck; do
            local val
            val=$(json_read "$CONFIG_FILE" "$key" "__MISSING__")
            if [[ "$val" == "__MISSING__" ]]; then missing=1; fi
        done
        if [[ "$missing" == "1" ]]; then
            python3 -c "
import json, os
d={'selectedModel':'$DEFAULT_MODEL','source':'$DEFAULT_SOURCE','fullAuto':True,'customArgs':'','autoUpdate':False,'skipUpdateCheck':False}
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

function pull_selected_model() {
    local model
    model=$(config_get "selectedModel" "$DEFAULT_MODEL")
    echo -e "${CLR_CYAN}Pulling model '$model' into local Ollama...${CLR_RESET}"
    if ollama pull "$model" 2>/dev/null; then
        echo -e "${CLR_GREEN}Model '$model' pulled successfully.${CLR_RESET}"
    else
        echo -e "${CLR_RED}ERROR pulling model.${CLR_RESET}"
    fi
    read -rp "Press Enter to continue" || true
}

# ============================================================
#  Auth / Server Helpers
# ============================================================
function test_ollama_auth() {
    ollama list &>/dev/null && return 0 || return 1
}

function check_ollama_signin() {
    echo -e "${CLR_CYAN}Checking Ollama sign-in status...${CLR_RESET}"
    if ollama list &>/dev/null; then
        echo -e "${CLR_GREEN}Ollama appears configured. Local models:${CLR_RESET}"
        ollama list 2>/dev/null | head -n 10 | while read -r line; do echo -e "${CLR_GRAY}  $line${CLR_RESET}"; done
    else
        echo -e "${CLR_YELLOW}Could not list Ollama models. You may need to run 'ollama signin'.${CLR_RESET}"
        ask "Run 'ollama signin' now? (y/n) " ans
        [[ "$(lc "$ans")" == "y" ]] && ollama signin
    fi
    read -rp "Press Enter to continue" || true
}

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
#  Model Fetchers
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
#  Model Picker Menus
# ============================================================
function show_cloud_model_menu() {
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
        echo -e "  [M] Manual entry (type a model name yourself) ${CLR_YELLOW}"
        echo -e "  [B] Back to main menu ${CLR_MAGENTA}"
        echo ""
        ask "Select a cloud model by number, or M/B: " choice
        case "$(lc "$choice")" in
            b) return ;;
            m)
                ask "Enter the full model name (e.g., kimi-k2.6:cloud): " manual
                if [[ -n "$manual" ]]; then
                    config_set "selectedModel" "$manual"
                    config_set "source" "cloud"
                    echo -e "${CLR_GREEN}Selected cloud model: $manual${CLR_RESET}"
                fi
                read -rp "Press Enter to continue" || true
                return
                ;;
        esac
        if [[ "$choice" =~ ^[0-9]+$ ]]; then
            local arr_idx=$(( (choice-1)*3 ))
            if [[ $arr_idx -ge 0 && $arr_idx -lt ${#models[@]} ]]; then
                local sel="${models[arr_idx]}"
                config_set "selectedModel" "$sel"
                config_set "source" "cloud"
                echo -e "${CLR_GREEN}Selected cloud model: $sel${CLR_RESET}"
            else
                echo -e "${CLR_RED}Invalid selection.${CLR_RESET}"
            fi
        else
            echo -e "${CLR_RED}Invalid input.${CLR_RESET}"
        fi
        read -rp "Press Enter to continue" || true
    done
}

function show_local_model_menu() {
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
            echo -e "${CLR_YELLOW}No local models found. You can pull one from the cloud first.${CLR_RESET}"
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
        echo -e "  [B] Back to main menu ${CLR_MAGENTA}"
        echo ""
        ask "Select a local model by number, or B: " choice
        case "$(lc "$choice")" in
            b) return ;;
        esac
        if [[ "$choice" =~ ^[0-9]+$ ]]; then
            local arr_idx=$(( (choice-1)*3 ))
            if [[ $arr_idx -ge 0 && $arr_idx -lt ${#models[@]} ]]; then
                local sel="${models[arr_idx]}"
                config_set "selectedModel" "$sel"
                config_set "source" "local"
                echo -e "${CLR_GREEN}Selected local model: $sel${CLR_RESET}"
            else
                echo -e "${CLR_RED}Invalid selection.${CLR_RESET}"
            fi
        else
            echo -e "${CLR_RED}Invalid input.${CLR_RESET}"
        fi
        read -rp "Press Enter to continue" || true
    done
}

function show_model_picker() {
    while true; do
        clear
        echo -e "${CLR_GREEN}=============================================${CLR_RESET}"
        echo -e "${CLR_GREEN}         Pick / Change Model${CLR_RESET}"
        echo -e "${CLR_GREEN}=============================================${CLR_RESET}"
        echo ""
        local model source
        model=$(config_get "selectedModel" "$DEFAULT_MODEL")
        source=$(config_get "source" "$DEFAULT_SOURCE")
        echo -e "${CLR_CYAN}Current selection:${CLR_RESET}"
        echo -e "  Model : $model"
        echo -e "  Source: $source"
        echo ""
        echo -e "${CLR_CYAN}Options:${CLR_RESET}"
        echo -e "  [1] Browse Cloud Models (Ollama Registry) ${CLR_YELLOW}"
        echo -e "  [2] Browse Local Models (this Mac) ${CLR_YELLOW}"
        echo -e "  [3] Manual Entry (type any model name) ${CLR_YELLOW}"
        echo -e "  [B] Back to Main Menu ${CLR_MAGENTA}"
        echo ""
        ask "Enter your choice: " choice
        case "$(lc "$choice")" in
            1) show_cloud_model_menu ;;
            2) show_local_model_menu ;;
            3)
                ask "Enter the full model name (e.g., kimi-k2.6:cloud, llama3.3:latest): " manual
                if [[ -n "$manual" ]]; then
                    config_set "selectedModel" "$manual"
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
#  Launch
# ============================================================
function launch_codex() {
    local -a passArgs=("$@")
    local model
    model=$(config_get "selectedModel" "$DEFAULT_MODEL")

    if ! start_ollama_server; then
        read -rp "Press Enter to return to menu" || true
        return
    fi

    clear
    local cmdParts=("ollama" "launch" "codex")
    local hasModel=0 hasYolo=0 foundSep=0
    local -a extraAfterSec=()
    local skipNext=0

    for a in "${passArgs[@]}"; do
        if [[ $skipNext -eq 1 ]]; then skipNext=0; continue; fi
        if [[ "$a" == "--" ]]; then foundSep=1; continue; fi
        if [[ $foundSep -eq 1 ]]; then extraAfterSec+=("$a"); continue; fi
        if [[ "$a" == "--model" ]]; then
            hasModel=1
            cmdParts+=("--model")
            skipNext=1
        elif [[ "$a" == --model=* ]]; then
            hasModel=1
            cmdParts+=("$a")
        elif [[ "$a" == "--yolo" ]]; then
            hasYolo=1
        else
            extraAfterSec+=("$a")
        fi
    done

    if [[ $hasModel -eq 0 && -n "$model" ]]; then
        cmdParts+=("--model" "$model")
    fi
    cmdParts+=("--")

    local fullauto
    fullauto=$(config_get "fullAuto" "$DEFAULT_FULLAUTO")
    if [[ $hasYolo -eq 0 && "$fullauto" == "True" ]]; then
        cmdParts+=("--yolo")
    fi

    local customArgs
    customArgs=$(config_get "customArgs" "")
    if [[ -n "$customArgs" ]]; then
        read -ra ca <<< "$customArgs"
        cmdParts+=("${ca[@]}")
    fi

    if [[ ${#extraAfterSec[@]} -gt 0 ]]; then
        cmdParts+=("${extraAfterSec[@]}")
    fi

    local cmdString
    cmdString=$(printf '%s ' "${cmdParts[@]}")
    echo -e "\n${CLR_GREEN}>>> $cmdString${CLR_RESET}"
    echo -e "${CLR_GRAY}$(printf '%.0s-' {1..50})${CLR_RESET}"

    clear
    if "${cmdParts[@]}"; then
        : # success
    else
        echo -e "${CLR_YELLOW}Codex exited with non-zero code.${CLR_RESET}"
    fi
    read -rp "Codex session ended. Press Enter to return to menu" || true
}

# ============================================================
#  Status & Menu
# ============================================================
function show_status() {
    local cExists="NO" oExists="NO" nExists="NO" authOk="NO"
    command -v codex &>/dev/null && cExists="YES"
    command -v ollama &>/dev/null && oExists="YES"
    command -v npm &>/dev/null && nExists="YES"
    test_ollama_auth && authOk="YES"

    local model source
    model=$(config_get "selectedModel" "$DEFAULT_MODEL")
    source=$(config_get "source" "$DEFAULT_SOURCE")
    local fullauto
    fullauto=$(config_get "fullAuto" "$DEFAULT_FULLAUTO")

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

    echo -e "\n${CLR_CYAN}========== Codex CLI + Ollama Launcher ==========${CLR_RESET}"
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
    if [[ "$authOk" == "YES" ]]; then
        echo -e "  Ollama Auth   : ${CLR_GREEN}OK${CLR_RESET}"
    else
        echo -e "  Ollama Auth   : ${CLR_RED}NOT SIGNED IN${CLR_RESET}"
    fi
    echo -e "  Config model  : ${CLR_CYAN}$model [source: $source]${CLR_RESET}"
    echo -e "  Full-auto     : ${CLR_CYAN}$( [[ "$fullauto" == "True" ]] && echo 'ON (--yolo)' || echo 'OFF' )${CLR_RESET}"
    echo -e "${CLR_CYAN}=================================================${CLR_RESET}"
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

    local model
    model=$(config_get "selectedModel" "$DEFAULT_MODEL")

    echo -e "\n[1] Install / Update Codex CLI ${CLR_WHITE}"
    [[ -n "$cUpdate" ]] && echo -e "${CLR_YELLOW}$cUpdate${CLR_RESET}"
    echo -e "[2] Install / Update Ollama ${CLR_WHITE}"
    [[ -n "$oUpdate" ]] && echo -e "${CLR_YELLOW}$oUpdate${CLR_RESET}"
    echo -e "[3] Pick / Change Model  [current: $model] ${CLR_WHITE}"
    local source
    source=$(config_get "source" "$DEFAULT_SOURCE")
    if [[ "$source" == "cloud" && "$oExists" == "YES" ]]; then
        echo -e "[4] Pull Selected Model Locally (ollama pull) ${CLR_WHITE}"
    else
        echo -e "[4] Pull Selected Model Locally [not applicable] ${CLR_GRAY}"
    fi
    echo -e "[5] Toggle Full-Auto Mode (--yolo) ${CLR_WHITE}"
    echo -e "[6] Set Custom Launch Arguments ${CLR_WHITE}"
    echo -e "[7] Check / Fix Ollama Sign-in ${CLR_WHITE}"
    echo -e "[8] Launch Codex CLI ${CLR_GREEN}"
    echo -e "[C] Clear Version Cache ${CLR_WHITE}"
    echo -e "[A] Toggle Auto-Update on Direct Launch ${CLR_WHITE}"
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
    if ! command -v codex &>/dev/null; then
        echo -e "${CLR_YELLOW}Codex CLI not found. Installing...${CLR_RESET}"
        install_codex_cli || exit 1
    fi
    if ! command -v ollama &>/dev/null; then
        echo -e "${CLR_YELLOW}Ollama not found. Installing...${CLR_RESET}"
        install_ollama || exit 1
    fi
    skipUpdate=""
    skipUpdate=$(config_get "skipUpdateCheck" "$DEFAULT_SKIPUPDATE")
    if [[ "$skipUpdate" != "True" ]]; then
        cInst="" cLat="" oInst="" oLat=""
        cInst=$(get_codex_installed_version)
        cLat=$(get_codex_latest_version)
        if [[ -n "$cInst" && -n "$cLat" ]] && version_greater "$cInst" "$cLat"; then
            autoUpd=""
            autoUpd=$(config_get "autoUpdate" "$DEFAULT_AUTOUPDATE")
            if [[ "$autoUpd" == "True" ]]; then
                echo -e "${CLR_CYAN}Auto-updating Codex CLI...${CLR_RESET}"
                install_codex_cli &>/dev/null
            else
                echo -e "${CLR_YELLOW}Codex update available: v$cInst -> v$cLat. Run launcher menu to update.${CLR_RESET}"
            fi
        fi
        oInst=$(get_ollama_installed_version)
        oLat=$(get_ollama_latest_version)
        if [[ -n "$oInst" && -n "$oLat" ]] && version_greater "$oInst" "$oLat"; then
            echo -e "${CLR_YELLOW}Ollama update available: v$oInst -> v$oLat. Run launcher menu to update.${CLR_RESET}"
        fi
    fi
    start_ollama_server || exit 1
    clear
    launch_codex "${launchArgs[@]}"
    exit $?
fi

# --- Interactive menu mode ---
while true; do
    show_main_menu
    ask "Enter choice: " choice
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
            show_model_picker
            ;;
        4)
            src=""
            src=$(config_get "source" "$DEFAULT_SOURCE")
            if [[ "$src" == "cloud" && $(command -v ollama &>/dev/null && echo YES || echo NO) == "YES" ]]; then
                pull_selected_model
            else
                echo -e "${CLR_YELLOW}Pull is only available when a cloud model is selected and Ollama is installed.${CLR_RESET}"
                read -rp "Press Enter to continue" || true
            fi
            ;;
        5)
            fa=""
            fa=$(config_get "fullAuto" "$DEFAULT_FULLAUTO")
            if [[ "$fa" == "True" ]]; then
                config_set "fullAuto" "False"
                echo -e "${CLR_GREEN}Full-auto mode: OFF${CLR_RESET}"
            else
                config_set "fullAuto" "True"
                echo -e "${CLR_GREEN}Full-auto mode: ON (--yolo)${CLR_RESET}"
            fi
            sleep 1
            ;;
        6)
            ca=""
            ca=$(config_get "customArgs" "")
            echo -e "${CLR_CYAN}Current custom args: $( [[ -n "$ca" ]] && echo "$ca" || echo '(none)' )${CLR_RESET}"
            ask "Enter extra args (e.g. --approval-mode full-auto), or blank to clear: " new
            config_set "customArgs" "${new:-}"
            echo -e "${CLR_GREEN}Custom args updated.${CLR_RESET}"
            sleep 1
            ;;
        7)
            check_ollama_signin
            ;;
        8)
            if ! command -v codex &>/dev/null; then
                echo -e "${CLR_RED}Codex CLI not installed. Install first (option 1).${CLR_RESET}"
                read -rp "Press Enter to continue" || true
            elif ! command -v ollama &>/dev/null; then
                echo -e "${CLR_RED}Ollama not installed. Install first (option 2).${CLR_RESET}"
                read -rp "Press Enter to continue" || true
            else
                clear
                launch_codex
            fi
            ;;
        c)
            cache_set "codexLastChecked" ""
            cache_set "ollamaLastChecked" ""
            echo -e "${CLR_GREEN}Version cache cleared.${CLR_RESET}"
            sleep 1
            ;;
        a)
            au=""
            au=$(config_get "autoUpdate" "$DEFAULT_AUTOUPDATE")
            if [[ "$au" == "True" ]]; then
                config_set "autoUpdate" "False"
                echo -e "${CLR_GREEN}Auto-update on direct launch: OFF${CLR_RESET}"
            else
                config_set "autoUpdate" "True"
                echo -e "${CLR_GREEN}Auto-update on direct launch: ON${CLR_RESET}"
            fi
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
