#!/usr/bin/env bash
set -euo pipefail

# ============================================================
#  DeepSeek CLI Launcher for macOS
#  Auto-updates Claude Code & Codex CLI, then interactive menu
# ============================================================

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/local/sbin:$PATH"
[[ ! -t 0 ]] && [[ -e /dev/tty ]] && exec < /dev/tty

if ! command -v python3 &>/dev/null; then
    echo "ERROR: python3 required. Install Xcode CLI tools: xcode-select --install"
    exit 1
fi

SCRIPT_DIR="$HOME/Documents/cli-launchers"
mkdir -p "$SCRIPT_DIR"
CONFIG_FILE="$SCRIPT_DIR/DeepSeek-Launcher.config.json"
LOG_FILE="$SCRIPT_DIR/launcher.log"

DEFAULT_MODEL="deepseek-v4-pro"

R='\033[0m'; RD='\033[1;31m'; GN='\033[1;32m'; YL='\033[1;33m'
CY='\033[1;36m'; MG='\033[1;35m'; WH='\033[1;37m'; GY='\033[0;37m'

lc() { echo "$1" | tr '[:upper:]' '[:lower:]'; }
ask() { printf -v "$2" '%s' ''; read -rp "$1" "$2" || true; }

# --- Logging ---
log() {
    local ts; ts=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$ts] $1" >> "$LOG_FILE" 2>/dev/null || true
    # Rotate at ~1MB
    if [[ -f "$LOG_FILE" ]]; then
        local sz; sz=$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
        if [[ $sz -gt 1048576 ]]; then mv "$LOG_FILE" "${LOG_FILE}.1" 2>/dev/null || true; fi
    fi
}
log "========== DeepSeek Launcher (macOS) started =========="

# --- JSON helpers ---
json_get() {
    local file="$1" key="$2" default="${3:-}"
    [[ ! -f "$file" ]] && { echo "$default"; return; }
    python3 -c "import json; d=json.load(open('$file')); print(d.get('$key','$default'))" 2>/dev/null || echo "$default"
}
json_set() {
    python3 -c "
import json, os
d = {}
if os.path.exists('$CONFIG_FILE'):
    try: d = json.load(open('$CONFIG_FILE'))
    except: pass
d['$1'] = '$2'
json.dump(d, open('$CONFIG_FILE','w'), indent=2)" 2>/dev/null
}
cfg() { json_get "$CONFIG_FILE" "$1" "$2"; }

# --- Version helpers ---
get_ver() {
    command -v "$1" &>/dev/null || { echo ""; return; }
    local v; v=$("$1" --version 2>/dev/null || true)
    [[ "$v" =~ ([0-9]+\.[0-9]+\.[0-9]+) ]] && echo "${BASH_REMATCH[1]}" || echo ""
}

is_stale() {
    local ts="$1"
    [[ -z "$ts" ]] && return 0
    python3 -c "
import datetime
try:
    t = datetime.datetime.fromisoformat('$ts'.replace('Z','+00:00'))
    delta = datetime.datetime.now(t.tzinfo) - t
    print('1' if delta.total_seconds() > 3600 else '0')
except: print('1')" 2>/dev/null | grep -q '1'
}

