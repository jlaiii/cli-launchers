#!/usr/bin/env bash
set -euo pipefail

# ============================================================
#  Ollama CLI Launcher for macOS
#  Auto-updates Ollama + Claude Code + Codex CLI, then menu
# ============================================================

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/local/sbin:$PATH"
[[ ! -t 0 ]] && [[ -e /dev/tty ]] && exec < /dev/tty

if ! command -v python3 &>/dev/null; then
    echo "ERROR: python3 required. Install Xcode CLI tools: xcode-select --install"
    exit 1
fi

SCRIPT_DIR="$HOME/Documents/cli-launchers"
mkdir -p "$SCRIPT_DIR"
CONFIG_FILE="$SCRIPT_DIR/Ollama-Launcher.config.json"
LOG_FILE="$SCRIPT_DIR/launcher.log"

DEFAULT_MODEL="kimi-k2.6:cloud"

R='\033[0m'; RD='\033[1;31m'; GN='\033[1;32m'; YL='\033[1;33m'
CY='\033[1;36m'; MG='\033[1;35m'; WH='\033[1;37m'; GY='\033[0;37m'

lc() { echo "$1" | tr '[:upper:]' '[:lower:]'; }
ask() { printf -v "$2" '%s' ''; read -rp "$1" "$2" || true; }

# --- Logging ---
log() {
    local ts; ts=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$ts] $1" >> "$LOG_FILE" 2>/dev/null || true
    if [[ -f "$LOG_FILE" ]]; then
        local sz; sz=$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
        [[ $sz -gt 1048576 ]] && mv "$LOG_FILE" "${LOG_FILE}.1" 2>/dev/null || true
    fi
}
log "========== Ollama Launcher (macOS) started =========="

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

# --- Server ---
ollama_running() { curl -fsSL --max-time 3 "http://localhost:11434/api/tags" &>/dev/null; }
start_ollama() {
    ollama_running && return 0
    echo -e "${YL}Starting Ollama server...${R}"
    log "Starting Ollama server"
    nohup ollama serve &>/dev/null &
    local tries=0
    while [[ $tries -lt 30 ]]; do
        sleep 0.5; ollama_running && { echo -e "${GN}Ollama server ready.${R}"; log "Ollama server started"; return 0; }
        ((tries++))
    done
    echo -e "${RD}Ollama server did not start.${R}"
    log "Ollama server start timeout"
    return 1
}

