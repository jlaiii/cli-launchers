#!/usr/bin/env bash
set -euo pipefail

# ============================================================
#  Ollama CLI Launcher for macOS
#  Codex CLI + Claude Code through Ollama
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

CONFIG_FILE="$SCRIPT_DIR/Ollama-Launcher.config.json"
VERSION_CACHE="$SCRIPT_DIR/Ollama-Launcher.versions.json"
CACHE_TTL_MINUTES=60

DEFAULT_MODEL="kimi-k2.6:cloud"
DEFAULT_SOURCE="cloud"
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
d={'selectedModel':'$DEFAULT_MODEL','source':'$DEFAULT_SOURCE','skipPermissions':True}
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
get_ollama_installed_version() {
    command -v ollama &>/dev/null || return
    local ver; ver=$(ollama --version 2>/dev/null || true)
    [[ "$ver" =~ ([0-9]+\.[0-9]+\.[0-9]+) ]] && echo "${BASH_REMATCH[1]}" || echo ""
}

get_ollama_latest_version() {
    local last; last=$(cache_get "ollamaLastChecked" "")
    cache_stale "$last" || { cache_get "ollamaLatestVersion" ""; return; }
    local resp; resp=$(curl -fsSL --max-time 15 "https://api.github.com/repos/ollama/ollama/releases/latest" 2>/dev/null || true)
    [[ -z "$resp" ]] && return
    local tag; tag=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tag_name',''))" 2>/dev/null || true)
    local ver="${tag#v}"
    [[ -n "$ver" ]] || return
    cache_set "ollamaLatestVersion" "$ver"
    cache_set "ollamaLastChecked" "$(python3 -c 'import datetime; print(datetime.datetime.now().isoformat())')"
    echo "$ver"
}

# --- Install ---
install_ollama() {
    echo -e "${CLR_CYAN}Installing/Updating Ollama...${CLR_RESET}"
    curl -fsSL https://ollama.com/install.sh | sh 2>/dev/null || echo -e "${CLR_RED}ERROR installing Ollama.${CLR_RESET}"
    read -rp "Press Enter to continue" || true
}

# --- Ollama Server ---
test_ollama_running() {
    curl -fsSL --max-time 3 "http://localhost:11434/api/tags" &>/dev/null && return 0 || return 1
}

start_ollama_server() {
    test_ollama_running && return 0
    echo -e "${CLR_YELLOW}Starting Ollama server...${CLR_RESET}"
    nohup ollama serve &>/dev/null &
    local tries=0
    while [[ $tries -lt 30 ]]; do
        sleep 0.5
        test_ollama_running && { echo -e "${CLR_GREEN}Ollama server ready.${CLR_RESET}"; return 0; }
        ((tries++))
    done
    echo -e "${CLR_RED}Ollama server did not start.${CLR_RESET}"
    return 1
}

test_ollama_auth() { ollama list &>/dev/null && return 0 || return 1; }