# ============================================================
# Auto-Update — checks npm registry directly
# ============================================================
auto_update() {
    echo -e "${GY}Auto-update check...${R}"
    log "Auto-update check starting"
    local did_work=0

    # --- Claude Code ---
    local claude_checked; claude_checked=$(cfg "claudeNpmChecked" "")
    local claude_latest; claude_latest=$(cfg "claudeNpmLatest" "")
    if is_stale "$claude_checked" || [[ -z "$claude_latest" ]]; then
        log "Fetching Claude Code latest from npm..."
        local resp; resp=$(curl -fsSL --max-time 10 "https://registry.npmjs.org/@anthropic-ai/claude-code/latest" 2>/dev/null || true)
        if [[ -n "$resp" ]]; then
            claude_latest=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('version',''))" 2>/dev/null || true)
            if [[ -n "$claude_latest" ]]; then
                json_set "claudeNpmLatest" "$claude_latest"
                json_set "claudeNpmChecked" "$(python3 -c 'import datetime; print(datetime.datetime.now().isoformat())' 2>/dev/null)"
                log "Claude Code npm latest: $claude_latest"
            fi
        else
            log "ERROR: offline, could not fetch Claude Code from npm"
        fi
    else
        log "Claude Code npm cache hit: $claude_latest"
    fi

    if [[ -n "$claude_latest" ]]; then
        if ! command -v claude &>/dev/null; then
            echo -e "${YL}  Claude Code: installing v$claude_latest...${R}"
            log "Claude Code not installed, installing v$claude_latest"
            if command -v npm &>/dev/null; then
                npm install -g @anthropic-ai/claude-code 2>/dev/null && sleep 3
            fi
            if command -v claude &>/dev/null; then
                claude install "$claude_latest" 2>/dev/null && \
                    echo -e "${GN}    Installed v$claude_latest${R}" && log "Claude Code install done" || \
                    { echo -e "${RD}    claude install failed${R}"; log "ERROR: claude install failed"; }
            else
                log "npm install didn't work, trying shell installer"
                curl -fsSL https://claude.ai/install.sh | sh 2>/dev/null && \
                    echo -e "${GN}    Installed${R}" || echo -e "${RD}    Install failed${R}"
            fi
            did_work=1
        else
            local ci; ci=$(get_ver claude)
            if [[ -n "$ci" && "$ci" != "$claude_latest" ]]; then
                echo -e "${YL}  Claude Code: v$ci -> v$claude_latest${R}"
                log "Claude Code update from v$ci to v$claude_latest"
                claude install "$claude_latest" 2>/dev/null && \
                    echo -e "${GN}    Updated to v$claude_latest${R}" && log "Claude Code update done" || \
                    { echo -e "${RD}    Update failed${R}"; log "ERROR: Claude Code update failed"; }
                did_work=1
            fi
        fi
    else
        echo -e "${GY}  Claude Code: offline, skipping.${R}"
    fi

    # --- Codex CLI ---
    local codex_checked; codex_checked=$(cfg "codexNpmChecked" "")
    local codex_latest; codex_latest=$(cfg "codexNpmLatest" "")
    if is_stale "$codex_checked" || [[ -z "$codex_latest" ]]; then
        log "Fetching Codex CLI latest from npm..."
        local resp; resp=$(curl -fsSL --max-time 10 "https://registry.npmjs.org/@openai/codex/latest" 2>/dev/null || true)
        if [[ -n "$resp" ]]; then
            codex_latest=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('version',''))" 2>/dev/null || true)
            if [[ -n "$codex_latest" ]]; then
                json_set "codexNpmLatest" "$codex_latest"
                json_set "codexNpmChecked" "$(python3 -c 'import datetime; print(datetime.datetime.now().isoformat())' 2>/dev/null)"
                log "Codex CLI npm latest: $codex_latest"
            fi
        else
            log "ERROR: offline, could not fetch Codex CLI from npm"
        fi
    else
        log "Codex CLI npm cache hit: $codex_latest"
    fi

    if [[ -n "$codex_latest" ]] && command -v npm &>/dev/null; then
        local ci; ci=$(get_ver codex)
        if [[ -z "$ci" ]]; then
            echo -e "${YL}  Codex CLI: installing v$codex_latest...${R}"
            log "Codex CLI not installed, installing v$codex_latest"
            npm install -g "@openai/codex@$codex_latest" 2>/dev/null && \
                echo -e "${GN}    Installed v$codex_latest${R}" && log "Codex CLI install done" || \
                { echo -e "${RD}    Install failed${R}"; log "ERROR: Codex CLI install failed"; }
            did_work=1
        elif [[ "$ci" != "$codex_latest" ]]; then
            echo -e "${YL}  Codex CLI: v$ci -> v$codex_latest${R}"
            log "Codex CLI update from v$ci to v$codex_latest"
            npm install -g "@openai/codex@$codex_latest" 2>/dev/null && \
                echo -e "${GN}    Updated to v$codex_latest${R}" && log "Codex CLI update done" || \
                { echo -e "${RD}    Update failed${R}"; log "ERROR: Codex CLI update failed"; }
            did_work=1
        fi
    fi

    [[ $did_work -eq 0 ]] && echo -e "${GY}  All up to date.${R}"
    echo ""
    log "Auto-update complete. did_work=$did_work"
}

