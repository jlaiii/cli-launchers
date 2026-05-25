@echo off
set "BAT_DIR=%~dp0"
set "PSFILE=%TEMP%\CodexLauncher.ps1"
powershell -NoProfile -Command "Get-Content '%~f0' -Encoding UTF8 | Select-Object -Skip 9 | Out-File '%PSFILE%' -Encoding UTF8"
set "BatDir=%~dp0"
powershell -ExecutionPolicy Bypass -Command "& '%PSFILE%' %*; exit $LASTEXITCODE"
set "EC=%errorlevel%"
del /Q "%PSFILE%" 2>nul
exit /b %EC%
#Requires -Version 5.1
<#
.SYNOPSIS
    Smart Launcher for Codex CLI + Ollama with Model Picker & Update Checker
.DESCRIPTION
    Checks Node.js, Codex CLI, and Ollama installations. Checks for updates,
    verifies auth, lets users pick cloud/local models, and launches Codex.
    Supports interactive menu or direct argument pass-through.
    Usage:
      Codex-Launcher.bat                           -> interactive menu
      Codex-Launcher.bat launch                      -> launch with saved config
      Codex-Launcher.bat --model o4-mini             -> launch with args
      Codex-Launcher.bat launch --model kimi-k2.6:cloud -- --yolo
#>

$ErrorActionPreference = "Stop"
Clear-Host

# ============================================
# Paths & Defaults
# ============================================
$script:BaseDir      = if ($env:BatDir) { $env:BatDir } elseif ($PSScriptRoot) { $PSScriptRoot } else { Join-Path $env:USERPROFILE ".cli-launchers" }
if (-not (Test-Path $script:BaseDir)) { New-Item -ItemType Directory -Force -Path $script:BaseDir | Out-Null }
$script:ConfigPath   = Join-Path $script:BaseDir "Codex-Launcher.config.json"
$script:VersionCache = Join-Path $script:BaseDir "Codex-Launcher.versions.json"
$script:CacheTTLMinutes = 60

$script:DefaultConfig = @{
    selectedModel   = "kimi-k2.6:cloud"
    source          = "cloud"
    fullAuto        = $true
    customArgs      = ""
    autoUpdate      = $false
    skipUpdateCheck = $false
    provider        = "ollama"
    deepseekModel   = "deepseek-chat"
    deepseekApiKey  = ""
}# ============================================
# Config Helpers
# ============================================
function Get-Config {
    if (Test-Path $script:ConfigPath) {
        try {
            $cfg = Get-Content $script:ConfigPath -Raw | ConvertFrom-Json
            foreach ($key in $script:DefaultConfig.Keys) {
                if (-not $cfg.PSObject.Properties[$key]) {
                    $cfg | Add-Member -NotePropertyName $key -NotePropertyValue $script:DefaultConfig[$key] -Force
                }
            }
            return $cfg
        } catch {
            return New-Object PSObject -Property $script:DefaultConfig
        }
    }
    return New-Object PSObject -Property $script:DefaultConfig
}

function Save-Config($cfg) {
    $cfg | ConvertTo-Json -Depth 5 | Set-Content $script:ConfigPath -Encoding UTF8
}

# ============================================
# Version Cache Helpers
# ============================================
function Get-VersionCache {
    $defaultCache = @{
        codexLatestVersion  = ""
        codexLastChecked    = ""
        ollamaLatestVersion = ""
        ollamaLastChecked   = ""
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
        } catch {
            return New-Object PSObject -Property $defaultCache
        }
    }
    return New-Object PSObject -Property $defaultCache
}

function Save-VersionCache($cache) {
    $cache | ConvertTo-Json -Depth 5 | Set-Content $script:VersionCache -Encoding UTF8
}

function Is-CacheStale($lastCheckedStr) {
    if ([string]::IsNullOrWhiteSpace($lastCheckedStr)) { return $true }
    try {
        $last = [datetime]::Parse($lastCheckedStr)
        return ([datetime]::Now - $last).TotalMinutes -gt $script:CacheTTLMinutes
    } catch {
        return $true
    }
}

# ============================================
# Version Checkers
# ============================================
function Get-CodexInstalledVersion {
    try {
        $ver = & codex --version 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        if ($ver -match '(\d+\.\d+\.\d+)') {
            return $matches[1]
        }
        $trimmed = ([string]$ver).Trim()
        if ($trimmed) { return $trimmed }
    } catch {}
    return $null
}

function Get-CodexLatestVersion {
    $cache = Get-VersionCache
    if (-not (Is-CacheStale $cache.codexLastChecked)) {
        return $cache.codexLatestVersion
    }
    try {
        $resp = Invoke-WebRequest -Uri "https://registry.npmjs.org/@openai/codex/latest" -UseBasicParsing -TimeoutSec 15
        $data = $resp.Content | ConvertFrom-Json
        $ver = $data.version
        if ($ver) {
            $cache.codexLatestVersion = $ver
            $cache.codexLastChecked = [datetime]::Now.ToString("o")
            Save-VersionCache $cache
        }
        return $ver
    } catch {
        return $null
    }
}

