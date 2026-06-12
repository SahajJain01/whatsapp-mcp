<#
.SYNOPSIS
  One-shot setup for the WhatsApp MCP server on Windows.

.DESCRIPTION
  Installs prerequisites (Go, MSYS2 + GCC, uv), builds the Go bridge with CGO,
  prepares the Python MCP server, registers a hidden auto-start scheduled task
  for the bridge, and wires the server into Claude Desktop's config.

  Designed to be idempotent: re-running skips anything already done.
  Works regardless of where the repo is cloned.

.NOTES
  Run from an elevated-or-normal PowerShell:
      powershell -ExecutionPolicy Bypass -File .\setup.ps1

  After it finishes, a window opens once to scan the WhatsApp QR code. After
  that the bridge runs hidden and auto-starts on every login.
#>

$ErrorActionPreference = "Stop"
$repo       = $PSScriptRoot
$bridgeDir  = Join-Path $repo "whatsapp-bridge"
$serverDir  = Join-Path $repo "whatsapp-mcp-server"
$taskName   = "WhatsAppBridge"

function Write-Step($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }
function Refresh-Path {
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("Path","User")
}

# ---------------------------------------------------------------------------
Write-Step "Checking winget"
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw "winget is required but not found. Install 'App Installer' from the Microsoft Store, then re-run."
}

# ---------------------------------------------------------------------------
Write-Step "Installing Go"
Refresh-Path
if (Get-Command go -ErrorAction SilentlyContinue) {
    Write-Host "Go already installed: $(go version)"
} else {
    winget install GoLang.Go --silent --accept-package-agreements --accept-source-agreements
    Refresh-Path
}

# ---------------------------------------------------------------------------
Write-Step "Installing MSYS2 + GCC (needed for CGO / go-sqlite3)"
$msys = "C:\msys64"
if (-not (Test-Path "$msys\usr\bin\bash.exe")) {
    winget install MSYS2.MSYS2 --silent --accept-package-agreements --accept-source-agreements
}
$gccPath = "$msys\ucrt64\bin\gcc.exe"
if (-not (Test-Path $gccPath)) {
    Write-Host "Installing GCC via pacman (this downloads ~70 MB)..."
    & "$msys\usr\bin\bash.exe" -l -c "pacman -Sy --noconfirm && pacman -S --noconfirm mingw-w64-ucrt-x86_64-gcc"
}
# Ensure ucrt64\bin is on the machine PATH
$machinePath = [System.Environment]::GetEnvironmentVariable("Path","Machine")
if ($machinePath -notlike "*$msys\ucrt64\bin*") {
    [System.Environment]::SetEnvironmentVariable("Path", "$machinePath;$msys\ucrt64\bin", "Machine")
    Write-Host "Added $msys\ucrt64\bin to system PATH"
}
Refresh-Path

# ---------------------------------------------------------------------------
Write-Step "Installing uv (Python package manager)"
Refresh-Path
if (Get-Command uv -ErrorAction SilentlyContinue) {
    Write-Host "uv already installed: $(uv --version)"
} else {
    powershell -ExecutionPolicy ByPass -c "irm https://astral.sh/uv/install.ps1 | iex"
    Refresh-Path
}
$uvExe = (Get-Command uv -ErrorAction SilentlyContinue).Source
if (-not $uvExe) { $uvExe = Join-Path $env:USERPROFILE ".local\bin\uv.exe" }

# ---------------------------------------------------------------------------
Write-Step "Building the WhatsApp bridge (CGO enabled)"
Refresh-Path
$env:CGO_ENABLED = "1"
go env -w CGO_ENABLED=1
Push-Location $bridgeDir
go build -o whatsapp-bridge.exe .
Pop-Location
Write-Host "Built $bridgeDir\whatsapp-bridge.exe"

# ---------------------------------------------------------------------------
Write-Step "Preparing the Python MCP server (uv sync)"
Push-Location $serverDir
& $uvExe sync
Pop-Location

# ---------------------------------------------------------------------------
Write-Step "Registering hidden auto-start task ($taskName)"
Get-Process whatsapp-bridge -ErrorAction SilentlyContinue | Stop-Process -Force
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
$vbs = Join-Path $bridgeDir "run-bridge-hidden.vbs"
$action    = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$vbs`""
$trigger   = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) `
                -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings `
    -Principal $principal -Description "Runs the WhatsApp MCP bridge hidden at login." | Out-Null
Write-Host "Task '$taskName' registered (runs hidden at every login)."

# ---------------------------------------------------------------------------
Write-Step "Wiring into Claude Desktop config"
$cfgPath = Join-Path $env:APPDATA "Claude\claude_desktop_config.json"
if (-not (Test-Path (Split-Path $cfgPath))) { New-Item -ItemType Directory -Path (Split-Path $cfgPath) | Out-Null }
if (Test-Path $cfgPath) {
    $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
} else {
    $cfg = [PSCustomObject]@{}
}
$whatsapp = [PSCustomObject]@{
    command = $uvExe
    args    = [string[]]@("--directory", $serverDir, "run", "main.py")
}
if ($cfg.PSObject.Properties.Name -contains "mcpServers") {
    $cfg.mcpServers | Add-Member -NotePropertyName "whatsapp" -NotePropertyValue $whatsapp -Force
} else {
    $cfg | Add-Member -NotePropertyName "mcpServers" -NotePropertyValue ([PSCustomObject]@{ whatsapp = $whatsapp }) -Force
}
$json = $cfg | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText($cfgPath, $json, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "Updated $cfgPath"
Write-Host "(Note: some Claude Desktop builds rewrite this file and may drop mcpServers; re-run this script if WhatsApp disappears.)" -ForegroundColor DarkYellow

# ---------------------------------------------------------------------------
Write-Step "First-time authentication"
$storeDb = Join-Path $bridgeDir "store\whatsapp.db"
if (Test-Path $storeDb) {
    Write-Host "Existing WhatsApp session found - starting bridge hidden, no QR needed."
    Start-ScheduledTask -TaskName $taskName
} else {
    Write-Host "No session yet. Opening a window to scan the QR code..." -ForegroundColor Yellow
    Start-Process powershell -ArgumentList '-NoExit','-ExecutionPolicy','Bypass','-File',(Join-Path $bridgeDir 'run-bridge.ps1')
    Write-Host "After you scan the QR and see 'Successfully connected', close that window," -ForegroundColor Yellow
    Write-Host "then run:  Start-ScheduledTask -TaskName $taskName   (or just log out and back in)" -ForegroundColor Yellow
}

Write-Step "Done"
Write-Host "Restart Claude Desktop, then try: 'search my WhatsApp contacts'." -ForegroundColor Green
