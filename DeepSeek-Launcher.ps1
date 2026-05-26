#Requires -Version 5.1
<#
.SYNOPSIS
    DeepSeek CLI Launcher — Codex CLI + Claude Code + Codex App through DeepSeek API
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
$script:BaseDir      = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "cli-launchers"
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

function Test-ClaudeDesktopInstalled {
    $null -ne (Get-StartApps 2>$null | Where-Object { $_.AppID -like "*Claude*" -and $_.AppID -like "*!Claude" })
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

    $cmdParts = @("codex", "-c", "model_reasoning_effort=high")
    if ($cfg.skipPermissions) { $cmdParts += "--yolo" }
    $cmdString = $cmdParts -join ' '
    Write-Host "`n>>> $cmdString (DeepSeek: $($cfg.deepseekModel))" -ForegroundColor Green
    Write-Host ("-" * 50) -ForegroundColor DarkGray
    try {
        $cmdPath = (Get-Command $cmdParts[0] -ErrorAction Stop).Source
        $cmdArgs = $cmdParts[1..($cmdParts.Length-1)]
        Start-Process -FilePath $cmdPath -ArgumentList $cmdArgs
        Write-Host "Launched in new window." -ForegroundColor Cyan
    } catch { Write-Host "ERROR: $_" -ForegroundColor Red }
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
    try {
        $cmdPath = (Get-Command $cmdParts[0] -ErrorAction Stop).Source
        $cmdArgs = $cmdParts[1..($cmdParts.Length-1)]
        Start-Process -FilePath $cmdPath -ArgumentList $cmdArgs
        Write-Host "Launched in new window." -ForegroundColor Cyan
    } catch { Write-Host "ERROR: $_" -ForegroundColor Red }
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

    # Use -c overrides (highest precedence in Codex config) so we don't
    # need to touch any config files or fight with cached ollama state.
    $env:DEEPSEEK_API_KEY = $cfg.deepseekApiKey

    $cmdParts = @(
        "codex", "app",
        "-c", "model_provider=deepseek",
        "-c", "model=$($cfg.deepseekModel)",
        "-c", "model_reasoning_effort=high",
        "-c", "wire_api=chat"
    )
    $cmdString = $cmdParts -join ' '
    Write-Host "`n>>> $cmdString (DeepSeek: $($cfg.deepseekModel))" -ForegroundColor Green
    Write-Host ("-" * 50) -ForegroundColor DarkGray
    try {
        $cmdPath = (Get-Command $cmdParts[0] -ErrorAction Stop).Source
        $cmdArgs = $cmdParts[1..($cmdParts.Length-1)]
        Start-Process -FilePath $cmdPath -ArgumentList $cmdArgs
        Write-Host "Launched in new window." -ForegroundColor Cyan
    } catch { Write-Host "ERROR: $_" -ForegroundColor Red }
}