# ============================================================
# Auto-Update
# ============================================================
auto_update() {
    echo -e "${GY}Auto-update check...${R}"
    log "Auto-update check starting"
    local did_work=0

    # --- Ollama (GitHub releases) ---
    local o_checked; o_checked=$(cfg "ollamaChecked" "")
    local o_latest; o_latest=$(cfg "ollamaLatest" "")
    if is_stale "$o_checked" || [[ -z "$o_latest" ]]; then
        log "Fetching Ollama latest from GitHub..."
        local resp; resp=$(curl -fsSL --max-time 10 "https://api.github.com/repos/ollama/ollama/releases/latest" 2>/dev/null || true)
        if [[ -n "$resp" ]]; then
            o_latest=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tag_name','').lstrip('v'))" 2>/dev/null || true)
            if [[ -n "$o_latest" ]]; then
                json_set "ollamaLatest" "$o_latest"
                json_set "ollamaChecked" "$(python3 -c 'import datetime; print(datetime.datetime.now().isoformat())' 2>/dev/null)"
                log "Ollama latest: $o_latest"
            fi
        else
            log "ERROR: offline, could not fetch Ollama"
        fi
    else
        log "Ollama cache hit: $o_latest"
    fi

    if command -v ollama &>/dev/null && [[ -n "$o_latest" ]]; then
        local oi; oi=$(get_ver ollama)
        if [[ -n "$oi" && "$oi" != "$o_latest" ]]; then
            echo -e "${YL}  Ollama: v$oi -> v$o_latest${R}"
            log "Ollama update from v$oi to v$o_latest"
            curl -fsSL https://ollama.com/install.sh | sh 2>/dev/null && echo -e "${GN}    Updated${R}" || echo -e "${RD}    Failed${R}"
            did_work=1
        fi
    elif ! command -v ollama &>/dev/null; then
        echo -e "${YL}  Ollama: installing...${R}"
        log "Ollama not installed, installing"
        curl -fsSL https://ollama.com/install.sh | sh 2>/dev/null && echo -e "${GN}    Installed${R}" || echo -e "${RD}    Failed${R}"
        did_work=1
    fi

    # --- Claude Code (npm) ---
    local c_checked; c_checked=$(cfg "claudeNpmChecked" "")
    local c_latest; c_latest=$(cfg "claudeNpmLatest" "")
    if is_stale "$c_checked" || [[ -z "$c_latest" ]]; then
        log "Fetching Claude Code latest from npm..."
        local resp; resp=$(curl -fsSL --max-time 10 "https://registry.npmjs.org/@anthropic-ai/claude-code/latest" 2>/dev/null || true)
        if [[ -n "$resp" ]]; then
            c_latest=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('version',''))" 2>/dev/null || true)
            if [[ -n "$c_latest" ]]; then
                json_set "claudeNpmLatest" "$c_latest"
                json_set "claudeNpmChecked" "$(python3 -c 'import datetime; print(datetime.datetime.now().isoformat())' 2>/dev/null)"
                log "Claude Code npm latest: $c_latest"
            fi
        else
            log "ERROR: offline, could not fetch Claude Code"
        fi
    else
        log "Claude Code npm cache hit: $c_latest"
    fi

    if [[ -n "$c_latest" ]]; then
        if ! command -v claude &>/dev/null; then
            echo -e "${YL}  Claude Code: installing v$c_latest...${R}"
            log "Claude Code not installed, installing v$c_latest"
            if command -v npm &>/dev/null; then npm install -g @anthropic-ai/claude-code 2>/dev/null && sleep 3; fi
            if command -v claude &>/dev/null; then claude install "$c_latest" 2>/dev/null && echo -e "${GN}    Installed${R}" || echo -e "${RD}    Failed${R}"; fi
            did_work=1
        else
            local ci; ci=$(get_ver claude)
            if [[ -n "$ci" && "$ci" != "$c_latest" ]]; then
                echo -e "${YL}  Claude Code: v$ci -> v$c_latest${R}"
                log "Claude Code update from v$ci to v$c_latest"
                claude install "$c_latest" 2>/dev/null && echo -e "${GN}    Updated${R}" || echo -e "${RD}    Failed${R}"
                did_work=1
            fi
        fi
    fi

    # --- Codex CLI (npm) ---
    local x_checked; x_checked=$(cfg "codexNpmChecked" "")
    local x_latest; x_latest=$(cfg "codexNpmLatest" "")
    if is_stale "$x_checked" || [[ -z "$x_latest" ]]; then
        log "Fetching Codex CLI latest from npm..."
        local resp; resp=$(curl -fsSL --max-time 10 "https://registry.npmjs.org/@openai/codex/latest" 2>/dev/null || true)
        if [[ -n "$resp" ]]; then
            x_latest=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('version',''))" 2>/dev/null || true)
            if [[ -n "$x_latest" ]]; then
                json_set "codexNpmLatest" "$x_latest"
                json_set "codexNpmChecked" "$(python3 -c 'import datetime; print(datetime.datetime.now().isoformat())' 2>/dev/null)"
                log "Codex CLI npm latest: $x_latest"
            fi
        else
            log "ERROR: offline, could not fetch Codex CLI"
        fi
    else
        log "Codex CLI npm cache hit: $x_latest"
    fi

    if [[ -n "$x_latest" ]] && command -v npm &>/dev/null; then
        local xi; xi=$(get_ver codex)
        if [[ -z "$xi" ]]; then
            echo -e "${YL}  Codex CLI: installing v$x_latest...${R}"
            log "Codex CLI not installed, installing v$x_latest"
            npm install -g "@openai/codex@$x_latest" 2>/dev/null && echo -e "${GN}    Installed${R}" || echo -e "${RD}    Failed${R}"
            did_work=1
        elif [[ "$xi" != "$x_latest" ]]; then
            echo -e "${YL}  Codex CLI: v$xi -> v$x_latest${R}"
            log "Codex CLI update from v$xi to v$x_latest"
            npm install -g "@openai/codex@$x_latest" 2>/dev/null && echo -e "${GN}    Updated${R}" || echo -e "${RD}    Failed${R}"
            did_work=1
        fi
    fi

    [[ $did_work -eq 0 ]] && echo -e "${GY}  All up to date.${R}"
    echo ""
    log "Auto-update complete. did_work=$did_work"
}