# --- Model Fetchers ---
fetch_cloud_models() {
    echo -e "${CLR_GRAY}Fetching newest models from Ollama registry...${CLR_RESET}"
    local resp; resp=$(curl -fsSL --max-time 15 "https://ollama.com/api/tags" 2>/dev/null || true)
    [[ -z "$resp" ]] && { echo -e "${CLR_RED}Failed.${CLR_RESET}"; return; }
    echo "$resp" | python3 -c "
import sys,json
try:
 d=json.load(sys.stdin)
 for m in sorted(d.get('models',[]), key=lambda x: x.get('modified_at',''), reverse=True)[:10]:
  gb=m.get('size',0)/1024/1024/1024
  print(f\"{m['name']}|{gb:.2f}|{m.get('modified_at','')[:10]}\")
except: pass" 2>/dev/null || true
}

fetch_local_models() {
    echo -e "${CLR_GRAY}Fetching local models from Ollama...${CLR_RESET}"
    local resp; resp=$(curl -fsSL --max-time 5 "http://localhost:11434/api/tags" 2>/dev/null || true)
    [[ -z "$resp" ]] && { echo -e "${CLR_RED}Failed.${CLR_RESET}"; return; }
    echo "$resp" | python3 -c "
import sys,json
try:
 d=json.load(sys.stdin)
 for m in sorted(d.get('models',[]), key=lambda x: x.get('modified_at',''), reverse=True):
  gb=m.get('size',0)/1024/1024/1024
  print(f\"{m['name']}|{gb:.2f}|{m.get('modified_at','')[:10]}\")
except: pass" 2>/dev/null || true
}

# --- Model Picker ---
show_cloud_model_menu() {
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
            read -rp "Press Enter" || true; return
        fi
        local idx=0 i=1
        while [[ $idx -lt ${#models[@]} ]]; do
            printf "  [%d] ${CLR_CYAN}%s${CLR_RESET}  (%s GB, %s)\n" "$i" "${models[idx]}" "${models[idx+1]}" "${models[idx+2]}"
            ((idx+=3)); ((i++))
        done
        echo ""; echo -e "  [M] Manual entry"
        echo -e "  [B] Back"; echo ""
        ask "Select: " choice
        case "$(lc "$choice")" in
            b) return ;;
            m)
                ask "Enter model name (e.g., kimi-k2.6:cloud): " manual
                [[ -n "$manual" ]] && { config_set "selectedModel" "$manual"; config_set "source" "cloud"; echo -e "${CLR_GREEN}Model: $manual${CLR_RESET}"; }
                read -rp "Press Enter" || true; return
                ;;
        esac
        if [[ "$choice" =~ ^[0-9]+$ ]]; then
            local arr_idx=$(( (choice-1)*3 ))
            [[ $arr_idx -ge 0 && $arr_idx -lt ${#models[@]} ]] && {
                config_set "selectedModel" "${models[arr_idx]}"; config_set "source" "cloud"
                echo -e "${CLR_GREEN}Model: ${models[arr_idx]}${CLR_RESET}"; }
        fi
        read -rp "Press Enter" || true
    done
}

show_local_model_menu() {
    while true; do
        clear
        echo -e "${CLR_GREEN}=============================================${CLR_RESET}"
        echo -e "${CLR_GREEN}   Local Models (on this Mac)${CLR_RESET}"
        echo -e "${CLR_GREEN}=============================================${CLR_RESET}"
        echo ""
        local models=()
        while IFS='|' read -r name size date; do
            [[ -n "$name" ]] && models+=("$name" "$size" "$date")
        done < <(fetch_local_models)
        if [[ ${#models[@]} -eq 0 ]]; then
            echo -e "${CLR_YELLOW}No local models found.${CLR_RESET}"
            read -rp "Press Enter" || true; return
        fi
        local idx=0 i=1
        while [[ $idx -lt ${#models[@]} ]]; do
            printf "  [%d] ${CLR_CYAN}%s${CLR_RESET}  (%s GB, %s)\n" "$i" "${models[idx]}" "${models[idx+1]}" "${models[idx+2]}"
            ((idx+=3)); ((i++))
        done
        echo ""; echo -e "  [B] Back"; echo ""
        ask "Select: " choice
        case "$(lc "$choice")" in b) return ;; esac
        if [[ "$choice" =~ ^[0-9]+$ ]]; then
            local arr_idx=$(( (choice-1)*3 ))
            [[ $arr_idx -ge 0 && $arr_idx -lt ${#models[@]} ]] && {
                config_set "selectedModel" "${models[arr_idx]}"; config_set "source" "local"
                echo -e "${CLR_GREEN}Model: ${models[arr_idx]}${CLR_RESET}"; }
        fi
        read -rp "Press Enter" || true
    done
}

show_model_picker() {
    while true; do
        clear
        echo -e "${CLR_GREEN}=============================================${CLR_RESET}"
        echo -e "${CLR_GREEN}         Pick / Change Model${CLR_RESET}"
        echo -e "${CLR_GREEN}=============================================${CLR_RESET}"
        echo ""
        echo -e "Current: ${CLR_CYAN}$(config_get 'selectedModel' "$DEFAULT_MODEL") [source: $(config_get 'source' "$DEFAULT_SOURCE")]${CLR_RESET}"
        echo ""
        echo -e "  [1] Browse Cloud Models"
        echo -e "  [2] Browse Local Models"
        echo -e "  [3] Manual Entry"
        echo -e "  [B] Back"
        echo ""
        ask "Enter choice: " choice
        case "$(lc "$choice")" in
            1) show_cloud_model_menu ;;
            2) show_local_model_menu ;;
            3)
                ask "Enter model name: " manual
                [[ -n "$manual" ]] && { config_set "selectedModel" "$manual"; config_set "source" "manual"; echo -e "${CLR_GREEN}Model: $manual${CLR_RESET}"; read -rp "Press Enter" || true; }
                ;;
            b) return ;;
        esac
    done
}

# --- Pull & Sign-in ---
pull_selected_model() {
    local model; model=$(config_get "selectedModel" "$DEFAULT_MODEL")
    echo -e "${CLR_CYAN}Pulling '$model'...${CLR_RESET}"
    ollama pull "$model" 2>/dev/null && echo -e "${CLR_GREEN}Done.${CLR_RESET}" || echo -e "${CLR_RED}ERROR.${CLR_RESET}"
    read -rp "Press Enter" || true
}

check_ollama_signin() {
    echo -e "${CLR_CYAN}Checking Ollama sign-in...${CLR_RESET}"
    if ollama list &>/dev/null; then
        echo -e "${CLR_GREEN}Signed in. Local models:${CLR_RESET}"
        ollama list 2>/dev/null | head -10 | while read -r line; do echo -e "${CLR_GRAY}  $line${CLR_RESET}"; done
    else
        echo -e "${CLR_YELLOW}Could not list models.${CLR_RESET}"
        ask "Run 'ollama signin'? (y/n) " ans
        [[ "$(lc "$ans")" == "y" ]] && ollama signin
    fi
    read -rp "Press Enter" || true
}

# --- Launch ---
launch_codex() {
    local model; model=$(config_get "selectedModel" "$DEFAULT_MODEL")
    start_ollama_server || { read -rp "Press Enter" || true; return; }
    local -a cmd=("ollama" "launch" "codex" "--model" "$model" "--")
    [[ "$(config_get 'skipPermissions' "$DEFAULT_SKIPPERMS")" == "True" ]] && cmd+=("--yolo")
    clear
    echo -e "\n${CLR_GREEN}>>> ${cmd[*]}${CLR_RESET}"
    "${cmd[@]}" || echo -e "${CLR_YELLOW}Codex exited with non-zero code.${CLR_RESET}"
    read -rp "Session ended. Press Enter" || true
}

launch_claude() {
    local model; model=$(config_get "selectedModel" "$DEFAULT_MODEL")
    start_ollama_server || { read -rp "Press Enter" || true; return; }
    local -a cmd=("ollama" "launch" "claude" "--model" "$model" "--")
    [[ "$(config_get 'skipPermissions' "$DEFAULT_SKIPPERMS")" == "True" ]] && cmd+=("--dangerously-skip-permissions")
    clear
    echo -e "\n${CLR_GREEN}>>> ${cmd[*]}${CLR_RESET}"
    "${cmd[@]}" || echo -e "${CLR_YELLOW}Claude Code exited with non-zero code.${CLR_RESET}"
    read -rp "Session ended. Press Enter" || true
}

launch_codex_app() {
    local model; model=$(config_get "selectedModel" "$DEFAULT_MODEL")
    start_ollama_server || { read -rp "Press Enter" || true; return; }
    local -a cmd=("ollama" "launch" "codex-app" "--model" "$model")
    clear
    echo -e "\n${CLR_GREEN}>>> ${cmd[*]}${CLR_RESET}"
    "${cmd[@]}" || echo -e "${CLR_YELLOW}Codex App exited with non-zero code.${CLR_RESET}"
    read -rp "Session ended. Press Enter" || true
}

# --- Status & Menu ---
show_status() {
    local oExists="NO"; command -v ollama &>/dev/null && oExists="YES"
    local authOk="NO"; test_ollama_auth && authOk="YES"
    local model source oUpdate=""
    model=$(config_get "selectedModel" "$DEFAULT_MODEL")
    source=$(config_get "source" "$DEFAULT_SOURCE")

    if [[ "$oExists" == "YES" ]]; then
        local oInst oLat
        oInst=$(get_ollama_installed_version)
        oLat=$(get_ollama_latest_version)
        [[ -n "$oInst" && -n "$oLat" ]] && version_greater "$oInst" "$oLat" && oUpdate=" (update v$oLat available)"
    fi

    echo -e "\n${CLR_CYAN}========== Ollama CLI Launcher ==========${CLR_RESET}"
    if [[ "$oExists" == "YES" ]]; then
        [[ -n "$oUpdate" ]] && echo -e "  Ollama        : ${CLR_YELLOW}v$oInst$oUpdate${CLR_RESET}" || echo -e "  Ollama        : ${CLR_GREEN}v$oInst (up to date)${CLR_RESET}"
    else
        echo -e "  Ollama        : ${CLR_RED}NOT INSTALLED${CLR_RESET}"
    fi
    [[ "$authOk" == "YES" ]] && echo -e "  Ollama Auth   : ${CLR_GREEN}OK${CLR_RESET}" || echo -e "  Ollama Auth   : ${CLR_RED}NOT SIGNED IN${CLR_RESET}"
    echo -e "  Model         : ${CLR_CYAN}$model [source: $source]${CLR_RESET}"
    local permText
    [[ "$(config_get 'skipPermissions' "$DEFAULT_SKIPPERMS")" == "True" ]] && permText="ON" || permText="OFF"
    echo -e "  Skip-perms    : ${CLR_CYAN}$permText${CLR_RESET}"
    echo -e "${CLR_CYAN}==========================================${CLR_RESET}"
}

show_main_menu() {
    clear
    show_status
    local oExists="NO"; command -v ollama &>/dev/null && oExists="YES"
    local model; model=$(config_get "selectedModel" "$DEFAULT_MODEL")

    echo -e "\n[1] Install / Update Ollama ${CLR_WHITE}"
    if [[ "$oExists" == "YES" ]]; then
        local oInst oLat; oInst=$(get_ollama_installed_version); oLat=$(get_ollama_latest_version)
        [[ -n "$oInst" && -n "$oLat" ]] && version_greater "$oInst" "$oLat" && echo -e "${CLR_YELLOW}     ^^ UPDATE AVAILABLE${CLR_RESET}"
    fi
    echo -e "[2] Pick / Change Model  [current: $model] ${CLR_WHITE}"
    local source; source=$(config_get "source" "$DEFAULT_SOURCE")
    if [[ "$source" == "cloud" && "$oExists" == "YES" ]]; then
        echo -e "[3] Pull Selected Model Locally ${CLR_WHITE}"
    else
        echo -e "[3] Pull Selected Model Locally [not applicable] ${CLR_GRAY}"
    fi
    echo -e "[4] Launch Codex CLI (via Ollama) ${CLR_GREEN}"
    echo -e "[5] Launch Claude Code (via Ollama) ${CLR_GREEN}"
    echo -e "[6] Launch Codex App (via Ollama) ${CLR_GREEN}"
    echo -e "[7] Check / Fix Ollama Sign-in ${CLR_WHITE}"
    echo -e "[8] Clear Version Cache ${CLR_WHITE}"
    local permText
    [[ "$(config_get 'skipPermissions' "$DEFAULT_SKIPPERMS")" == "True" ]] && permText="ON" || permText="OFF"
    echo -e "[T] Toggle Permission Bypass [currently: $permText] ${CLR_WHITE}"
    echo -e "[Q] Quit ${CLR_MAGENTA}"
    echo ""
}

# --- Main ---
ensure_config

if [[ $# -gt 0 ]]; then
    case "$(lc "$1")" in
        codex)
            command -v ollama &>/dev/null || { echo "Ollama not found. Installing..."; install_ollama; }
            start_ollama_server || exit 1
            launch_codex; exit $?
            ;;
        claude)
            command -v ollama &>/dev/null || { echo "Ollama not found. Installing..."; install_ollama; }
            start_ollama_server || exit 1
            launch_claude; exit $?
            ;;
        codex-app)
            command -v ollama &>/dev/null || { echo "Ollama not found. Installing..."; install_ollama; }
            start_ollama_server || exit 1
            launch_codex_app; exit $?
            ;;
    esac
fi

while true; do
    show_main_menu
    ask "Enter choice: " choice
    case "$(lc "$choice")" in
        1)
            if command -v ollama &>/dev/null; then
                local oInst oLat; oInst=$(get_ollama_installed_version); oLat=$(get_ollama_latest_version)
                [[ -n "$oInst" && -n "$oLat" ]] && version_greater "$oInst" "$oLat" && {
                    echo -e "${CLR_YELLOW}Ollama update: v$oInst -> v$oLat${CLR_RESET}"
                    ask "Update now? (y/n) " ans; [[ "$(lc "$ans")" == "y" ]] && install_ollama
                } || { ask "Ollama is up to date. Reinstall? (y/n) " ans; [[ "$(lc "$ans")" == "y" ]] && install_ollama; }
            else
                ask "Install Ollama now? (y/n) " ans; [[ "$(lc "$ans")" == "y" ]] && install_ollama
            fi
            read -rp "Press Enter" || true
            ;;
        2) show_model_picker ;;
        3)
            if [[ "$(config_get 'source' "$DEFAULT_SOURCE")" == "cloud" ]] && command -v ollama &>/dev/null; then
                pull_selected_model
            else
                echo -e "${CLR_YELLOW}Only available with cloud models and Ollama installed.${CLR_RESET}"
                read -rp "Press Enter" || true
            fi
            ;;
        4)
            command -v ollama &>/dev/null || { echo -e "${CLR_RED}Ollama not installed. Use option 1.${CLR_RESET}"; read -rp "Press Enter" || true; continue; }
            launch_codex
            ;;
        5)
            command -v ollama &>/dev/null || { echo -e "${CLR_RED}Ollama not installed. Use option 1.${CLR_RESET}"; read -rp "Press Enter" || true; continue; }
            launch_claude
            ;;
        6)
            command -v ollama &>/dev/null || { echo -e "${CLR_RED}Ollama not installed. Use option 1.${CLR_RESET}"; read -rp "Press Enter" || true; continue; }
            launch_codex_app
            ;;
        7) check_ollama_signin ;;
        8)
            cache_set "ollamaLastChecked" ""
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
