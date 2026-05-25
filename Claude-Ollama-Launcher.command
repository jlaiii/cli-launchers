#!/usr/bin/env bash
set -euo pipefail

# ============================================================
#  Claude + Ollama Launcher for macOS
#  Interactive menu + direct launch for Anthropic Claude Code
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

CONFIG_FILE="$SCRIPT_DIR/Claude-Ollama-Launcher.config.json"
VERSION_CACHE="$SCRIPT_DIR/Claude-Ollama-Launcher.versions.json"
CACHE_TTL_MINUTES=60

# --- Defaults ---
DEFAULT_MODEL="kimi-k2.6:cloud"
DEFAULT_SOURCE="cloud"
DEFAULT_SKIPPERMS="true"
DEFAULT_CUSTOMCMD=""
DEFAULT_PROVIDER="ollama"
DEFAULT_DEEPSEEK_MODEL="deepseek-chat"
DEFAULT_DEEPSEEK_KEY=""

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
d={'selectedModel':'$DEFAULT_MODEL','source':'$DEFAULT_SOURCE','skipPermissions':True,'customCommand':'','provider':'$DEFAULT_PROVIDER','deepseekModel':'$DEFAULT_DEEPSEEK_MODEL','deepseekApiKey':'$DEFAULT_DEEPSEEK_KEY'}
with open('$CONFIG_FILE','w') as f: json.dump(d,f,indent=2)
" 2>/dev/null
    else
        local missing=0
        for key in selectedModel source skipPermissions customCommand provider deepseekModel deepseekApiKey; do
            local val
            val=$(json_read "$CONFIG_FILE" "$key" "__MISSING__")
            if [[ "$val" == "__MISSING__" ]]; then missing=1; fi
        done
        if [[ "$missing" == "1" ]]; then
            python3 -c "
import json, os
d={'selectedModel':'$DEFAULT_MODEL','source':'$DEFAULT_SOURCE','skipPermissions':True,'customCommand':'','provider':'$DEFAULT_PROVIDER','deepseekModel':'$DEFAULT_DEEPSEEK_MODEL','deepseekApiKey':'$DEFAULT_DEEPSEEK_KEY'}
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
d={'claudeLatestVersion':'','claudeLastChecked':'','ollamaLatestVersion':'','ollamaLastChecked':''}
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
function get_claude_installed_version() {
    if ! command -v claude &>/dev/null; then echo ""; return; fi
    local ver
    ver=$(claude --version 2>/dev/null || true)
    [[ -z "$ver" ]] && echo "" && return
    if [[ "$ver" =~ ([0-9]+\.[0-9]+\.[0-9]+) ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "$ver" | tr -d '\n'
    fi
}

function get_claude_latest_version() {
    local last
    last=$(cache_get "claudeLastChecked" "")
    if ! cache_stale "$last"; then
        cache_get "claudeLatestVersion" ""
        return
    fi
    local resp
    resp=$(curl -fsSL --max-time 15 "https://registry.npmjs.org/@anthropic-ai/claude-code/latest" 2>/dev/null || true)
    [[ -z "$resp" ]] && echo "" && return
    local ver
    ver=$(echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('version',''))" 2>/dev/null || true)
    if [[ -n "$ver" ]]; then
        cache_set "claudeLatestVersion" "$ver"
        cache_set "claudeLastChecked" "$(python3 -c 'import datetime; print(datetime.datetime.now().isoformat())')"
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
function install_claude_code() {
    echo -e "${CLR_CYAN}Installing / Updating Claude Code from https://claude.ai/install.sh ...${CLR_RESET}"
    if curl -fsSL https://claude.ai/install.sh | sh 2>/dev/null; then
        echo -e "${CLR_GREEN}Claude Code installation/update completed.${CLR_RESET}"
    else
        echo -e "${CLR_RED}ERROR installing/updating Claude Code.${CLR_RESET}"
    fi
    read -rp "Press Enter to continue" || true
}

function install_ollama() {
    echo -e "${CLR_CYAN}Installing / Updating Ollama from https://ollama.com/install.sh ...${CLR_RESET}"
    if curl -fsSL https://ollama.com/install.sh | sh 2>/dev/null; then
        echo -e "${CLR_GREEN}Ollama installation/update completed.${CLR_RESET}"
    else
        echo -e "${CLR_RED}ERROR installing/updating Ollama.${CLR_RESET}"
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

# ============================================================
#  Provider & DeepSeek Helpers
# ============================================================
function show_provider_menu() {
    clear
    echo -e "${CLR_GREEN}=============================================${CLR_RESET}"
    echo -e "${CLR_GREEN}   Select AI Provider${CLR_RESET}"
    echo -e "${CLR_GREEN}=============================================${CLR_RESET}"
    echo ""
    local current
    current=$(config_get "provider" "$DEFAULT_PROVIDER")
    echo -e "${CLR_CYAN}Current provider: $current${CLR_RESET}"
    echo ""
    echo -e "  [1] Ollama (local & cloud models via ollama)"
    echo -e "  [2] DeepSeek (API via openai-compatible endpoint)"
    echo -e "  [B] Back"
    echo ""
    ask "Select provider: " choice
    case "$(lc "$choice")" in
        1) config_set "provider" "ollama"; echo -e "${CLR_GREEN}Provider set to Ollama.${CLR_RESET}"; sleep 1 ;;
        2) config_set "provider" "deepseek"; echo -e "${CLR_GREEN}Provider set to DeepSeek.${CLR_RESET}"; sleep 1 ;;
        b) return ;;
        *) echo -e "${CLR_RED}Invalid choice.${CLR_RESET}"; sleep 1 ;;
    esac
}