# --- Status ---
show_status() {
    local has_claude="NO"; command -v claude &>/dev/null && has_claude="YES"
    local has_codex="NO";  command -v codex &>/dev/null && has_codex="YES"
    local claude_ver; claude_ver=$(get_ver claude)
    local codex_ver;  codex_ver=$(get_ver codex)
    local model; model=$(cfg "model" "$DEFAULT_MODEL")
    local key_status="NOT SET"; [[ -n "$(cfg 'apikey' '')" ]] && key_status="SET"
    local perms="ON"; [[ "$(cfg 'skipPerms' 'True')" != "True" ]] && perms="OFF"

    echo -e "\n${CY}========== DeepSeek CLI Launcher ==========${R}"
    if [[ "$has_claude" == "YES" && -n "$claude_ver" ]]; then echo -e "  Claude Code   : ${GN}v$claude_ver${R}"
    else echo -e "  Claude Code   : ${GY}not installed${R}"; fi
    if [[ "$has_codex" == "YES" && -n "$codex_ver" ]]; then echo -e "  Codex CLI     : ${GN}v$codex_ver${R}"
    else echo -e "  Codex CLI     : ${GY}not installed${R}"; fi
    [[ "$key_status" == "SET" ]] && echo -e "  DeepSeek Key  : ${GN}SET${R}" || echo -e "  DeepSeek Key  : ${RD}NOT SET${R}"
    echo -e "  Model         : ${CY}$model${R}"
    echo -e "  Skip Perms    : ${CY}$perms${R}"
    echo -e "${CY}============================================${R}"
}

# --- Launch ---
require_key() {
    [[ -n "$(cfg 'apikey' '')" ]] && return 0
    echo -e "${RD}API key not set! Use option 5.${R}"
    read -rp "Press Enter" || true
    return 1
}

launch_claude() {
    require_key || return
    local model; model=$(cfg "model" "$DEFAULT_MODEL")
    export ANTHROPIC_BASE_URL="https://api.deepseek.com/anthropic"
    export ANTHROPIC_API_KEY="$(cfg 'apikey' '')"
    export DISABLE_AUTOUPDATER=1
    log "Launching Claude Code CLI ($model)"
    local cmd=("claude")
    [[ "$(cfg 'skipPerms' 'True')" == "True" ]] && cmd+=("--dangerously-skip-permissions")
    clear
    echo -e "\n${GN}>>> claude (DeepSeek: $model)${R}"
    "${cmd[@]}" || { echo -e "${YL}Exited with non-zero code.${R}"; log "Claude Code exited non-zero"; }
    read -rp "Session ended. Press Enter" || true
}

launch_codex() {
    require_key || return
    local model; model=$(cfg "model" "$DEFAULT_MODEL")
    export OPENAI_API_KEY="$(cfg 'apikey' '')"
    export OPENAI_BASE_URL="https://api.deepseek.com/v1"
    log "Launching Codex CLI ($model)"
    local cmd=("codex" "-c" "model_reasoning_effort=high")
    [[ "$(cfg 'skipPerms' 'True')" == "True" ]] && cmd+=("--yolo")
    clear
    echo -e "\n${GN}>>> codex (DeepSeek: $model)${R}"
    "${cmd[@]}" || { echo -e "${YL}Exited with non-zero code.${R}"; log "Codex CLI exited non-zero"; }
    read -rp "Session ended. Press Enter" || true
}

launch_codex_app() {
    require_key || return
    local model; model=$(cfg "model" "$DEFAULT_MODEL")
    export DEEPSEEK_API_KEY="$(cfg 'apikey' '')"
    log "Launching Codex App ($model)"
    local cmd=("codex" "app" "-c" "model_provider=deepseek" "-c" "model=$model"
               "-c" "model_reasoning_effort=high" "-c" "wire_api=chat")
    clear
    echo -e "\n${GN}>>> codex app (DeepSeek: $model)${R}"
    "${cmd[@]}" || { echo -e "${YL}Exited with non-zero code.${R}"; log "Codex App exited non-zero"; }
    read -rp "Session ended. Press Enter" || true
}