function Get-OllamaInstalledVersion {
    try {
        $ver = ollama --version 2>$null
        if ($ver) {
            if ($ver -match '(\d+\.\d+\.\d+)') {
                return $matches[1]
            }
        }
    } catch {}
    return $null
}

function Get-OllamaLatestVersion {
    $cache = Get-VersionCache
    if (-not (Is-CacheStale $cache.ollamaLastChecked)) {
        return $cache.ollamaLatestVersion
    }
    try {
        $resp = Invoke-WebRequest -Uri "https://api.github.com/repos/ollama/ollama/releases/latest" -UseBasicParsing -TimeoutSec 15
        $data = $resp.Content | ConvertFrom-Json
        $ver = $data.tag_name
        if ($ver) {
            $ver = $ver -replace '^v',''
            $cache.ollamaLatestVersion = $ver
            $cache.ollamaLastChecked = [datetime]::Now.ToString("o")
            Save-VersionCache $cache
        }
        return $ver
    } catch {
        return $null
    }
}

function Compare-Versions($installed, $latest) {
    if ([string]::IsNullOrWhiteSpace($installed) -or [string]::IsNullOrWhiteSpace($latest)) { return $false }
    try {
        $instParts = [version]$installed
        $latParts  = [version]$latest
        return $latParts -gt $instParts
    } catch {
        return $installed -ne $latest
    }
}

function Test-CommandExists($cmd) {
    $null -ne (Get-Command $cmd -ErrorAction SilentlyContinue)
}# ============================================
# Installers
# ============================================
function Install-NodeJS {
    if (Test-CommandExists "winget") {
        Write-Host "Installing Node.js via winget... (this may take a minute)" -ForegroundColor Cyan
        $oldEAP = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            winget install OpenJS.NodeJS -e --accept-package-agreements --accept-source-agreements 2>$null | Out-Null
            $wgExit = $LASTEXITCODE
            if ($wgExit -ne 0) {
                Write-Host "winget exited with code $wgExit. Falling back to manual download..." -ForegroundColor Yellow
                throw "winget failed"
            }
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
            if (Test-CommandExists "npm") {
                Write-Host "Node.js / npm is ready!" -ForegroundColor Green
                return $true
            }
        } catch {
            if ($_.Exception.Message -ne "winget failed") {
                Write-Host "winget install failed: $_" -ForegroundColor Yellow
            }
            Write-Host "Falling back to manual download..." -ForegroundColor Yellow
        } finally {
            $ErrorActionPreference = $oldEAP
        }
    }
    Write-Host "Downloading Node.js LTS installer..." -ForegroundColor Cyan
    try {
        $index = Invoke-WebRequest "https://nodejs.org/download/release/index.json" -UseBasicParsing -TimeoutSec 30 | ConvertFrom-Json
        $lts = $index | Where-Object { $_.lts -ne $false -and $_.lts -ne "" } | Select-Object -First 1
        if (-not $lts) { $lts = $index | Select-Object -First 1 }
        $ver = $lts.version
        $url = "https://nodejs.org/dist/$ver/node-$ver-x64.msi"
        $msi = Join-Path $env:TEMP "node-installer.msi"
        Invoke-WebRequest $url -OutFile $msi -TimeoutSec 120
        Write-Host "Installing Node.js MSI silently..." -ForegroundColor Cyan
        Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn /norestart" -Wait
        Remove-Item $msi -Force -ErrorAction SilentlyContinue
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
        if (Test-CommandExists "npm") {
            Write-Host "Node.js installed successfully!" -ForegroundColor Green
            return $true
        }
    } catch {
        Write-Host "Failed to auto-install Node.js. Please install manually from https://nodejs.org" -ForegroundColor Red
    }
    return $false
}

function Install-CodexCLI {
    if (-not (Test-CommandExists "npm")) {
        Write-Host "Node.js / npm not found." -ForegroundColor Yellow
        $confirm = Read-Host "Install Node.js automatically? (y/n)"
        if ($confirm -eq 'y') {
            $nodeOk = Install-NodeJS
            if (-not $nodeOk) { return $false }
        } else {
            return $false
        }
    }
    Write-Host "Installing / Updating Codex CLI via npm... (this may take a minute)" -ForegroundColor Cyan
    $oldEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        npm install -g @openai/codex 2>$null | Out-Null
        $npmExit = $LASTEXITCODE
        if ($npmExit -ne 0) {
            Write-Host "npm install exited with code $npmExit." -ForegroundColor Red
            return $false
        }
        # Refresh PATH so the new binary is discoverable in this session
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
        if (Test-CommandExists "codex") {
            $ver = Get-CodexInstalledVersion
            Write-Host "Codex CLI installed / updated! Version: $ver" -ForegroundColor Green
            return $true
        } else {
            Write-Host "Codex CLI command not found after install. Try restarting the launcher." -ForegroundColor Yellow
            return $false
        }
    } catch {
        Write-Host "npm install failed: $_" -ForegroundColor Red
        Write-Host "Try running this launcher as Administrator." -ForegroundColor Yellow
        return $false
    } finally {
        $ErrorActionPreference = $oldEAP
    }
}

