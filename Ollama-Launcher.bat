@echo off
set "BAT_DIR=%~dp0"
set "PSFILE=%TEMP%\OllamaLauncher.ps1"
powershell -NoProfile -Command "Get-Content '%~f0' -Encoding UTF8 | Select-Object -Skip 9 | Out-File '%PSFILE%' -Encoding UTF8"
set "BatDir=%~dp0"
powershell -ExecutionPolicy Bypass -Command "& '%PSFILE%' %*; exit "
set "EC=%errorlevel%"
del /Q "%PSFILE%" 2>nul
exit /b %EC%
#Requires -Version 5.1
<#
.SYNOPSIS
    Ollama CLI Launcher â€” auto-updating launcher for Codex CLI + Claude Code + Codex App via Ollama
.DESCRIPTION
    Auto-updates Ollama, Claude Code & Codex CLI at startup.
    Browse models, pull, and launch any tool.
    Usage:
      Ollama-Launcher.bat                  -> interactive menu
      Ollama-Launcher.bat codex            -> launch Codex CLI directly
      Ollama-Launcher.bat claude           -> launch Claude Code directly
      Ollama-Launcher.bat codex-app        -> launch Codex App directly
      Ollama-Launcher.bat claude-desktop   -> launch Claude Desktop directly
#>

$ErrorActionPreference = "Continue"
Clear-Host

# ============================================
# Logging
# ============================================
$script:BaseDir = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "cli-launchers"
New-Item -ItemType Directory -Force -Path $script:BaseDir | Out-Null
$script:LogPath = Join-Path $script:BaseDir "launcher.log"

function Write-Log {
    param([string]$Msg)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] $Msg"
    try { Add-Content -Path $script:LogPath -Value $line -Encoding UTF8 } catch {}
    try {
        $f = Get-Item $script:LogPath -ErrorAction Stop
        if ($f.Length -gt 1MB) {
            $bak = $script:LogPath -replace '\.log$', '.1.log'
            Move-Item -Force $script:LogPath $bak
        }
    } catch {}
}
Write-Log "========== Ollama Launcher started =========="

# ============================================
# Config
# ============================================
$script:ConfigPath = Join-Path $script:BaseDir "Ollama-Launcher.config.json"

$DefaultCfg = @{
    model = "kimi-k2.6:cloud"
    source = "cloud"
    skipPerms = $true
    ollamaLatest = ""; ollamaChecked = ""
    claudeNpmLatest = ""; claudeNpmChecked = ""
    codexNpmLatest = ""; codexNpmChecked = ""
}

function Get-Cfg {
    if (Test-Path $script:ConfigPath) {
        try {
            $c = Get-Content $script:ConfigPath -Raw | ConvertFrom-Json
            foreach ($k in $DefaultCfg.Keys) {
                if (-not $c.PSObject.Properties[$k]) { $c | Add-Member -NotePropertyName $k -NotePropertyValue $DefaultCfg[$k] -Force }
            }
            return $c
        } catch { Write-Log "WARN: Could not parse config, using defaults" }
    }
    New-Object PSObject -Property $DefaultCfg
}

function Save-Cfg($c) {
    try { $c | ConvertTo-Json -Depth 3 | Set-Content $script:ConfigPath -Encoding UTF8 } catch {}
}

# ============================================
# Helpers
# ============================================
function Has($cmd) {
    $r = $null -ne (Get-Command $cmd -ErrorAction SilentlyContinue)
    Write-Log "  Has($cmd) = $r"
    return $r
}

function Get-InstalledVer($cmd) {
    try {
        $v = & $cmd --version 2>&1
        Write-Log "  $cmd --version output: $v"
        if ($v -match '(\d+\.\d+\.\d+)') {
            Write-Log "  $cmd installed version: $($matches[1])"
            return $matches[1]
        }
    } catch { Write-Log "  $cmd --version failed: $_" }
    return $null
}

function Is-CacheStale($ts) {
    if ([string]::IsNullOrWhiteSpace($ts)) { return $true }
    try { return ([datetime]::Now - [datetime]::Parse($ts)).TotalMinutes -gt 60 }
    catch { return $true }
}