launch_claude_desktop() {
    require_key || return
    local model; model=$(cfg "model" "$DEFAULT_MODEL")
    local api_key; api_key=$(cfg "apikey" "")
    log "Launching Claude Desktop ($model)"

    echo -e "\n${CY}Preparing Claude Desktop...${R}"
    pkill -f "/Applications/Claude.*\.app/Contents/MacOS/Claude" 2>/dev/null || true
    sleep 2
    log "Killed existing Claude Desktop (if any)"

    local cid; cid=$(uuidgen 2>/dev/null || python3 -c "import uuid; print(uuid.uuid4())" 2>/dev/null)
    local lib="$HOME/Library/Application Support/Claude-3p/configLibrary"
    mkdir -p "$lib"

    python3 -c "
import json, os
lib = '$lib'
cid = '$cid'
model_defs = [
    {'name': 'claude-opus-4-7',           'labelOverride': 'DeepSeek V4 Pro (Opus 4.7)'},
    {'name': 'claude-opus-4-6',           'labelOverride': 'DeepSeek V4 Pro (Opus 4.6)'},
    {'name': 'claude-sonnet-4-6',         'labelOverride': 'DeepSeek V4 Flash (Sonnet 4.6)'},
    {'name': 'claude-haiku-4-5-20251001', 'labelOverride': 'DeepSeek V4 Flash (Haiku 4.5)'},
]
meta = {'appliedId': cid, 'entries': [{'id': cid, 'name': 'DeepSeek Gateway'}]}
with open(os.path.join(lib, '_meta.json'), 'w') as f: json.dump(meta, f, indent=2)
config = {
    'inferenceProvider': 'gateway',
    'inferenceGatewayBaseUrl': 'https://api.deepseek.com/anthropic',
    'inferenceGatewayApiKey': '$api_key',
    'inferenceGatewayAuthScheme': 'bearer',
    'inferenceModels': model_defs,
    'disableEssentialTelemetry': True, 'disableNonessentialTelemetry': True,
    'disableNonessentialServices': True, 'unstableDisableModelVerification': True,
    'builtinToolPolicy': {
        'Bash': 'allow', 'Read': 'allow', 'Write': 'allow', 'Edit': 'allow',
        'Glob': 'allow', 'Grep': 'allow', 'NotebookEdit': 'allow',
        'WebFetch': 'allow', 'WebSearch': 'allow',
        'Task': 'allow', 'TaskCreate': 'allow', 'TaskUpdate': 'allow',
        'TaskGet': 'allow', 'TaskList': 'allow', 'TaskStop': 'allow',
        'Skill': 'allow', 'AskUserQuestion': 'allow', 'SendUserMessage': 'allow'
    }
}
with open(os.path.join(lib, cid + '.json'), 'w') as f: json.dump(config, f, indent=2)
# 3p config
config3p = {
    'deploymentMode': '3p',
    'enterpriseConfig': {k:v for k,v in config.items() if k != 'unstableDisableModelVerification'}
}
p3p = os.path.join(os.path.expanduser('~/Library/Application Support/Claude-3p'), 'claude_desktop_config.json')
os.makedirs(os.path.dirname(p3p), exist_ok=True)
with open(p3p, 'w') as f: json.dump(config3p, f, indent=2)
" 2>/dev/null
    log "Wrote 3p config"

    # Clear OAuth
    local cfg_path="$HOME/Library/Application Support/Claude/config.json"
    [[ -f "$cfg_path" ]] && python3 -c "
import json; d=json.load(open('$cfg_path'))
for k in ['oauth:tokenCache','oauth:refreshToken','oauth:accountId','oauth:accessToken',
          'oauth:expiresAt','oauth:token','activeAccountId','activeOrgId',
          'authSession','lastSignedInAccount','oauthTokens']:
    d.pop(k, None)
json.dump(d, open('$cfg_path','w'), indent=2)" 2>/dev/null && log "Cleared OAuth session"

    echo -e "${GY}  Config written. Look for 'Continue with Gateway' at sign-in.${R}"
    echo -e "${GN}Launching Claude Desktop...${R}"
    open -a Claude 2>/dev/null || open -a "Claude Code" 2>/dev/null || {
        echo -e "${RD}Claude Desktop not found. Install: https://claude.ai/download${R}"
        log "ERROR: Claude Desktop not found"
        read -rp "Press Enter" || true
    }
}

# --- Settings ---
set_api_key() {
    clear
    echo -e "${GN}========== Set DeepSeek API Key ==========${R}\n"
    local cur; cur=$(cfg "apikey" "")
    [[ -n "$cur" ]] && echo -e "${CY}Current key: ${cur:0:4}****${R}\n" || echo -e "${YL}No API key set.${R}\n"
    echo -e "${CY}Get key at: https://platform.deepseek.com/api_keys${R}\n"
    ask "Enter API key (blank to keep current): " key
    if [[ -n "$key" ]]; then
        json_set "apikey" "$key"
        echo -e "${GN}Saved.${R}"
        log "API key updated"
    fi
    sleep 1
}