function Install-Ollama {
    Write-Host "Installing/Updating Ollama from https://ollama.com/install.ps1 ..." -ForegroundColor Cyan
    try {
        irm https://ollama.com/install.ps1 | iex
        Write-Host "Ollama installation/update completed." -ForegroundColor Green
    } catch {
        Write-Host "ERROR installing/updating Ollama: $_" -ForegroundColor Red
    }
    Read-Host "Press Enter to continue"
}

function Pull-SelectedModel {
    $cfg = Get-Config
    $model = $cfg.selectedModel
    Write-Host "Pulling model '$model' into local Ollama..." -ForegroundColor Cyan
    try {
        ollama pull $model
        Write-Host "Model '$model' pulled successfully." -ForegroundColor Green
    } catch {
        Write-Host "ERROR pulling model: $_" -ForegroundColor Red
    }
    Read-Host "Press Enter to continue"
}

# ============================================
# Auth Helpers
# ============================================
function Test-OllamaAuth {
    try {
        $models = ollama list 2>$null
        return ($LASTEXITCODE -eq 0 -and $models)
    } catch {
        return $false
    }
}

function Check-OllamaSignin {
    Write-Host "Checking Ollama sign-in status..." -ForegroundColor Cyan
    try {
        $models = ollama list 2>$null
        if ($LASTEXITCODE -eq 0 -and $models) {
            Write-Host "Ollama appears configured. Local models:" -ForegroundColor Green
            $models | Select-Object -First 10 | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
        } else {
            Write-Host "Could not list Ollama models. You may need to run 'ollama signin'." -ForegroundColor Yellow
            $choice = Read-Host "Run 'ollama signin' now? (y/n)"
            if ($choice -eq 'y') { ollama signin }
        }
    } catch {
        Write-Host "Error checking Ollama status: $_" -ForegroundColor Red
    }
    Read-Host "Press Enter to continue"
}# ============================================
# Ollama Server Helpers
# ============================================
function Test-OllamaRunning {
    try {
        $null = Invoke-WebRequest -Uri "http://localhost:11434/api/tags" -UseBasicParsing -TimeoutSec 3
        return $true
    } catch {
        return $false
    }
}

function Start-OllamaServer {
    if (Test-OllamaRunning) { return $true }
    Write-Host "Starting Ollama server in background..." -ForegroundColor Yellow
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
        Write-Host "Ollama server did not become ready in time." -ForegroundColor Red
        return $false
    } catch {
        Write-Host "Failed to start Ollama server: $_" -ForegroundColor Red
        return $false
    }
}

# ============================================
# Model Fetchers
# ============================================
function Get-CloudModels {
    Write-Host "Fetching top 10 newest models from Ollama cloud registry..." -ForegroundColor DarkGray
    try {
        $resp = Invoke-WebRequest -Uri "https://ollama.com/api/tags" -UseBasicParsing -TimeoutSec 15
        $data = $resp.Content | ConvertFrom-Json
        $models = @($data.models)
        if ($models.Count -eq 0) { return @() }
        foreach ($m in $models) {
            try { $dt = [datetime]::Parse($m.modified_at) } catch { $dt = [datetime]::MinValue }
            $m | Add-Member -NotePropertyName modified_dt -NotePropertyValue $dt -Force
        }
        $sorted = $models | Sort-Object modified_dt -Descending | Select-Object -First 10
        return $sorted
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
        $sorted = $models | Sort-Object modified_dt -Descending
        return $sorted
    } catch {
        Write-Host "Failed to fetch local models (is Ollama running?): $_" -ForegroundColor Red
        return @()
    }
}

# ============================================
# Model Picker Menus
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
    $i = 1
    foreach ($m in $models) {
        $sizeGB = "{0:N2}" -f ($m.size / 1GB)
        Write-Host "  [$i] $($m.name)" -ForegroundColor Cyan -NoNewline
        Write-Host "  (size: $sizeGB GB, updated: $($m.modified_at.Substring(0,10)))" -ForegroundColor DarkGray
        $i++
    }
    Write-Host ""
    Write-Host "  [M] Manual entry (type a model name yourself)" -ForegroundColor Yellow
    Write-Host "  [B] Back to main menu" -ForegroundColor Magenta
    Write-Host ""
    $choice = Read-Host "Select a cloud model by number, or M/B"
    if ($choice.ToLower() -eq "b") { return }
    if ($choice.ToLower() -eq "m") {
        $manual = Read-Host "Enter the full model name (e.g., kimi-k2.6:cloud)"
        if ($manual) {
            $cfg = Get-Config
            $cfg.selectedModel = $manual
            $cfg.source = "cloud"
            Save-Config $cfg
            Write-Host "Selected cloud model: $manual" -ForegroundColor Green
        }
        Read-Host "Press Enter to continue"
        return
    }
    $idx = 0
    if ([int]::TryParse($choice, [ref]$idx)) {
        if ($idx -ge 1 -and $idx -le $models.Count) {
            $selected = $models[$idx - 1].name
            $cfg = Get-Config
            $cfg.selectedModel = $selected
            $cfg.source = "cloud"
            Save-Config $cfg
            Write-Host "Selected cloud model: $selected" -ForegroundColor Green
        } else {
            Write-Host "Invalid selection." -ForegroundColor Red
        }
    } else {
        Write-Host "Invalid input." -ForegroundColor Red
    }
    Read-Host "Press Enter to continue"
}