# Ollama server
function Test-OllamaRunning {
    try { $null = Invoke-WebRequest -Uri "http://localhost:11434/api/tags" -UseBasicParsing -TimeoutSec 3; return $true } catch { return $false }
}

function Start-OllamaServer {
    if (Test-OllamaRunning) { return $true }
    Write-Host "Starting Ollama server..." -ForegroundColor Yellow
    Write-Log "Starting Ollama server"
    try {
        Start-Process -FilePath "ollama" -ArgumentList "serve" -WindowStyle Hidden
        $tries = 0
        while ($tries -lt 30) {
            Start-Sleep -Milliseconds 500
            if (Test-OllamaRunning) { Write-Host "Ollama server ready." -ForegroundColor Green; Write-Log "Ollama server started"; return $true }
            $tries++
        }
        Write-Host "Ollama server did not start." -ForegroundColor Red
        Write-Log "Ollama server start timeout"
        return $false
    } catch { Write-Log "Ollama server start error: $_"; return $false }
}

# ============================================
# Auto-Update â€” Ollama + Claude Code + Codex CLI
# ============================================
function Invoke-AutoUpdate {
    Write-Host "Auto-update check..." -ForegroundColor DarkGray
    Write-Log "Auto-update check starting"
    $cfg = Get-Cfg
    $didWork = $false

    # --- Ollama (GitHub releases) ---
    try {
        if ((Is-CacheStale $cfg.ollamaChecked) -or (-not $cfg.ollamaLatest)) {
            Write-Log "  Fetching Ollama latest from GitHub..."
            $resp = Invoke-WebRequest -Uri "https://api.github.com/repos/ollama/ollama/releases/latest" -UseBasicParsing -TimeoutSec 10
            $data = $resp.Content | ConvertFrom-Json
            if ($data.tag_name) {
                $cfg.ollamaLatest = $data.tag_name -replace '^v', ''
                $cfg.ollamaChecked = [datetime]::Now.ToString("o")
                Save-Cfg $cfg
                Write-Log "  Ollama latest: $($cfg.ollamaLatest)"
            }
        } else { Write-Log "  Ollama cache hit: $($cfg.ollamaLatest)" }
    } catch {
        Write-Log "  ERROR fetching Ollama from GitHub: $_"
        Write-Host "  Ollama: offline, skipping." -ForegroundColor DarkGray
    }

    if (Has "ollama" -and $cfg.ollamaLatest) {
        $oi = Get-InstalledVer "ollama"
        if ($oi -and $oi -ne $cfg.ollamaLatest) {
            Write-Host "  Ollama: v$oi -> v$($cfg.ollamaLatest)" -ForegroundColor Yellow
            Write-Log "  Ollama update from v$oi to v$($cfg.ollamaLatest)"
            try { irm https://ollama.com/install.ps1 | iex; Write-Host "    Updated" -ForegroundColor Green; $didWork = $true }
            catch { Write-Log "  Ollama update error: $_" }
        }
    } elseif (-not (Has "ollama")) {
        Write-Host "  Ollama: installing..." -ForegroundColor Yellow
        Write-Log "  Ollama not installed, installing"
        try { irm https://ollama.com/install.ps1 | iex; Write-Host "    Installed" -ForegroundColor Green; $didWork = $true }
        catch { Write-Log "  Ollama install error: $_" }
    }

    # --- Claude Code (npm) ---
    try {
        if ((Is-CacheStale $cfg.claudeNpmChecked) -or (-not $cfg.claudeNpmLatest)) {
            Write-Log "  Fetching Claude Code latest from npm..."
            $resp = Invoke-WebRequest -Uri "https://registry.npmjs.org/@anthropic-ai/claude-code/latest" -UseBasicParsing -TimeoutSec 10
            $data = $resp.Content | ConvertFrom-Json
            if ($data.version) {
                $cfg.claudeNpmLatest = $data.version
                $cfg.claudeNpmChecked = [datetime]::Now.ToString("o")
                Save-Cfg $cfg
                Write-Log "  Claude Code npm latest: $($data.version)"
            }
        } else { Write-Log "  Claude Code npm cache hit: $($cfg.claudeNpmLatest)" }
    } catch {
        Write-Log "  ERROR fetching Claude Code from npm: $_"
        Write-Host "  Claude Code: offline, skipping." -ForegroundColor DarkGray
    }

    if ($cfg.claudeNpmLatest) {
        if (-not (Has "claude")) {
            Write-Host "  Claude Code: installing v$($cfg.claudeNpmLatest)..." -ForegroundColor Yellow
            Write-Log "  Claude Code not installed, installing v$($cfg.claudeNpmLatest)"
            try {
                if (Has "npm") {
                    npm install -g @anthropic-ai/claude-code 2>&1 | ForEach-Object { Write-Log "  npm: $_" }
                    Start-Sleep 3
                }
                if (Has "claude") {
                    & claude install $cfg.claudeNpmLatest 2>&1 | ForEach-Object { Write-Log "  claude install: $_" }
                } else { irm https://claude.ai/install.ps1 | iex }
                Write-Host "    Installed" -ForegroundColor Green
                Write-Log "  Claude Code install done"
                $didWork = $true
            } catch { Write-Log "  Claude Code install error: $_"; Write-Host "    Install failed" -ForegroundColor Red }
        } else {
            $ci = Get-InstalledVer "claude"
            if ($ci -and $ci -ne $cfg.claudeNpmLatest) {
                Write-Host "  Claude Code: v$ci -> v$($cfg.claudeNpmLatest)" -ForegroundColor Yellow
                Write-Log "  Claude Code update from v$ci to v$($cfg.claudeNpmLatest)"
                try { & claude install $cfg.claudeNpmLatest 2>&1 | ForEach-Object { Write-Log "  claude install: $_" }; Write-Host "    Updated" -ForegroundColor Green; $didWork = $true }
                catch { Write-Log "  Claude Code update error: $_" }
            }
        }
    }

    # --- Codex CLI (npm) ---
    try {
        if ((Is-CacheStale $cfg.codexNpmChecked) -or (-not $cfg.codexNpmLatest)) {
            Write-Log "  Fetching Codex CLI latest from npm..."
            $resp = Invoke-WebRequest -Uri "https://registry.npmjs.org/@openai/codex/latest" -UseBasicParsing -TimeoutSec 10
            $data = $resp.Content | ConvertFrom-Json
            if ($data.version) {
                $cfg.codexNpmLatest = $data.version
                $cfg.codexNpmChecked = [datetime]::Now.ToString("o")
                Save-Cfg $cfg
                Write-Log "  Codex CLI npm latest: $($data.version)"
            }
        } else { Write-Log "  Codex CLI npm cache hit: $($cfg.codexNpmLatest)" }
    } catch {
        Write-Log "  ERROR fetching Codex CLI from npm: $_"
        Write-Host "  Codex CLI: offline, skipping." -ForegroundColor DarkGray
    }

    if ($cfg.codexNpmLatest -and (Has "npm")) {
        $ci = Get-InstalledVer "codex"
        if (-not $ci) {
            Write-Host "  Codex CLI: installing v$($cfg.codexNpmLatest)..." -ForegroundColor Yellow
            Write-Log "  Codex CLI not installed, installing v$($cfg.codexNpmLatest)"
            try { npm install -g "@openai/codex@$($cfg.codexNpmLatest)" 2>&1 | ForEach-Object { Write-Log "  npm: $_" }; Write-Host "    Installed" -ForegroundColor Green; $didWork = $true }
            catch { Write-Log "  Codex CLI install error: $_" }
        } elseif ($ci -ne $cfg.codexNpmLatest) {
            Write-Host "  Codex CLI: v$ci -> v$($cfg.codexNpmLatest)" -ForegroundColor Yellow
            Write-Log "  Codex CLI update from v$ci to v$($cfg.codexNpmLatest)"
            try { npm install -g "@openai/codex@$($cfg.codexNpmLatest)" 2>&1 | ForEach-Object { Write-Log "  npm: $_" }; Write-Host "    Updated" -ForegroundColor Green; $didWork = $true }
            catch { Write-Log "  Codex CLI update error: $_" }
        }
    }

    if (-not $didWork) { Write-Host "  All up to date." -ForegroundColor DarkGray }
    Write-Host ""
    Write-Log "Auto-update complete. didWork=$didWork"
}

# ============================================
# Status
# ============================================
function Show-Status {
    $cfg = Get-Cfg
    $hasOllama = Has "ollama"; $hasClaude = Has "claude"; $hasCodex = Has "codex"
    $ollamaVer = if ($hasOllama) { Get-InstalledVer "ollama" } else { $null }
    $claudeVer = if ($hasClaude) { Get-InstalledVer "claude" } else { $null }
    $codexVer  = if ($hasCodex)  { Get-InstalledVer "codex" } else { $null }

    Write-Host "========== Ollama CLI Launcher ==========" -ForegroundColor Cyan
    if ($hasOllama -and $ollamaVer) { Write-Host "  Ollama        : v$ollamaVer" -ForegroundColor Green }
    else { Write-Host "  Ollama        : NOT INSTALLED" -ForegroundColor Red }
    if ($hasClaude -and $claudeVer) { Write-Host "  Claude Code   : v$claudeVer" -ForegroundColor Green }
    else { Write-Host "  Claude Code   : not installed" -ForegroundColor DarkGray }
    if ($hasCodex -and $codexVer) { Write-Host "  Codex CLI     : v$codexVer" -ForegroundColor Green }
    else { Write-Host "  Codex CLI     : not installed" -ForegroundColor DarkGray }
    Write-Host "  Model         : $($cfg.model) [$($cfg.source)]" -ForegroundColor Cyan
    $perm = if ($cfg.skipPerms) { "ON" } else { "OFF" }
    Write-Host "  Skip Perms    : $perm" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
}

# ============================================
# Model Browser
# ============================================
function Get-CloudModels {
    Write-Host "Fetching newest models from Ollama registry..." -ForegroundColor DarkGray
    try {
        $resp = Invoke-WebRequest -Uri "https://ollama.com/api/tags" -UseBasicParsing -TimeoutSec 15
        $data = $resp.Content | ConvertFrom-Json
        $models = @($data.models)
        if ($models.Count -eq 0) { return @() }
        foreach ($m in $models) {
            try { $m | Add-Member -NotePropertyName modified_dt -NotePropertyValue ([datetime]::Parse($m.modified_at)) -Force }
            catch { $m | Add-Member -NotePropertyName modified_dt -NotePropertyValue ([datetime]::MinValue) -Force }
        }
        return ($models | Sort-Object modified_dt -Descending | Select-Object -First 10)
    } catch { Write-Log "Cloud models fetch error: $_"; return @() }
}

function Get-LocalModels {
    try {
        $resp = Invoke-WebRequest -Uri "http://localhost:11434/api/tags" -UseBasicParsing -TimeoutSec 5
        return @(($resp.Content | ConvertFrom-Json).models)
    } catch { Write-Log "Local models fetch error: $_"; return @() }
}

function Browse-CloudModels {
    Clear-Host
    Write-Host "========== Cloud Models (Newest 10) ==========" -ForegroundColor Green
    Write-Host ""
    $models = Get-CloudModels
    if ($models.Count -eq 0) { Write-Host "No cloud models could be fetched." -ForegroundColor Red; Read-Host "Press Enter"; return }
    for ($i = 0; $i -lt $models.Count; $i++) {
        $sizeGB = "{0:N2}" -f ($models[$i].size / 1GB)
        Write-Host "  [$($i+1)] $($models[$i].name)  ($sizeGB GB)" -ForegroundColor Cyan
    }
    Write-Host ""
    Write-Host "  [M] Manual entry  [B] Back" -ForegroundColor White
    Write-Host ""
    $choice = Read-Host "Select"
    if ($choice.ToLower() -eq "b") { return }
    if ($choice.ToLower() -eq "m") { $m = Read-Host "Model name"; if ($m) { $cfg = Get-Cfg; $cfg.model = $m; $cfg.source = "cloud"; Save-Cfg $cfg }; return }
    $idx = 0
    if ([int]::TryParse($choice, [ref]$idx) -and $idx -ge 1 -and $idx -le $models.Count) {
        $cfg = Get-Cfg; $cfg.model = $models[$idx-1].name; $cfg.source = "cloud"; Save-Cfg $cfg
        Write-Host "Model: $($models[$idx-1].name)" -ForegroundColor Green
    }
    Read-Host "Press Enter"
}

function Browse-LocalModels {
    Clear-Host
    Write-Host "========== Local Models ==========" -ForegroundColor Green
    Write-Host ""
    $models = Get-LocalModels
    if ($models.Count -eq 0) { Write-Host "No local models found." -ForegroundColor Yellow; Read-Host "Press Enter"; return }
    for ($i = 0; $i -lt $models.Count; $i++) {
        $sizeGB = "{0:N2}" -f ($models[$i].size / 1GB)
        Write-Host "  [$($i+1)] $($models[$i].name)  ($sizeGB GB)" -ForegroundColor Cyan
    }
    Write-Host ""
    Write-Host "  [B] Back" -ForegroundColor White
    Write-Host ""
    $choice = Read-Host "Select"
    if ($choice.ToLower() -eq "b") { return }
    $idx = 0
    if ([int]::TryParse($choice, [ref]$idx) -and $idx -ge 1 -and $idx -le $models.Count) {
        $cfg = Get-Cfg; $cfg.model = $models[$idx-1].name; $cfg.source = "local"; Save-Cfg $cfg
        Write-Host "Model: $($models[$idx-1].name)" -ForegroundColor Green
    }
    Read-Host "Press Enter"
}

function Show-ModelPicker {
    while ($true) {
        Clear-Host
        Write-Host "========== Pick Model ==========" -ForegroundColor Green
        Write-Host ""
        $cfg = Get-Cfg
        Write-Host "Current: $($cfg.model) [$($cfg.source)]" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  [1] Browse Cloud Models (newest 10)" -ForegroundColor Yellow
        Write-Host "  [2] Browse Local Models" -ForegroundColor Yellow
        Write-Host "  [3] Manual Entry" -ForegroundColor Yellow
        Write-Host "  [P] Pull Current Model" -ForegroundColor White
        Write-Host "  [B] Back" -ForegroundColor Magenta
        Write-Host ""
        $choice = Read-Host "Choice"
        switch ($choice.ToLower()) {
            "1" { Browse-CloudModels }
            "2" { Browse-LocalModels }
            "3" {
                $m = Read-Host "Enter model name"
                if ($m) { $cfg = Get-Cfg; $cfg.model = $m; $cfg.source = "manual"; Save-Cfg $cfg; Write-Host "Model: $m" -ForegroundColor Green; Write-Log "Model changed: $m" }
                Read-Host "Press Enter"
            }
            "p" {
                $m = (Get-Cfg).model
                Write-Host "Pulling '$m'..." -ForegroundColor Cyan
                Write-Log "Pulling model: $m"
                ollama pull $m
                Read-Host "Press Enter"
            }
            "b" { return }
        }
    }
}

# ============================================
# Launch Functions
# ============================================
function Launch-Codex {
    if (-not (Start-OllamaServer)) { Read-Host "Press Enter"; return }
    $model = (Get-Cfg).model
    Write-Log "Launching Codex CLI via Ollama ($model)"
    $a = @("ollama", "launch", "codex", "--model", $model, "--")
    if ((Get-Cfg).skipPerms) { $a += "--yolo" }
    Write-Host "`n>>> ollama launch codex --model $model" -ForegroundColor Green
    Write-Host ("-" * 50) -ForegroundColor DarkGray
    try {
        $p = (Get-Command "ollama" -ErrorAction Stop).Source
        Start-Process -FilePath $p -ArgumentList $a[1..($a.Length-1)]
        Write-Host "Launched in new window." -ForegroundColor Cyan
    } catch { Write-Log "  Launch error: $_"; $oa = "ollama"; $oargs = $a[1..($a.Length-1)]; try { & $oa @oargs } catch {} }
    Read-Host "Press Enter to return"
}

function Launch-Claude {
    if (-not (Start-OllamaServer)) { Read-Host "Press Enter"; return }
    $model = (Get-Cfg).model
    Write-Log "Launching Claude Code via Ollama ($model)"
    $a = @("ollama", "launch", "claude", "--model", $model, "--")
    if ((Get-Cfg).skipPerms) { $a += "--dangerously-skip-permissions" }
    Write-Host "`n>>> ollama launch claude --model $model" -ForegroundColor Green
    Write-Host ("-" * 50) -ForegroundColor DarkGray
    try {
        $p = (Get-Command "ollama" -ErrorAction Stop).Source
        Start-Process -FilePath $p -ArgumentList $a[1..($a.Length-1)]
        Write-Host "Launched in new window." -ForegroundColor Cyan
    } catch { Write-Log "  Launch error: $_"; $oa = "ollama"; $oargs = $a[1..($a.Length-1)]; try { & $oa @oargs } catch {} }
    Read-Host "Press Enter to return"
}

function Launch-CodexApp {
    if (-not (Start-OllamaServer)) { Read-Host "Press Enter"; return }
    $model = (Get-Cfg).model
    Write-Log "Launching Codex App via Ollama ($model)"
    $a = @("ollama", "launch", "codex-app", "--model", $model)
    Write-Host "`n>>> ollama launch codex-app --model $model" -ForegroundColor Green
    Write-Host ("-" * 50) -ForegroundColor DarkGray
    try {
        $p = (Get-Command "ollama" -ErrorAction Stop).Source
        Start-Process -FilePath $p -ArgumentList $a[1..($a.Length-1)]
        Write-Host "Launched in new window." -ForegroundColor Cyan
    } catch { Write-Log "  Launch error: $_"; $oa = "ollama"; $oargs = $a[1..($a.Length-1)]; try { & $oa @oargs } catch {} }
    Read-Host "Press Enter to return"
}

function Launch-ClaudeDesktop {
    if (-not (Start-OllamaServer)) { Read-Host "Press Enter"; return }
    Write-Log "Launching Claude Desktop via Ollama"

    Write-Host "`nPreparing Claude Desktop..." -ForegroundColor Cyan
    Get-Process -Name "Claude" -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne 0 } |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Write-Log "  Killed existing Claude Desktop (if any)"

    $local   = [Environment]::GetFolderPath("LocalApplicationData")
    $roaming = [Environment]::GetFolderPath("ApplicationData")
    $utf8    = New-Object System.Text.UTF8Encoding $false
    $cid     = [Guid]::NewGuid().ToString()

    $gateway = [ordered]@{
        inferenceProvider          = "gateway"
        inferenceGatewayBaseUrl    = "http://127.0.0.1:11434"
        inferenceGatewayApiKey     = "ollama"
        inferenceGatewayAuthScheme = "bearer"
        inferenceModels            = @(
            @{ name = "claude-opus-4-7";           labelOverride = "Ollama (Opus 4.7)" }
            @{ name = "claude-sonnet-4-6";         labelOverride = "Ollama (Sonnet 4.6)" }
            @{ name = "claude-haiku-4-5-20251001"; labelOverride = "Ollama (Haiku 4.5)" }
        )
        disableEssentialTelemetry    = $true
        disableNonessentialTelemetry = $true
        disableNonessentialServices  = $true
        unstableDisableModelVerification = $true
        builtinToolPolicy = [ordered]@{
            Bash="allow";Read="allow";Write="allow";Edit="allow";Glob="allow";Grep="allow"
            NotebookEdit="allow";WebFetch="allow";WebSearch="allow"
            Task="allow";TaskCreate="allow";TaskUpdate="allow";TaskGet="allow";TaskList="allow";TaskStop="allow"
            Skill="allow";AskUserQuestion="allow";SendUserMessage="allow"
        }
    }

    foreach ($libDir in @(
        (Join-Path $local "Claude-3p\configLibrary"),
        (Join-Path $local "Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude-3p\configLibrary")
    )) {
        New-Item -ItemType Directory -Force -Path $libDir | Out-Null
        Get-ChildItem $libDir -Filter "*.json" -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne "_meta.json" -and $_.Name -ne "$cid.json" } | Remove-Item -Force
        $meta = [ordered]@{ appliedId = $cid; entries = @(@{ id = $cid; name = "Ollama Gateway" }) }
        [System.IO.File]::WriteAllText((Join-Path $libDir "_meta.json"), ($meta | ConvertTo-Json -Depth 3), $utf8)
        [System.IO.File]::WriteAllText((Join-Path $libDir "$cid.json"), ($gateway | ConvertTo-Json -Depth 5), $utf8)
    }

    $enterprise = [ordered]@{}
    foreach ($k in $gateway.Keys) { if ($k -ne "unstableDisableModelVerification") { $enterprise[$k] = $gateway[$k] } }
    $json3p = ([ordered]@{ deploymentMode = "3p"; enterpriseConfig = $enterprise } | ConvertTo-Json -Depth 5)
    foreach ($p in @(
        (Join-Path $roaming "Claude-3p\claude_desktop_config.json"),
        (Join-Path $local "Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude-3p\claude_desktop_config.json")
    )) {
        New-Item -ItemType Directory -Force -Path (Split-Path $p -Parent) | Out-Null
        [System.IO.File]::WriteAllText($p, $json3p, $utf8)
    }

    # Clear OAuth
    $base = Join-Path $local "Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude"
    $cfgPath = Join-Path $base "config.json"
    if (Test-Path $cfgPath) {
        try {
            $claudeCfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
            $keys = @("oauth:tokenCache","oauth:refreshToken","oauth:accountId","oauth:accessToken",
                       "oauth:expiresAt","oauth:token","activeAccountId","activeOrgId",
                       "authSession","lastSignedInAccount","oauthTokens")
            $changed = $false
            foreach ($k in $keys) { if ($claudeCfg.PSObject.Properties[$k]) { $claudeCfg.PSObject.Properties.Remove($k); $changed = $true } }
            if ($changed) { [System.IO.File]::WriteAllText($cfgPath, ($claudeCfg | ConvertTo-Json -Depth 5), $utf8) }
        } catch {}
    }
    foreach ($p in @(
        (Join-Path $local "Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude\developer_settings.json"),
        (Join-Path $local "Claude\developer_settings.json"),
        (Join-Path $roaming "Claude\developer_settings.json")
    )) {
        New-Item -ItemType Directory -Force -Path (Split-Path $p -Parent) | Out-Null
        [System.IO.File]::WriteAllText($p, '{"allowDevTools":true}', $utf8)
    }
    Write-Log "  Wrote 3p config + dev mode"

    Write-Host "  Config written." -ForegroundColor DarkGray
    Write-Host ("-" * 50) -ForegroundColor DarkGray
    Write-Host "Launching Claude Desktop..." -ForegroundColor Green
    try { Start-Process "shell:appsFolder\Claude_pzs8sxrjxfjjc!Claude"; Write-Log "  Launched Claude Desktop" }
    catch { Write-Log "  Launch error: $_"; Write-Host "Not found. Install: https://claude.ai/download" -ForegroundColor Red }
}

# ============================================
# Menu
# ============================================
function Show-Menu {
    Clear-Host
    Show-Status
    $cfg = Get-Cfg
    Write-Host ""
    Write-Host "[1] Launch Codex CLI (via Ollama)" -ForegroundColor Green
    Write-Host "[2] Launch Claude Code (via Ollama)" -ForegroundColor Green
    Write-Host "[3] Launch Codex App (via Ollama)" -ForegroundColor Green
    Write-Host "[4] Launch Claude Desktop (via Ollama)" -ForegroundColor Green
    Write-Host "[5] Pick / Browse Models [current: $($cfg.model)]" -ForegroundColor White
    Write-Host "[6] Check Ollama Sign-in" -ForegroundColor White
    $perm = if ($cfg.skipPerms) { "ON" } else { "OFF" }
    Write-Host "[T] Toggle Permissions [$perm]" -ForegroundColor White
    Write-Host "[L] View Log" -ForegroundColor White
    Write-Host "[Q] Quit" -ForegroundColor Magenta
    Write-Host ""
}

# ============================================
# Run
# ============================================
try { Invoke-AutoUpdate } catch { Write-Log "FATAL: Auto-update crashed: $_"; Write-Host "Auto-update error (continuing anyway): $_" -ForegroundColor Red }

if ($args.Count -gt 0) {
    $target = $args[0].ToLower()
    if (-not (Has "ollama")) { Write-Host "Ollama not found. Run without args to auto-install." -ForegroundColor Red; exit 1 }
    if (-not (Start-OllamaServer)) { exit 1 }
    Write-Log "Direct launch: $target"
    switch ($target) {
        "codex"          { Launch-Codex }
        "claude"         { Launch-Claude }
        "codex-app"      { Launch-CodexApp }
        "claude-desktop" { Launch-ClaudeDesktop }
        default { Write-Host "Usage: Ollama-Launcher.bat [codex|claude|codex-app|claude-desktop]"; exit 1 }
    }
    exit 0
}

while ($true) {
    Show-Menu
    $choice = Read-Host "Choice"
    Write-Log "Menu choice: $choice"
    switch ($choice.ToLower()) {
        "1" { try { Launch-Codex } catch { Write-Log "Launch-Codex crashed: $_"; Write-Host "Error: $_" -ForegroundColor Red; Read-Host "Press Enter" } }
        "2" { try { Launch-Claude } catch { Write-Log "Launch-Claude crashed: $_"; Write-Host "Error: $_" -ForegroundColor Red; Read-Host "Press Enter" } }
        "3" { try { Launch-CodexApp } catch { Write-Log "Launch-CodexApp crashed: $_"; Write-Host "Error: $_" -ForegroundColor Red; Read-Host "Press Enter" } }
        "4" { try { Launch-ClaudeDesktop } catch { Write-Log "Launch-ClaudeDesktop crashed: $_"; Write-Host "Error: $_" -ForegroundColor Red; Read-Host "Press Enter" } }
        "5" { Show-ModelPicker }
        "6" {
            Write-Host "Checking Ollama sign-in..." -ForegroundColor Cyan
            if (Has "ollama") {
                try { ollama list 2>$null | Out-Null; if ($LASTEXITCODE -eq 0) { Write-Host "Signed in." -ForegroundColor Green } else { Write-Host "Not signed in." -ForegroundColor Yellow; $ans = Read-Host "Run 'ollama signin'? (y/n)"; if ($ans -eq 'y') { ollama signin } } }
                catch { Write-Host "Error." -ForegroundColor Red }
            } else { Write-Host "Ollama not installed." -ForegroundColor Red }
            Read-Host "Press Enter"
        }
        "t" { $c = Get-Cfg; $c.skipPerms = -not $c.skipPerms; Save-Cfg $c; Write-Log "Permissions toggled: $($c.skipPerms)" }
        "l" {
            Clear-Host
            Write-Host "========== Log File ==========" -ForegroundColor Cyan
            Write-Host "Path: $script:LogPath" -ForegroundColor DarkGray
            Write-Host ""
            if (Test-Path $script:LogPath) { Get-Content $script:LogPath -Tail 40 } else { Write-Host "No log file yet." -ForegroundColor Yellow }
            Write-Host ""; Read-Host "Press Enter to return"
        }
        "q" { Write-Host "Bye!" -ForegroundColor Green; Write-Log "User quit"; exit 0 }
        default { Write-Host "Invalid." -ForegroundColor Red; Start-Sleep -Seconds 1 }
    }
}