function show_deepseek_model_picker() {
    while true; do
        clear
        echo -e "${CLR_GREEN}=============================================${CLR_RESET}"
        echo -e "${CLR_GREEN}   DeepSeek Model Selection${CLR_RESET}"
        echo -e "${CLR_GREEN}=============================================${CLR_RESET}"
        echo ""
        local current
        current=$(config_get "deepseekModel" "$DEFAULT_DEEPSEEK_MODEL")
        echo -e "${CLR_CYAN}Current model: $current${CLR_RESET}"
        echo ""
        echo -e "  [1] deepseek-chat"
        echo -e "  [2] deepseek-reasoner"
        echo -e "  [M] Manual entry"
        echo -e "  [B] Back"
        echo ""
        ask "Select DeepSeek model: " choice
        case "$(lc "$choice")" in
            1) config_set "deepseekModel" "deepseek-chat"
               echo -e "${CLR_GREEN}Model set to deepseek-chat.${CLR_RESET}" ;;
            2) config_set "deepseekModel" "deepseek-reasoner"
               echo -e "${CLR_GREEN}Model set to deepseek-reasoner.${CLR_RESET}" ;;
            m)
                ask "Enter model name: " manual
                if [[ -n "$manual" ]]; then
                    config_set "deepseekModel" "$manual"
                    echo -e "${CLR_GREEN}Model set to: $manual${CLR_RESET}"
                fi
                read -rp "Press Enter to continue" || true
                return
                ;;
            b) return ;;
            *) echo -e "${CLR_RED}Invalid choice.${CLR_RESET}" ;;
        esac
        read -rp "Press Enter to continue" || true
    done
}

function set_deepseek_key() {
    clear
    echo -e "${CLR_GREEN}=============================================${CLR_RESET}"
    echo -e "${CLR_GREEN}   Set DeepSeek API Key${CLR_RESET}"
    echo -e "${CLR_GREEN}=============================================${CLR_RESET}"
    echo ""
    local current
    current=$(config_get "deepseekApiKey" "$DEFAULT_DEEPSEEK_KEY")
    if [[ -n "$current" ]]; then
        echo -e "${CLR_CYAN}Current key: ${current:0:4}****${CLR_RESET}"
    else
        echo -e "${CLR_YELLOW}No API key set.${CLR_RESET}"
    fi
    echo ""
    ask "Enter DeepSeek API key (or leave blank to keep current): " newKey
    if [[ -n "$newKey" ]]; then
        config_set "deepseekApiKey" "$newKey"
        echo -e "${CLR_GREEN}API key saved.${CLR_RESET}"
    else
        echo -e "${CLR_GRAY}Key unchanged.${CLR_RESET}"
    fi
    read -rp "Press Enter to continue" || true
}