# --- Status ---
show_status() {
    local has_o="NO"; command -v ollama &>/dev/null && has_o="YES"
    local has_c="NO"; command -v claude &>/dev/null && has_c="YES"
    local has_x="NO"; command -v codex &>/dev/null && has_x="YES"
    local ov; ov=$(get_ver ollama); local cv; cv=$(get_ver claude); local xv; xv=$(get_ver codex)
    local model; model=$(cfg "model" "$DEFAULT_MODEL")
    local source; source=$(cfg "source" "cloud")
    local perms="ON"; [[ "$(cfg 'skipPerms' 'True')" != "True" ]] && perms="OFF"

    echo -e "\n${CY}========== Ollama CLI Launcher ==========${R}"
    [[ "$has_o" == "YES" && -n "$ov" ]] && echo -e "  Ollama        : ${GN}v$ov${R}" || echo -e "  Ollama        : ${RD}NOT INSTALLED${R}"
    [[ "$has_c" == "YES" && -n "$cv" ]] && echo -e "  Claude Code   : ${GN}v$cv${R}" || echo -e "  Claude Code   : ${GY}not installed${R}"
    [[ "$has_x" == "YES" && -n "$xv" ]] && echo -e "  Codex CLI     : ${GN}v$xv${R}" || echo -e "  Codex CLI     : ${GY}not installed${R}"
    echo -e "  Model         : ${CY}$model [$source]${R}"
    echo -e "  Skip Perms    : ${CY}$perms${R}"
    echo -e "${CY}============================================${R}"
}

