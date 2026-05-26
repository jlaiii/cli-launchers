#Requires -Version 5.1
<#
.SYNOPSIS
    Smart Launcher for Claude Code + Ollama with Model Picker & Update Checker
.DESCRIPTION
    Checks if Claude Code and Ollama are installed, checks for updates,
    fetches top 10 newest models from Ollama cloud registry and local models,
    lets users pick source (local vs cloud), and launches Claude Code.
    This script is embedded inside a self-extracting batch file.
#>

$ErrorActionPreference = "Stop"

# Config files live next to the original .bat file (passed via $env:BatDir)
$script:BaseDir      = if ($env:BatDir) { $env:BatDir } elseif ($PSScriptRoot) { $PSScriptRoot } else { Join-Path $env:USERPROFILE ".cli-launchers" }
if (-not (Test-Path $script:BaseDir)) { New-Item -ItemType Directory -Force -Path $script:BaseDir | Out-Null }
$script:ConfigPath   = Join-Path $script:BaseDir "Claude-Ollama-Launcher.config.json"
$script:VersionCache = Join-Path $script:BaseDir "Claude-Ollama-Launcher.versions.json"
$script:CacheTTLMinutes = 60

# Default config
$script:DefaultConfig = @{
    selectedModel    = "kimi-k2.6:cloud"
    source           = "cloud"   # "cloud" or "local"
    skipPermissions  = $true     # if true, adds --dangerously-skip-permissions
    customCommand    = ""        # e.g. "ollama launch claude" or leave empty for default
    provider         = "ollama"  # "ollama" or "deepseek"
    deepseekModel    = "deepseek-chat"
    deepseekApiKey   = ""
}

# ============================================
# Config Helpers
# ============================================