function Show-LocalModelMenu {
    Clear-Host
    Write-Host "=============================================" -ForegroundColor Green
    Write-Host "   Local Models (Downloaded on this PC)" -ForegroundColor Green
    Write-Host "=============================================" -ForegroundColor Green
    Write-Host ""
    $models = Get-LocalModels
    if ($models.Count -eq 0) {
        Write-Host "No local models found. You can pull one from the cloud first." -ForegroundColor Yellow
        Read-Host "Press Enter to return"
        return
    }
    $i = 1
    foreach ($m in $models) {
        $sizeGB = "{0:N2}" -f ($m.size / 1GB)
        Write-Host "  [$i] $($m.name)" -ForegroundColor Cyan -NoNewline
        Write-Host "  (size: $sizeGB GB, updated: $($m.modified_at.Substring(0,10)))" -ForegroundColor DarkGray
        $i++
    }
    Write-Host ""
    Write-Host "  [B] Back to main menu" -ForegroundColor Magenta
    Write-Host ""
    $choice = Read-Host "Select a local model by number, or B"
    if ($choice.ToLower() -eq "b") { return }
    $idx = 0
    if ([int]::TryParse($choice, [ref]$idx)) {
        if ($idx -ge 1 -and $idx -le $models.Count) {
            $selected = $models[$idx - 1].name
            $cfg = Get-Config
            $cfg.selectedModel = $selected
            $cfg.source = "local"
            Save-Config $cfg
            Write-Host "Selected local model: $selected" -ForegroundColor Green
        } else {
            Write-Host "Invalid selection." -ForegroundColor Red
        }
    } else {
        Write-Host "Invalid input." -ForegroundColor Red
    }
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
        Write-Host "Current selection:" -ForegroundColor Cyan
        Write-Host "  Provider : $($cfg.provider)" -ForegroundColor White
        Write-Host "  Model    : $($cfg.selectedModel)" -ForegroundColor White
        Write-Host "  Source   : $($cfg.source)" -ForegroundColor White
        if ($cfg.provider -eq "deepseek") {
            Write-Host "  DeepSeek Model : $($cfg.deepseekModel)" -ForegroundColor White
            if ($cfg.deepseekApiKey) {
                $masked = $cfg.deepseekApiKey.Substring(0, [Math]::Min(8, $cfg.deepseekApiKey.Length)) + "..."
                Write-Host "  DeepSeek Key   : $masked" -ForegroundColor DarkGray
            } else {
                Write-Host "  DeepSeek Key   : NOT SET" -ForegroundColor Red
            }
        }
        Write-Host ""
        Write-Host "Options:" -ForegroundColor Cyan
        Write-Host "  [1] Browse Cloud Models (Ollama Registry)" -ForegroundColor Yellow
        Write-Host "  [2] Browse Local Models (this PC)" -ForegroundColor Yellow
        if ($cfg.provider -eq "deepseek") {
            Write-Host "  [3] DeepSeek Model Settings" -ForegroundColor Yellow
        } else {
            Write-Host "  [3] Manual Entry (type any model name)" -ForegroundColor Yellow
        }
        Write-Host "  [4] Switch Provider (Ollama / DeepSeek)" -ForegroundColor Yellow
        Write-Host "  [B] Back to Main Menu" -ForegroundColor Magenta
        Write-Host ""
        $choice = Read-Host "Enter your choice"
        switch ($choice.ToLower()) {
            "1" { Show-CloudModelMenu }
            "2" { Show-LocalModelMenu }
            "3" {
                if ((Get-Config).provider -eq "deepseek") {
                    Show-DeepSeekModelPicker
                } else {
                    $manual = Read-Host "Enter the full model name (e.g., kimi-k2.6:cloud, llama3.3:latest)"
                    if ($manual) {
                        $cfg = Get-Config
                        $cfg.selectedModel = $manual
                        $cfg.source = "manual"
                        Save-Config $cfg
                        Write-Host "Model set to: $manual" -ForegroundColor Green
                        Read-Host "Press Enter to continue"
                    }
                }
            }
            "4" { Show-ProviderMenu }
            "b" { return }
            default { Write-Host "Invalid choice." -ForegroundColor Red; Start-Sleep -Seconds 1 }
        }
    }
}function Show-ProviderMenu {
    while ($true) {
        Clear-Host
        Write-Host "=============================================" -ForegroundColor Green
        Write-Host "         Select AI Provider" -ForegroundColor Green
        Write-Host "=============================================" -ForegroundColor Green
        Write-Host ""
        $cfg = Get-Config
        Write-Host "Current provider: $($cfg.provider)" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "Options:" -ForegroundColor Cyan
        Write-Host "  [1] Ollama (local / cloud models)" -ForegroundColor Yellow
        Write-Host "  [2] DeepSeek API (cloud API)" -ForegroundColor Yellow
        Write-Host "  [B] Back to Main Menu" -ForegroundColor Magenta
        Write-Host ""
        $choice = Read-Host "Enter your choice"
        switch ($choice.ToLower()) {
            "1" {
                $cfg = Get-Config
                $cfg.provider = "ollama"
                Save-Config $cfg
                Write-Host "Provider set to: Ollama" -ForegroundColor Green
                Start-Sleep -Seconds 1
                return
            }
            "2" {
                $cfg = Get-Config
                if ([string]::IsNullOrWhiteSpace($cfg.deepseekApiKey)) {
                    Write-Host "DeepSeek API key is not set." -ForegroundColor Yellow
                    $key = Read-Host "Enter your DeepSeek API key (or press Enter to skip)"
                    if ($key) {
                        $cfg.deepseekApiKey = $key.Trim()
                    }
                }
                $cfg.provider = "deepseek"
                Save-Config $cfg
                Write-Host "Provider set to: DeepSeek" -ForegroundColor Green
                Start-Sleep -Seconds 1
                return
            }
            "b" { return }
            default { Write-Host "Invalid choice." -ForegroundColor Red; Start-Sleep -Seconds 1 }
        }
    }
}

