@echo off
set "BAT_DIR=%~dp0"
set "PSFILE=%TEMP%\CodexAppLauncher.ps1"
powershell -NoProfile -Command "Get-Content '%~f0' -Encoding UTF8 | Select-Object -Skip 9 | Out-File '%PSFILE%' -Encoding UTF8"
set "BatDir=%~dp0"
powershell -ExecutionPolicy Bypass -Command "& '%PSFILE%' %*; exit $LASTEXITCODE"
set "EC=%errorlevel%"
del /Q "%PSFILE%" 2>nul
exit /b %EC%
#Requires -Version 5.1
<#
.SYNOPSIS
    Smart Launcher for Codex App with Ollama or DeepSeek API + Model Picker
.DESCRIPTION
    Launches Codex App through Ollama or directly via DeepSeek API.
    Lets users pick their provider, set API keys, and choose models.
    Usage:
      Codex-App-Launcher.bat                 -> interactive menu
      Codex-App-Launcher.bat launch           -> launch with saved config
      Codex-App-Launcher.bat --model deepseek-chat --provider deepseek
#>

$ErrorActionPreference = "Stop"
Clear-Host

# ============================================
# Paths & Defaults
# ============================================
$script:BaseDir      = if ($env:BatDir) { $env:BatDir } elseif ($PSScriptRoot) { $PSScriptRoot } else { Join-Path $env:USERPROFILE ".cli-launchers" }
if (-not (Test-Path $script:BaseDir)) { New-Item -ItemType Directory -Force -Path $script:BaseDir | Out-Null }
$script:ConfigPath   = Join-Path $script:BaseDir "Codex-App-Launcher.config.json"
$script:VersionCache = Join-Path $script:BaseDir "Codex-App-Launcher.versions.json"
$script:CacheTTLMinutes = 60

$script:DefaultConfig = @{
    provider        = "ollama"          # "ollama" or "deepseek"
    ollamaModel     = "kimi-k2.6:cloud" # Ollama model name
    source          = "cloud"           # "cloud" or "local"
    deepseekModel   = "deepseek-chat"   # deepseek-chat (V4) or deepseek-reasoner (Flash)
    deepseekApiKey  = ""               # User's DeepSeek API key
    customArgs      = ""
    autoUpdate      = $false
    skipUpdateCheck = $false
}

# ============================================
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
}

# ============================================
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

# ============================================
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
# Ollama Auth
# ============================================
function Test-OllamaAuth {
    try {
        $models = ollama list 2>$null
        return ($LASTEXITCODE -eq 0 -and $models)
    } catch {
        return $false
    }
}

# ============================================
# Model Fetchers (Ollama)
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
# Provider Selection Menu
# ============================================
function Show-ProviderMenu {
    while ($true) {
        Clear-Host
        Write-Host "=============================================" -ForegroundColor Green
        Write-Host "         Choose API Provider" -ForegroundColor Green
        Write-Host "=============================================" -ForegroundColor Green
        Write-Host ""
        $cfg = Get-Config
        Write-Host "Current provider: $($cfg.provider.ToUpper())" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "Options:" -ForegroundColor Cyan
        Write-Host "  [1] Ollama - Use Ollama cloud/local models" -ForegroundColor Yellow
        Write-Host "  [2] DeepSeek - Use DeepSeek API (bring your own key)" -ForegroundColor Yellow
        Write-Host "  [B] Back to Main Menu" -ForegroundColor Magenta
        Write-Host ""
        $choice = Read-Host "Enter your choice"
        switch ($choice.ToLower()) {
            "1" {
                $cfg = Get-Config
                $cfg.provider = "ollama"
                Save-Config $cfg
                Write-Host "Provider set to: OLLAMA" -ForegroundColor Green
                Start-Sleep -Seconds 1
                return
            }
            "2" {
                $cfg = Get-Config
                $cfg.provider = "deepseek"
                if (-not $cfg.deepseekApiKey) {
                    Write-Host ""
                    Write-Host "DeepSeek API key required." -ForegroundColor Yellow
                    Write-Host "Get your key at: https://platform.deepseek.com/api_keys" -ForegroundColor Cyan
                    $key = Read-Host "Enter your DeepSeek API key (starts with 'sk-')"
                    if ($key) {
                        $cfg.deepseekApiKey = $key.Trim()
                    } else {
                        Write-Host "No key entered. You can set it later from the menu." -ForegroundColor Yellow
                        Start-Sleep -Seconds 2
                    }
                }
                Save-Config $cfg
                Write-Host "Provider set to: DEEPSEEK" -ForegroundColor Green
                Start-Sleep -Seconds 1
                return
            }
            "b" { return }
            default { Write-Host "Invalid choice." -ForegroundColor Red; Start-Sleep -Seconds 1 }
        }
    }
}