function show_model_picker() {
    while true; do
        clear
        echo -e "${CLR_GREEN}=============================================${CLR_RESET}"
        echo -e "${CLR_GREEN}         Pick / Change Model${CLR_RESET}"
        echo -e "${CLR_GREEN}=============================================${CLR_RESET}"
        echo ""
        local model source provider
        model=$(config_get "selectedModel" "$DEFAULT_MODEL")
        source=$(config_get "source" "$DEFAULT_SOURCE")
        provider=$(config_get "provider" "$DEFAULT_PROVIDER")
        echo -e "${CLR_CYAN}Current selection:${CLR_RESET}"
        echo -e "  Provider: $provider"
        echo -e "  Model   : $model"
        echo -e "  Source  : $source"
        if [[ "$(lc "$provider")" == "deepseek" ]]; then
            local dsModel dsKey
            dsModel=$(config_get "deepseekModel" "$DEFAULT_DEEPSEEK_MODEL")
            dsKey=$(config_get "deepseekApiKey" "$DEFAULT_DEEPSEEK_KEY")
            if [[ -n "$dsKey" ]]; then
                echo -e "  DeepSeek : $dsModel (key: configured)"
            else
                echo -e "  DeepSeek : $dsModel (${CLR_RED}key: missing${CLR_RESET})"
            fi
        fi
        echo ""
        echo -e "${CLR_CYAN}Options:${CLR_RESET}"
        echo -e "  [1] Browse Cloud Models (Ollama Registry) ${CLR_YELLOW}"
        echo -e "  [2] Browse Local Models (this Mac) ${CLR_YELLOW}"
        echo -e "  [3] Manual Entry (type any model name) ${CLR_YELLOW}"
        echo -e "  [P] Switch Provider (ollama / deepseek) ${CLR_YELLOW}"
        echo -e "  [K] Set DeepSeek API Key ${CLR_YELLOW}"
        echo -e "  [D] Select DeepSeek Model ${CLR_YELLOW}"
        echo -e "  [B] Back to Main Menu ${CLR_MAGENTA}"
        echo ""
        ask "Enter your choice: " choice
        case "$(lc "$choice")" in
            1) show_cloud_model_menu ;;
            2) show_local_model_menu ;;
            3)
                ask "Enter the full model name (e.g., ollama/llama3, kimi-k2.6:cloud, llama3.3:latest): " manual
                if [[ -n "$manual" ]]; then
                    config_set "selectedModel" "$manual"
                    config_set "source" "manual"
                    echo -e "${CLR_GREEN}Model set to: $manual${CLR_RESET}"
                    read -rp "Press Enter to continue" || true
                fi
                ;;
            p) show_provider_menu ;;
            k) set_deepseek_key ;;
            d) show_deepseek_model_picker ;;
            b) return ;;
            *) echo -e "${CLR_RED}Invalid choice.${CLR_RESET}"; sleep 1 ;;
        esac
    done
}

