[CmdletBinding()]
param(
    [switch]$SkipModelDownload,
    [ValidateSet("Codex", "ClaudeDesktop", "OpenCode", "None")]
    [string[]]$McpClients
)

$ErrorActionPreference = "Stop"
$sourceRoot = [IO.Path]::GetFullPath($PSScriptRoot)
$installRoot = [IO.Path]::GetFullPath((Join-Path $env:USERPROFILE "mcp\whatsapp-mcp"))
$bridgeDir = Join-Path $installRoot "whatsapp-bridge"
$serverDir = Join-Path $installRoot "whatsapp-mcp-server"
$taskName = "WhatsAppMCPBridge"

function Write-Step([string]$Message) {
    Write-Host "`n=== $Message ===" -ForegroundColor Cyan
}

function Refresh-Path {
    $env:Path = @(
        [Environment]::GetEnvironmentVariable("Path", "Machine")
        [Environment]::GetEnvironmentVariable("Path", "User")
        "C:\msys64\ucrt64\bin"
        (Join-Path $env:USERPROFILE ".local\bin")
    ) -join ";"
}

function Install-WingetPackage(
    [string]$Id,
    [string]$Name,
    [switch]$UserScope
) {
    Write-Step "Installing $Name"
    $arguments = @(
        "install", "--id", $Id, "--exact", "--silent",
        "--accept-package-agreements", "--accept-source-agreements",
        "--disable-interactivity"
    )
    if ($UserScope) {
        $arguments += @("--scope", "user")
    }
    & winget @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "winget failed to install $Name (exit code $LASTEXITCODE)."
    }
}

function Resolve-Executable([string]$Name, [string[]]$FallbackPaths) {
    Refresh-Path
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }
    foreach ($candidate in $FallbackPaths) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }
    throw "$Name was installed but its executable could not be found."
}

function Read-JsonObject([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        return [PSCustomObject]@{}
    }
    try {
        return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    } catch {
        throw "Cannot update invalid JSON file: $Path"
    }
}

function Write-JsonObject([string]$Path, [PSCustomObject]$Value) {
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $json = $Value | ConvertTo-Json -Depth 20
    [IO.File]::WriteAllText($Path, $json, [Text.UTF8Encoding]::new($false))
}

function Select-McpClients {
    Write-Host "Which MCP clients should WhatsApp MCP configure?" -ForegroundColor Yellow
    Write-Host "  1. Codex"
    Write-Host "  2. Claude Desktop"
    Write-Host "  3. OpenCode"
    Write-Host "  4. None"

    while ($true) {
        $answer = Read-Host "Enter one or more numbers separated by commas [1]"
        if ([string]::IsNullOrWhiteSpace($answer)) {
            return [string[]]@("Codex")
        }

        $choices = @{
            "1" = "Codex"
            "2" = "ClaudeDesktop"
            "3" = "OpenCode"
            "4" = "None"
        }
        $selected = [Collections.Generic.List[string]]::new()
        $valid = $true
        foreach ($token in ($answer -split "[,\s]+" | Where-Object { $_ })) {
            if (-not $choices.ContainsKey($token)) {
                $valid = $false
                break
            }
            if (-not $selected.Contains($choices[$token])) {
                $selected.Add($choices[$token])
            }
        }

        if ($valid -and $selected.Count -gt 0 -and
            -not ($selected.Contains("None") -and $selected.Count -gt 1)) {
            return [string[]]$selected.ToArray()
        }
        Write-Warning "Choose 1, 2, 3, or 4. Multiple clients may be comma-separated; None must be selected alone."
    }
}