function Write-ClaudeDesktop3pConfig {
    param([string]$ApiKey, [string]$DeepSeekModel)

    # Map DeepSeek model to a Claude model name that passes the whitelist.
    # DeepSeek's /anthropic endpoint auto-maps:
    #   claude-opus*              -> deepseek-v4-pro
    #   claude-sonnet* / haiku*   -> deepseek-v4-flash
    $claudeModel = switch -Wildcard ($DeepSeekModel) {
        "deepseek-v4-pro*"   { "claude-opus-4-7" }
        "deepseek-v4-flash*"  { "claude-sonnet-4-6" }
        default               { "claude-sonnet-4-6" }
    }

    # Build model list with labelOverride so Claude Desktop's model picker
    # shows the actual DeepSeek model each Claude name maps to:
    #   Opus 4.7 / 4.6 → DeepSeek V4 Pro
    #   Sonnet 4.6 / Haiku 4.5 → DeepSeek V4 Flash
    $modelDefs = @(
        @{ name = "claude-opus-4-7";          label = "DeepSeek V4 Pro (Opus 4.7)" }
        @{ name = "claude-opus-4-6";          label = "DeepSeek V4 Pro (Opus 4.6)" }
        @{ name = "claude-sonnet-4-6";        label = "DeepSeek V4 Flash (Sonnet 4.6)" }
        @{ name = "claude-haiku-4-5-20251001"; label = "DeepSeek V4 Flash (Haiku 4.5)" }
    )
    # Ensure the user's preferred model is first (default in the picker)
    $orderedNames = @($claudeModel) + ($modelDefs | ForEach-Object { $_.name } | Where-Object { $_ -ne $claudeModel })
    $seen = @{}
    $allModels = @($orderedNames | Where-Object { -not $seen.ContainsKey($_) ; $seen[$_] = $true } | ForEach-Object {
        $name = $_
        $def = $modelDefs | Where-Object { $_.name -eq $name } | Select-Object -First 1
        if ($def) {
            @{ name = $def.name; labelOverride = $def.label }
        } else {
            @{ name = $name }
        }
    })

    $gatewayConfig = [ordered]@{
        inferenceProvider          = "gateway"
        inferenceGatewayBaseUrl    = "https://api.deepseek.com/anthropic"
        inferenceGatewayApiKey     = $ApiKey
        inferenceGatewayAuthScheme = "bearer"
        inferenceModels            = $allModels
        disableEssentialTelemetry    = $true
        disableNonessentialTelemetry = $true
        disableNonessentialServices  = $true
        unstableDisableModelVerification = $true
        builtinToolPolicy = [ordered]@{
            Bash              = "allow"
            Read              = "allow"
            Write             = "allow"
            Edit              = "allow"
            Glob              = "allow"
            Grep              = "allow"
            NotebookEdit      = "allow"
            WebFetch          = "allow"
            WebSearch         = "allow"
            Task              = "allow"
            TaskCreate        = "allow"
            TaskUpdate        = "allow"
            TaskGet           = "allow"
            TaskList          = "allow"
            TaskStop          = "allow"
            Skill             = "allow"
            AskUserQuestion   = "allow"
            SendUserMessage   = "allow"
        }
        permissions = [ordered]@{
            defaultMode = "bypassPermissions"
        }
    }

    $roaming = [Environment]::GetFolderPath("ApplicationData")
    $local   = [Environment]::GetFolderPath("LocalApplicationData")
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false

    # ================================================================
    # Approach 1: configLibrary (primary — what modern Claude Desktop reads)
    #   %LOCALAPPDATA%\Claude-3p\configLibrary\_meta.json
    #   %LOCALAPPDATA%\Claude-3p\configLibrary\{uuid}.json
    # ================================================================
    $configId = [Guid]::NewGuid().ToString()
    $libPaths = @(
        (Join-Path $local "Claude-3p\configLibrary")
        (Join-Path $local "Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude-3p\configLibrary")
    )
    foreach ($libDir in $libPaths) {
        if (-not (Test-Path $libDir)) { New-Item -ItemType Directory -Force -Path $libDir | Out-Null }

        # Clean up old UUID config files from previous runs
        Get-ChildItem $libDir -Filter "*.json" -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -ne "_meta.json" -and $_.Name -ne "$configId.json"
        } | Remove-Item -Force

        $metaPath = Join-Path $libDir "_meta.json"
        $meta = [ordered]@{
            appliedId = $configId
            entries   = @(@{ id = $configId; name = "DeepSeek Gateway" })
        }
        [System.IO.File]::WriteAllText($metaPath, ($meta | ConvertTo-Json -Depth 3), $utf8NoBom)

        $configPath = Join-Path $libDir "$configId.json"
        [System.IO.File]::WriteAllText($configPath, ($gatewayConfig | ConvertTo-Json -Depth 5), $utf8NoBom)
    }

    # ================================================================
    # Approach 2: claude_desktop_config.json (legacy / broader compat)
    #   Merge deploymentMode=3p + enterpriseConfig into existing files
    # ================================================================
    $enterpriseConfig = [ordered]@{}
    foreach ($key in $gatewayConfig.Keys) {
        if ($key -ne "unstableDisableModelVerification") {
            $enterpriseConfig[$key] = $gatewayConfig[$key]
        }
    }

    $config3p = [ordered]@{
        deploymentMode = "3p"
        enterpriseConfig = $enterpriseConfig
        preferences = [ordered]@{
            secureVmFeaturesEnabled     = $true
            coworkScheduledTasksEnabled = $true
            ccdScheduledTasksEnabled    = $true
            sidebarMode                 = "epitaxy"
            coworkWebSearchEnabled      = $true
        }
    }
    $json3p = $config3p | ConvertTo-Json -Depth 5

    $paths3p = @(
        (Join-Path $local "Claude-3p\claude_desktop_config.json")
        (Join-Path $local "Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude-3p\claude_desktop_config.json")
        (Join-Path $roaming "Claude-3p\claude_desktop_config.json")
    )
    foreach ($p in $paths3p) {
        $dir = Split-Path $p -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        [System.IO.File]::WriteAllText($p, $json3p, $utf8NoBom)
    }

    # Merge into main Claude config (preserve the Desktop's own keys)
    $mainPaths = @(
        (Join-Path $local "Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude\claude_desktop_config.json")
        (Join-Path $local "Claude\claude_desktop_config.json")
        (Join-Path $roaming "Claude\claude_desktop_config.json")
    )
    foreach ($p in $mainPaths) {
        $dir = Split-Path $p -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

        $existing = $null
        if (Test-Path $p) {
            try { $existing = Get-Content $p -Raw | ConvertFrom-Json } catch { }
        }
        if (-not $existing) { $existing = New-Object PSObject }

        $existing | Add-Member -NotePropertyName "deploymentMode" -NotePropertyValue "3p" -Force
        $existing | Add-Member -NotePropertyName "enterpriseConfig" -NotePropertyValue $enterpriseConfig -Force

        if (-not ($existing.PSObject.Properties.Name -contains "preferences")) {
            $existing | Add-Member -NotePropertyName "preferences" -NotePropertyValue ([ordered]@{}) -Force
        }

        $merged = $existing | ConvertTo-Json -Depth 6
        [System.IO.File]::WriteAllText($p, $merged, $utf8NoBom)
    }

    Write-Host "  Wrote 3p config (configLibrary + claude_desktop_config.json)" -ForegroundColor DarkGray
}