# ============================================================
#  Launch
# ============================================================
function launch_claude() {
    local provider
    provider=$(config_get "provider" "$DEFAULT_PROVIDER")

    if [[ "$(lc "$provider")" == "deepseek" ]]; then
        local dsKey dsModel
        dsKey=$(config_get "deepseekApiKey" "$DEFAULT_DEEPSEEK_KEY")
        dsModel=$(config_get "deepseekModel" "$DEFAULT_DEEPSEEK_MODEL")
        if [[ -z "$dsKey" ]]; then
            echo -e "${CLR_RED}ERROR: DeepSeek API key is not set. Please configure it via menu option [3] -> [K].${CLR_RESET}"
            read -rp "Press Enter to return to menu" || true
            return
        fi
        export OPENAI_API_KEY="$dsKey"
        export OPENAI_BASE_URL="https://api.deepseek.com"

        clear
        local skip
        skip=$(config_get "skipPermissions" "$DEFAULT_SKIPPERMS")
        echo -e "\n${CLR_GREEN}>>> Launching Claude Code with DeepSeek ($dsModel)${CLR_RESET}"
        echo -e "${CLR_GRAY}$(printf '%.0s-' {1..50})${CLR_RESET}"

        clear
        local exitCode=0
        if [[ "$skip" == "True" ]]; then
            claude --model "$dsModel" --dangerously-skip-permissions || exitCode=$?
        else
            claude --model "$dsModel" || exitCode=$?
        fi
        if [[ $exitCode -ne 0 ]]; then
            echo -e "${CLR_YELLOW}Claude Code exited with non-zero code ($exitCode).${CLR_RESET}"
        fi
        read -rp "Claude Code session ended. Press Enter to return to menu" || true
    else
        local model
        model=$(config_get "selectedModel" "$DEFAULT_MODEL")

        if ! start_ollama_server; then
            read -rp "Press Enter to return to menu" || true
            return
        fi

        clear
        local cmdParts=("ollama" "launch" "claude")
        local customCmd
        customCmd=$(config_get "customCommand" "")
        if [[ -n "$customCmd" ]]; then
            read -ra customParts <<< "$customCmd"
            cmdParts=("${customParts[@]}")
        fi
        cmdParts+=("--model" "$model" "--")

        local skip
        skip=$(config_get "skipPermissions" "$DEFAULT_SKIPPERMS")
        if [[ "$skip" == "True" ]]; then
            cmdParts+=("--dangerously-skip-permissions")
        fi

        local cmdString
        cmdString=$(printf '%s ' "${cmdParts[@]}")
        echo -e "\n${CLR_GREEN}>>> $cmdString${CLR_RESET}"
        echo -e "${CLR_GRAY}$(printf '%.0s-' {1..50})${CLR_RESET}"

        clear
        if "${cmdParts[@]}"; then
            : # success
        else
            echo -e "${CLR_YELLOW}Claude Code exited with non-zero code.${CLR_RESET}"
        fi
        read -rp "Claude Code session ended. Press Enter to return to menu" || true
    fi
}

# ============================================================
#  Status & Menu
# ============================================================
function show_status() {
    local cExists="NO" oExists="NO" authOk="NO"
    command -v claude &>/dev/null && cExists="YES"
    command -v ollama &>/dev/null && oExists="YES"
    test_ollama_auth && authOk="YES"

    local model source provider
    model=$(config_get "selectedModel" "$DEFAULT_MODEL")
    source=$(config_get "source" "$DEFAULT_SOURCE")
    provider=$(config_get "provider" "$DEFAULT_PROVIDER")
    local skip
    skip=$(config_get "skipPermissions" "$DEFAULT_SKIPPERMS")

    local cUpdate="" oUpdate=""
    if [[ "$cExists" == "YES" ]]; then
        local cInst cLat
        cInst=$(get_claude_installed_version)
        cLat=$(get_claude_latest_version)
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

    echo -e "\n${CLR_CYAN}========== Claude Code + Ollama Launcher ==========${CLR_RESET}"
    if [[ "$cExists" == "YES" ]]; then
        local cInst
        cInst=$(get_claude_installed_version)
        if [[ -n "$cUpdate" ]]; then
            echo -e "  Claude Code   : ${CLR_YELLOW}v$cInst$cUpdate${CLR_RESET}"
        else
            echo -e "  Claude Code   : ${CLR_GREEN}v$cInst (up to date)${CLR_RESET}"
        fi
    else
        echo -e "  Claude Code   : ${CLR_RED}NOT INSTALLED${CLR_RESET}"
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
    echo -e "  Provider      : ${CLR_CYAN}$provider${CLR_RESET}"
    if [[ "$(lc "$provider")" == "deepseek" ]]; then
        local dsModel dsKey dsKeyStatus
        dsModel=$(config_get "deepseekModel" "$DEFAULT_DEEPSEEK_MODEL")
        dsKey=$(config_get "deepseekApiKey" "$DEFAULT_DEEPSEEK_KEY")
        if [[ -n "$dsKey" ]]; then dsKeyStatus="${CLR_GREEN}configured${CLR_RESET}"; else dsKeyStatus="${CLR_RED}MISSING${CLR_RESET}"; fi
        echo -e "  DeepSeek model: ${CLR_CYAN}$dsModel${CLR_RESET}"
        echo -e "  DeepSeek key  : $dsKeyStatus"
    fi
    echo -e "  Config model  : ${CLR_CYAN}$model [source: $source]${CLR_RESET}"
    local permText
    if [[ "$skip" == "True" ]]; then permText="ON (--dangerously-skip-permissions)"; else permText="OFF"; fi
    echo -e "  Skip-perms    : ${CLR_CYAN}$permText${CLR_RESET}"
    echo -e "${CLR_CYAN}===================================================${CLR_RESET}"
}