function Show-DeepSeekModelPicker {
    while ($true) {
        Clear-Host
        Write-Host "=============================================" -ForegroundColor Green
        Write-Host "       DeepSeek Model Settings" -ForegroundColor Green
        Write-Host "=============================================" -ForegroundColor Green
        Write-Host ""
        $cfg = Get-Config
        Write-Host "Current DeepSeek model: $($cfg.deepseekModel)" -ForegroundColor Cyan
        if ($cfg.deepseekApiKey) {
            $masked = $cfg.deepseekApiKey.Substring(0, [Math]::Min(8, $cfg.deepseekApiKey.Length)) + "..."
            Write-Host "API key: $masked" -ForegroundColor DarkGray
        } else {
            Write-Host "API key: NOT SET" -ForegroundColor Red
        }
        Write-Host ""
        Write-Host "Options:" -ForegroundColor Cyan
        Write-Host "  [1] DeepSeek V4 (Recommended)  -> deepseek-chat" -ForegroundColor Yellow
        Write-Host "  [2] DeepSeek R1 (Flash)        -> deepseek-reasoner" -ForegroundColor Yellow
        Write-Host "  [3] Manual Entry (type a model name)" -ForegroundColor Yellow
        Write-Host "  [S] Set / Update API Key" -ForegroundColor Yellow
        Write-Host "  [B] Back to Main Menu" -ForegroundColor Magenta
        Write-Host ""
        $choice = Read-Host "Enter your choice"
        switch ($choice.ToLower()) {
            "1" {
                $cfg = Get-Config
                $cfg.deepseekModel = "deepseek-chat"
                Save-Config $cfg
                Write-Host "DeepSeek model set to: deepseek-chat (V4)" -ForegroundColor Green
                Start-Sleep -Seconds 1
            }
            "2" {
                $cfg = Get-Config
                $cfg.deepseekModel = "deepseek-reasoner"
                Save-Config $cfg
                Write-Host "DeepSeek model set to: deepseek-reasoner (R1 Flash)" -ForegroundColor Green
                Start-Sleep -Seconds 1
            }
            "3" {
                $manual = Read-Host "Enter the DeepSeek model name (e.g., deepseek-chat)"
                if ($manual) {
                    $cfg = Get-Config
                    $cfg.deepseekModel = $manual.Trim()
                    Save-Config $cfg
                    Write-Host "DeepSeek model set to: $($cfg.deepseekModel)" -ForegroundColor Green
                    Start-Sleep -Seconds 1
                }
            }
            "s" {
                Set-DeepSeekApiKey
            }
            "b" { return }
            default { Write-Host "Invalid choice." -ForegroundColor Red; Start-Sleep -Seconds 1 }
        }
    }
}

function Set-DeepSeekApiKey {
    Clear-Host
    Write-Host "=============================================" -ForegroundColor Green
    Write-Host "       DeepSeek API Key Setup" -ForegroundColor Green
    Write-Host "=============================================" -ForegroundColor Green
    Write-Host ""
    $cfg = Get-Config
    if ($cfg.deepseekApiKey) {
        $masked = $cfg.deepseekApiKey.Substring(0, [Math]::Min(8, $cfg.deepseekApiKey.Length)) + "..."
        Write-Host "Current key: $masked" -ForegroundColor DarkGray
    } else {
        Write-Host "Current key: NOT SET" -ForegroundColor Yellow
    }
    Write-Host ""
    $key = Read-Host "Enter your DeepSeek API key (or press Enter to cancel)"
    if ($key) {
        $cfg = Get-Config
        $cfg.deepseekApiKey = $key.Trim()
        Save-Config $cfg
        Write-Host "DeepSeek API key updated." -ForegroundColor Green
    } else {
        Write-Host "API key unchanged." -ForegroundColor Yellow
    }
    Start-Sleep -Seconds 1
}

