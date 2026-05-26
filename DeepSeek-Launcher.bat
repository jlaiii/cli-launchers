@echo off
set "BAT_DIR=%~dp0"
set "PSFILE=%TEMP%\DeepSeekLauncher.ps1"
powershell -NoProfile -Command "Get-Content '%~f0' -Encoding UTF8 | Select-Object -Skip 9 | Out-File '%PSFILE%' -Encoding UTF8"
set "BatDir=%~dp0"
powershell -ExecutionPolicy Bypass -Command "& '%PSFILE%' %*; exit $LASTEXITCODE"
set "EC=%errorlevel%"
del /Q "%PSFILE%" 2>nul
exit /b %EC%
#Requires -Version 5.1
<#
.SYNOPSIS
    DeepSeek CLI Launcher â€” Codex CLI + Claude Code + Codex App through DeepSeek API
.DESCRIPTION
    Single launcher for running Codex CLI, Claude Code, and Codex App through
    the DeepSeek API. Set your API key, pick a model, and launch any tool.
    Usage:
      DeepSeek-Launcher.bat                -> interactive menu
      DeepSeek-Launcher.bat codex          -> launch Codex CLI directly
      DeepSeek-Launcher.bat claude         -> launch Claude Code directly
      DeepSeek-Launcher.bat codex-app      -> launch Codex App directly
#>

$ErrorActionPreference = "Stop"
Clear-Host

# ============================================
# Paths & Config
# ============================================
$script:BaseDir      = if ($env:BatDir) { $env:BatDir } elseif ($PSScriptRoot) { $PSScriptRoot } else { Join-Path $env:USERPROFILE ".cli-launchers" }
if (-not (Test-Path $script:BaseDir)) { New-Item -ItemType Directory -Force -Path $script:BaseDir | Out-Null }
$script:ConfigPath   = Join-Path $script:BaseDir "DeepSeek-Launcher.config.json"
$script:VersionCache = Join-Path $script:BaseDir "DeepSeek-Launcher.versions.json"
$script:CacheTTLMinutes = 60

$script:DefaultConfig = @{
    deepseekModel   = "deepseek-v4-pro"
    deepseekApiKey  = ""
    skipPermissions = $true
}

# ============================================
# Config Helpers
# ============================================
function Get-Config {
    $defaults = $script:DefaultConfig
    if (Test-Path $script:ConfigPath) {
        try {
            $cfg = Get-Content $script:ConfigPath -Raw | ConvertFrom-Json
            foreach ($key in $defaults.Keys) {
                if (-not $cfg.PSObject.Properties[$key]) {
                    $cfg | Add-Member -NotePropertyName $key -NotePropertyValue $defaults[$key] -Force
                }
            }
            return $cfg
        } catch { }
    }
    New-Object PSObject -Property $defaults
}

function Save-Config($cfg) {
    $cfg | ConvertTo-Json -Depth 3 | Set-Content $script:ConfigPath -Encoding UTF8
}

# ============================================
# Version Cache
# ============================================
function Get-VersionCache {
    $defaultCache = @{
        codexLatestVersion  = ""; codexLastChecked  = ""
        claudeLatestVersion = ""; claudeLastChecked = ""
    }
    if (Test-Path $script:VersionCache) {
        try {
            $cache = Get-Content $script:VersionCache -Raw | ConvertFrom-Json
            foreach ($key in $defaultCache.Keys) {
                if (-not $cache.PSObject.Properties[$key]) {
                    $cache | Add-Member -NotePropertyName $key -NotePropertyValue $defaultCache[$key] -Force
                }
            }
            return $cache
        } catch { }
    }
    New-Object PSObject -Property $defaultCache
}

function Save-VersionCache($cache) {
    $cache | ConvertTo-Json -Depth 3 | Set-Content $script:VersionCache -Encoding UTF8
}

