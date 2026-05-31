@echo off
set "BAT_DIR=%~dp0"
set "PSFILE=%TEMP%\DeepSeekLauncher.ps1"
powershell -NoProfile -Command "Get-Content '%~f0' -Encoding UTF8 | Select-Object -Skip 9 | Out-File '%PSFILE%' -Encoding UTF8"
set "BatDir=%~dp0"
powershell -ExecutionPolicy Bypass -Command "& '%PSFILE%' %*; exit "
set "EC=%errorlevel%"
del /Q "%PSFILE%" 2>nul
exit /b %EC%
#Requires -Version 5.1
$ErrorActionPreference = "Continue"
Clear-Host

# Logging
$script:BaseDir = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "cli-launchers"
$null = New-Item -ItemType Directory -Force -Path $script:BaseDir 2>$null
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
Write-Log "========== DeepSeek Launcher started =========="

# Config
$script:ConfigPath = Join-Path $script:BaseDir "DeepSeek-Launcher.config.json"
$DefaultCfg = @{
    model = "deepseek-v4-pro"
    apikey = ""
    skipPerms = $true
    claudeNpmLatest = ""
    claudeNpmChecked = ""
    codexNpmLatest = ""
    codexNpmChecked = ""
}

function Get-Cfg {
    if (Test-Path $script:ConfigPath) {
        try {
            $c = Get-Content $script:ConfigPath -Raw | ConvertFrom-Json
            foreach ($k in $DefaultCfg.Keys) {
                if (-not $c.PSObject.Properties[$k]) {
                    $c | Add-Member -NotePropertyName $k -NotePropertyValue $DefaultCfg[$k] -Force
                }
            }
            return $c
        }
        catch { Write-Log "WARN: Could not parse config" }
    }
    New-Object PSObject -Property $DefaultCfg
}

function Save-Cfg($c) {
    try { $c | ConvertTo-Json -Depth 3 | Set-Content $script:ConfigPath -Encoding UTF8 }
    catch { Write-Log "WARN: Could not save config" }
}

# Helpers
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
            $ver = $matches[1]
            Write-Log "  $cmd installed version: $ver"
            return $ver
        }
    }
    catch { Write-Log "  $cmd --version failed: $_" }
    return $null
}

function Is-CacheStale($ts) {
    if ([string]::IsNullOrWhiteSpace($ts)) { return $true }
    try { return ([datetime]::Now - [datetime]::Parse($ts)).TotalMinutes -gt 60 }
    catch { return $true }
}