function show_main_menu() {
    show_status
    local cExists="NO" oExists="NO"
    command -v claude &>/dev/null && cExists="YES"
    command -v ollama &>/dev/null && oExists="YES"

    local cUpdate="" oUpdate=""
    if [[ "$cExists" == "YES" ]]; then
        local cInst cLat
        cInst=$(get_claude_installed_version)
        cLat=$(get_claude_latest_version)
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

    echo -e "\n[1] Install / Update Claude Code ${CLR_WHITE}"
    [[ -n "$cUpdate" ]] && echo -e "${CLR_YELLOW}$cUpdate${CLR_RESET}"
    echo -e "[2] Install / Update Ollama ${CLR_WHITE}"
    [[ -n "$oUpdate" ]] && echo -e "${CLR_YELLOW}$oUpdate${CLR_RESET}"
    echo -e "[3] Pick / Change Model  [current: $model] ${CLR_WHITE}"
    local source provider
    source=$(config_get "source" "$DEFAULT_SOURCE")
    provider=$(config_get "provider" "$DEFAULT_PROVIDER")
    if [[ "$source" == "cloud" && "$oExists" == "YES" && "$(lc "$provider")" != "deepseek" ]]; then
        echo -e "[4] Pull Selected Model Locally (ollama pull) ${CLR_WHITE}"
    else
        echo -e "[4] Pull Selected Model Locally [not applicable] ${CLR_GRAY}"
    fi
    echo -e "[5] Launch Claude Code ${CLR_GREEN}"
    echo -e "[6] Check / Fix Ollama Sign-in ${CLR_WHITE}"
    echo -e "[7] Refresh Status ${CLR_WHITE}"
    local cmdLabel
    cmdLabel=$(config_get "customCommand" "")
    echo -e "[C] Set Custom Launch Command $( [[ -n "$cmdLabel" ]] && echo "[custom: $cmdLabel]" || echo "[default: claude]" ) ${CLR_WHITE}"
    local toggleLabel
    if [[ "$(config_get "skipPermissions" "$DEFAULT_SKIPPERMS")" == "True" ]]; then
        toggleLabel="ON -> switch to normal mode"
    else
        toggleLabel="OFF -> switch to skip-perms mode"
    fi
    echo -e "[T] Toggle Permission Bypass: $toggleLabel ${CLR_WHITE}"
    echo -e "[Q] Quit ${CLR_MAGENTA}"
    echo ""
}

# ============================================================
#  Main
# ============================================================
ensure_config
ensure_cache