# ============================================
# Launch
# ============================================
function Launch-Codex([string[]]$passArgs) {
    $cfg = Get-Config

    if ($cfg.provider -eq "deepseek") {
        if ([string]::IsNullOrWhiteSpace($cfg.deepseekApiKey)) {
            Write-Host "DeepSeek API key is not set. Please set it in the model picker first." -ForegroundColor Red
            Read-Host "Press Enter to return to menu"
            return
        }
        $env:OPENAI_API_KEY = $cfg.deepseekApiKey
        $env:OPENAI_BASE_URL = "https://api.deepseek.com"
        $model = $cfg.deepseekModel
        $cmdParts = @("codex")
    } else {
        $model = $cfg.selectedModel
        $cmdParts = @("ollama", "launch", "codex")
    }

    if ($passArgs -and $passArgs.Count -gt 0) {
        $hasModel = $false
        $hasYolo = $false
        $extraAfterSep = @()
        $foundSep = $false
        $skipNext = $false
        foreach ($a in $passArgs) {
            if ($skipNext) { $skipNext = $false; continue }
            if ($a -eq "--") {
                $foundSep = $true
                continue
            }
            if ($foundSep) {
                $extraAfterSep += $a
                continue
            }
            if ($a -eq "--model") {
                $hasModel = $true
                $cmdParts += "--model"
                $skipNext = $true
            } elseif ($a.StartsWith("--model=")) {
                $hasModel = $true
                $cmdParts += $a
            } elseif ($a -eq "--yolo") {
                $hasYolo = $true
            } else {
                $extraAfterSep += $a
            }
        }
        if (-not $hasModel -and $model) {
            $cmdParts += "--model"
            $cmdParts += $model
        }
        $cmdParts += "--"
        if (-not $hasYolo -and $cfg.fullAuto) {
            $cmdParts += "--yolo"
        }
        if ($cfg.customArgs) {
            $cmdParts += ($cfg.customArgs -split ' ')
        }
        if ($extraAfterSep.Count -gt 0) {
            $cmdParts += $extraAfterSep
        }
    } else {
        if ($model) {
            $cmdParts += "--model"
            $cmdParts += $model
        }
        $cmdParts += "--"
        if ($cfg.fullAuto) {
            $cmdParts += "--yolo"
        }
        if ($cfg.customArgs) {
            $cmdParts += ($cfg.customArgs -split ' ')
        }
    }

    $cmdString = $cmdParts -join ' '
    Write-Host "`n>>> $cmdString" -ForegroundColor Green
    Write-Host ("-" * 50) -ForegroundColor DarkGray

    if ($cfg.provider -eq "ollama") {
        if (-not (Start-OllamaServer)) {
            Read-Host "Press Enter to return to menu"
            return
        }
    }

    Clear-Host
    try {
        if ($cfg.provider -eq "deepseek") {
            & $cmdParts[0] @($cmdParts[1..($cmdParts.Length-1)])
        } else {
            $proc = Start-Process -FilePath $cmdParts[0] -ArgumentList $cmdParts[1..($cmdParts.Length-1)] -NoNewWindow -Wait -PassThru
            if ($proc.ExitCode -ne 0) {
                Write-Host "Codex exited with code $($proc.ExitCode)." -ForegroundColor Yellow
            }
        }
    } catch {
        Write-Host "ERROR launching Codex: $_" -ForegroundColor Red
    }
    Read-Host "Codex session ended. Press Enter to return to menu"
}

# ============================================
# Menu UI
# ============================================
function Show-Status {
    $cExists = Test-CommandExists "codex"
    $oExists = Test-CommandExists "ollama"
    $nExists = Test-CommandExists "npm"
    $authOk  = Test-OllamaAuth
    $cfg     = Get-Config

    $codexUpdate = $false
    $ollamaUpdate = $false
    $codexInstalledVer = $null
    $ollamaInstalledVer = $null

    if ($cExists) {
        $codexInstalledVer = Get-CodexInstalledVersion
        $codexLatestVer = Get-CodexLatestVersion
        if ($codexInstalledVer -and $codexLatestVer) {
            $codexUpdate = Compare-Versions $codexInstalledVer $codexLatestVer
        }
    }
    if ($oExists) {
        $ollamaInstalledVer = Get-OllamaInstalledVersion
        $ollamaLatestVer = Get-OllamaLatestVersion
        if ($ollamaInstalledVer -and $ollamaLatestVer) {
            $ollamaUpdate = Compare-Versions $ollamaInstalledVer $ollamaLatestVer
        }
    }

    Write-Host "`n========== Codex CLI + Ollama Launcher ==========" -ForegroundColor Cyan
    if ($nExists) {
        $nVer = npm --version 2>$null
        Write-Host "  Node.js / npm : OK (npm v$nVer)" -ForegroundColor Green
    } else {
        Write-Host "  Node.js / npm : NOT FOUND" -ForegroundColor Red
    }
    if ($cExists) {
        if ($codexUpdate) {
            Write-Host "  Codex CLI     : v$codexInstalledVer (update v$codexLatestVer available)" -ForegroundColor Yellow
        } else {
            Write-Host "  Codex CLI     : v$codexInstalledVer (up to date)" -ForegroundColor Green
        }
    } else {
        Write-Host "  Codex CLI     : NOT INSTALLED" -ForegroundColor Red
    }
    if ($oExists) {
        if ($ollamaUpdate) {
            Write-Host "  Ollama        : v$ollamaInstalledVer (update v$ollamaLatestVer available)" -ForegroundColor Yellow
        } else {
            Write-Host "  Ollama        : v$ollamaInstalledVer (up to date)" -ForegroundColor Green
        }
    } else {
        Write-Host "  Ollama        : NOT INSTALLED" -ForegroundColor Red
    }
    if ($authOk) {
        Write-Host "  Ollama Auth   : OK" -ForegroundColor Green
    } else {
        Write-Host "  Ollama Auth   : NOT SIGNED IN" -ForegroundColor Red
    }
    Write-Host "  Provider      : $($cfg.provider)" -ForegroundColor Cyan
    Write-Host "  Config model  : $($cfg.selectedModel) [source: $($cfg.source)]" -ForegroundColor Cyan
    if ($cfg.provider -eq "deepseek") {
        Write-Host "  DeepSeek model: $($cfg.deepseekModel)" -ForegroundColor Cyan
        if ($cfg.deepseekApiKey) {
            Write-Host "  DeepSeek key  : SET" -ForegroundColor Green
        } else {
            Write-Host "  DeepSeek key  : NOT SET" -ForegroundColor Red
        }
    }
    Write-Host "  Full-auto     : $(if ($cfg.fullAuto) { 'ON (--yolo)' } else { 'OFF' })" -ForegroundColor Cyan
    Write-Host "=================================================" -ForegroundColor Cyan
}