# --- Model Browser ---
fetch_cloud() {
    local resp; resp=$(curl -fsSL --max-time 15 "https://ollama.com/api/tags" 2>/dev/null || true)
    [[ -z "$resp" ]] && return
    echo "$resp" | python3 -c "
import sys,json
for m in sorted(json.load(sys.stdin).get('models',[]), key=lambda x: x.get('modified_at',''), reverse=True)[:10]:
    gb=m.get('size',0)/1024/1024/1024
    print(f\"{m['name']}|{gb:.2f}\")" 2>/dev/null || true
}

fetch_local() {
    local resp; resp=$(curl -fsSL --max-time 5 "http://localhost:11434/api/tags" 2>/dev/null || true)
    [[ -z "$resp" ]] && return
    echo "$resp" | python3 -c "
import sys,json
for m in json.load(sys.stdin).get('models',[]):
    gb=m.get('size',0)/1024/1024/1024
    print(f\"{m['name']}|{gb:.2f}\")" 2>/dev/null || true
}

browse_cloud() {
    clear
    echo -e "${GN}========== Cloud Models (Newest 10) ==========${R}\n"
    local models=()
    while IFS='|' read -r n s; do [[ -n "$n" ]] && models+=("$n" "$s"); done < <(fetch_cloud)
    if [[ ${#models[@]} -eq 0 ]]; then echo -e "${RD}No models fetched.${R}"; read -rp "Press Enter" || true; return; fi
    local i=1 idx=0
    while [[ $idx -lt ${#models[@]} ]]; do
        printf "  [%d] ${CY}%s${R}  (%s GB)\n" "$i" "${models[idx]}" "${models[idx+1]}"
        ((idx+=2)); ((i++))
    done
    echo -e "\n  [M] Manual  [B] Back\n"
    ask "Select: " c
    case "$(lc "$c")" in
        b) return ;;
        m) ask "Model: " m; [[ -n "$m" ]] && { json_set "model" "$m"; json_set "source" "cloud"; }; return ;;
    esac
    if [[ "$c" =~ ^[0-9]+$ ]]; then
        local ai=$(( (c-1)*2 ))
        [[ $ai -ge 0 && $ai -lt ${#models[@]} ]] && { json_set "model" "${models[ai]}"; json_set "source" "cloud"; echo -e "${GN}Model: ${models[ai]}${R}"; }
    fi
    read -rp "Press Enter" || true
}

browse_local() {
    clear
    echo -e "${GN}========== Local Models ==========${R}\n"
    local models=()
    while IFS='|' read -r n s; do [[ -n "$n" ]] && models+=("$n" "$s"); done < <(fetch_local)
    if [[ ${#models[@]} -eq 0 ]]; then echo -e "${YL}No local models.${R}"; read -rp "Press Enter" || true; return; fi
    local i=1 idx=0
    while [[ $idx -lt ${#models[@]} ]]; do
        printf "  [%d] ${CY}%s${R}  (%s GB)\n" "$i" "${models[idx]}" "${models[idx+1]}"
        ((idx+=2)); ((i++))
    done
    echo -e "\n  [B] Back\n"
    ask "Select: " c
    case "$(lc "$c")" in b) return ;; esac
    if [[ "$c" =~ ^[0-9]+$ ]]; then
        local ai=$(( (c-1)*2 ))
        [[ $ai -ge 0 && $ai -lt ${#models[@]} ]] && { json_set "model" "${models[ai]}"; json_set "source" "local"; echo -e "${GN}Model: ${models[ai]}${R}"; }
    fi
    read -rp "Press Enter" || true
}

show_model_picker() {
    while true; do
        clear
        echo -e "${GN}========== Pick Model ==========${R}\n"
        echo -e "Current: ${CY}$(cfg 'model' "$DEFAULT_MODEL") [$(cfg 'source' 'cloud')]${R}\n"
        echo -e "  [1] Browse Cloud Models"
        echo -e "  [2] Browse Local Models"
        echo -e "  [3] Manual Entry"
        echo -e "  [P] Pull Current Model"
        echo -e "  [B] Back\n"
        ask "Choice: " c
        case "$(lc "$c")" in
            1) browse_cloud ;;
            2) browse_local ;;
            3) ask "Model: " m; [[ -n "$m" ]] && { json_set "model" "$m"; json_set "source" "manual"; }; read -rp "Press Enter" || true ;;
            p) echo -e "${CY}Pulling '$(cfg 'model' "$DEFAULT_MODEL")'...${R}"; ollama pull "$(cfg 'model' "$DEFAULT_MODEL")"; read -rp "Press Enter" || true ;;
            b) return ;;
        esac
    done
}

# --- Launch ---
launch_codex() {
    start_ollama || { read -rp "Press Enter" || true; return; }
    local model; model=$(cfg "model" "$DEFAULT_MODEL")
    log "Launching Codex CLI via Ollama ($model)"
    local cmd=("ollama" "launch" "codex" "--model" "$model" "--")
    [[ "$(cfg 'skipPerms' 'True')" == "True" ]] && cmd+=("--yolo")
    clear
    echo -e "\n${GN}>>> ollama launch codex --model $model${R}"
    "${cmd[@]}" || echo -e "${YL}Exited non-zero.${R}"
    read -rp "Press Enter" || true
}

launch_claude() {
    start_ollama || { read -rp "Press Enter" || true; return; }
    local model; model=$(cfg "model" "$DEFAULT_MODEL")
    log "Launching Claude Code via Ollama ($model)"
    local cmd=("ollama" "launch" "claude" "--model" "$model" "--")
    [[ "$(cfg 'skipPerms' 'True')" == "True" ]] && cmd+=("--dangerously-skip-permissions")
    clear
    echo -e "\n${GN}>>> ollama launch claude --model $model${R}"
    "${cmd[@]}" || echo -e "${YL}Exited non-zero.${R}"
    read -rp "Press Enter" || true
}

launch_codex_app() {
    start_ollama || { read -rp "Press Enter" || true; return; }
    local model; model=$(cfg "model" "$DEFAULT_MODEL")
    log "Launching Codex App via Ollama ($model)"
    local cmd=("ollama" "launch" "codex-app" "--model" "$model")
    clear
    echo -e "\n${GN}>>> ollama launch codex-app --model $model${R}"
    "${cmd[@]}" || echo -e "${YL}Exited non-zero.${R}"
    read -rp "Press Enter" || true
}

launch_claude_desktop() {
    start_ollama || { read -rp "Press Enter" || true; return; }
    log "Launching Claude Desktop via Ollama"

    echo -e "\n${CY}Preparing Claude Desktop...${R}"
    pkill -x Claude 2>/dev/null || true
    sleep 2
    log "Killed existing Claude Desktop (if any)"

    local cid; cid=$(uuidgen 2>/dev/null || python3 -c "import uuid; print(uuid.uuid4())" 2>/dev/null)
    local lib="$HOME/Library/Application Support/Claude-3p/configLibrary"
    mkdir -p "$lib"

    python3 -c "
import json, os
lib = '$lib'; cid = '$cid'
meta = {'appliedId': cid, 'entries': [{'id': cid, 'name': 'Ollama Gateway'}]}
with open(os.path.join(lib, '_meta.json'), 'w') as f: json.dump(meta, f, indent=2)
config = {
    'inferenceProvider': 'gateway',
    'inferenceGatewayBaseUrl': 'http://localhost:11434',
    'inferenceGatewayApiKey': 'ollama',
    'inferenceGatewayAuthScheme': 'bearer',
    'inferenceModels': [
        {'name': 'claude-opus-4-7', 'labelOverride': 'Ollama (Opus 4.7)'},
        {'name': 'claude-sonnet-4-6', 'labelOverride': 'Ollama (Sonnet 4.6)'},
        {'name': 'claude-haiku-4-5-20251001', 'labelOverride': 'Ollama (Haiku 4.5)'},
    ],
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
config3p = {
    'deploymentMode': '3p',
    'enterpriseConfig': {k:v for k,v in config.items() if k != 'unstableDisableModelVerification'}
}
p3p = os.path.join(os.path.expanduser('~/Library/Application Support/Claude-3p'), 'claude_desktop_config.json')
os.makedirs(os.path.dirname(p3p), exist_ok=True)
with open(p3p, 'w') as f: json.dump(config3p, f, indent=2)
" 2>/dev/null
    log "Wrote 3p config"

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
        echo -e "${RD}Claude Desktop not found.${R}"
        log "ERROR: Claude Desktop not found"
        read -rp "Press Enter" || true
    }
}

show_main_menu() {
    clear
    show_status
    local model; model=$(cfg "model" "$DEFAULT_MODEL")
    local perms="ON"; [[ "$(cfg 'skipPerms' 'True')" != "True" ]] && perms="OFF"

    echo ""
    echo -e "[1] Launch Codex CLI (via Ollama)     ${GN}${R}"
    echo -e "[2] Launch Claude Code (via Ollama)   ${GN}${R}"
    echo -e "[3] Launch Codex App (via Ollama)     ${GN}${R}"
    echo -e "[4] Launch Claude Desktop (via Ollama) ${GN}${R}"
    echo -e "[5] Pick / Browse Models [current: $model] ${WH}${R}"
    echo -e "[6] Check Ollama Sign-in              ${WH}${R}"
    echo -e "[T] Toggle Permissions [$perms]          ${WH}${R}"
    echo -e "[L] View Log                           ${WH}${R}"
    echo -e "[Q] Quit                               ${MG}${R}"
    echo ""
}

# ============================================================
# Run
# ============================================================
[[ -f "$CONFIG_FILE" ]] || python3 -c "
import json
json.dump({'model':'$DEFAULT_MODEL','source':'cloud','skipPerms':True,
           'ollamaLatest':'','ollamaChecked':'','claudeNpmLatest':'','claudeNpmChecked':'',
           'codexNpmLatest':'','codexNpmChecked':''}, open('$CONFIG_FILE','w'), indent=2)" 2>/dev/null

if auto_update 2>/dev/null; then :; else
    log "FATAL: auto-update crashed"
    echo -e "${RD}Auto-update error (continuing anyway)${R}"
fi

if [[ $# -gt 0 ]]; then
    command -v ollama &>/dev/null || { echo "Ollama not found. Run without args."; exit 1; }
    start_ollama || exit 1
    log "Direct launch: $1"
    case "$(lc "$1")" in
        codex) launch_codex; exit $? ;;
        claude) launch_claude; exit $? ;;
        codex-app) launch_codex_app; exit $? ;;
        claude-desktop) launch_claude_desktop; exit $? ;;
    esac
fi

while true; do
    show_main_menu
    ask "Choice: " choice
    log "Menu choice: $choice"
    case "$(lc "$choice")" in
        1) launch_codex ;;
        2) launch_claude ;;
        3) launch_codex_app ;;
        4) launch_claude_desktop ;;
        5) show_model_picker ;;
        6)
            echo -e "${CY}Checking Ollama sign-in...${R}"
            ollama list &>/dev/null && echo -e "${GN}Signed in.${R}" || { echo -e "${YL}Not signed in.${R}"; ask "Run 'ollama signin'? (y/n) " a; [[ "$(lc "$a")" == "y" ]] && ollama signin; }
            read -rp "Press Enter" || true ;;
        t) local sp; sp=$(cfg "skipPerms" "True")
           [[ "$sp" == "True" ]] && json_set "skipPerms" "False" || json_set "skipPerms" "True"
           log "Permissions toggled" ;;
        l)
            clear
            echo -e "${CY}========== Log File ==========${R}"
            echo -e "Path: $LOG_FILE"
            echo ""
            [[ -f "$LOG_FILE" ]] && tail -40 "$LOG_FILE" || echo -e "${YL}No log file yet.${R}"
            echo ""; read -rp "Press Enter" || true ;;
        q) echo -e "${GN}Bye!${R}"; log "User quit"; exit 0 ;;
    esac
done