function Clear-ClaudeDesktopSession {
    # Remove active OAuth session so Claude Desktop reads the 3p config
    # instead of auto-logging into an existing Anthropic account.
    $local   = [Environment]::GetFolderPath("LocalApplicationData")
    $base    = Join-Path $local "Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude"

    Write-Host "Clearing any existing Claude Desktop session..." -ForegroundColor DarkGray

    # Clear OAuth token from config.json (the main auth session)
    $cfgPath = Join-Path $base "config.json"
    if (Test-Path $cfgPath) {
        try {
            $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
            $changed = $false
            # Clear all known auth-related keys
            $keysToClear = @("oauth:tokenCache", "oauth:refreshToken", "oauth:accountId",
                             "oauth:accessToken", "oauth:expiresAt", "oauth:token",
                             "activeAccountId", "activeOrgId", "authSession",
                             "lastSignedInAccount", "oauthTokens")
            foreach ($key in $keysToClear) {
                if ($cfg.PSObject.Properties[$key]) {
                    $cfg.PSObject.Properties.Remove($key)
                    $changed = $true
                }
            }
            if ($changed) {
                $cleaned = $cfg | ConvertTo-Json -Depth 5
                $utf8NoBom = New-Object System.Text.UTF8Encoding $false
                [System.IO.File]::WriteAllText($cfgPath, $cleaned, $utf8NoBom)
                Write-Host "  Cleared OAuth session from config.json" -ForegroundColor DarkGray
            }
        } catch { }
    }

    # Remove cowork-enabled-cli-ops (tied to the signed-in account)
    $coworkPath = Join-Path $base "cowork-enabled-cli-ops.json"
    if (Test-Path $coworkPath) {
        Remove-Item $coworkPath -Force
        Write-Host "  Removed cowork session file" -ForegroundColor DarkGray
    }

    # Remove ant-did (anonymous device ID that may link to prior session)
    $antDidPath = Join-Path $base "ant-did"
    if (Test-Path $antDidPath) {
        Remove-Item $antDidPath -Force
        Write-Host "  Removed device identity file" -ForegroundColor DarkGray
    }

    # Write bypass permission mode into the Desktop's own config.json
    # so the embedded Claude Code starts in bypassPermissions mode
    if (-not (Test-Path $cfgPath)) {
        $cfg = New-Object PSObject
    } else {
        try { $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json } catch { $cfg = New-Object PSObject }
    }
    if (-not ($cfg.PSObject.Properties.Name -contains "allowBypassPermissionsMode")) {
        $cfg | Add-Member -NotePropertyName "permissionMode" -NotePropertyValue "bypassPermissions" -Force
        $cfg | Add-Member -NotePropertyName "allowBypassPermissionsMode" -NotePropertyValue $true -Force
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($cfgPath, ($cfg | ConvertTo-Json -Depth 3), $utf8NoBom)
        Write-Host "  Set permission mode to bypass" -ForegroundColor DarkGray
    }
}

function Enable-ClaudeDeveloperMode {
    # Create developer_settings.json so the Developer menu + 3p inference appear
    # without the user having to enable it manually via Help -> Troubleshooting.
    $paths = @(
        (Join-Path ([Environment]::GetFolderPath("LocalApplicationData")) "Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude\developer_settings.json")
        (Join-Path ([Environment]::GetFolderPath("LocalApplicationData")) "Claude\developer_settings.json")
        (Join-Path ([Environment]::GetFolderPath("ApplicationData")) "Claude\developer_settings.json")
    )
    $json = '{"allowDevTools":true}'
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    foreach ($p in $paths) {
        $dir = Split-Path $p -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        [System.IO.File]::WriteAllText($p, $json, $utf8NoBom)
    }
}