# ============================================
# Auto-Update
# ============================================
function Invoke-AutoUpdate {
    Write-Host "Auto-update check..." -ForegroundColor DarkGray
    Write-Log "Auto-update check starting"
    $cfg = Get-Cfg
    $didWork = $false

    # Claude Code - fetch npm latest if stale
    try {
        if ((Is-CacheStale $cfg.claudeNpmChecked) -or (-not $cfg.claudeNpmLatest)) {
            Write-Log "  Fetching Claude Code latest from npm"
            $resp = Invoke-WebRequest -Uri "https://registry.npmjs.org/@anthropic-ai/claude-code/latest" -UseBasicParsing -TimeoutSec 10
            $data = $resp.Content | ConvertFrom-Json
            if ($data.version) {
                $cfg.claudeNpmLatest = $data.version
                $cfg.claudeNpmChecked = [datetime]::Now.ToString("o")
                Save-Cfg $cfg
                Write-Log "  Claude Code npm latest: $($data.version)"
            }
        }
        else {
            Write-Log "  Claude Code npm cache hit: $($cfg.claudeNpmLatest)"
        }
    }
    catch {
        Write-Log "  ERROR fetching Claude Code from npm: $_"
        Write-Host "  Claude Code: offline, skipping." -ForegroundColor DarkGray
    }

    # Claude Code - install/update if needed
    $claudeTarget = $cfg.claudeNpmLatest
    if ($claudeTarget) {
        $hasClaude = Has "claude"
        if (-not $hasClaude) {
            Write-Host "  Claude Code: installing v$claudeTarget..." -ForegroundColor Yellow
            Write-Log "  Claude Code not installed, installing v$claudeTarget"
            try {
                if (Has "npm") {
                    Write-Log "  Running npm install -g @anthropic-ai/claude-code"
                    $null = npm install -g @anthropic-ai/claude-code 2>&1
                    Start-Sleep -Seconds 3
                }
                if (Has "claude") {
                    Write-Log "  Running claude install $claudeTarget"
                    $null = & claude install $claudeTarget 2>&1
                }
                else {
                    Write-Log "  Falling back to official installer"
                    irm https://claude.ai/install.ps1 | iex
                }
                Write-Host "    Installed v$claudeTarget" -ForegroundColor Green
                Write-Log "  Claude Code install complete"
                $didWork = $true
            }
            catch {
                Write-Log "  Claude Code install error: $_"
                Write-Host "    Install failed" -ForegroundColor Red
            }
        }
        else {
            $claudeInst = Get-InstalledVer "claude"
            if ($claudeInst -and $claudeInst -ne $claudeTarget) {
                Write-Host "  Claude Code: v$claudeInst -> v$claudeTarget" -ForegroundColor Yellow
                Write-Log "  Claude Code update from v$claudeInst to v$claudeTarget"
                try {
                    $null = & claude install $claudeTarget 2>&1
                    Write-Host "    Updated to v$claudeTarget" -ForegroundColor Green
                    Write-Log "  Claude Code update done"
                    $didWork = $true
                }
                catch {
                    Write-Log "  Claude Code update error: $_"
                    Write-Host "    Update failed" -ForegroundColor Red
                }
            }
        }
    }

    # Codex CLI - fetch npm latest if stale
    try {
        if ((Is-CacheStale $cfg.codexNpmChecked) -or (-not $cfg.codexNpmLatest)) {
            Write-Log "  Fetching Codex CLI latest from npm"
            $resp = Invoke-WebRequest -Uri "https://registry.npmjs.org/@openai/codex/latest" -UseBasicParsing -TimeoutSec 10
            $data = $resp.Content | ConvertFrom-Json
            if ($data.version) {
                $cfg.codexNpmLatest = $data.version
                $cfg.codexNpmChecked = [datetime]::Now.ToString("o")
                Save-Cfg $cfg
                Write-Log "  Codex CLI npm latest: $($data.version)"
            }
        }
        else {
            Write-Log "  Codex CLI npm cache hit: $($cfg.codexNpmLatest)"
        }
    }
    catch {
        Write-Log "  ERROR fetching Codex CLI from npm: $_"
        Write-Host "  Codex CLI: offline, skipping." -ForegroundColor DarkGray
    }

    # Codex CLI - install/update if needed
    $codexTarget = $cfg.codexNpmLatest
    if ($codexTarget -and (Has "npm")) {
        $codexInst = Get-InstalledVer "codex"
        if (-not $codexInst) {
            Write-Host "  Codex CLI: installing v$codexTarget..." -ForegroundColor Yellow
            Write-Log "  Codex CLI not installed, installing v$codexTarget"
            try {
                $null = npm install -g "@openai/codex@$codexTarget" 2>&1
                Write-Host "    Installed v$codexTarget" -ForegroundColor Green
                Write-Log "  Codex CLI install done"
                $didWork = $true
            }
            catch {
                Write-Log "  Codex CLI install error: $_"
                Write-Host "    Install failed" -ForegroundColor Red
            }
        }
        elseif ($codexInst -ne $codexTarget) {
            Write-Host "  Codex CLI: v$codexInst -> v$codexTarget" -ForegroundColor Yellow
            Write-Log "  Codex CLI update from v$codexInst to v$codexTarget"
            try {
                $null = npm install -g "@openai/codex@$codexTarget" 2>&1
                Write-Host "    Updated to v$codexTarget" -ForegroundColor Green
                Write-Log "  Codex CLI update done"
                $didWork = $true
            }
            catch {
                Write-Log "  Codex CLI update error: $_"
                Write-Host "    Update failed" -ForegroundColor Red
            }
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
    $hasClaude = Has "claude"
    $hasCodex = Has "codex"
    $claudeVer = ""
    $codexVer = ""
    if ($hasClaude) { $claudeVer = Get-InstalledVer "claude" }
    if ($hasCodex) { $codexVer = Get-InstalledVer "codex" }

    Write-Host "========== DeepSeek CLI Launcher ==========" -ForegroundColor Cyan
    if ($hasClaude -and $claudeVer) {
        Write-Host "  Claude Code   : v$claudeVer" -ForegroundColor Green
    }
    else {
        Write-Host "  Claude Code   : not installed" -ForegroundColor DarkGray
    }
    if ($hasCodex -and $codexVer) {
        Write-Host "  Codex CLI     : v$codexVer" -ForegroundColor Green
    }
    else {
        Write-Host "  Codex CLI     : not installed" -ForegroundColor DarkGray
    }
    if ($cfg.apikey) {
        Write-Host "  DeepSeek Key  : SET" -ForegroundColor Green
    }
    else {
        Write-Host "  DeepSeek Key  : NOT SET" -ForegroundColor Red
    }
    Write-Host "  Model         : $($cfg.model)" -ForegroundColor Cyan
    $perm = "ON"
    if (-not $cfg.skipPerms) { $perm = "OFF" }
    Write-Host "  Skip Perms    : $perm" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
}

# Require API key
function Assert-Key {
    if (-not (Get-Cfg).apikey) {
        Write-Host "API key not set! Use option 5." -ForegroundColor Red
        Read-Host "Press Enter"
        return $false
    }
    return $true
}

# ============================================
# Launch: Claude Code
# ============================================
function Launch-ClaudeCode {
    if (-not (Assert-Key)) { return }
    $cfg = Get-Cfg
    Write-Log "Launching Claude Code CLI"
    $env:ANTHROPIC_BASE_URL = "https://api.deepseek.com/anthropic"
    $env:ANTHROPIC_API_KEY = $cfg.apikey
    $env:DISABLE_AUTOUPDATER = "1"

    $cmdArgs = @()
    if ($cfg.skipPerms) { $cmdArgs += "--dangerously-skip-permissions" }

    Write-Host ""
    Write-Host ">>> claude (DeepSeek: $($cfg.model))" -ForegroundColor Green
    Write-Host ("-" * 50) -ForegroundColor DarkGray
    try {
        $p = (Get-Command "claude" -ErrorAction Stop).Source
        Write-Log "  Starting: $p $cmdArgs"
        Start-Process -FilePath $p -ArgumentList $cmdArgs
        Write-Host "Launched in new window." -ForegroundColor Cyan
    }
    catch {
        Write-Log "  Start-Process failed, invoking directly: $_"
        try { & claude @cmdArgs }
        catch { Write-Log "  Direct invoke also failed: $_" }
    }
}

# ============================================
# Launch: Codex CLI
# ============================================
function Launch-CodexCLI {
    if (-not (Assert-Key)) { return }
    $cfg = Get-Cfg
    Write-Log "Launching Codex CLI"
    $env:OPENAI_API_KEY = $cfg.apikey
    $env:OPENAI_BASE_URL = "https://api.deepseek.com/v1"

    $cmdArgs = @("-c", "model_reasoning_effort=high")
    if ($cfg.skipPerms) { $cmdArgs += "--yolo" }

    Write-Host ""
    Write-Host ">>> codex (DeepSeek: $($cfg.model))" -ForegroundColor Green
    Write-Host ("-" * 50) -ForegroundColor DarkGray
    try {
        $p = (Get-Command "codex.cmd" -ErrorAction Stop).Source
        Write-Log "  Starting: $p $cmdArgs"
        Start-Process -FilePath $p -ArgumentList $cmdArgs
        Write-Host "Launched in new window." -ForegroundColor Cyan
    }
    catch {
        Write-Log "  Start-Process failed, invoking directly: $_"
        try { & codex @cmdArgs }
        catch { Write-Log "  Direct invoke also failed: $_" }
    }
}

# ============================================
# Launch: Codex App
# ============================================
function Launch-CodexApp {
    if (-not (Assert-Key)) { return }
    $cfg = Get-Cfg
    Write-Log "Launching Codex App"
    $env:DEEPSEEK_API_KEY = $cfg.apikey

    $cmdArgs = @("app",
        "-c", "model_provider=deepseek",
        "-c", "model=$($cfg.model)",
        "-c", "model_reasoning_effort=high",
        "-c", "wire_api=chat")
    Write-Log "  Args: codex $cmdArgs"

    Write-Host ""
    Write-Host ">>> codex app (DeepSeek: $($cfg.model))" -ForegroundColor Green
    Write-Host ("-" * 50) -ForegroundColor DarkGray
    try {
        $p = (Get-Command "codex.cmd" -ErrorAction Stop).Source
        Write-Log "  Starting: $p $cmdArgs"
        Start-Process -FilePath $p -ArgumentList $cmdArgs
        Write-Host "Launched in new window." -ForegroundColor Cyan
    }
    catch {
        Write-Log "  Start-Process failed, invoking directly: $_"
        try { & codex @cmdArgs }
        catch { Write-Log "  Direct invoke also failed: $_" }
    }
}

# ============================================
# Launch: Claude Desktop (3p gateway config)
# ============================================
function Launch-ClaudeDesktop {
    if (-not (Assert-Key)) { return }
    $cfg = Get-Cfg
    Write-Log "Launching Claude Desktop"

    Write-Host ""
    Write-Host "Preparing Claude Desktop..." -ForegroundColor Cyan

    # Kill running Desktop
    Get-Process -Name "Claude" -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne 0 } |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Write-Log "  Killed existing Claude Desktop (if any)"

    $local   = [Environment]::GetFolderPath("LocalApplicationData")
    $roaming = [Environment]::GetFolderPath("ApplicationData")
    $utf8    = New-Object System.Text.UTF8Encoding $false
    $cid     = [Guid]::NewGuid().ToString()

    $modelDefs = @(
        @{ name = "claude-opus-4-7";           labelOverride = "DeepSeek V4 Pro (Opus 4.7)" }
        @{ name = "claude-opus-4-6";           labelOverride = "DeepSeek V4 Pro (Opus 4.6)" }
        @{ name = "claude-sonnet-4-6";         labelOverride = "DeepSeek V4 Flash (Sonnet 4.6)" }
        @{ name = "claude-haiku-4-5-20251001"; labelOverride = "DeepSeek V4 Flash (Haiku 4.5)" }
    )

    $gateway = [ordered]@{
        inferenceProvider              = "gateway"
        inferenceGatewayBaseUrl        = "https://api.deepseek.com/anthropic"
        inferenceGatewayApiKey         = $cfg.apikey
        inferenceGatewayAuthScheme     = "bearer"
        inferenceModels                = $modelDefs
        disableEssentialTelemetry      = $true
        disableNonessentialTelemetry   = $true
        disableNonessentialServices    = $true
        unstableDisableModelVerification = $true
        builtinToolPolicy              = [ordered]@{
            Bash = "allow"; Read = "allow"; Write = "allow"; Edit = "allow"
            Glob = "allow"; Grep = "allow"; NotebookEdit = "allow"
            WebFetch = "allow"; WebSearch = "allow"
            Task = "allow"; TaskCreate = "allow"; TaskUpdate = "allow"
            TaskGet = "allow"; TaskList = "allow"; TaskStop = "allow"
            Skill = "allow"; AskUserQuestion = "allow"; SendUserMessage = "allow"
        }
    }

    # Write configLibrary
    $libDirs = @(
        (Join-Path $local "Claude-3p\configLibrary")
        (Join-Path $local "Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude-3p\configLibrary")
    )
    foreach ($libDir in $libDirs) {
        $null = New-Item -ItemType Directory -Force -Path $libDir 2>&1
        Get-ChildItem $libDir -Filter "*.json" -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne "_meta.json" -and $_.Name -ne "$cid.json" } |
            Remove-Item -Force -ErrorAction SilentlyContinue

        $meta = [ordered]@{ appliedId = $cid; entries = @(@{ id = $cid; name = "DeepSeek Gateway" }) }
        $metaJson = $meta | ConvertTo-Json -Depth 3
        $gateJson = $gateway | ConvertTo-Json -Depth 5
        [System.IO.File]::WriteAllText((Join-Path $libDir "_meta.json"), $metaJson, $utf8)
        [System.IO.File]::WriteAllText((Join-Path $libDir "$cid.json"), $gateJson, $utf8)
        Write-Log "  Wrote configLibrary: $libDir"
    }

    # Write claude_desktop_config.json (legacy compat)
    $enterprise = [ordered]@{}
    foreach ($k in $gateway.Keys) {
        if ($k -ne "unstableDisableModelVerification") {
            $enterprise[$k] = $gateway[$k]
        }
    }
    $json3p = ([ordered]@{ deploymentMode = "3p"; enterpriseConfig = $enterprise } | ConvertTo-Json -Depth 5)
    $paths3p = @(
        (Join-Path $local "Claude-3p\claude_desktop_config.json")
        (Join-Path $local "Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude-3p\claude_desktop_config.json")
        (Join-Path $roaming "Claude-3p\claude_desktop_config.json")
    )
    foreach ($p in $paths3p) {
        $parentDir = Split-Path $p -Parent
        $null = New-Item -ItemType Directory -Force -Path $parentDir 2>&1
        [System.IO.File]::WriteAllText($p, $json3p, $utf8)
        Write-Log "  Wrote 3p config: $p"
    }

    # Clear OAuth session
    $base = Join-Path $local "Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude"
    $claudeCfgPath = Join-Path $base "config.json"
    if (Test-Path $claudeCfgPath) {
        try {
            $claudeCfg = Get-Content $claudeCfgPath -Raw | ConvertFrom-Json
            $oauthKeys = @(
                "oauth:tokenCache", "oauth:refreshToken", "oauth:accountId",
                "oauth:accessToken", "oauth:expiresAt", "oauth:token",
                "activeAccountId", "activeOrgId", "authSession",
                "lastSignedInAccount", "oauthTokens"
            )
            $changed = $false
            foreach ($k in $oauthKeys) {
                if ($claudeCfg.PSObject.Properties[$k]) {
                    $claudeCfg.PSObject.Properties.Remove($k)
                    $changed = $true
                }
            }
            if ($changed) {
                $cleanJson = $claudeCfg | ConvertTo-Json -Depth 5
                [System.IO.File]::WriteAllText($claudeCfgPath, $cleanJson, $utf8)
            }
            Write-Log "  Cleared OAuth session"
        }
        catch { Write-Log "  OAuth clear failed: $_" }
    }

    # Developer mode
    $devPaths = @(
        (Join-Path $local "Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude\developer_settings.json")
        (Join-Path $local "Claude\developer_settings.json")
        (Join-Path $roaming "Claude\developer_settings.json")
    )
    foreach ($p in $devPaths) {
        $parentDir = Split-Path $p -Parent
        $null = New-Item -ItemType Directory -Force -Path $parentDir 2>&1
        [System.IO.File]::WriteAllText($p, '{"allowDevTools":true}', $utf8)
    }
    Write-Log "  Enabled developer mode"

    Write-Host "  Config written. Look for 'Continue with Gateway' at sign-in." -ForegroundColor DarkGray
    Write-Host ("-" * 50) -ForegroundColor DarkGray
    Write-Host "Launching Claude Desktop..." -ForegroundColor Green
    try {
        Start-Process "shell:appsFolder\Claude_pzs8sxrjxfjjc!Claude"
        Write-Log "  Launched Claude Desktop"
    }
    catch {
        Write-Log "  Claude Desktop launch failed: $_"
        Write-Host "Not found. Install: https://claude.ai/download" -ForegroundColor Red
    }
}