function Get-Config {
    if (Test-Path $script:ConfigPath) {
        try {
            $cfg = Get-Content $script:ConfigPath -Raw | ConvertFrom-Json
            if (-not $cfg.PSObject.Properties["selectedModel"])    { $cfg | Add-Member -NotePropertyName selectedModel -NotePropertyValue $script:DefaultConfig.selectedModel }
            if (-not $cfg.PSObject.Properties["source"])            { $cfg | Add-Member -NotePropertyName source -NotePropertyValue $script:DefaultConfig.source }
            if (-not $cfg.PSObject.Properties["skipPermissions"])  { $cfg | Add-Member -NotePropertyName skipPermissions -NotePropertyValue $script:DefaultConfig.skipPermissions }
            if (-not $cfg.PSObject.Properties["customCommand"])    { $cfg | Add-Member -NotePropertyName customCommand -NotePropertyValue $script:DefaultConfig.customCommand }
            if (-not $cfg.PSObject.Properties["provider"])         { $cfg | Add-Member -NotePropertyName provider -NotePropertyValue $script:DefaultConfig.provider }
            if (-not $cfg.PSObject.Properties["deepseekModel"])    { $cfg | Add-Member -NotePropertyName deepseekModel -NotePropertyValue $script:DefaultConfig.deepseekModel }
            if (-not $cfg.PSObject.Properties["deepseekApiKey"])   { $cfg | Add-Member -NotePropertyName deepseekApiKey -NotePropertyValue $script:DefaultConfig.deepseekApiKey }
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
        claudeLatestVersion = ""
        claudeLastChecked   = ""
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

function Get-ClaudeInstalledVersion {
    try {
        $ver = claude --version 2>$null
        if ($ver) {
            # Parse version like "2.1.143 (Claude Code)" or "2.1.143"
            if ($ver -match '(\d+\.\d+\.\d+)') {
                return $matches[1]
            }
        }
    } catch {}
    return $null
}

function Get-ClaudeLatestVersion {
    $cache = Get-VersionCache
    if (-not (Is-CacheStale $cache.claudeLastChecked)) {
        return $cache.claudeLatestVersion
    }
    try {
        $resp = Invoke-WebRequest -Uri "https://registry.npmjs.org/@anthropic-ai/claude-code/latest" -UseBasicParsing -TimeoutSec 15
        $data = $resp.Content | ConvertFrom-Json
        $ver = $data.version
        if ($ver) {
            $cache.claudeLatestVersion = $ver
            $cache.claudeLastChecked = [datetime]::Now.ToString("o")
            Save-VersionCache $cache
            return $ver
        }
    } catch {}
    return $null
}

function Get-OllamaInstalledVersion {
    try {
        $ver = ollama --version 2>$null
        if ($ver) {
            # Parse "ollama version is 0.24.0"
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
        $tag = $data.tag_name
        if ($tag) {
            $ver = $tag -replace '^v', ''
            $cache.ollamaLatestVersion = $ver
            $cache.ollamaLastChecked = [datetime]::Now.ToString("o")
            Save-VersionCache $cache
            return $ver
        }
    } catch {}
    return $null
}

function Compare-Versions($installed, $latest) {
    if ([string]::IsNullOrWhiteSpace($installed) -or [string]::IsNullOrWhiteSpace($latest)) {
        return $null
    }
    try {
        $inst = [version]$installed
        $lat  = [version]$latest
        return ($lat -gt $inst)
    } catch {
        return $null
    }
}

# ============================================
# Prerequisite Checks
# ============================================

function Test-CommandExists {
    param([string]$Command)
    try {
        $null = Get-Command $Command -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function Find-ClaudeExe {
    # If already in PATH, return the resolved path
    try {
        $cmd = Get-Command "claude" -ErrorAction Stop
        if ($cmd) { return $cmd.Source }
    } catch {}

    # Search common install locations that the official installer uses
    $candidates = @(
        (Join-Path $env:USERPROFILE ".local\bin\claude.exe")
        (Join-Path $env:USERPROFILE "bin\claude.exe")
        (Join-Path $env:LOCALAPPDATA "Programs\Claude\claude.exe")
        (Join-Path $env:LOCALAPPDATA "AnthropicClaude\claude.exe")
        (Join-Path $env:LOCALAPPDATA "Claude\claude.exe")
        (Join-Path $env:ProgramFiles "Claude\claude.exe")
        (Join-Path $env:ProgramFiles "(x86)\Claude\claude.exe")
    )

    foreach ($path in $candidates) {
        if (Test-Path $path) { return $path }
    }
    return $null
}

function Ensure-ClaudeInPath {
    $claudePath = Find-ClaudeExe
    if ($claudePath) {
        $dir = Split-Path -Parent $claudePath
        $pathDirs = $env:PATH -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        if ($pathDirs -notcontains $dir) {
            $env:PATH = "$dir;$env:PATH"
        }
    }
}

# ============================================
# Installers / Updaters
# ============================================

function Install-ClaudeCode {
    Write-Host "Installing/Updating Claude Code from https://claude.ai/install.ps1 ..." -ForegroundColor Cyan
    try {
        irm https://claude.ai/install.ps1 | iex
        Write-Host "Claude Code installation/update completed." -ForegroundColor Green
        Ensure-ClaudeInPath
        $claudePath = Find-ClaudeExe
        if ($claudePath) {
            $dir = Split-Path -Parent $claudePath
            $pathDirs = $env:PATH -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
            if ($pathDirs -contains $dir) {
                Write-Host "Claude Code is now available in this session from: $dir" -ForegroundColor Green
            } else {
                Write-Host "WARNING: Claude Code was installed to $dir but could not be added to PATH for this session." -ForegroundColor Yellow
                Write-Host "You may need to add $dir to your system PATH manually (System Properties > Environment Variables)." -ForegroundColor Yellow
            }
        } else {
            Write-Host "WARNING: Claude Code installer finished but claude.exe was not found in expected locations." -ForegroundColor Yellow
        }
    } catch {
        Write-Host "ERROR installing/updating Claude Code: $_" -ForegroundColor Red
    }
    Read-Host "Press Enter to continue"
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
# Provider Menus
# ============================================

function Show-ProviderMenu {
    while ($true) {
        Clear-Host
        Write-Host "=============================================" -ForegroundColor Green
        Write-Host "         Select Provider" -ForegroundColor Green
        Write-Host "=============================================" -ForegroundColor Green
        Write-Host ""

        $cfg = Get-Config
        Write-Host "Current provider: $($cfg.provider)" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  [1] Ollama (local + cloud models)" -ForegroundColor Yellow
        Write-Host "  [2] DeepSeek (API-based)" -ForegroundColor Yellow
        Write-Host "  [B] Back to Main Menu" -ForegroundColor Magenta
        Write-Host ""

        $choice = Read-Host "Enter your choice"
        switch ($choice.ToLower()) {
            "1" {
                $cfg = Get-Config
                $cfg.provider = "ollama"
                Save-Config $cfg
                Write-Host "Provider set to: Ollama" -ForegroundColor Green
                Read-Host "Press Enter to continue"
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
                        Write-Host "No key entered. You can set it later from the model picker." -ForegroundColor Yellow
                        Start-Sleep -Seconds 2
                    }
                }
                Save-Config $cfg
                Write-Host "Provider set to: DeepSeek" -ForegroundColor Green
                Read-Host "Press Enter to continue"
                return
            }
            "b" { return }
            default { Write-Host "Invalid choice." -ForegroundColor Red; Start-Sleep -Seconds 1 }
        }
    }
}

function Show-DeepSeekModelPicker {
    Clear-Host
    Write-Host "=============================================" -ForegroundColor Green
    Write-Host "   DeepSeek Model Selection" -ForegroundColor Green
    Write-Host "=============================================" -ForegroundColor Green
    Write-Host ""

    $cfg = Get-Config
    Write-Host "Current DeepSeek model: $($cfg.deepseekModel)" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  [1] DeepSeek-V4 (recommended) -> deepseek-chat" -ForegroundColor Yellow
    Write-Host "  [2] DeepSeek-Flash             -> deepseek-reasoner" -ForegroundColor Yellow
    Write-Host "  [M] Manual entry (custom model ID)" -ForegroundColor Yellow
    Write-Host "  [B] Back to menu" -ForegroundColor Magenta
    Write-Host ""

    $choice = Read-Host "Enter your choice"
    switch ($choice.ToLower()) {
        "1" {
            $cfg = Get-Config
            $cfg.deepseekModel = "deepseek-chat"
            Save-Config $cfg
            Write-Host "DeepSeek model set to: deepseek-chat (V4)" -ForegroundColor Green
            Read-Host "Press Enter to continue"
        }
        "2" {
            $cfg = Get-Config
            $cfg.deepseekModel = "deepseek-reasoner"
            Save-Config $cfg
            Write-Host "DeepSeek model set to: deepseek-reasoner (Flash)" -ForegroundColor Green
            Read-Host "Press Enter to continue"
        }
        "m" {
            $manual = Read-Host "Enter the DeepSeek model ID (e.g., deepseek-chat, deepseek-reasoner)"
            if ($manual) {
                $cfg = Get-Config
                $cfg.deepseekModel = $manual
                Save-Config $cfg
                Write-Host "DeepSeek model set to: $manual" -ForegroundColor Green
            }
            Read-Host "Press Enter to continue"
        }
        "b" { return }
        default { Write-Host "Invalid choice." -ForegroundColor Red; Start-Sleep -Seconds 1 }
    }
}

function Set-DeepSeekApiKey {
    Clear-Host
    Write-Host "=============================================" -ForegroundColor Green
    Write-Host "   Set DeepSeek API Key" -ForegroundColor Green
    Write-Host "=============================================" -ForegroundColor Green
    Write-Host ""

    $cfg = Get-Config
    $maskedKey = if ($cfg.deepseekApiKey) {
        $key = $cfg.deepseekApiKey
        if ($key.Length -gt 8) { $key.Substring(0,4) + "..." + $key.Substring($key.Length - 4) } else { "(set, hidden)" }
    } else { "(not set)" }
    Write-Host "Current API key: $maskedKey" -ForegroundColor Cyan
    Write-Host ""

    $newKey = Read-Host "Enter DeepSeek API Key (or leave blank to keep current)"
    if ($newKey.Trim()) {
        $cfg = Get-Config
        $cfg.deepseekApiKey = $newKey.Trim()
        Save-Config $cfg
        Write-Host "DeepSeek API key saved." -ForegroundColor Green
    } else {
        Write-Host "API key unchanged." -ForegroundColor Yellow
    }
    Read-Host "Press Enter to continue"
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
        Write-Host "  Provider: $($cfg.provider)" -ForegroundColor White
        if ($cfg.provider -eq "deepseek") {
            Write-Host "  Model   : $($cfg.deepseekModel)" -ForegroundColor White
            $dsKeyStatus = if ($cfg.deepseekApiKey) { "**** (set)" } else { "(not set)" }
            Write-Host "  API Key : $dsKeyStatus" -ForegroundColor White
        } else {
            Write-Host "  Model   : $($cfg.selectedModel)" -ForegroundColor White
            Write-Host "  Source  : $($cfg.source)" -ForegroundColor White
        }
        Write-Host ""
        Write-Host "Options:" -ForegroundColor Cyan

        if ($cfg.provider -eq "deepseek") {
            Write-Host "  [1] Switch to Ollama Provider" -ForegroundColor Yellow
            Write-Host "  [2] Pick DeepSeek Model (V4 / Flash)" -ForegroundColor Yellow
            Write-Host "  [3] Set DeepSeek API Key" -ForegroundColor Yellow
            Write-Host "  [4] Manual Model Entry" -ForegroundColor Yellow
            Write-Host "  [B] Back to Main Menu" -ForegroundColor Magenta
            Write-Host ""

            $choice = Read-Host "Enter your choice"
            switch ($choice.ToLower()) {
                "1" {
                    $cfg = Get-Config
                    $cfg.provider = "ollama"
                    Save-Config $cfg
                    Write-Host "Switched to Ollama provider." -ForegroundColor Green
                    Read-Host "Press Enter to continue"
                }
                "2" { Show-DeepSeekModelPicker }
                "3" { Set-DeepSeekApiKey }
                "4" {
                    $manual = Read-Host "Enter the full model ID (e.g., deepseek-chat, deepseek-reasoner)"
                    if ($manual) {
                        $cfg = Get-Config
                        $cfg.deepseekModel = $manual
                        Save-Config $cfg
                        Write-Host "DeepSeek model set to: $manual" -ForegroundColor Green
                        Read-Host "Press Enter to continue"
                    }
                }
                "b" { return }
                default { Write-Host "Invalid choice." -ForegroundColor Red; Start-Sleep -Seconds 1 }
            }
        } else {
            Write-Host "  [1] Switch to DeepSeek Provider" -ForegroundColor Yellow
            Write-Host "  [2] Browse Cloud Models (Ollama Registry)" -ForegroundColor Yellow
            Write-Host "  [3] Browse Local Models (this PC)" -ForegroundColor Yellow
            Write-Host "  [4] Manual Entry (type any model name)" -ForegroundColor Yellow
            Write-Host "  [B] Back to Main Menu" -ForegroundColor Magenta
            Write-Host ""

            $choice = Read-Host "Enter your choice"
            switch ($choice.ToLower()) {
                "1" {
                    $cfg = Get-Config
                    $cfg.provider = "deepseek"
                    Save-Config $cfg
                    Write-Host "Switched to DeepSeek provider." -ForegroundColor Green
                    Read-Host "Press Enter to continue"
                }
                "2" { Show-CloudModelMenu }
                "3" { Show-LocalModelMenu }
                "4" {
                    $manual = Read-Host "Enter the full model name (e.g., ollama/llama3, kimi-k2.6:cloud, llama3.3:latest)"
                    if ($manual) {
                        $cfg = Get-Config
                        $cfg.selectedModel = $manual
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
}

# ============================================
# Ollama Sign-in Check
# ============================================

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
}

# ============================================
# Launcher
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

function Launch-ClaudeOllama {
    $cfg = Get-Config

    if ($cfg.provider -eq "deepseek") {
        if (-not $cfg.deepseekApiKey) {
            Write-Host "ERROR: DeepSeek API key is not set. Use menu option 3 to set it." -ForegroundColor Red
            Read-Host "Press Enter to return to menu"
            return
        }

        Clear-Host
        $env:OPENAI_API_KEY = $cfg.deepseekApiKey
        $env:OPENAI_BASE_URL = "https://api.deepseek.com/v1"

        $cmdParts = @("claude")
        $cmdParts += "--model=$($cfg.deepseekModel)"
        if ($cfg.skipPermissions) {
            $cmdParts += "--dangerously-skip-permissions"
        }

        $cmdString = $cmdParts -join ' '
        Write-Host "`n>>> DeepSeek | $cmdString" -ForegroundColor Green
        Write-Host ("-" * 50) -ForegroundColor DarkGray

        Clear-Host
        try {
            $cmdArgs = $cmdParts[1..($cmdParts.Length-1)]
            & $cmdParts[0] @cmdArgs
            if ($LASTEXITCODE -ne 0) {
                Write-Host "Claude Code exited with code $LASTEXITCODE." -ForegroundColor Yellow
            }
        } catch {
            Write-Host "ERROR launching Claude: $_" -ForegroundColor Red
        }
        Read-Host "Claude Code session ended. Press Enter to return to menu"
        return
    }

    $model = $cfg.selectedModel

    # Ensure Ollama server is running before launch
    if (-not (Start-OllamaServer)) {
        Read-Host "Press Enter to return to menu"
        return
    }

    Clear-Host

    # Build command exactly like the working manual command:
    # ollama launch claude --model <model> -- <claude-args>
    $cmdParts = @()
    if ($cfg.customCommand) {
        $cmdParts += $cfg.customCommand.Split(' ', [System.StringSplitOptions]::RemoveEmptyEntries)
    } else {
        $cmdParts += "ollama"
        $cmdParts += "launch"
        $cmdParts += "claude"
    }
    $cmdParts += "--model"
    $cmdParts += $model
    # Insert -- separator so everything after it is passed to claude, not ollama
    $cmdParts += "--"
    if ($cfg.skipPermissions) {
        $cmdParts += "--dangerously-skip-permissions"
    }

    $cmdString = $cmdParts -join ' '
    Write-Host "`n>>> $cmdString" -ForegroundColor Green
    Write-Host ("-" * 50) -ForegroundColor DarkGray

    Clear-Host
    try {
        $proc = Start-Process -FilePath $cmdParts[0] -ArgumentList $cmdParts[1..($cmdParts.Length-1)] -NoNewWindow -Wait -PassThru
        if ($proc.ExitCode -ne 0) {
            Write-Host "Claude Code exited with code $($proc.ExitCode)." -ForegroundColor Yellow
        }
    } catch {
        Write-Host "ERROR launching Claude: $_" -ForegroundColor Red
    }
    Read-Host "Claude Code session ended. Press Enter to return to menu"
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

# ============================================
# Status Display
# ============================================
function Show-Status {
    $cExists = Test-CommandExists "claude"
    $oExists = Test-CommandExists "ollama"
    $authOk  = Test-OllamaAuth
    $cfg     = Get-Config

    $claudeUpdate = $false
    $ollamaUpdate = $false
    $claudeInstalledVer = $null
    $ollamaInstalledVer = $null

    if ($cExists) {
        $claudeInstalledVer = Get-ClaudeInstalledVersion
        $claudeLatestVer = Get-ClaudeLatestVersion
        if ($claudeInstalledVer -and $claudeLatestVer) {
            $claudeUpdate = Compare-Versions $claudeInstalledVer $claudeLatestVer
        }
    }
    if ($oExists) {
        $ollamaInstalledVer = Get-OllamaInstalledVersion
        $ollamaLatestVer = Get-OllamaLatestVersion
        if ($ollamaInstalledVer -and $ollamaLatestVer) {
            $ollamaUpdate = Compare-Versions $ollamaInstalledVer $ollamaLatestVer
        }
    }

    Write-Host "`n========== Claude Code + Ollama Launcher ==========" -ForegroundColor Cyan
    if ($cExists) {
        if ($claudeUpdate) {
            Write-Host "  Claude Code   : v$claudeInstalledVer (update v$claudeLatestVer available)" -ForegroundColor Yellow
        } else {
            Write-Host "  Claude Code   : v$claudeInstalledVer (up to date)" -ForegroundColor Green
        }
    } else {
        Write-Host "  Claude Code   : NOT INSTALLED" -ForegroundColor Red
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
    if ($cfg.provider -eq "deepseek") {
        Write-Host "  DS Model      : $($cfg.deepseekModel)" -ForegroundColor Cyan
        $dsKeyStatus = if ($cfg.deepseekApiKey) { "**** (set)" } else { "(not set)" }
        Write-Host "  DS API Key    : $dsKeyStatus" -ForegroundColor Cyan
    }
    Write-Host "  Config model  : $($cfg.selectedModel) [source: $($cfg.source)]" -ForegroundColor Cyan
    $permText = if ($cfg.skipPermissions) { "ON (--dangerously-skip-permissions)" } else { "OFF" }
    Write-Host "  Skip-perms    : $permText" -ForegroundColor Cyan
    if ($cfg.customCommand) {
        Write-Host "  Custom Cmd    : $($cfg.customCommand)" -ForegroundColor Magenta
    }
    Write-Host "=====================================================" -ForegroundColor Cyan
}

# ============================================
# Main Menu
# ============================================
function Show-MainMenu {
    Show-Status
    $cExists = Test-CommandExists "claude"
    $oExists = Test-CommandExists "ollama"
    $cfg = Get-Config

    $claudeUpdate = $false
    $ollamaUpdate = $false
    if ($cExists) {
        $inst = Get-ClaudeInstalledVersion
        $lat  = Get-ClaudeLatestVersion
        if ($inst -and $lat) { $claudeUpdate = Compare-Versions $inst $lat }
    }
    if ($oExists) {
        $inst = Get-OllamaInstalledVersion
        $lat  = Get-OllamaLatestVersion
        if ($inst -and $lat) { $ollamaUpdate = Compare-Versions $inst $lat }
    }

    Write-Host "`n[1] Install / Update Claude Code" -ForegroundColor White
    if ($claudeUpdate) { Write-Host "     ^^ UPDATE AVAILABLE" -ForegroundColor Yellow }
    Write-Host "[2] Install / Update Ollama" -ForegroundColor White
    if ($ollamaUpdate) { Write-Host "     ^^ UPDATE AVAILABLE" -ForegroundColor Yellow }
    Write-Host "[3] Pick / Change Model  [current: $(if ($cfg.provider -eq "deepseek") { $cfg.deepseekModel } else { $cfg.selectedModel })]" -ForegroundColor White
    if ($cfg.source -eq "cloud" -and $oExists -and $cfg.provider -eq "ollama") {
        Write-Host "[4] Pull Selected Model Locally (ollama pull)" -ForegroundColor White
    } else {
        Write-Host "[4] Pull Selected Model Locally [not applicable]" -ForegroundColor DarkGray
    }
    $launchLabel = if ($cfg.provider -eq "deepseek") { "DeepSeek -> Claude" } else { "Ollama -> Claude" }
    Write-Host "[5] Launch Claude Code [$launchLabel]" -ForegroundColor Green
    Write-Host "[6] Check / Fix Ollama Sign-in" -ForegroundColor White
    Write-Host "[7] Refresh Status" -ForegroundColor White
    Write-Host "[8] Switch Provider [current: $($cfg.provider)]" -ForegroundColor White
    $cmdLabel = if ($cfg.customCommand) { "[custom: $($cfg.customCommand)]" } else { "[default: claude]" }
    Write-Host "[C] Set Custom Launch Command $cmdLabel" -ForegroundColor White
    $toggleLabel = if ($cfg.skipPermissions) { "ON -> switch to normal mode" } else { "OFF -> switch to skip-perms mode" }
    Write-Host "[T] Toggle Permission Bypass: $toggleLabel" -ForegroundColor White
    Write-Host "[Q] Quit" -ForegroundColor Magenta
    Write-Host ""
}

# ========== MAIN EXECUTION ==========

Ensure-ClaudeInPath

# --- Direct launch mode (arguments provided) ---
if ($args.Count -gt 0) {
    $launchArgs = $args
    if ($launchArgs[0] -eq "launch") {
        if ($launchArgs.Count -gt 1) { $launchArgs = $launchArgs[1..($launchArgs.Count-1)] } else { $launchArgs = @() }
    }

    if (-not (Test-CommandExists "claude")) {
        Write-Host "Claude Code not found. Installing..." -ForegroundColor Yellow
        Install-ClaudeCode
        if (-not (Test-CommandExists "claude")) {
            Write-Host "Failed to install Claude Code." -ForegroundColor Red
            exit 1
        }
    }

    $cfg = Get-Config

    if ($cfg.provider -eq "ollama") {
        if (-not (Test-CommandExists "ollama")) {
            Write-Host "Ollama not found. Installing..." -ForegroundColor Yellow
            Install-Ollama
        }
        if (-not (Start-OllamaServer)) { exit 1 }
    } else {
        if (-not $cfg.deepseekApiKey) {
            Write-Host "DeepSeek API key is not set. Run launcher menu to configure." -ForegroundColor Red
            exit 1
        }
        $env:OPENAI_API_KEY = $cfg.deepseekApiKey
        $env:OPENAI_BASE_URL = "https://api.deepseek.com/v1"
    }

    Clear-Host
    $hasModel = $false
    foreach ($a in $launchArgs) {
        if ($a -eq "--model" -or $a.StartsWith("--model=")) { $hasModel = $true }
    }
    $cmdParts = if ($cfg.provider -eq "deepseek") {
        $parts = @("claude")
        if (-not $hasModel) { $parts += "--model=$($cfg.deepseekModel)" }
        $parts
    } else {
        @("ollama", "launch", "claude", "--model", $cfg.selectedModel, "--")
    }
    if ($cfg.skipPermissions) { $cmdParts += "--dangerously-skip-permissions" }
    if ($cfg.customCommand -and $cfg.provider -ne "deepseek") {
        $cmdParts = $cfg.customCommand.Split(' ', [System.StringSplitOptions]::RemoveEmptyEntries)
        $cmdParts += "--model"
        $cmdParts += $cfg.selectedModel
        $cmdParts += "--"
        if ($cfg.skipPermissions) { $cmdParts += "--dangerously-skip-permissions" }
    }
    if ($launchArgs.Count -gt 0) { $cmdParts += $launchArgs }

    $cmdString = $cmdParts -join ' '
    Write-Host ">>> $cmdString $(if ($cfg.provider -eq 'deepseek') { '(DeepSeek API)' })" -ForegroundColor Green
    try {
        if ($cfg.provider -eq "deepseek") {
            $cmdArgs = $cmdParts[1..($cmdParts.Length-1)]
            & $cmdParts[0] @cmdArgs
        } else {
            $proc = Start-Process -FilePath $cmdParts[0] -ArgumentList $cmdParts[1..($cmdParts.Length-1)] -NoNewWindow -Wait -PassThru
        }
    } catch {
        Write-Host "ERROR: $_" -ForegroundColor Red
        exit 1
    }
    exit $LASTEXITCODE
}

while ($true) {
    Show-MainMenu
    $choice = Read-Host "Enter your choice"

    switch ($choice.ToLower()) {
        "1" {
            if (Test-CommandExists "claude") {
                $inst = Get-ClaudeInstalledVersion
                $lat  = Get-ClaudeLatestVersion
                $needsUpdate = Compare-Versions $inst $lat
                if ($needsUpdate) {
                    Write-Host "Claude Code update available: v$inst installed, v$lat available." -ForegroundColor Yellow
                    $confirm = Read-Host "Update Claude Code now? (y/n)"
                    if ($confirm -eq 'y') { Install-ClaudeCode }
                } else {
                    $confirm = Read-Host "Claude Code is up to date (v$inst). Reinstall anyway? (y/n)"
                    if ($confirm -eq 'y') { Install-ClaudeCode }
                }
            } else {
                $confirm = Read-Host "Install Claude Code now? (y/n)"
                if ($confirm -eq 'y') { Install-ClaudeCode }
            }
            Read-Host "Press Enter to return to menu"
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
            Read-Host "Press Enter to return to menu"
        }
        "3" {
            Show-ModelPicker
        }
        "4" {
            $cfg = Get-Config
            if ($cfg.source -eq "cloud" -and (Test-CommandExists "ollama")) {
                Pull-SelectedModel
            } else {
                Write-Host "Pull is only available when a cloud model is selected and Ollama is installed." -ForegroundColor Yellow
                Read-Host "Press Enter to continue"
            }
        }
        "5" {
            $cfg = Get-Config
            if (-not (Test-CommandExists "claude")) {
                Write-Host "ERROR: Claude Code is not installed. Please install it first (Menu option 1)." -ForegroundColor Red
                Read-Host "Press Enter to return to menu"
            } elseif ($cfg.provider -eq "ollama" -and -not (Test-CommandExists "ollama")) {
                Write-Host "ERROR: Ollama is not installed. Please install it first (Menu option 2)." -ForegroundColor Red
                Read-Host "Press Enter to return to menu"
            } else {
                Launch-ClaudeOllama
            }
        }
        "6" {
            Check-OllamaSignin
        }
        "7" {
            $cache = Get-VersionCache
            $cache.claudeLastChecked = ""
            $cache.ollamaLastChecked = ""
            Save-VersionCache $cache
            Write-Host "Version cache cleared." -ForegroundColor Green
            Start-Sleep -Seconds 1
        }
        "8" {
            Show-ProviderMenu
        }
        "c" {
            $cfg = Get-Config
            $current = $cfg.customCommand
            Write-Host "Current custom command: $(if ($current) { $current } else { '(empty = default claude)' })" -ForegroundColor Cyan
            $newCmd = Read-Host "Enter custom launch command (e.g. 'ollama launch claude'), or leave blank to reset to default"
            $cfg.customCommand = $newCmd.Trim()
            Save-Config $cfg
            Write-Host "Custom command updated." -ForegroundColor Green
            Start-Sleep -Seconds 1
        }
        "t" {
            $cfg = Get-Config
            $cfg.skipPermissions = -not $cfg.skipPermissions
            Save-Config $cfg
            $modeText = if ($cfg.skipPermissions) { "SKIP-PERMISSIONS" } else { "NORMAL" }
            Write-Host "Launch mode toggled to: $modeText" -ForegroundColor Green
            Start-Sleep -Seconds 1
        }
        "q" {
            Write-Host "Exiting launcher. Goodbye!" -ForegroundColor Green
            exit 0
        }
        default {
            Write-Host "Invalid choice. Please try again." -ForegroundColor Red
            Start-Sleep -Seconds 1
        }
    }
}