function Is-CacheStale($lastCheckedStr) {
    if ([string]::IsNullOrWhiteSpace($lastCheckedStr)) { return $true }
    try {
        $last = [datetime]::Parse($lastCheckedStr)
        return ([datetime]::Now - $last).TotalMinutes -gt $script:CacheTTLMinutes
    } catch { return $true }
}

function Test-CommandExists($cmd) {
    $null -ne (Get-Command $cmd -ErrorAction SilentlyContinue)
}

function Compare-Versions($installed, $latest) {
    if ([string]::IsNullOrWhiteSpace($installed) -or [string]::IsNullOrWhiteSpace($latest)) { return $null }
    try { return ([version]$latest -gt [version]$installed) } catch { return $null }
}

# ============================================
# Version Checkers (Codex + Claude only)
# ============================================
function Get-CodexInstalledVersion {
    try {
        $ver = & codex --version 2>$null
        if ($LASTEXITCODE -eq 0 -and $ver -match '(\d+\.\d+\.\d+)') { return $matches[1] }
    } catch { }
    return $null
}

function Get-CodexLatestVersion {
    $cache = Get-VersionCache
    if (-not (Is-CacheStale $cache.codexLastChecked)) { return $cache.codexLatestVersion }
    try {
        $resp = Invoke-WebRequest -Uri "https://registry.npmjs.org/@openai/codex/latest" -UseBasicParsing -TimeoutSec 15
        $data = $resp.Content | ConvertFrom-Json
        if ($data.version) {
            $cache.codexLatestVersion = $data.version
            $cache.codexLastChecked = [datetime]::Now.ToString("o")
            Save-VersionCache $cache
            return $data.version
        }
    } catch { }
    return $null
}

function Get-ClaudeInstalledVersion {
    try {
        $ver = claude --version 2>$null
        if ($ver -match '(\d+\.\d+\.\d+)') { return $matches[1] }
    } catch { }
    return $null
}

function Get-ClaudeLatestVersion {
    $cache = Get-VersionCache
    if (-not (Is-CacheStale $cache.claudeLastChecked)) { return $cache.claudeLatestVersion }
    try {
        $resp = Invoke-WebRequest -Uri "https://registry.npmjs.org/@anthropic-ai/claude-code/latest" -UseBasicParsing -TimeoutSec 15
        $data = $resp.Content | ConvertFrom-Json
        if ($data.version) {
            $cache.claudeLatestVersion = $data.version
            $cache.claudeLastChecked = [datetime]::Now.ToString("o")
            Save-VersionCache $cache
            return $data.version
        }
    } catch { }
    return $null
}

# ============================================
# Installers
# ============================================
function Install-NodeJS {
    if (Test-CommandExists "winget") {
        Write-Host "Installing Node.js via winget..." -ForegroundColor Cyan
        try {
            winget install OpenJS.NodeJS -e --accept-package-agreements --accept-source-agreements 2>$null | Out-Null
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
            if (Test-CommandExists "npm") { Write-Host "Node.js ready!" -ForegroundColor Green; return $true }
        } catch { }
    }
    Write-Host "Downloading Node.js LTS..." -ForegroundColor Cyan
    try {
        $index = Invoke-WebRequest "https://nodejs.org/download/release/index.json" -UseBasicParsing -TimeoutSec 30 | ConvertFrom-Json
        $lts = $index | Where-Object { $_.lts -ne $false -and $_.lts -ne "" } | Select-Object -First 1
        if (-not $lts) { $lts = $index | Select-Object -First 1 }
        $url = "https://nodejs.org/dist/$($lts.version)/node-$($lts.version)-x64.msi"
        $msi = Join-Path $env:TEMP "node-installer.msi"
        Invoke-WebRequest $url -OutFile $msi -TimeoutSec 120
        Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn /norestart" -Wait
        Remove-Item $msi -Force -ErrorAction SilentlyContinue
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
        if (Test-CommandExists "npm") { Write-Host "Node.js installed!" -ForegroundColor Green; return $true }
    } catch { }
    Write-Host "Could not auto-install Node.js. Install from https://nodejs.org" -ForegroundColor Red
    return $false
}