while true; do
    show_main_menu
    ask "Enter your choice: " choice
    case "$(lc "$choice")" in
        1)
            if command -v claude &>/dev/null; then
                inst="" lat=""
                inst=$(get_claude_installed_version)
                lat=$(get_claude_latest_version)
                if [[ -n "$inst" && -n "$lat" ]] && version_greater "$inst" "$lat"; then
                    echo -e "${CLR_YELLOW}Claude Code update available: v$inst installed, v$lat available.${CLR_RESET}"
                    ask "Update Claude Code now? (y/n) " ans
                    [[ "$(lc "$ans")" == "y" ]] && install_claude_code
                else
                    ask "Claude Code is up to date (v$inst). Reinstall anyway? (y/n) " ans
                    [[ "$(lc "$ans")" == "y" ]] && install_claude_code
                fi
            else
                ask "Install Claude Code now? (y/n) " ans
                [[ "$(lc "$ans")" == "y" ]] && install_claude_code
            fi
            read -rp "Press Enter to return to menu" || true
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
            read -rp "Press Enter to return to menu" || true
            ;;
        3)
            show_model_picker
            ;;
        4)
            src=""
            src=$(config_get "source" "$DEFAULT_SOURCE")
            prov=""
            prov=$(config_get "provider" "$DEFAULT_PROVIDER")
            if [[ "$src" == "cloud" && "$(lc "$prov")" != "deepseek" ]] && command -v ollama &>/dev/null; then
                pull_selected_model
            else
                echo -e "${CLR_YELLOW}Pull is only available when a cloud model is selected with Ollama provider.${CLR_RESET}"
                read -rp "Press Enter to continue" || true
            fi
            ;;
        5)
            if ! command -v claude &>/dev/null; then
                echo -e "${CLR_RED}ERROR: Claude Code is not installed. Please install it first (Menu option 1).${CLR_RESET}"
                read -rp "Press Enter to return to menu" || true
            else
                local launchProvider
                launchProvider=$(config_get "provider" "$DEFAULT_PROVIDER")
                if [[ "$(lc "$launchProvider")" == "deepseek" ]]; then
                    local dk
                    dk=$(config_get "deepseekApiKey" "$DEFAULT_DEEPSEEK_KEY")
                    if [[ -z "$dk" ]]; then
                        echo -e "${CLR_YELLOW}WARNING: DeepSeek API key is not set. Claude will launch but may fail.${CLR_RESET}"
                        echo -e "${CLR_YELLOW}Configure it via menu option [3] -> [K].${CLR_RESET}"
                        ask "Launch anyway? (y/n) " ans
                        if [[ "$(lc "$ans")" != "y" ]]; then
                            read -rp "Press Enter to return to menu" || true
                            continue
                        fi
                    fi
                    launch_claude
                elif ! command -v ollama &>/dev/null; then
                    echo -e "${CLR_RED}ERROR: Ollama is not installed. Please install it first (Menu option 2), or switch provider to DeepSeek.${CLR_RESET}"
                    read -rp "Press Enter to return to menu" || true
                else
                    launch_claude
                fi
            fi
            ;;
        6)
            check_ollama_signin
            ;;
        7)
            cache_set "claudeLastChecked" ""
            cache_set "ollamaLastChecked" ""
            echo -e "${CLR_GREEN}Version cache cleared.${CLR_RESET}"
            sleep 1
            ;;
        c)
            current=""
            current=$(config_get "customCommand" "")
            echo -e "${CLR_CYAN}Current custom command: $( [[ -n "$current" ]] && echo "$current" || echo '(empty = default claude)' )${CLR_RESET}"
            ask "Enter custom launch command (e.g. 'ollama launch claude'), or leave blank to reset: " newCmd
            config_set "customCommand" "${newCmd:-}"
            echo -e "${CLR_GREEN}Custom command updated.${CLR_RESET}"
            sleep 1
            ;;
        t)
            sp=""
            sp=$(config_get "skipPermissions" "$DEFAULT_SKIPPERMS")
            if [[ "$sp" == "True" ]]; then
                config_set "skipPermissions" "False"
                echo -e "${CLR_GREEN}Launch mode toggled to: NORMAL${CLR_RESET}"
            else
                config_set "skipPermissions" "True"
                echo -e "${CLR_GREEN}Launch mode toggled to: SKIP-PERMISSIONS${CLR_RESET}"
            fi
            sleep 1
            ;;
        q)
            echo -e "${CLR_GREEN}Exiting launcher. Goodbye!${CLR_RESET}"
            exit 0
            ;;
        *)
            echo -e "${CLR_RED}Invalid choice. Please try again.${CLR_RESET}"
            sleep 1
            ;;
    esac
done