pick_model() {
    clear
    echo -e "${GN}========== Pick Model ==========${R}\n"
    echo -e "Current: ${CY}$(cfg 'model' "$DEFAULT_MODEL")${R}\n"
    echo -e "  [1] DeepSeek V4 Pro  (deepseek-v4-pro)"
    echo -e "  [2] DeepSeek V4 Flash (deepseek-v4-flash)"
    echo -e "  [M] Manual entry\n"
    ask "Choice: " choice
    case "$(lc "$choice")" in
        1) json_set "model" "deepseek-v4-pro"; echo -e "${GN}Model: deepseek-v4-pro${R}"; log "Model changed: deepseek-v4-pro" ;;
        2) json_set "model" "deepseek-v4-flash"; echo -e "${GN}Model: deepseek-v4-flash${R}"; log "Model changed: deepseek-v4-flash" ;;
        m) ask "Enter model ID: " m; [[ -n "$m" ]] && { json_set "model" "$m"; echo -e "${GN}Model: $m${R}"; log "Model changed: $m"; read -rp "Press Enter" || true; } ;;
    esac
    sleep 1
}

# --- Menu ---
show_main_menu() {
    clear
    show_status
    local model; model=$(cfg "model" "$DEFAULT_MODEL")
    local perms="ON"; [[ "$(cfg 'skipPerms' 'True')" != "True" ]] && perms="OFF"

    echo ""
    echo -e "[1] Launch Claude Code          ${GN}${R}"
    echo -e "[2] Launch Codex CLI            ${GN}${R}"
    echo -e "[3] Launch Codex App            ${GN}${R}"
    echo -e "[4] Launch Claude Desktop       ${GN}${R}"
    echo -e "[5] Set DeepSeek API Key        ${WH}${R}"
    echo -e "[6] Pick Model [current: $model] ${WH}${R}"
    echo -e "[T] Toggle Permissions [$perms]     ${WH}${R}"
    echo -e "[L] View Log                    ${WH}${R}"
    echo -e "[Q] Quit                        ${MG}${R}"
    echo ""
}

# ============================================================
# Run
# ============================================================
[[ -f "$CONFIG_FILE" ]] || python3 -c "
import json
json.dump({'model':'$DEFAULT_MODEL','apikey':'','skipPerms':True,
           'claudeNpmLatest':'','claudeNpmChecked':'','codexNpmLatest':'','codexNpmChecked':''},
          open('$CONFIG_FILE','w'), indent=2)" 2>/dev/null

if auto_update 2>/dev/null; then :; else
    log "FATAL: auto-update crashed"
    echo -e "${RD}Auto-update error (continuing anyway)${R}"
fi

if [[ $# -gt 0 ]]; then
    [[ -z "$(cfg 'apikey' '')" ]] && { echo -e "${RD}API key not set. Run without args to configure.${R}"; exit 1; }
    log "Direct launch: $1"
    case "$(lc "$1")" in
        codex)          launch_codex; exit $? ;;
        claude)         launch_claude; exit $? ;;
        codex-app)      launch_codex_app; exit $? ;;
        claude-desktop) launch_claude_desktop; exit $? ;;
    esac
fi

while true; do
    show_main_menu
    ask "Choice: " choice
    log "Menu choice: $choice"
    case "$(lc "$choice")" in
        1) launch_claude ;;
        2) launch_codex ;;
        3) launch_codex_app ;;
        4) launch_claude_desktop ;;
        5) set_api_key ;;
        6) pick_model ;;
        t) local sp; sp=$(cfg "skipPerms" "True")
           [[ "$sp" == "True" ]] && json_set "skipPerms" "False" || json_set "skipPerms" "True"
           log "Permissions toggled" ;;
        l)
            clear
            echo -e "${CY}========== Log File ==========${R}"
            echo -e "Path: $LOG_FILE"
            echo ""
            if [[ -f "$LOG_FILE" ]]; then tail -40 "$LOG_FILE"; else echo -e "${YL}No log file yet.${R}"; fi
            echo ""; read -rp "Press Enter" || true ;;
        q) echo -e "${GN}Bye!${R}"; log "User quit"; exit 0 ;;
    esac
done