function Install-CodexCLI {
    if (-not (Test-CommandExists "npm")) {
        $ans = Read-Host "Node.js/npm required. Install now? (y/n)"
        if ($ans -ne 'y') { return $false }
        if (-not (Install-NodeJS)) { return $false }
    }
    Write-Host "Installing Codex CLI via npm..." -ForegroundColor Cyan
    $oldEAP = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    try {
        npm install -g @openai/codex 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Host "npm install failed. Try Administrator." -ForegroundColor Red; return $false }
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
        $ver = Get-CodexInstalledVersion
        Write-Host "Codex CLI v$ver installed." -ForegroundColor Green
        return $true
    } catch { Write-Host "ERROR: $_" -ForegroundColor Red; return $false }
    finally { $ErrorActionPreference = $oldEAP }
}

function Install-ClaudeCode {
    Write-Host "Installing/Updating Claude Code..." -ForegroundColor Cyan
    try {
        irm https://claude.ai/install.ps1 | iex
        Write-Host "Claude Code installation complete." -ForegroundColor Green
    } catch { Write-Host "ERROR: $_" -ForegroundColor Red }
    Read-Host "Press Enter to continue"
}

# ============================================
# DeepSeek API Key + Model Picker
# ============================================
function Set-DeepSeekApiKey {
    Clear-Host
    Write-Host "=============================================" -ForegroundColor Green
    Write-Host "   Set DeepSeek API Key" -ForegroundColor Green
    Write-Host "=============================================" -ForegroundColor Green
    Write-Host ""
    $cfg = Get-Config
    if ($cfg.deepseekApiKey) {
        $masked = $cfg.deepseekApiKey.Substring(0, [Math]::Min(8, $cfg.deepseekApiKey.Length)) + "..."
        Write-Host "Current key: $masked" -ForegroundColor Cyan
    } else {
        Write-Host "No API key set." -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "Get your key at: https://platform.deepseek.com/api_keys" -ForegroundColor Cyan
    Write-Host ""
    $key = Read-Host "Enter DeepSeek API key (or blank to keep current)"
    if ($key.Trim()) {
        $cfg.deepseekApiKey = $key.Trim()
        Save-Config $cfg
        Write-Host "API key saved." -ForegroundColor Green
    } else {
        Write-Host "Key unchanged." -ForegroundColor Yellow
    }
    Start-Sleep -Seconds 1
}

function Show-DeepSeekModelPicker {
    while ($true) {
        Clear-Host
        Write-Host "=============================================" -ForegroundColor Green
        Write-Host "   DeepSeek Model Selection" -ForegroundColor Green
        Write-Host "=============================================" -ForegroundColor Green
        Write-Host ""
        $cfg = Get-Config
        Write-Host "Current: $($cfg.deepseekModel)" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  [1] DeepSeek V4 Pro (Recommended)  deepseek-v4-pro" -ForegroundColor Yellow
        Write-Host "  [2] DeepSeek V4 Flash               deepseek-v4-flash" -ForegroundColor Yellow
        Write-Host "  [M] Manual entry" -ForegroundColor Yellow
        Write-Host "  [K] Set API Key" -ForegroundColor White
        Write-Host "  [B] Back" -ForegroundColor Magenta
        Write-Host ""
        $choice = Read-Host "Enter choice"
        switch ($choice.ToLower()) {
            "1" { $cfg = Get-Config; $cfg.deepseekModel = "deepseek-v4-pro"; Save-Config $cfg; Write-Host "Selected: deepseek-v4-pro (V4 Pro)" -ForegroundColor Green; Start-Sleep -Seconds 1; return }
            "2" { $cfg = Get-Config; $cfg.deepseekModel = "deepseek-v4-flash"; Save-Config $cfg; Write-Host "Selected: deepseek-v4-flash (Flash)" -ForegroundColor Green; Start-Sleep -Seconds 1; return }
            "m" {
                $manual = Read-Host "Enter DeepSeek model ID"
                if ($manual) { $cfg = Get-Config; $cfg.deepseekModel = $manual; Save-Config $cfg; Write-Host "Model: $manual" -ForegroundColor Green; Read-Host "Press Enter to continue" }
                return
            }
            "k" { Set-DeepSeekApiKey }
            "b" { return }
            default { Write-Host "Invalid choice." -ForegroundColor Red; Start-Sleep -Seconds 1 }
        }
    }
}

# ============================================
# Launch Functions
# ============================================
function Require-ApiKey {
    $cfg = Get-Config
    if (-not $cfg.deepseekApiKey) {
        Write-Host "ERROR: DeepSeek API key not set." -ForegroundColor Red
        Write-Host "Use option 4 to set your key." -ForegroundColor Yellow
        Read-Host "Press Enter to return to menu"
        return $false
    }
    return $true
}

function Launch-CodexCLI {
    if (-not (Require-ApiKey)) { return }
    if (-not (Test-CommandExists "codex")) {
        Write-Host "Codex CLI not installed." -ForegroundColor Yellow
        $ans = Read-Host "Install now? (y/n)"
        if ($ans -ne 'y') { return }
        if (-not (Install-CodexCLI)) { return }
    }
    $cfg = Get-Config
    $env:OPENAI_API_KEY = $cfg.deepseekApiKey
    $env:OPENAI_BASE_URL = "https://api.deepseek.com/v1"

    $cmdParts = @("codex", "--model-reasoning-effort", "high")
    if ($cfg.skipPermissions) { $cmdParts += "--yolo" }
    $cmdString = $cmdParts -join ' '
    Write-Host "`n>>> $cmdString (DeepSeek: $($cfg.deepseekModel))" -ForegroundColor Green
    Write-Host ("-" * 50) -ForegroundColor DarkGray
    Clear-Host
    try {
        $cmdArgs = $cmdParts[1..($cmdParts.Length-1)]
        & $cmdParts[0] @cmdArgs
        if ($LASTEXITCODE -ne 0) { Write-Host "Codex exited with code $LASTEXITCODE." -ForegroundColor Yellow }
    } catch { Write-Host "ERROR: $_" -ForegroundColor Red }
    Read-Host "Session ended. Press Enter to return to menu"
}

function Launch-ClaudeCode {
    if (-not (Require-ApiKey)) { return }
    $cfg = Get-Config
    $env:ANTHROPIC_BASE_URL = "https://api.deepseek.com/anthropic"
    $env:ANTHROPIC_API_KEY = $cfg.deepseekApiKey

    $cmdParts = @("claude")
    if ($cfg.skipPermissions) { $cmdParts += "--dangerously-skip-permissions" }
    $cmdString = $cmdParts -join ' '
    Write-Host "`n>>> $cmdString (DeepSeek: $($cfg.deepseekModel))" -ForegroundColor Green
    Write-Host ("-" * 50) -ForegroundColor DarkGray
    Clear-Host
    try {
        $cmdArgs = $cmdParts[1..($cmdParts.Length-1)]
        & $cmdParts[0] @cmdArgs
        if ($LASTEXITCODE -ne 0) { Write-Host "Claude Code exited with code $LASTEXITCODE." -ForegroundColor Yellow }
    } catch { Write-Host "ERROR: $_" -ForegroundColor Red }
    Read-Host "Session ended. Press Enter to return to menu"
}

function Launch-CodexApp {
    if (-not (Require-ApiKey)) { return }
    if (-not (Test-CommandExists "codex")) {
        Write-Host "Codex CLI not installed (needed for Codex App)." -ForegroundColor Yellow
        $ans = Read-Host "Install now? (y/n)"
        if ($ans -ne 'y') { return }
        if (-not (Install-CodexCLI)) { return }
    }
    $cfg = Get-Config
    $codexHome = Join-Path $env:USERPROFILE ".codex"
    if (-not (Test-Path $codexHome)) { New-Item -ItemType Directory -Force -Path $codexHome | Out-Null }

    # Back up existing config + auth, write a clean DeepSeek config
    $configFile = Join-Path $codexHome "config.toml"
    $backupFile = Join-Path $codexHome "config.toml.cli-launcher-backup"
    $hadConfig = Test-Path $configFile
    if ($hadConfig) { Copy-Item $configFile $backupFile -Force }

    # Temporarily remove auth.json so it doesn't override our provider
    $authFile = Join-Path $codexHome "auth.json"
    $authBackup = Join-Path $codexHome "auth.json.cli-launcher-backup"
    $hadAuth = Test-Path $authFile
    if ($hadAuth) { Move-Item $authFile $authBackup -Force }

    $toml = @"
model = "$($cfg.deepseekModel)"
model_provider = "deepseek"
model_reasoning_effort = "high"
wire_api = "chat"

[model_providers.deepseek]
name = "DeepSeek"
base_url = "https://api.deepseek.com/v1"
env_key = "DEEPSEEK_API_KEY"
"@
    Set-Content -LiteralPath $configFile -Value $toml -Encoding UTF8
    $env:DEEPSEEK_API_KEY = $cfg.deepseekApiKey

    $cmdParts = @("codex", "app")
    $cmdString = $cmdParts -join ' '
    Write-Host "`n>>> $cmdString (DeepSeek: $($cfg.deepseekModel))" -ForegroundColor Green
    Write-Host ("-" * 50) -ForegroundColor DarkGray
    Clear-Host
    try {
        $cmdArgs = $cmdParts[1..($cmdParts.Length-1)]
        & $cmdParts[0] @cmdArgs
        if ($LASTEXITCODE -ne 0) { Write-Host "Codex App exited with code $LASTEXITCODE." -ForegroundColor Yellow }
    } catch { Write-Host "ERROR: $_" -ForegroundColor Red }

    # Restore original config + auth
    if ($hadConfig) { Copy-Item $backupFile $configFile -Force; Remove-Item $backupFile -Force }
    else { Remove-Item $configFile -Force -ErrorAction SilentlyContinue }
    if ($hadAuth) { Move-Item $authBackup $authFile -Force }
    Read-Host "Session ended. Press Enter to return to menu"
}

# ============================================
# Status Display
# ============================================
function Show-Status {
    $cCodex  = Test-CommandExists "codex"
    $cClaude = Test-CommandExists "claude"
    $cfg     = Get-Config

    Write-Host "`n========== DeepSeek CLI Launcher ==========" -ForegroundColor Cyan
    if ($cCodex) {
        $inst = Get-CodexInstalledVersion
        $lat  = Get-CodexLatestVersion
        if ($inst -and $lat -and (Compare-Versions $inst $lat)) {
            Write-Host "  Codex CLI     : v$inst (update v$lat available)" -ForegroundColor Yellow
        } else {
            Write-Host "  Codex CLI     : v$inst (up to date)" -ForegroundColor Green
        }
    } else {
        Write-Host "  Codex CLI     : NOT INSTALLED" -ForegroundColor DarkGray
    }
    if ($cClaude) {
        $inst = Get-ClaudeInstalledVersion
        $lat  = Get-ClaudeLatestVersion
        if ($inst -and $lat -and (Compare-Versions $inst $lat)) {
            Write-Host "  Claude Code   : v$inst (update v$lat available)" -ForegroundColor Yellow
        } else {
            Write-Host "  Claude Code   : v$inst (up to date)" -ForegroundColor Green
        }
    } else {
        Write-Host "  Claude Code   : NOT INSTALLED" -ForegroundColor DarkGray
    }
    Write-Host "  DeepSeek Model: $($cfg.deepseekModel)" -ForegroundColor Cyan
    if ($cfg.deepseekApiKey) {
        Write-Host "  DeepSeek Key  : SET" -ForegroundColor Green
    } else {
        Write-Host "  DeepSeek Key  : NOT SET" -ForegroundColor Red
    }
    $permText = if ($cfg.skipPermissions) { "ON" } else { "OFF" }
    Write-Host "  Skip-perms    : $permText" -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan
}

# ============================================
# Main Menu
# ============================================
function Show-MainMenu {
    Clear-Host
    Show-Status
    $cCodex  = Test-CommandExists "codex"
    $cClaude = Test-CommandExists "claude"
    $cfg     = Get-Config

    Write-Host "`n[1] Install / Update Codex CLI (needed for Codex + Codex App)" -ForegroundColor White
    if ($cCodex) {
        $inst = Get-CodexInstalledVersion; $lat = Get-CodexLatestVersion
        if ($inst -and $lat -and (Compare-Versions $inst $lat)) { Write-Host "     ^^ UPDATE AVAILABLE" -ForegroundColor Yellow }
    }
    Write-Host "[2] Install / Update Claude Code" -ForegroundColor White
    if ($cClaude) {
        $inst = Get-ClaudeInstalledVersion; $lat = Get-ClaudeLatestVersion
        if ($inst -and $lat -and (Compare-Versions $inst $lat)) { Write-Host "     ^^ UPDATE AVAILABLE" -ForegroundColor Yellow }
    }
    Write-Host "[3] Pick DeepSeek Model [current: $($cfg.deepseekModel)]" -ForegroundColor White
    Write-Host "[4] Set DeepSeek API Key" -ForegroundColor White
    if ($cCodex -and $cfg.deepseekApiKey) {
        Write-Host "[5] Launch Codex CLI (via DeepSeek)" -ForegroundColor Green
    } else {
        $reason = if (-not $cfg.deepseekApiKey) { "API key not set" } else { "Codex CLI not installed" }
        Write-Host "[5] Launch Codex CLI [$reason]" -ForegroundColor DarkGray
    }
    if ($cClaude -and $cfg.deepseekApiKey) {
        Write-Host "[6] Launch Claude Code (via DeepSeek)" -ForegroundColor Green
    } else {
        $reason = if (-not $cfg.deepseekApiKey) { "API key not set" } else { "Claude Code not installed" }
        Write-Host "[6] Launch Claude Code [$reason]" -ForegroundColor DarkGray
    }
    if ($cCodex -and $cfg.deepseekApiKey) {
        Write-Host "[7] Launch Codex App (via DeepSeek)" -ForegroundColor Green
    } else {
        $reason = if (-not $cfg.deepseekApiKey) { "API key not set" } else { "Codex CLI not installed" }
        Write-Host "[7] Launch Codex App [$reason]" -ForegroundColor DarkGray
    }
    Write-Host "[C] Clear Version Cache" -ForegroundColor White
    $permText = if ($cfg.skipPermissions) { "ON" } else { "OFF" }
    Write-Host "[T] Toggle Permission Bypass [currently: $permText]" -ForegroundColor White
    Write-Host "[Q] Quit" -ForegroundColor Magenta
    Write-Host ""
}

# ============================================
# Main
# ============================================
if ($args.Count -gt 0) {
    $target = $args[0].ToLower()
    $cfg = Get-Config
    if (-not $cfg.deepseekApiKey) { Write-Host "ERROR: DeepSeek API key not set. Run launcher to configure." -ForegroundColor Red; exit 1 }

    switch ($target) {
        "codex"     { Launch-CodexCLI; exit $LASTEXITCODE }
        "claude"    { Launch-ClaudeCode; exit $LASTEXITCODE }
        "codex-app" { Launch-CodexApp; exit $LASTEXITCODE }
        default {
            Write-Host "Usage: DeepSeek-Launcher.bat [codex|claude|codex-app]"
            exit 1
        }
    }
}

while ($true) {
    Show-MainMenu
    $choice = Read-Host "Enter choice"
    $cfg = Get-Config
    switch ($choice.ToLower()) {
        "1" {
            if (Test-CommandExists "codex") {
                $inst = Get-CodexInstalledVersion; $lat = Get-CodexLatestVersion
                if ($inst -and $lat -and (Compare-Versions $inst $lat)) {
                    Write-Host "Codex update: v$inst -> v$lat" -ForegroundColor Yellow
                    $ans = Read-Host "Update now? (y/n)"
                    if ($ans -eq 'y') { Install-CodexCLI }
                } else {
                    $ans = Read-Host "Codex CLI is up to date. Reinstall? (y/n)"
                    if ($ans -eq 'y') { Install-CodexCLI }
                }
            } else {
                $ans = Read-Host "Install Codex CLI now? (y/n)"
                if ($ans -eq 'y') { Install-CodexCLI }
            }
            Read-Host "Press Enter to continue"
        }
        "2" {
            if (Test-CommandExists "claude") {
                $inst = Get-ClaudeInstalledVersion; $lat = Get-ClaudeLatestVersion
                if ($inst -and $lat -and (Compare-Versions $inst $lat)) {
                    Write-Host "Claude Code update: v$inst -> v$lat" -ForegroundColor Yellow
                    $ans = Read-Host "Update now? (y/n)"
                    if ($ans -eq 'y') { Install-ClaudeCode }
                } else {
                    $ans = Read-Host "Claude Code is up to date. Reinstall? (y/n)"
                    if ($ans -eq 'y') { Install-ClaudeCode }
                }
            } else {
                $ans = Read-Host "Install Claude Code now? (y/n)"
                if ($ans -eq 'y') { Install-ClaudeCode }
            }
            Read-Host "Press Enter to continue"
        }
        "3" { Show-DeepSeekModelPicker }
        "4" { Set-DeepSeekApiKey }
        "5" {
            if (-not $cfg.deepseekApiKey) {
                Write-Host "API key not set. Use option 4 first." -ForegroundColor Red
                Read-Host "Press Enter to continue"
            } elseif (-not (Test-CommandExists "codex")) {
                Write-Host "Codex CLI not installed. Use option 1 first." -ForegroundColor Red
                Read-Host "Press Enter to continue"
            } else { Launch-CodexCLI }
        }
        "6" {
            if (-not $cfg.deepseekApiKey) {
                Write-Host "API key not set. Use option 4 first." -ForegroundColor Red
                Read-Host "Press Enter to continue"
            } elseif (-not (Test-CommandExists "claude")) {
                Write-Host "Claude Code not installed. Use option 2 first." -ForegroundColor Red
                Read-Host "Press Enter to continue"
            } else { Launch-ClaudeCode }
        }
        "7" {
            if (-not $cfg.deepseekApiKey) {
                Write-Host "API key not set. Use option 4 first." -ForegroundColor Red
                Read-Host "Press Enter to continue"
            } elseif (-not (Test-CommandExists "codex")) {
                Write-Host "Codex CLI not installed. Use option 1 first." -ForegroundColor Red
                Read-Host "Press Enter to continue"
            } else { Launch-CodexApp }
        }
        "c" {
            $cache = Get-VersionCache
            $cache.codexLastChecked = ""; $cache.claudeLastChecked = ""
            Save-VersionCache $cache
            Write-Host "Version cache cleared." -ForegroundColor Green; Start-Sleep -Seconds 1
        }
        "t" {
            $cfg = Get-Config
            $cfg.skipPermissions = -not $cfg.skipPermissions
            Save-Config $cfg
            $text = if ($cfg.skipPermissions) { "SKIP-PERMISSIONS" } else { "NORMAL" }
            Write-Host "Mode: $text" -ForegroundColor Green; Start-Sleep -Seconds 1
        }
        "q" { Write-Host "Goodbye!" -ForegroundColor Green; exit 0 }
        default { Write-Host "Invalid choice." -ForegroundColor Red; Start-Sleep -Seconds 1 }
    }
}