function Show-MainMenu {
    Show-Status
    $cExists = Test-CommandExists "codex"
    $oExists = Test-CommandExists "ollama"
    $cfg = Get-Config

    $codexUpdate = $false
    $ollamaUpdate = $false
    if ($cExists) {
        $inst = Get-CodexInstalledVersion
        $lat  = Get-CodexLatestVersion
        if ($inst -and $lat) { $codexUpdate = Compare-Versions $inst $lat }
    }
    if ($oExists) {
        $inst = Get-OllamaInstalledVersion
        $lat  = Get-OllamaLatestVersion
        if ($inst -and $lat) { $ollamaUpdate = Compare-Versions $inst $lat }
    }

    Write-Host "`n[1] Install / Update Codex CLI" -ForegroundColor White
    if ($codexUpdate) { Write-Host "     ^^ UPDATE AVAILABLE" -ForegroundColor Yellow }
    Write-Host "[2] Install / Update Ollama" -ForegroundColor White
    if ($ollamaUpdate) { Write-Host "     ^^ UPDATE AVAILABLE" -ForegroundColor Yellow }
    Write-Host "[3] Pick / Change Model  [current: $($cfg.selectedModel)]" -ForegroundColor White
    if ($cfg.provider -eq "deepseek") {
        Write-Host "     DeepSeek model: $($cfg.deepseekModel)" -ForegroundColor DarkGray
    }
    if ($cfg.source -eq "cloud" -and $oExists) {
        Write-Host "[4] Pull Selected Model Locally (ollama pull)" -ForegroundColor White
    } else {
        Write-Host "[4] Pull Selected Model Locally [not applicable]" -ForegroundColor DarkGray
    }
    Write-Host "[5] Toggle Full-Auto Mode (--yolo)" -ForegroundColor White
    Write-Host "[6] Set Custom Launch Arguments" -ForegroundColor White
    Write-Host "[7] Check / Fix Ollama Sign-in" -ForegroundColor White
    Write-Host "[8] Launch Codex CLI" -ForegroundColor Green
    Write-Host "[C] Clear Version Cache" -ForegroundColor White
    Write-Host "[A] Toggle Auto-Update on Direct Launch" -ForegroundColor White
    Write-Host "[Q] Quit" -ForegroundColor Magenta
    Write-Host ""
}

# ============================================
# Main
# ============================================

# --- Direct launch mode (arguments provided) ---
if ($args.Count -gt 0) {
    $launchArgs = $args
    if ($launchArgs[0] -eq "launch") {
        if ($launchArgs.Count -gt 1) { $launchArgs = $launchArgs[1..($launchArgs.Count-1)] } else { $launchArgs = @() }
    }

    if (-not (Test-CommandExists "codex")) {
        Write-Host "Codex CLI not found. Installing..." -ForegroundColor Yellow
        $ok = Install-CodexCLI
        if (-not $ok) { exit 1 }
    }
    if (-not (Test-CommandExists "ollama")) {
        Write-Host "Ollama not found. Installing..." -ForegroundColor Yellow
        Install-Ollama
    }

    $cfg = Get-Config

    if (-not $cfg.skipUpdateCheck) {
        $cInst = Get-CodexInstalledVersion
        $cLat  = Get-CodexLatestVersion
        if (Compare-Versions $cInst $cLat) {
            if ($cfg.autoUpdate) {
                Write-Host "Auto-updating Codex CLI..." -ForegroundColor Cyan
                Install-CodexCLI | Out-Null
            } else {
                Write-Host "Codex update available: v$cInst -> v$cLat. Run launcher menu to update." -ForegroundColor Yellow
            }
        }
    }

    if ($cfg.provider -eq "ollama") {
        $oInst = Get-OllamaInstalledVersion
        $oLat  = Get-OllamaLatestVersion
        if (Compare-Versions $oInst $oLat) {
            Write-Host "Ollama update available: v$oInst -> v$oLat. Run launcher menu to update." -ForegroundColor Yellow
        }
        if (-not (Start-OllamaServer)) {
            exit 1
        }
    } else {
        if ([string]::IsNullOrWhiteSpace($cfg.deepseekApiKey)) {
            Write-Host "DeepSeek API key is not set. Run the launcher menu to configure." -ForegroundColor Red
            exit 1
        }
        $env:OPENAI_API_KEY = $cfg.deepseekApiKey
        $env:OPENAI_BASE_URL = "https://api.deepseek.com"
    }

    Clear-Host
    Launch-Codex -passArgs $launchArgs
    exit $LASTEXITCODE
}