# ============================================
# Ollama Model Picker
# ============================================
function Show-OllamaCloudModelMenu {
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
    Write-Host "  [M] Manual entry" -ForegroundColor Yellow
    Write-Host "  [B] Back" -ForegroundColor Magenta
    Write-Host ""
    $choice = Read-Host "Select a cloud model by number, or M/B"
    if ($choice.ToLower() -eq "b") { return }
    if ($choice.ToLower() -eq "m") {
        $manual = Read-Host "Enter the full model name (e.g., kimi-k2.6:cloud)"
        if ($manual) {
            $cfg = Get-Config
            $cfg.ollamaModel = $manual
            $cfg.source = "cloud"
            Save-Config $cfg
            Write-Host "Selected model: $manual" -ForegroundColor Green
        }
        Read-Host "Press Enter to continue"
        return
    }
    $idx = 0
    if ([int]::TryParse($choice, [ref]$idx)) {
        if ($idx -ge 1 -and $idx -le $models.Count) {
            $selected = $models[$idx - 1].name
            $cfg = Get-Config
            $cfg.ollamaModel = $selected
            $cfg.source = "cloud"
            Save-Config $cfg
            Write-Host "Selected model: $selected" -ForegroundColor Green
        } else { Write-Host "Invalid selection." -ForegroundColor Red }
    } else { Write-Host "Invalid input." -ForegroundColor Red }
    Read-Host "Press Enter to continue"
}