function Resolve-CodexCli {
    $candidates = [Collections.Generic.List[string]]::new()
    if ($env:CODEX_CLI_PATH) {
        $candidates.Add($env:CODEX_CLI_PATH)
    }

    $codexBinRoot = Join-Path $env:LOCALAPPDATA "OpenAI\Codex\bin"
    if (Test-Path -LiteralPath $codexBinRoot) {
        Get-ChildItem -LiteralPath $codexBinRoot -Filter "codex.exe" -Recurse -File |
            Sort-Object LastWriteTime -Descending |
            ForEach-Object { $candidates.Add($_.FullName) }
    }

    $package = Get-AppxPackage -Name "OpenAI.Codex" -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending |
        Select-Object -First 1
    if ($package) {
        $candidates.Add((Join-Path $package.InstallLocation "app\resources\codex.exe"))
    }

    $command = Get-Command "codex" -ErrorAction SilentlyContinue
    if ($command) {
        $candidates.Add($command.Source)
    }

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }
    throw "Codex was selected, but the Codex CLI could not be found. Install or open Codex and run setup again."
}

function Test-CodexMcpServer([string]$CodexExe, [string]$Name) {
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "SilentlyContinue"
        & $CodexExe mcp get $Name *> $null
        return $LASTEXITCODE -eq 0
    } finally {
        $ErrorActionPreference = $previousPreference
    }
}

function Remove-JsonMcpEntry([string]$Path, [string]$ContainerName) {
    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    $config = Read-JsonObject $Path
    if ($config.PSObject.Properties.Name -notcontains $ContainerName) {
        return
    }
    $container = $config.$ContainerName
    $container.PSObject.Properties.Remove("whatsapp")
    if (@($container.PSObject.Properties).Count -eq 0) {
        $config.PSObject.Properties.Remove($ContainerName)
    }
    Write-JsonObject -Path $Path -Value $config
}

if (-not $PSBoundParameters.ContainsKey("McpClients")) {
    $McpClients = Select-McpClients
}
$selectedClients = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($client in $McpClients) {
    [void]$selectedClients.Add($client)
}

Write-Step "Checking Windows package manager"
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw "winget is required. Install App Installer from Microsoft Store and run setup again."
}

if (-not (Get-Command go -ErrorAction SilentlyContinue) -and
    -not (Test-Path -LiteralPath "C:\Program Files\Go\bin\go.exe")) {
    Install-WingetPackage -Id "GoLang.Go" -Name "Go"
}

if (-not (Test-Path -LiteralPath "C:\msys64\usr\bin\bash.exe")) {
    Install-WingetPackage -Id "MSYS2.MSYS2" -Name "MSYS2"
}

$bashExe = "C:\msys64\usr\bin\bash.exe"
if (-not (Test-Path -LiteralPath "C:\msys64\ucrt64\bin\gcc.exe")) {
    Write-Step "Installing GCC for the SQLite bridge"
    & $bashExe -lc "pacman-key --init && pacman-key --populate msys2"
    & $bashExe -lc "pacman -Sy --noconfirm msys2-keyring"
    & $bashExe -lc "test -f /var/lib/pacman/db.lck && rm -f /var/lib/pacman/db.lck; pacman -S --needed --noconfirm mingw-w64-ucrt-x86_64-gcc"
    if ($LASTEXITCODE -ne 0) {
        throw "MSYS2 failed to install GCC (exit code $LASTEXITCODE)."
    }
}

if (-not (Get-Command uv -ErrorAction SilentlyContinue) -and
    -not (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Links\uv.exe"))) {
    Install-WingetPackage -Id "astral-sh.uv" -Name "uv" -UserScope
}

if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue) -and
    -not (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Links\ffmpeg.exe"))) {
    Install-WingetPackage -Id "Gyan.FFmpeg" -Name "FFmpeg" -UserScope
}