# --- Interactive menu mode ---
while ($true) {
    Show-MainMenu
    $choice = Read-Host "Enter choice"
    switch ($choice.ToLower()) {
        "1" {
            if (Test-CommandExists "codex") {
                $inst = Get-CodexInstalledVersion
                $lat  = Get-CodexLatestVersion
                $needsUpdate = Compare-Versions $inst $lat
                if ($needsUpdate) {
                    Write-Host "Codex CLI update available: v$inst installed, v$lat available." -ForegroundColor Yellow
                    $confirm = Read-Host "Update Codex CLI now? (y/n)"
                    if ($confirm -eq 'y') { Install-CodexCLI }
                } else {
                    $confirm = Read-Host "Codex CLI is up to date (v$inst). Reinstall anyway? (y/n)"
                    if ($confirm -eq 'y') { Install-CodexCLI }
                }
            } else {
                $confirm = Read-Host "Install Codex CLI now? (y/n)"
                if ($confirm -eq 'y') { Install-CodexCLI }
            }
            Read-Host "`nPress Enter to continue"
        }
        "2" {
            if (Test-CommandExists "ollama") {
                $inst = Get-OllamaInstalledVersion
                $lat  = Get-OllamaLatestVersion
                $needsUpdate = Compare-Versions $inst $lat
                if ($needsUpdate) {
                    Write-Host "Ollama update available: v$inst installed, v$lat available." -ForegroundColor Yellow
                    $confirm = Read-Host "Update Ollama now? (y/n)"
                    if ($confirm -eq 'y') { Install-Ollama }
                } else {
                    $confirm = Read-Host "Ollama is up to date (v$inst). Reinstall anyway? (y/n)"
                    if ($confirm -eq 'y') { Install-Ollama }
                }
            } else {
                $confirm = Read-Host "Install Ollama now? (y/n)"
                if ($confirm -eq 'y') { Install-Ollama }
            }
            Read-Host "`nPress Enter to continue"
        }
        "3" {
            Show-ModelPicker
        }
        "4" {
            if ($cfg.source -eq "cloud" -and (Test-CommandExists "ollama")) {
                Pull-SelectedModel
            } else {
                Write-Host "Pull is only available when a cloud model is selected and Ollama is installed." -ForegroundColor Yellow
                Read-Host "Press Enter to continue"
            }
        }
        "5" {
            $cfg = Get-Config
            $cfg.fullAuto = -not $cfg.fullAuto
            Save-Config $cfg
            $mode = if ($cfg.fullAuto) { "ON (--yolo)" } else { "OFF" }
            Write-Host "Full-auto mode: $mode" -ForegroundColor Green
            Start-Sleep -Seconds 1
        }
        "6" {
            $cfg = Get-Config
            Write-Host "Current custom args: $(if ($cfg.customArgs) { $cfg.customArgs } else { '(none)' })" -ForegroundColor Cyan
            $new = Read-Host "Enter extra args (e.g. --approval-mode full-auto), or blank to clear"
            $cfg.customArgs = $new.Trim()
            Save-Config $cfg
            Write-Host "Custom args updated." -ForegroundColor Green
            Start-Sleep -Seconds 1
        }
        "7" {
            Check-OllamaSignin
        }
        "8" {
            if (-not (Test-CommandExists "codex")) {
                Write-Host "Codex CLI not installed. Install first (option 1)." -ForegroundColor Red
                Read-Host "Press Enter to continue"
            } elseif ((Get-Config).provider -eq "ollama" -and -not (Test-CommandExists "ollama")) {
                Write-Host "Ollama not installed. Install first (option 2)." -ForegroundColor Red
                Read-Host "Press Enter to continue"
            } else {
                Clear-Host
                Launch-Codex
            }
        }
        "c" {
            $cache = Get-VersionCache
            $cache.codexLastChecked = ""
            $cache.ollamaLastChecked = ""
            Save-VersionCache $cache
            Write-Host "Version cache cleared." -ForegroundColor Green
            Start-Sleep -Seconds 1
        }
        "a" {
            $cfg = Get-Config
            $cfg.autoUpdate = -not $cfg.autoUpdate
            Save-Config $cfg
            $txt = if ($cfg.autoUpdate) { "ON" } else { "OFF" }
            Write-Host "Auto-update on direct launch: $txt" -ForegroundColor Green
            Start-Sleep -Seconds 1
        }
        "q" {
            Write-Host "Goodbye!" -ForegroundColor Green
            exit 0
        }
        default {
            Write-Host "Invalid choice." -ForegroundColor Red
            Start-Sleep -Seconds 1
        }
    }
}