# ============================================
# Settings
# ============================================
function Set-ApiKey {
    Clear-Host
    Write-Host "========== Set DeepSeek API Key ==========" -ForegroundColor Green
    Write-Host ""
    $cfg = Get-Cfg
    if ($cfg.apikey) {
        $masked = $cfg.apikey.Substring(0, [Math]::Min(8, $cfg.apikey.Length)) + "..."
        Write-Host "Current key: $masked" -ForegroundColor Cyan
    }
    else {
        Write-Host "No API key set." -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "Get key at: https://platform.deepseek.com/api_keys" -ForegroundColor Cyan
    Write-Host ""
    $key = Read-Host "Enter API key (blank to keep current)"
    if ($key.Trim()) {
        $cfg.apikey = $key.Trim()
        Save-Cfg $cfg
        Write-Log "API key updated"
        Write-Host "Saved." -ForegroundColor Green
    }
    Start-Sleep -Seconds 1
}

function Pick-Model {
    Clear-Host
    Write-Host "========== Pick Model ==========" -ForegroundColor Green
    Write-Host ""
    $cfg = Get-Cfg
    Write-Host "Current: $($cfg.model)" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  [1] DeepSeek V4 Pro  (deepseek-v4-pro)" -ForegroundColor Yellow
    Write-Host "  [2] DeepSeek V4 Flash (deepseek-v4-flash)" -ForegroundColor Yellow
    Write-Host "  [M] Manual entry" -ForegroundColor White
    Write-Host ""
    $choice = Read-Host "Choice"
    switch ($choice.ToLower()) {
        "1" {
            $cfg.model = "deepseek-v4-pro"
            Save-Cfg $cfg
            Write-Host "Model: deepseek-v4-pro" -ForegroundColor Green
        }
        "2" {
            $cfg.model = "deepseek-v4-flash"
            Save-Cfg $cfg
            Write-Host "Model: deepseek-v4-flash" -ForegroundColor Green
        }
        "m" {
            $m = Read-Host "Enter model ID"
            if ($m) {
                $cfg.model = $m
                Save-Cfg $cfg
                Write-Host "Model: $m" -ForegroundColor Green
                Read-Host "Press Enter"
            }
        }
    }
    Write-Log "Model changed to: $($cfg.model)"
    Start-Sleep -Seconds 1
}

# ============================================
# Main Menu
# ============================================
function Show-Menu {
    Clear-Host
    Show-Status
    $cfg = Get-Cfg
    $perm = "ON"
    if (-not $cfg.skipPerms) { $perm = "OFF" }

    Write-Host ""
    Write-Host "[1] Launch Claude Code" -ForegroundColor Green
    Write-Host "[2] Launch Codex CLI" -ForegroundColor Green
    Write-Host "[3] Launch Codex App" -ForegroundColor Green
    Write-Host "[4] Launch Claude Desktop" -ForegroundColor Green
    Write-Host "[5] Set DeepSeek API Key" -ForegroundColor White
    Write-Host "[6] Pick Model [current: $($cfg.model)]" -ForegroundColor White
    Write-Host "[T] Toggle Permissions [$perm]" -ForegroundColor White
    Write-Host "[L] View Log" -ForegroundColor White
    Write-Host "[Q] Quit" -ForegroundColor Magenta
    Write-Host ""
}

# ============================================
# Run
# ============================================
try {
    Invoke-AutoUpdate
}
catch {
    Write-Log "FATAL: Auto-update crashed: $_"
    Write-Host "Auto-update error (continuing anyway): $_" -ForegroundColor Red
}

if ($args.Count -gt 0) {
    $target = $args[0].ToLower()
    $cfg = Get-Cfg
    if (-not $cfg.apikey -and $target -ne "claude-desktop") {
        Write-Host "API key not set. Run without args to configure." -ForegroundColor Red
        Write-Log "Direct launch aborted: no API key"
        exit 1
    }
    Write-Log "Direct launch: $target"
    switch ($target) {
        "codex"          { Launch-CodexCLI }
        "claude"         { Launch-ClaudeCode }
        "codex-app"      { Launch-CodexApp }
        "claude-desktop" { Launch-ClaudeDesktop }
        default {
            Write-Host "Usage: DeepSeek-Launcher.bat [codex|claude|codex-app|claude-desktop]"
            exit 1
        }
    }
    Write-Log "Exiting after direct launch"
    exit 0
}

while ($true) {
    Show-Menu
    $choice = Read-Host "Choice"
    Write-Log "Menu choice: $choice"
    switch ($choice.ToLower()) {
        "1" {
            try { Launch-ClaudeCode }
            catch { Write-Log "Launch-ClaudeCode crashed: $_"; Write-Host "Error: $_" -ForegroundColor Red; Read-Host "Press Enter" }
        }
        "2" {
            try { Launch-CodexCLI }
            catch { Write-Log "Launch-CodexCLI crashed: $_"; Write-Host "Error: $_" -ForegroundColor Red; Read-Host "Press Enter" }
        }
        "3" {
            try { Launch-CodexApp }
            catch { Write-Log "Launch-CodexApp crashed: $_"; Write-Host "Error: $_" -ForegroundColor Red; Read-Host "Press Enter" }
        }
        "4" {
            try { Launch-ClaudeDesktop }
            catch { Write-Log "Launch-ClaudeDesktop crashed: $_"; Write-Host "Error: $_" -ForegroundColor Red; Read-Host "Press Enter" }
        }
        "5" { Set-ApiKey }
        "6" { Pick-Model }
        "t" {
            $c = Get-Cfg
            $c.skipPerms = -not $c.skipPerms
            Save-Cfg $c
            Write-Log "Permissions toggled to: $($c.skipPerms)"
        }
        "l" {
            Clear-Host
            Write-Host "========== Log File ==========" -ForegroundColor Cyan
            Write-Host "Path: $script:LogPath" -ForegroundColor DarkGray
            Write-Host ""
            if (Test-Path $script:LogPath) {
                Get-Content $script:LogPath -Tail 40
            }
            else {
                Write-Host "No log file yet." -ForegroundColor Yellow
            }
            Write-Host ""
            Read-Host "Press Enter to return"
        }
        "q" {
            Write-Host "Bye!" -ForegroundColor Green
            Write-Log "User quit"
            exit 0
        }
        default {
            Write-Host "Invalid." -ForegroundColor Red
            Start-Sleep -Seconds 1
        }
    }
}