$goExe = Resolve-Executable -Name "go" -FallbackPaths @("C:\Program Files\Go\bin\go.exe")
$uvExe = Resolve-Executable -Name "uv" -FallbackPaths @(
    (Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Links\uv.exe"),
    (Join-Path $env:USERPROFILE ".local\bin\uv.exe")
)

Write-Step "Installing application files to $installRoot"
if (-not $sourceRoot.Equals($installRoot, [StringComparison]::OrdinalIgnoreCase)) {
    New-Item -ItemType Directory -Path $installRoot -Force | Out-Null
    $excludedDirectories = @(
        (Join-Path $sourceRoot ".git"),
        (Join-Path $sourceRoot ".venv"),
        (Join-Path $sourceRoot "whatsapp-mcp-server\.venv"),
        (Join-Path $sourceRoot "whatsapp-bridge\store")
    )
    & robocopy $sourceRoot $installRoot /E /R:2 /W:1 /NFL /NDL /NJH /NJS /NP `
        /XD $excludedDirectories /XF ".debug-journal.md" "*.pyc" "whatsapp-bridge.exe"
    if ($LASTEXITCODE -ge 8) {
        throw "Failed to copy application files (robocopy exit code $LASTEXITCODE)."
    }
}

Write-Step "Building the WhatsApp bridge"
$env:CGO_ENABLED = "1"
$env:Path = "C:\msys64\ucrt64\bin;$env:Path"
Push-Location $bridgeDir
try {
    & $goExe build -o "whatsapp-bridge.exe" .
    if ($LASTEXITCODE -ne 0) {
        throw "Go bridge build failed (exit code $LASTEXITCODE)."
    }
} finally {
    Pop-Location
}

Write-Step "Installing Python and speech-to-text dependencies"
& $uvExe --directory $serverDir sync
if ($LASTEXITCODE -ne 0) {
    throw "uv sync failed (exit code $LASTEXITCODE)."
}

if (-not $SkipModelDownload) {
    Write-Step "Downloading the local Whisper large-v3 model"
    & $uvExe --directory $serverDir run python -c "from huggingface_hub import snapshot_download; snapshot_download('Systran/faster-whisper-large-v3')"
    if ($LASTEXITCODE -ne 0) {
        throw "The large-v3 model could not be prepared (exit code $LASTEXITCODE)."
    }
}

$sessionDb = Join-Path $bridgeDir "store\whatsapp.db"
if (-not (Test-Path -LiteralPath $sessionDb)) {
    Write-Step "Linking WhatsApp"
    $runner = Join-Path $bridgeDir "run-bridge.ps1"
    Start-Process powershell.exe -WindowStyle Normal -ArgumentList @(
        "-NoProfile", "-NoExit", "-ExecutionPolicy", "Bypass", "-File", "`"$runner`""
    )
    Write-Host "Scan the QR code in the new window. After it says Successfully connected, press Enter here." -ForegroundColor Yellow
    Read-Host | Out-Null
    Get-Process "whatsapp-bridge" -ErrorAction SilentlyContinue | Stop-Process -Force
}