function Launch-ClaudeDesktop {
    if (-not (Require-ApiKey)) { return }
    $cfg = Get-Config

    # Kill any running Claude Desktop (GUI only, not CLI) so it starts fresh with the new config
    Write-Host "`nPreparing Claude Desktop for third-party mode..." -ForegroundColor Cyan
    $claudeDesktopProcs = Get-Process -Name "Claude" -ErrorAction SilentlyContinue | Where-Object {
        $_.MainWindowHandle -ne 0
    }
    if ($claudeDesktopProcs) {
        Write-Host "  Stopping running Claude Desktop..." -ForegroundColor DarkGray
        $claudeDesktopProcs | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }

    Clear-ClaudeDesktopSession
    Enable-ClaudeDeveloperMode
    Write-ClaudeDesktop3pConfig -ApiKey $cfg.deepseekApiKey -DeepSeekModel $cfg.deepseekModel

    Write-Host ("-" * 50) -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Yellow
    Write-Host "  Developer Mode + 3p config applied automatically" -ForegroundColor Green
    Write-Host "============================================================" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  If the app asks you to sign in:" -ForegroundColor Cyan
    Write-Host "    -> Click 'Continue with Gateway' on the sign-in screen" -ForegroundColor White
    Write-Host ""
    Write-Host "  If you don't see the Gateway option:" -ForegroundColor Cyan
    Write-Host "    Help -> Troubleshooting -> Enable Developer Mode" -ForegroundColor White
    Write-Host ""
    Write-Host "  To enable Bypass Permissions (auto-approve all tools):" -ForegroundColor Cyan
    Write-Host "    1. Click your avatar (bottom-left) -> Settings" -ForegroundColor White
    Write-Host "    2. Select 'Claude Code' in the sidebar" -ForegroundColor White
    Write-Host "    3. Turn ON 'Allow bypass permissions mode'" -ForegroundColor White
    Write-Host "    4. Start a NEW chat, then select Bypass from" -ForegroundColor White
    Write-Host "       the permission mode dropdown next to the chat input" -ForegroundColor White
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Launching Claude Code Desktop..." -ForegroundColor Green
    try {
        Start-Process "shell:appsFolder\Claude_pzs8sxrjxfjjc!Claude"
    } catch {
        Write-Host "ERROR: Could not launch Claude Desktop." -ForegroundColor Red
        Write-Host "Install from: https://claude.ai/download" -ForegroundColor Yellow
    }
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
    $cDesktop = Test-ClaudeDesktopInstalled
    if ($cDesktop) {
        Write-Host "  Claude Desktop : INSTALLED" -ForegroundColor Green
    } else {
        Write-Host "  Claude Desktop : NOT INSTALLED" -ForegroundColor DarkGray
    }
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
        Write-Host "[6] Launch Claude Code CLI (via DeepSeek)" -ForegroundColor Green
    } else {
        $reason = if (-not $cfg.deepseekApiKey) { "API key not set" } else { "Claude Code not installed" }
        Write-Host "[6] Launch Claude Code CLI [$reason]" -ForegroundColor DarkGray
    }
    if ($cCodex -and $cfg.deepseekApiKey) {
        Write-Host "[7] Launch Codex App (via DeepSeek)" -ForegroundColor Green
    } else {
        $reason = if (-not $cfg.deepseekApiKey) { "API key not set" } else { "Codex CLI not installed" }
        Write-Host "[7] Launch Codex App [$reason]" -ForegroundColor DarkGray
    }
    $cDesktop = Test-ClaudeDesktopInstalled
    if ($cDesktop -and $cfg.deepseekApiKey) {
        Write-Host "[8] Launch Claude Code Desktop (via DeepSeek)" -ForegroundColor Green
    } else {
        $reason = if (-not $cfg.deepseekApiKey) { "API key not set" } else { "Claude Desktop not installed" }
        Write-Host "[8] Launch Claude Desktop [$reason]" -ForegroundColor DarkGray
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
        "codex"           { Launch-CodexCLI; exit $LASTEXITCODE }
        "claude"          { Launch-ClaudeCode; exit $LASTEXITCODE }
        "codex-app"       { Launch-CodexApp; exit $LASTEXITCODE }
        "claude-desktop"  { Launch-ClaudeDesktop; exit $LASTEXITCODE }
        default {
            Write-Host "Usage: DeepSeek-Launcher.bat [codex|claude|codex-app|claude-desktop]"
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
        "8" {
            if (-not $cfg.deepseekApiKey) {
                Write-Host "API key not set. Use option 4 first." -ForegroundColor Red
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
            Write-Host "Mode: $text" -ForegroundColor Green; Start-Sleep -Seconds 1
        }
        "q" { Write-Host "Goodbye!" -ForegroundColor Green; exit 0 }
        default { Write-Host "Invalid choice." -ForegroundColor Red; Start-Sleep -Seconds 1 }
    }
}
