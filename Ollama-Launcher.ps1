#Requires -Version 5.1
<#
.SYNOPSIS
    Ollama CLI Launcher — Codex CLI + Claude Code + Codex App through Ollama
.DESCRIPTION
    Single launcher for running Codex CLI, Claude Code, and Codex App through Ollama.
    Browse cloud/local models, pull models, check for updates, toggle permissions.
    Usage:
      Ollama-Launcher.bat                  -> interactive menu
      Ollama-Launcher.bat codex            -> launch Codex CLI directly
      Ollama-Launcher.bat claude           -> launch Claude Code directly
      Ollama-Launcher.bat codex-app        -> launch Codex App directly
#>

$ErrorActionPreference = "Stop"
Clear-Host

# ============================================
# Paths & Config
# ============================================
$script:BaseDir      = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "cli-launchers"
if (-not (Test-Path $script:BaseDir)) { New-Item -ItemType Directory -Force -Path $script:BaseDir | Out-Null }
$script:ConfigPath   = Join-Path $script:BaseDir "Ollama-Launcher.config.json"
$script:VersionCache = Join-Path $script:BaseDir "Ollama-Launcher.versions.json"
$script:CacheTTLMinutes = 60

$script:DefaultConfig = @{
    selectedModel   = "kimi-k2.6:cloud"
    source          = "cloud"
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
        ollamaLatestVersion = ""; ollamaLastChecked = ""
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

function Test-ClaudeDesktopInstalled {
    $null -ne (Get-StartApps 2>$null | Where-Object { $_.AppID -like "*Claude*" -and $_.AppID -like "*!Claude" })
}

function Compare-Versions($installed, $latest) {
    if ([string]::IsNullOrWhiteSpace($installed) -or [string]::IsNullOrWhiteSpace($latest)) { return $null }
    try {
        return ([version]$latest -gt [version]$installed)
    } catch { return $null }
}

# ============================================
# Version Checkers
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

function Get-OllamaInstalledVersion {
    try {
        $ver = ollama --version 2>$null
        if ($ver -match '(\d+\.\d+\.\d+)') { return $matches[1] }
    } catch { }
    return $null
}

function Get-OllamaLatestVersion {
    $cache = Get-VersionCache
    if (-not (Is-CacheStale $cache.ollamaLastChecked)) { return $cache.ollamaLatestVersion }
    try {
        $resp = Invoke-WebRequest -Uri "https://api.github.com/repos/ollama/ollama/releases/latest" -UseBasicParsing -TimeoutSec 15
        $data = $resp.Content | ConvertFrom-Json
        if ($data.tag_name) {
            $ver = $data.tag_name -replace '^v', ''
            $cache.ollamaLatestVersion = $ver
            $cache.ollamaLastChecked = [datetime]::Now.ToString("o")
            Save-VersionCache $cache
            return $ver
        }
    } catch { }
    return $null
}

# ============================================
# Ollama Server & Auth
# ============================================
function Test-OllamaRunning {
    try {
        $null = Invoke-WebRequest -Uri "http://localhost:11434/api/tags" -UseBasicParsing -TimeoutSec 3
        return $true
    } catch { return $false }
}

function Start-OllamaServer {
    if (Test-OllamaRunning) { return $true }
    Write-Host "Starting Ollama server..." -ForegroundColor Yellow
    try {
        Start-Process -FilePath "ollama" -ArgumentList "serve" -WindowStyle Hidden
        $tries = 0
        while ($tries -lt 30) {
            Start-Sleep -Milliseconds 500
            if (Test-OllamaRunning) {
                Write-Host "Ollama server is ready." -ForegroundColor Green
                return $true
            }
            $tries++
        }
        Write-Host "Ollama server did not start in time." -ForegroundColor Red
        return $false
    } catch {
        Write-Host "Failed to start Ollama: $_" -ForegroundColor Red
        return $false
    }
}

function Test-OllamaAuth {
    try {
        ollama list 2>$null | Out-Null
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
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

function Install-Ollama {
    Write-Host "Installing/Updating Ollama..." -ForegroundColor Cyan
    try {
        irm https://ollama.com/install.ps1 | iex
        Write-Host "Ollama installation complete." -ForegroundColor Green
    } catch {
        Write-Host "ERROR: $_" -ForegroundColor Red
    }
    Read-Host "Press Enter to continue"
}

# ============================================
# Model Fetchers
# ============================================
function Get-CloudModels {
    Write-Host "Fetching newest models from Ollama registry..." -ForegroundColor DarkGray
    try {
        $resp = Invoke-WebRequest -Uri "https://ollama.com/api/tags" -UseBasicParsing -TimeoutSec 15
        $data = $resp.Content | ConvertFrom-Json
        $models = @($data.models)
        if ($models.Count -eq 0) { return @() }
        foreach ($m in $models) {
            try { $dt = [datetime]::Parse($m.modified_at) } catch { $dt = [datetime]::MinValue }
            $m | Add-Member -NotePropertyName modified_dt -NotePropertyValue $dt -Force
        }
        return ($models | Sort-Object modified_dt -Descending | Select-Object -First 10)
    } catch {
        Write-Host "Failed to fetch cloud models: $_" -ForegroundColor Red
        return @()
    }
}

function Get-LocalModels {
    Write-Host "Fetching local models from Ollama..." -ForegroundColor DarkGray
    try {
        $resp = Invoke-WebRequest -Uri "http://localhost:11434/api/tags" -UseBasicParsing -TimeoutSec 5
        $data = $resp.Content | ConvertFrom-Json
        $models = @($data.models)
        if ($models.Count -eq 0) { return @() }
        foreach ($m in $models) {
            try { $dt = [datetime]::Parse($m.modified_at) } catch { $dt = [datetime]::MinValue }
            $m | Add-Member -NotePropertyName modified_dt -NotePropertyValue $dt -Force
        }
        return ($models | Sort-Object modified_dt -Descending)
    } catch {
        Write-Host "Failed to fetch local models: $_" -ForegroundColor Red
        return @()
    }
}

# ============================================
# Model Picker
# ============================================
function Show-CloudModelMenu {
    Clear-Host
    Write-Host "=============================================" -ForegroundColor Green
    Write-Host "   Cloud Models (Ollama Registry - Newest)" -ForegroundColor Green
    Write-Host "=============================================" -ForegroundColor Green
    Write-Host ""
    $models = Get-CloudModels
    if ($models.Count -eq 0) {
        Write-Host "No cloud models could be fetched." -ForegroundColor Red
        Read-Host "Press Enter to return"
        return
    }
    for ($i = 0; $i -lt $models.Count; $i++) {
        $sizeGB = "{0:N2}" -f ($models[$i].size / 1GB)
        Write-Host "  [$($i+1)] $($models[$i].name)" -ForegroundColor Cyan -NoNewline
        Write-Host "  ($sizeGB GB, $($models[$i].modified_at.Substring(0,10)))" -ForegroundColor DarkGray
    }
    Write-Host ""
    Write-Host "  [M] Manual entry" -ForegroundColor Yellow
    Write-Host "  [B] Back" -ForegroundColor Magenta
    Write-Host ""
    $choice = Read-Host "Select a model"
    if ($choice.ToLower() -eq "b") { return }
    if ($choice.ToLower() -eq "m") {
        $manual = Read-Host "Enter model name (e.g., kimi-k2.6:cloud)"
        if ($manual) {
            $cfg = Get-Config; $cfg.selectedModel = $manual; $cfg.source = "cloud"; Save-Config $cfg
            Write-Host "Model: $manual" -ForegroundColor Green
        }
        Read-Host "Press Enter to continue"
        return
    }
    $idx = 0
    if ([int]::TryParse($choice, [ref]$idx) -and $idx -ge 1 -and $idx -le $models.Count) {
        $sel = $models[$idx - 1].name
        $cfg = Get-Config; $cfg.selectedModel = $sel; $cfg.source = "cloud"; Save-Config $cfg
        Write-Host "Model: $sel" -ForegroundColor Green
    } else { Write-Host "Invalid selection." -ForegroundColor Red }
    Read-Host "Press Enter to continue"
}

function Show-LocalModelMenu {
    Clear-Host
    Write-Host "=============================================" -ForegroundColor Green
    Write-Host "   Local Models (on this PC)" -ForegroundColor Green
    Write-Host "=============================================" -ForegroundColor Green
    Write-Host ""
    $models = Get-LocalModels
    if ($models.Count -eq 0) {
        Write-Host "No local models found. Pull one from the cloud first." -ForegroundColor Yellow
        Read-Host "Press Enter to return"
        return
    }
    for ($i = 0; $i -lt $models.Count; $i++) {
        $sizeGB = "{0:N2}" -f ($models[$i].size / 1GB)
        Write-Host "  [$($i+1)] $($models[$i].name)" -ForegroundColor Cyan -NoNewline
        Write-Host "  ($sizeGB GB, $($models[$i].modified_at.Substring(0,10)))" -ForegroundColor DarkGray
    }
    Write-Host ""
    Write-Host "  [B] Back" -ForegroundColor Magenta
    Write-Host ""
    $choice = Read-Host "Select a model"
    if ($choice.ToLower() -eq "b") { return }
    $idx = 0
    if ([int]::TryParse($choice, [ref]$idx) -and $idx -ge 1 -and $idx -le $models.Count) {
        $sel = $models[$idx - 1].name
        $cfg = Get-Config; $cfg.selectedModel = $sel; $cfg.source = "local"; Save-Config $cfg
        Write-Host "Model: $sel" -ForegroundColor Green
    } else { Write-Host "Invalid selection." -ForegroundColor Red }
    Read-Host "Press Enter to continue"
}

function Show-ModelPicker {
    while ($true) {
        Clear-Host
        Write-Host "=============================================" -ForegroundColor Green
        Write-Host "         Pick / Change Model" -ForegroundColor Green
        Write-Host "=============================================" -ForegroundColor Green
        Write-Host ""
        $cfg = Get-Config
        Write-Host "Current: $($cfg.selectedModel) [source: $($cfg.source)]" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  [1] Browse Cloud Models (newest 10)" -ForegroundColor Yellow
        Write-Host "  [2] Browse Local Models" -ForegroundColor Yellow
        Write-Host "  [3] Manual Entry" -ForegroundColor Yellow
        Write-Host "  [B] Back" -ForegroundColor Magenta
        Write-Host ""
        $choice = Read-Host "Enter choice"
        switch ($choice.ToLower()) {
            "1" { Show-CloudModelMenu }
            "2" { Show-LocalModelMenu }
            "3" {
                $manual = Read-Host "Enter full model name (e.g., kimi-k2.6:cloud, llama3.3:latest)"
                if ($manual) {
                    $cfg = Get-Config; $cfg.selectedModel = $manual; $cfg.source = "manual"; Save-Config $cfg
                    Write-Host "Model: $manual" -ForegroundColor Green
                    Read-Host "Press Enter to continue"
                }
            }
            "b" { return }
            default { Write-Host "Invalid choice." -ForegroundColor Red; Start-Sleep -Seconds 1 }
        }
    }
}

# ============================================
# Pull & Sign-in
# ============================================
function Pull-SelectedModel {
    $model = (Get-Config).selectedModel
    Write-Host "Pulling '$model' into local Ollama..." -ForegroundColor Cyan
    try {
        ollama pull $model
        Write-Host "Done." -ForegroundColor Green
    } catch { Write-Host "ERROR: $_" -ForegroundColor Red }
    Read-Host "Press Enter to continue"
}

function Check-OllamaSignin {
    Write-Host "Checking Ollama sign-in..." -ForegroundColor Cyan
    try {
        $models = ollama list 2>$null
        if ($LASTEXITCODE -eq 0 -and $models) {
            Write-Host "Ollama is signed in. Local models:" -ForegroundColor Green
            $models | Select-Object -First 10 | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
        } else {
            Write-Host "Could not list models. You may need to sign in." -ForegroundColor Yellow
            $ans = Read-Host "Run 'ollama signin' now? (y/n)"
            if ($ans -eq 'y') { ollama signin }
        }
    } catch { Write-Host "Error: $_" -ForegroundColor Red }
    Read-Host "Press Enter to continue"
}

# ============================================
# Launch Functions
# ============================================
function Launch-Codex {
    $model = (Get-Config).selectedModel
    if (-not (Start-OllamaServer)) { Read-Host "Press Enter to return"; return }
    if (-not (Ensure-CodexInstalled)) { return }

    $cmdParts = @("ollama", "launch", "codex", "--model", $model, "--")
    if ((Get-Config).skipPermissions) { $cmdParts += "--yolo" }
    $cmdString = $cmdParts -join ' '
    Write-Host "`n>>> $cmdString" -ForegroundColor Green
    Write-Host ("-" * 50) -ForegroundColor DarkGray
    Clear-Host
    try {
        $proc = Start-Process -FilePath $cmdParts[0] -ArgumentList $cmdParts[1..($cmdParts.Length-1)] -NoNewWindow -Wait -PassThru
        if ($proc.ExitCode -ne 0) { Write-Host "Codex exited with code $($proc.ExitCode)." -ForegroundColor Yellow }
    } catch { Write-Host "ERROR: $_" -ForegroundColor Red }
    Read-Host "Session ended. Press Enter to return to menu"
}

function Launch-Claude {
    $model = (Get-Config).selectedModel
    if (-not (Start-OllamaServer)) { Read-Host "Press Enter to return"; return }

    $cmdParts = @("ollama", "launch", "claude", "--model", $model, "--")
    if ((Get-Config).skipPermissions) { $cmdParts += "--dangerously-skip-permissions" }
    $cmdString = $cmdParts -join ' '
    Write-Host "`n>>> $cmdString" -ForegroundColor Green
    Write-Host ("-" * 50) -ForegroundColor DarkGray
    Clear-Host
    try {
        $proc = Start-Process -FilePath $cmdParts[0] -ArgumentList $cmdParts[1..($cmdParts.Length-1)] -NoNewWindow -Wait -PassThru
        if ($proc.ExitCode -ne 0) { Write-Host "Claude Code exited with code $($proc.ExitCode)." -ForegroundColor Yellow }
    } catch { Write-Host "ERROR: $_" -ForegroundColor Red }
    Read-Host "Session ended. Press Enter to return to menu"
}

function Launch-CodexApp {
    $model = (Get-Config).selectedModel
    if (-not (Start-OllamaServer)) { Read-Host "Press Enter to return"; return }
    if (-not (Ensure-CodexInstalled)) { return }

    $cmdParts = @("ollama", "launch", "codex-app", "--model", $model)
    $cmdString = $cmdParts -join ' '
    Write-Host "`n>>> $cmdString" -ForegroundColor Green
    Write-Host ("-" * 50) -ForegroundColor DarkGray
    Clear-Host
    try {
        $proc = Start-Process -FilePath $cmdParts[0] -ArgumentList $cmdParts[1..($cmdParts.Length-1)] -NoNewWindow -Wait -PassThru
        if ($proc.ExitCode -ne 0) { Write-Host "Codex App exited with code $($proc.ExitCode)." -ForegroundColor Yellow }
    } catch { Write-Host "ERROR: $_" -ForegroundColor Red }
    Read-Host "Session ended. Press Enter to return to menu"
}

function Launch-ClaudeDesktop {
    $model = (Get-Config).selectedModel
    if (-not (Start-OllamaServer)) { Read-Host "Press Enter to return"; return }

    $env:ANTHROPIC_BASE_URL = "http://localhost:11434"
    $env:ANTHROPIC_CUSTOM_MODEL_OPTION = $model
    $env:ANTHROPIC_CUSTOM_MODEL_OPTION_NAME = "Ollama ($model)"
    $env:ANTHROPIC_DEFAULT_OPUS_MODEL = $model
    $env:ANTHROPIC_DEFAULT_SONNET_MODEL = $model
    $env:ANTHROPIC_DEFAULT_HAIKU_MODEL = $model
    $env:CLAUDE_CODE_DISABLE_NONSTREAMING_FALLBACK = "1"

    Write-Host "`nLaunching Claude Code Desktop with Ollama: $model" -ForegroundColor Green
    Write-Host ("-" * 50) -ForegroundColor DarkGray
    try {
        Start-Process "shell:appsFolder\Claude_pzs8sxrjxfjjc!Claude"
    } catch {
        Write-Host "ERROR: Could not launch Claude Desktop." -ForegroundColor Red
        Write-Host "Install from: https://claude.ai/download" -ForegroundColor Yellow
        Read-Host "Press Enter to return to menu"
    }
}

function Ensure-CodexInstalled {
    if (Test-CommandExists "codex") { return $true }
    Write-Host "Codex CLI not found." -ForegroundColor Yellow
    if (-not (Test-CommandExists "npm")) {
        $ans = Read-Host "Node.js/npm required. Install now? (y/n)"
        if ($ans -ne 'y') { return $false }
        if (-not (Install-NodeJS)) { return $false }
    }
    Write-Host "Installing Codex CLI via npm..." -ForegroundColor Cyan
    npm install -g @openai/codex 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "npm install failed. Try running as Administrator." -ForegroundColor Red
        Read-Host "Press Enter to continue"
        return $false
    }
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
    Write-Host "Codex CLI installed." -ForegroundColor Green
    return $true
}

# ============================================
# Status Display
# ============================================
function Show-Status {
    $oExists = Test-CommandExists "ollama"
    $cCodex  = Test-CommandExists "codex"
    $cClaude = Test-CommandExists "claude"
    $authOk  = Test-OllamaAuth
    $cfg     = Get-Config

    Write-Host "`n========== Ollama CLI Launcher ==========" -ForegroundColor Cyan

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
    if ($oExists) {
        $inst = Get-OllamaInstalledVersion
        $lat  = Get-OllamaLatestVersion
        if ($inst -and $lat -and (Compare-Versions $inst $lat)) {
            Write-Host "  Ollama        : v$inst (update v$lat available)" -ForegroundColor Yellow
        } else {
            Write-Host "  Ollama        : v$inst (up to date)" -ForegroundColor Green
        }
    } else {
        Write-Host "  Ollama        : NOT INSTALLED" -ForegroundColor Red
    }
    if ($authOk) {
        Write-Host "  Ollama Auth   : OK" -ForegroundColor Green
    } else {
        Write-Host "  Ollama Auth   : NOT SIGNED IN" -ForegroundColor Red
    }
    Write-Host "  Model         : $($cfg.selectedModel) [source: $($cfg.source)]" -ForegroundColor Cyan
    $permText = if ($cfg.skipPermissions) { "ON" } else { "OFF" }
    Write-Host "  Skip-perms    : $permText" -ForegroundColor Cyan
    $cDesktop = Test-ClaudeDesktopInstalled
    if ($cDesktop) {
        Write-Host "  Claude Desktop : INSTALLED" -ForegroundColor Green
    } else {
        Write-Host "  Claude Desktop : NOT INSTALLED" -ForegroundColor DarkGray
    }
    Write-Host "===========================================" -ForegroundColor Cyan
}

# ============================================
# Main Menu
# ============================================
function Show-MainMenu {
    Clear-Host
    Show-Status
    $oExists = Test-CommandExists "ollama"
    $cCodex  = Test-CommandExists "codex"
    $cClaude = Test-CommandExists "claude"
    $cfg     = Get-Config

    Write-Host "`n[1] Install / Update Ollama" -ForegroundColor White
    if ($oExists) {
        $inst = Get-OllamaInstalledVersion; $lat = Get-OllamaLatestVersion
        if ($inst -and $lat -and (Compare-Versions $inst $lat)) { Write-Host "     ^^ UPDATE AVAILABLE" -ForegroundColor Yellow }
    }
    Write-Host "[2] Pick / Change Model  [current: $($cfg.selectedModel)]" -ForegroundColor White
    if ($cfg.source -eq "cloud" -and $oExists) {
        Write-Host "[3] Pull Selected Model Locally" -ForegroundColor White
    } else {
        Write-Host "[3] Pull Selected Model Locally [not applicable]" -ForegroundColor DarkGray
    }
    if ($cCodex -and $oExists) {
        Write-Host "[4] Launch Codex CLI (via Ollama)" -ForegroundColor Green
    } else {
        $reason = if (-not $oExists) { "Ollama not installed" } else { "Codex CLI not installed" }
        Write-Host "[4] Launch Codex CLI [$reason]" -ForegroundColor DarkGray
    }
    if ($cClaude -and $oExists) {
        Write-Host "[5] Launch Claude Code (via Ollama)" -ForegroundColor Green
    } else {
        $reason = if (-not $oExists) { "Ollama not installed" } else { "Claude Code not installed" }
        Write-Host "[5] Launch Claude Code [$reason]" -ForegroundColor DarkGray
    }
    if ($cCodex -and $oExists) {
        Write-Host "[6] Launch Codex App (via Ollama)" -ForegroundColor Green
    } else {
        $reason = if (-not $oExists) { "Ollama not installed" } else { "Codex CLI not installed" }
        Write-Host "[6] Launch Codex App [$reason]" -ForegroundColor DarkGray
    }
    Write-Host "[7] Check / Fix Ollama Sign-in" -ForegroundColor White
    Write-Host "[8] Clear Version Cache" -ForegroundColor White
    $cDesktop = Test-ClaudeDesktopInstalled
    if ($cDesktop -and $oExists) {
        Write-Host "[9] Launch Claude Code Desktop (via Ollama)" -ForegroundColor Green
    } else {
        $reason = if (-not $oExists) { "Ollama not installed" } else { "Claude Desktop not installed" }
        Write-Host "[9] Launch Claude Desktop [$reason]" -ForegroundColor DarkGray
    }
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
    if ($target -eq "codex") {
        if (-not (Test-CommandExists "ollama")) { Write-Host "Ollama not found. Installing..." -ForegroundColor Yellow; Install-Ollama }
        if (-not (Start-OllamaServer)) { exit 1 }
        Launch-Codex; exit $LASTEXITCODE
    } elseif ($target -eq "claude") {
        if (-not (Test-CommandExists "ollama")) { Write-Host "Ollama not found. Installing..." -ForegroundColor Yellow; Install-Ollama }
        if (-not (Start-OllamaServer)) { exit 1 }
        Launch-Claude; exit $LASTEXITCODE
    } elseif ($target -eq "codex-app") {
        if (-not (Test-CommandExists "ollama")) { Write-Host "Ollama not found. Installing..." -ForegroundColor Yellow; Install-Ollama }
        if (-not (Start-OllamaServer)) { exit 1 }
        Launch-CodexApp; exit $LASTEXITCODE
    } elseif ($target -eq "claude-desktop") {
        if (-not (Test-CommandExists "ollama")) { Write-Host "Ollama not found. Installing..." -ForegroundColor Yellow; Install-Ollama }
        if (-not (Start-OllamaServer)) { exit 1 }
        Launch-ClaudeDesktop; exit $LASTEXITCODE
    }
}

while ($true) {
    Show-MainMenu
    $choice = Read-Host "Enter choice"
    $cfg = Get-Config
    switch ($choice.ToLower()) {
        "1" {
            if (Test-CommandExists "ollama") {
                $inst = Get-OllamaInstalledVersion; $lat = Get-OllamaLatestVersion
                if ($inst -and $lat -and (Compare-Versions $inst $lat)) {
                    Write-Host "Ollama update: v$inst -> v$lat" -ForegroundColor Yellow
                    $ans = Read-Host "Update now? (y/n)"
                    if ($ans -eq 'y') { Install-Ollama }
                } else {
                    $ans = Read-Host "Ollama is up to date. Reinstall? (y/n)"
                    if ($ans -eq 'y') { Install-Ollama }
                }
            } else {
                $ans = Read-Host "Install Ollama now? (y/n)"
                if ($ans -eq 'y') { Install-Ollama }
            }
            Read-Host "Press Enter to continue"
        }
        "2" { Show-ModelPicker }
        "3" {
            if ($cfg.source -eq "cloud" -and (Test-CommandExists "ollama")) { Pull-SelectedModel }
            else { Write-Host "Only available with cloud models and Ollama installed." -ForegroundColor Yellow; Read-Host "Press Enter to continue" }
        }
        "4" {
            if (-not (Test-CommandExists "ollama")) {
                Write-Host "Ollama not installed. Use option 1 first." -ForegroundColor Red
                Read-Host "Press Enter to continue"
            } else { Launch-Codex }
        }
        "5" {
            if (-not (Test-CommandExists "ollama")) {
                Write-Host "Ollama not installed. Use option 1 first." -ForegroundColor Red
                Read-Host "Press Enter to continue"
            } else { Launch-Claude }
        }
        "6" {
            if (-not (Test-CommandExists "ollama")) {
                Write-Host "Ollama not installed. Use option 1 first." -ForegroundColor Red
                Read-Host "Press Enter to continue"
            } elseif (-not (Test-CommandExists "codex")) {
                Write-Host "Codex CLI not installed (needed for Codex App)." -ForegroundColor Red
                $ans = Read-Host "Install now? (y/n)"
                if ($ans -eq 'y') { Ensure-CodexInstalled | Out-Null }
                Read-Host "Press Enter to continue"
            } else { Launch-CodexApp }
        }
        "7" { Check-OllamaSignin }
        "8" {
            $cache = Get-VersionCache
            $cache.codexLastChecked = ""; $cache.claudeLastChecked = ""; $cache.ollamaLastChecked = ""
            Save-VersionCache $cache
            Write-Host "Version cache cleared." -ForegroundColor Green; Start-Sleep -Seconds 1
        }
        "9" {
            if (-not (Test-CommandExists "ollama")) {
                Write-Host "Ollama not installed. Use option 1 first." -ForegroundColor Red
                Read-Host "Press Enter to continue"
            } elseif (-not (Test-ClaudeDesktopInstalled)) {
                Write-Host "Claude Desktop not installed. Install from https://claude.ai/download" -ForegroundColor Red
                Read-Host "Press Enter to continue"
            } else { Launch-ClaudeDesktop }
        }
        "t" {
            $cfg = Get-Config
            $cfg.skipPermissions = -not $cfg.skipPermissions
            Save-Config $cfg
            $text = if ($cfg.skipPermissions) { "SKIP-PERMISSIONS" } else { "NORMAL" }
            Write-Host "Mode: $text" -ForegroundColor Green
            Start-Sleep -Seconds 1
        }
        "q" { Write-Host "Goodbye!" -ForegroundColor Green; exit 0 }
        default { Write-Host "Invalid choice." -ForegroundColor Red; Start-Sleep -Seconds 1 }
    }
}