Write-Step "Registering the persistent bridge task"
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
$hiddenLauncher = Join-Path $bridgeDir "run-bridge-hidden.vbs"
$action = New-ScheduledTaskAction -Execute "wscript.exe" -Argument (
    "//B //NoLogo `"$hiddenLauncher`""
)
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries -StartWhenAvailable `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
    -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
    -Settings $settings -Principal $principal `
    -Description "Keeps the WhatsApp MCP bridge running for the signed-in user." | Out-Null
Start-ScheduledTask -TaskName $taskName

Write-Step "Configuring MCP clients"
$claudePath = Join-Path $env:APPDATA "Claude\claude_desktop_config.json"
if ($selectedClients.Contains("ClaudeDesktop")) {
    $claude = Read-JsonObject $claudePath
    $claudeServer = [PSCustomObject]@{
        command = $uvExe
        args = [string[]]@("--directory", $serverDir, "run", "main.py")
    }
    if ($claude.PSObject.Properties.Name -contains "mcpServers") {
        $claude.mcpServers | Add-Member -NotePropertyName "whatsapp" -NotePropertyValue $claudeServer -Force
    } else {
        $claude | Add-Member -NotePropertyName "mcpServers" -NotePropertyValue ([PSCustomObject]@{ whatsapp = $claudeServer })
    }
    Write-JsonObject -Path $claudePath -Value $claude
} else {
    Remove-JsonMcpEntry -Path $claudePath -ContainerName "mcpServers"
}

$opencodePath = Join-Path $env:USERPROFILE ".config\opencode\opencode.json"
if ($selectedClients.Contains("OpenCode")) {
    $opencode = Read-JsonObject $opencodePath
    $opencodeServer = [PSCustomObject]@{
        type = "local"
        command = [string[]]@($uvExe, "run", "main.py")
        cwd = $serverDir
        enabled = $true
    }
    if ($opencode.PSObject.Properties.Name -contains "mcp") {
        $opencode.mcp | Add-Member -NotePropertyName "whatsapp" -NotePropertyValue $opencodeServer -Force
    } else {
        $opencode | Add-Member -NotePropertyName "mcp" -NotePropertyValue ([PSCustomObject]@{ whatsapp = $opencodeServer })
    }
    Write-JsonObject -Path $opencodePath -Value $opencode
} else {
    Remove-JsonMcpEntry -Path $opencodePath -ContainerName "mcp"
}

$codexExe = $null
if ($selectedClients.Contains("Codex")) {
    $codexExe = Resolve-CodexCli
} else {
    try {
        $codexExe = Resolve-CodexCli
    } catch {
        $codexExe = $null
    }
}
if ($codexExe) {
    if (Test-CodexMcpServer -CodexExe $codexExe -Name "whatsapp") {
        & $codexExe mcp remove whatsapp
        if ($LASTEXITCODE -ne 0) {
            throw "Codex could not remove the previous WhatsApp MCP configuration."
        }
    }
    if ($selectedClients.Contains("Codex")) {
        & $codexExe mcp add whatsapp -- $uvExe --directory $serverDir run main.py
        if ($LASTEXITCODE -ne 0) {
            throw "Codex could not register WhatsApp MCP."
        }
    }
}

Write-Step "Registering Windows uninstaller"
$uninstallScript = Join-Path $bridgeDir "uninstall.ps1"
$uninstallKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\WhatsAppMCP"
New-Item -Path $uninstallKey -Force | Out-Null
$uninstallCommand = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$uninstallScript`""
New-ItemProperty -Path $uninstallKey -Name "DisplayName" -Value "WhatsApp MCP" -PropertyType String -Force | Out-Null
New-ItemProperty -Path $uninstallKey -Name "DisplayVersion" -Value "0.1.0" -PropertyType String -Force | Out-Null
New-ItemProperty -Path $uninstallKey -Name "Publisher" -Value "WhatsApp MCP" -PropertyType String -Force | Out-Null
New-ItemProperty -Path $uninstallKey -Name "InstallLocation" -Value $installRoot -PropertyType String -Force | Out-Null
New-ItemProperty -Path $uninstallKey -Name "DisplayIcon" -Value (Join-Path $bridgeDir "whatsapp-bridge.exe") -PropertyType String -Force | Out-Null
New-ItemProperty -Path $uninstallKey -Name "UninstallString" -Value $uninstallCommand -PropertyType String -Force | Out-Null
New-ItemProperty -Path $uninstallKey -Name "QuietUninstallString" -Value "$uninstallCommand -Quiet" -PropertyType String -Force | Out-Null
New-ItemProperty -Path $uninstallKey -Name "NoModify" -Value 1 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $uninstallKey -Name "NoRepair" -Value 1 -PropertyType DWord -Force | Out-Null

Write-Step "Installation complete"
Write-Host "Installed at: $installRoot" -ForegroundColor Green
Write-Host "The bridge is supervised now and will start again after every Windows sign-in." -ForegroundColor Green
$configuredNames = $McpClients -join ", "
Write-Host "Configured MCP clients: $configuredNames" -ForegroundColor Green
Write-Host "Restart the selected MCP clients to load the server." -ForegroundColor Green