function Show-OllamaLocalModelMenu {
    Clear-Host
    Write-Host "=============================================" -ForegroundColor Green
    Write-Host "   Local Models (Downloaded on this PC)" -ForegroundColor Green
    Write-Host "=============================================" -ForegroundColor Green
    Write-Host ""
    $models = Get-LocalModels
    if ($models.Count -eq 0) {
        Write-Host "No local models found." -ForegroundColor Yellow
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
    Write-Host "  [B] Back" -ForegroundColor Magenta
    Write-Host ""
    $choice = Read-Host "Select a local model by number, or B"
    if ($choice.ToLower() -eq "b") { return }
    $idx = 0
    if ([int]::TryParse($choice, [ref]$idx)) {
        if ($idx -ge 1 -and $idx -le $models.Count) {
            $selected = $models[$idx - 1].name
            $cfg = Get-Config
            $cfg.ollamaModel = $selected
            $cfg.source = "local"
            Save-Config $cfg
            Write-Host "Selected model: $selected" -ForegroundColor Green
        } else { Write-Host "Invalid selection." -ForegroundColor Red }
    } else { Write-Host "Invalid input." -ForegroundColor Red }
    Read-Host "Press Enter to continue"
}

function Show-OllamaModelPicker {
    while ($true) {
        Clear-Host
        Write-Host "=============================================" -ForegroundColor Green
        Write-Host "    Pick Ollama Model" -ForegroundColor Green
        Write-Host "=============================================" -ForegroundColor Green
        Write-Host ""
        $cfg = Get-Config
        Write-Host "Current model: $($cfg.ollamaModel)" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "Options:" -ForegroundColor Cyan
        Write-Host "  [1] Browse Cloud Models (Ollama Registry)" -ForegroundColor Yellow
        Write-Host "  [2] Browse Local Models (this PC)" -ForegroundColor Yellow
        Write-Host "  [3] Manual Entry (type any model name)" -ForegroundColor Yellow
        Write-Host "  [B] Back to Model Menu" -ForegroundColor Magenta
        Write-Host ""
        $choice = Read-Host "Enter your choice"
        switch ($choice.ToLower()) {
            "1" { Show-OllamaCloudModelMenu }
            "2" { Show-OllamaLocalModelMenu }
            "3" {
                $manual = Read-Host "Enter the full model name (e.g., kimi-k2.6:cloud, llama3.3:latest)"
                if ($manual) {
                    $cfg = Get-Config
                    $cfg.ollamaModel = $manual
                    $cfg.source = "manual"
                    Save-Config $cfg
                    Write-Host "Model set to: $manual" -ForegroundColor Green
                    Read-Host "Press Enter to continue"
                }
            }
            "b" { return }
            default { Write-Host "Invalid choice." -ForegroundColor Red; Start-Sleep -Seconds 1 }
        }
    }
}

# ============================================
# DeepSeek Model Picker
# ============================================
function Show-DeepSeekModelPicker {
    while ($true) {
        Clear-Host
        Write-Host "=============================================" -ForegroundColor Green
        Write-Host "    Pick DeepSeek Model" -ForegroundColor Green
        Write-Host "=============================================" -ForegroundColor Green
        Write-Host ""
        $cfg = Get-Config
        $modelLabel = switch ($cfg.deepseekModel) {
            "deepseek-chat" { "DeepSeek V4 (Recommended)" }
            "deepseek-reasoner" { "DeepSeek R1 (Flash/Reasoning)" }
            default { $cfg.deepseekModel }
        }
        Write-Host "Current model: $modelLabel" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "Available DeepSeek models:" -ForegroundColor Cyan
        Write-Host "  [1] DeepSeek V4 (Recommended) - deepseek-chat" -ForegroundColor Yellow
        Write-Host "       Latest flagship chat model. Best for general coding." -ForegroundColor DarkGray
        Write-Host "  [2] DeepSeek R1 (Flash)       - deepseek-reasoner" -ForegroundColor Yellow
        Write-Host "       Fast reasoning model. Best for complex logic." -ForegroundColor DarkGray
        Write-Host "  [3] Manual Entry (type any DeepSeek model ID)" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  [S] Set / Update API Key" -ForegroundColor White
        Write-Host "  [B] Back to Model Menu" -ForegroundColor Magenta
        Write-Host ""
        $choice = Read-Host "Enter your choice"
        switch ($choice.ToLower()) {
            "1" {
                $cfg = Get-Config
                $cfg.deepseekModel = "deepseek-chat"
                Save-Config $cfg
                Write-Host "Selected: DeepSeek V4 (deepseek-chat) - Recommended" -ForegroundColor Green
                Start-Sleep -Seconds 1
            }
            "2" {
                $cfg = Get-Config
                $cfg.deepseekModel = "deepseek-reasoner"
                Save-Config $cfg
                Write-Host "Selected: DeepSeek R1 (deepseek-reasoner) - Flash" -ForegroundColor Green
                Start-Sleep -Seconds 1
            }
            "3" {
                $manual = Read-Host "Enter the full DeepSeek model ID (e.g., deepseek-chat)"
                if ($manual) {
                    $cfg = Get-Config
                    $cfg.deepseekModel = $manual
                    Save-Config $cfg
                    Write-Host "Model set to: $manual" -ForegroundColor Green
                    Read-Host "Press Enter to continue"
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
    Write-Host "    Set DeepSeek API Key" -ForegroundColor Green
    Write-Host "=============================================" -ForegroundColor Green
    Write-Host ""
    $cfg = Get-Config
    if ($cfg.deepseekApiKey) {
        $maskedKey = $cfg.deepseekApiKey.Substring(0, [Math]::Min(8, $cfg.deepseekApiKey.Length)) + "..."
        Write-Host "Current key: $maskedKey" -ForegroundColor Cyan
    } else {
        Write-Host "No API key set." -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "Get your DeepSeek API key at: https://platform.deepseek.com/api_keys" -ForegroundColor Cyan
    Write-Host ""
    $key = Read-Host "Enter your DeepSeek API key (or leave blank to keep current)"
    if ($key.Trim()) {
        $cfg.deepseekApiKey = $key.Trim()
        Save-Config $cfg
        Write-Host "API key saved." -ForegroundColor Green
    } else {
        Write-Host "API key unchanged." -ForegroundColor Yellow
    }
    Start-Sleep -Seconds 1
}

# ============================================
# Model Menu (Unified)
# ============================================
function Show-ModelMenu {
    while ($true) {
        Clear-Host
        Write-Host "=============================================" -ForegroundColor Green
        Write-Host "    Pick / Change Model" -ForegroundColor Green
        Write-Host "=============================================" -ForegroundColor Green
        Write-Host ""
        $cfg = Get-Config
        Write-Host "Provider: $($cfg.provider.ToUpper())" -ForegroundColor Cyan
        if ($cfg.provider -eq "ollama") {
            Write-Host "Model   : $($cfg.ollamaModel) [source: $($cfg.source)]" -ForegroundColor White
        } else {
            $modelLabel = switch ($cfg.deepseekModel) {
                "deepseek-chat" { "DeepSeek V4 (Recommended)" }
                "deepseek-reasoner" { "DeepSeek R1 (Flash/Reasoning)" }
                default { $cfg.deepseekModel }
            }
            Write-Host "Model   : $modelLabel" -ForegroundColor White
            if ($cfg.deepseekApiKey) {
                $masked = $cfg.deepseekApiKey.Substring(0, [Math]::Min(8, $cfg.deepseekApiKey.Length)) + "..."
                Write-Host "API Key : $masked" -ForegroundColor White
            } else {
                Write-Host "API Key : NOT SET" -ForegroundColor Red
            }
        }
        Write-Host ""
        Write-Host "Options:" -ForegroundColor Cyan
        Write-Host "  [1] Switch Provider (Ollama / DeepSeek)" -ForegroundColor Yellow
        if ($cfg.provider -eq "ollama") {
            Write-Host "  [2] Browse Ollama Models" -ForegroundColor Yellow
        } else {
            Write-Host "  [2] Pick DeepSeek Model" -ForegroundColor Yellow
            Write-Host "  [3] Set DeepSeek API Key" -ForegroundColor Yellow
        }
        Write-Host "  [B] Back to Main Menu" -ForegroundColor Magenta
        Write-Host ""
        $choice = Read-Host "Enter your choice"
        switch ($choice.ToLower()) {
            "1" { Show-ProviderMenu }
            "2" {
                $cfg = Get-Config
                if ($cfg.provider -eq "ollama") {
                    Show-OllamaModelPicker
                } else {
                    Show-DeepSeekModelPicker
                }
            }
            "3" {
                $cfg = Get-Config
                if ($cfg.provider -eq "deepseek") {
                    Set-DeepSeekApiKey
                }
            }
            "b" { return }
            default { Write-Host "Invalid choice." -ForegroundColor Red; Start-Sleep -Seconds 1 }
        }
    }
}

# ============================================
# Pull Model (Ollama only)
# ============================================
function Pull-SelectedModel {
    $cfg = Get-Config
    if ($cfg.provider -ne "ollama") {
        Write-Host "Pull is only available when using Ollama provider." -ForegroundColor Yellow
        Read-Host "Press Enter to continue"
        return
    }
    $model = $cfg.ollamaModel
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
# Launch Codex App
# ============================================
function Launch-CodexApp([string[]]$passArgs) {
    $cfg = Get-Config

    if ($cfg.provider -eq "deepseek") {
        if (-not $cfg.deepseekApiKey) {
            Write-Host "ERROR: DeepSeek API key not set." -ForegroundColor Red
            Write-Host "Go to Model menu (option 2) to set your key." -ForegroundColor Yellow
            Read-Host "Press Enter to return to menu"
            return
        }

        Write-Host "Configuring DeepSeek API environment..." -ForegroundColor Cyan
        $env:OPENAI_API_KEY = $cfg.deepseekApiKey
        $env:OPENAI_BASE_URL = "https://api.deepseek.com/v1"
        Write-Host "Using model: $($cfg.deepseekModel)" -ForegroundColor Cyan

        $cmdParts = @("codex", "--model=$($cfg.deepseekModel)")
        if ($passArgs -and $passArgs.Count -gt 0) {
            $skipNext = $false
            foreach ($a in $passArgs) {
                if ($skipNext) { $cmdParts += "--model=$a"; $skipNext = $false; continue }
                if ($a -eq "--model") { $skipNext = $true; continue }
                $cmdParts += $a
            }
        }
        if ($cfg.customArgs) {
            $cmdParts += ($cfg.customArgs -split ' ')
        }

        $cmdString = $cmdParts -join ' '
        Write-Host "`n>>> $cmdString (DeepSeek API)" -ForegroundColor Green
        Write-Host ("-" * 50) -ForegroundColor DarkGray

        Clear-Host
        try {
            & $cmdParts[0] @($cmdParts[1..($cmdParts.Length-1)])
            if ($LASTEXITCODE -ne 0) {
                Write-Host "Codex App exited with code $LASTEXITCODE." -ForegroundColor Yellow
            }
        } catch {
            Write-Host "ERROR launching Codex App: $_" -ForegroundColor Red
        }
    } else {
        $model = $cfg.ollamaModel
        if (-not (Start-OllamaServer)) {
            Read-Host "Press Enter to return to menu"
            return
        }

        $cmdParts = @("ollama", "launch", "codex-app")
        if ($passArgs -and $passArgs.Count -gt 0) {
            $hasModel = $false
            $foundSep = $false
            $extraAfterSep = @()
            $skipNext = $false
            foreach ($a in $passArgs) {
                if ($skipNext) { $skipNext = $false; continue }
                if ($a -eq "--") { $foundSep = $true; continue }
                if ($foundSep) { $extraAfterSep += $a; continue }
                if ($a -eq "--model") { $hasModel = $true; $cmdParts += "--model"; $skipNext = $true }
                elseif ($a.StartsWith("--model=")) { $hasModel = $true; $cmdParts += $a }
                else { $extraAfterSep += $a }
            }
            if (-not $hasModel -and $model) {
                $cmdParts += "--model"
                $cmdParts += $model
            }
            $cmdParts += "--"
            if ($extraAfterSep.Count -gt 0) { $cmdParts += $extraAfterSep }
        } else {
            if ($model) {
                $cmdParts += "--model"
                $cmdParts += $model
            }
            $cmdParts += "--"
        }
        if ($cfg.customArgs) {
            $cmdParts += ($cfg.customArgs -split ' ')
        }

        $cmdString = $cmdParts -join ' '
        Write-Host "`n>>> $cmdString" -ForegroundColor Green
        Write-Host ("-" * 50) -ForegroundColor DarkGray

        Clear-Host
        try {
            $proc = Start-Process -FilePath $cmdParts[0] -ArgumentList $cmdParts[1..($cmdParts.Length-1)] -NoNewWindow -Wait -PassThru
            if ($proc.ExitCode -ne 0) {
                Write-Host "Codex App exited with code $($proc.ExitCode)." -ForegroundColor Yellow
            }
        } catch {
            Write-Host "ERROR launching Codex App: $_" -ForegroundColor Red
        }
    }
    Read-Host "Codex App session ended. Press Enter to return to menu"
}

# ============================================
# Status Display
# ============================================
function Show-Status {
    $cExists = Test-CommandExists "codex"
    $oExists = Test-CommandExists "ollama"
    $nExists = Test-CommandExists "npm"
    $appExists = Test-CommandExists "codex-app"
    $cfg = Get-Config

    $codexUpdate = $false
    $ollamaUpdate = $false

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

    Write-Host "`n========== Codex App Launcher ==========" -ForegroundColor Cyan
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
    if ($appExists) {
        Write-Host "  Codex App     : AVAILABLE" -ForegroundColor Green
    } else {
        Write-Host "  Codex App     : NOT FOUND (installed via Codex CLI)" -ForegroundColor Yellow
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
    Write-Host "  Provider      : $($cfg.provider.ToUpper())" -ForegroundColor Cyan
    if ($cfg.provider -eq "ollama") {
        Write-Host "  Model         : $($cfg.ollamaModel) [source: $($cfg.source)]" -ForegroundColor Cyan
    } else {
        $modelLabel = switch ($cfg.deepseekModel) {
            "deepseek-chat" { "DeepSeek V4 (Recommended)" }
            "deepseek-reasoner" { "DeepSeek R1 (Flash/Reasoning)" }
            default { $cfg.deepseekModel }
        }
        Write-Host "  Model         : $modelLabel" -ForegroundColor Cyan
        if ($cfg.deepseekApiKey) {
            Write-Host "  API Key       : SET" -ForegroundColor Green
        } else {
            Write-Host "  API Key       : NOT SET" -ForegroundColor Red
        }
    }
    Write-Host "===========================================" -ForegroundColor Cyan
}

# ============================================
# Main Menu
# ============================================
function Show-MainMenu {
    Show-Status
    $cExists = Test-CommandExists "codex"
    $oExists = Test-CommandExists "ollama"
    $cfg = Get-Config

    Write-Host "`n[1] Install / Update Codex CLI" -ForegroundColor White
    if ($cExists) {
        $inst = Get-CodexInstalledVersion
        $lat = Get-CodexLatestVersion
        if (Compare-Versions $inst $lat) { Write-Host "     ^^ UPDATE AVAILABLE" -ForegroundColor Yellow }
    }
    if ($oExists) {
        $inst = Get-OllamaInstalledVersion
        $lat = Get-OllamaLatestVersion
        if (Compare-Versions $inst $lat) {
            Write-Host "[2] Install / Update Ollama" -ForegroundColor White
            Write-Host "     ^^ UPDATE AVAILABLE" -ForegroundColor Yellow
        } else {
            Write-Host "[2] Install / Update Ollama" -ForegroundColor White
        }
    } else {
        Write-Host "[2] Install / Update Ollama" -ForegroundColor White
    }
    Write-Host "[3] Pick / Change Provider & Model" -ForegroundColor White
    if ($cfg.provider -eq "ollama" -and $cfg.source -eq "cloud" -and $oExists) {
        Write-Host "[4] Pull Ollama Model Locally" -ForegroundColor White
    } else {
        Write-Host "[4] Pull Ollama Model Locally [not applicable]" -ForegroundColor DarkGray
    }
    Write-Host "[5] Set Custom Launch Arguments" -ForegroundColor White
    Write-Host "[6] Launch Codex App" -ForegroundColor Green
    Write-Host "[C] Clear Version Cache" -ForegroundColor White
    Write-Host "[Q] Quit" -ForegroundColor Magenta
    Write-Host ""
}

# ============================================
# Main
# ============================================
if ($args.Count -gt 0) {
    $launchArgs = $args
    if ($launchArgs[0] -eq "launch") {
        if ($launchArgs.Count -gt 1) { $launchArgs = $launchArgs[1..($launchArgs.Count-1)] } else { $launchArgs = @() }
    }

    $cfg = Get-Config
    if ($cfg.provider -eq "deepseek") {
        if (-not $cfg.deepseekApiKey) {
            Write-Host "ERROR: DeepSeek API key not set. Run launcher menu to configure." -ForegroundColor Red
            exit 1
        }
        $env:OPENAI_API_KEY = $cfg.deepseekApiKey
        $env:OPENAI_BASE_URL = "https://api.deepseek.com/v1"
        Clear-Host
        $cmdParts = @("codex")
        $hasModel = $false
        $skipNext = $false
        foreach ($a in $launchArgs) {
            if ($skipNext) { $cmdParts += "--model=$a"; $skipNext = $false; continue }
            if ($a -eq "--model") { $hasModel = $true; $skipNext = $true; continue }
            if ($a.StartsWith("--model=")) { $hasModel = $true; $cmdParts += $a; continue }
            $cmdParts += $a
        }
        if (-not $hasModel) { $cmdParts += "--model=$($cfg.deepseekModel)" }
        if ($cfg.customArgs) { $cmdParts += ($cfg.customArgs -split ' ') }
        $cmdString = $cmdParts -join ' '
        Write-Host ">>> $cmdString (DeepSeek API)" -ForegroundColor Green
        try {
            & $cmdParts[0] @($cmdParts[1..($cmdParts.Length-1)])
            exit $LASTEXITCODE
        } catch {
            Write-Host "ERROR: $_" -ForegroundColor Red
            exit 1
        }
    } else {
        if (-not (Test-CommandExists "codex")) {
            Write-Host "Codex CLI not found. Installing..." -ForegroundColor Yellow
            $ok = Install-CodexCLI
            if (-not $ok) { exit 1 }
        }
        if (-not (Test-CommandExists "ollama")) {
            Write-Host "Ollama not found. Installing..." -ForegroundColor Yellow
            Install-Ollama
        }
        if (-not (Start-OllamaServer)) { exit 1 }
        Clear-Host
        Launch-CodexApp -passArgs $launchArgs
        exit $LASTEXITCODE
    }
}

while ($true) {
    Show-MainMenu
    $choice = Read-Host "Enter choice"
    $cfg = Get-Config
    switch ($choice.ToLower()) {
        "1" {
            if (Test-CommandExists "codex") {
                $inst = Get-CodexInstalledVersion
                $lat = Get-CodexLatestVersion
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
                $lat = Get-OllamaLatestVersion
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
        "3" { Show-ModelMenu }
        "4" {
            if ($cfg.provider -eq "ollama" -and $cfg.source -eq "cloud" -and (Test-CommandExists "ollama")) {
                Pull-SelectedModel
            } else {
                Write-Host "Pull is only available when using Ollama provider with a cloud model." -ForegroundColor Yellow
                Read-Host "Press Enter to continue"
            }
        }
        "5" {
            $cfg = Get-Config
            Write-Host "Current custom args: $(if ($cfg.customArgs) { $cfg.customArgs } else { '(none)' })" -ForegroundColor Cyan
            $new = Read-Host "Enter extra args, or blank to clear"
            $cfg.customArgs = $new.Trim()
            Save-Config $cfg
            Write-Host "Custom args updated." -ForegroundColor Green
            Start-Sleep -Seconds 1
        }
        "6" {
            if (-not (Test-CommandExists "codex")) {
                Write-Host "Codex CLI not installed. Install first (option 1)." -ForegroundColor Red
                Read-Host "Press Enter to continue"
            } elseif ($cfg.provider -eq "ollama" -and -not (Test-CommandExists "ollama")) {
                Write-Host "Ollama not installed. Install first (option 2)." -ForegroundColor Red
                Read-Host "Press Enter to continue"
            } elseif ($cfg.provider -eq "deepseek" -and -not $cfg.deepseekApiKey) {
                Write-Host "DeepSeek API key not set. Go to option 3 to configure." -ForegroundColor Red
                Read-Host "Press Enter to continue"
            } else {
                Clear-Host
                Launch-CodexApp
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

