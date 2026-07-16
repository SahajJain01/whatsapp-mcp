[CmdletBinding()]
param(
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"
$taskName = "WhatsAppMCPBridge"
$installRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$expectedRoot = [IO.Path]::GetFullPath((Join-Path $env:USERPROFILE "mcp\whatsapp-mcp"))

if (-not $installRoot.Equals($expectedRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to uninstall from unexpected location: $installRoot"
}

if (-not $Quiet) {
    $confirmation = Read-Host "Remove WhatsApp MCP and all locally cached messages/transcripts? Type YES to continue"
    if ($confirmation -cne "YES") {
        Write-Host "Uninstall cancelled."
        exit 0
    }
}

Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
Get-CimInstance Win32_Process -Filter "Name = 'whatsapp-bridge.exe'" |
    Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($installRoot, [StringComparison]::OrdinalIgnoreCase) } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

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
    return $null
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

$codexExe = Resolve-CodexCli
if ($codexExe) {
    if (Test-CodexMcpServer -CodexExe $codexExe -Name "whatsapp") {
        & $codexExe mcp remove whatsapp
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Codex config could not be updated."
        }
    }
}

$claudePath = Join-Path $env:APPDATA "Claude\claude_desktop_config.json"
if (Test-Path -LiteralPath $claudePath) {
    try {
        $claude = Get-Content -LiteralPath $claudePath -Raw | ConvertFrom-Json
        if ($claude.PSObject.Properties.Name -contains "mcpServers") {
            $claude.mcpServers.PSObject.Properties.Remove("whatsapp")
            if (@($claude.mcpServers.PSObject.Properties).Count -eq 0) {
                $claude.PSObject.Properties.Remove("mcpServers")
            }
            $json = $claude | ConvertTo-Json -Depth 20
            [IO.File]::WriteAllText($claudePath, $json, [Text.UTF8Encoding]::new($false))
        }
    } catch {
        Write-Warning "Claude config could not be updated: $($_.Exception.Message)"
    }
}

$opencodePath = Join-Path $env:USERPROFILE ".config\opencode\opencode.json"
if (Test-Path -LiteralPath $opencodePath) {
    try {
        $opencode = Get-Content -LiteralPath $opencodePath -Raw | ConvertFrom-Json
        if ($opencode.PSObject.Properties.Name -contains "mcp") {
            $opencode.mcp.PSObject.Properties.Remove("whatsapp")
            if (@($opencode.mcp.PSObject.Properties).Count -eq 0) {
                $opencode.PSObject.Properties.Remove("mcp")
            }
            $json = $opencode | ConvertTo-Json -Depth 20
            [IO.File]::WriteAllText($opencodePath, $json, [Text.UTF8Encoding]::new($false))
        }
    } catch {
        Write-Warning "opencode config could not be updated: $($_.Exception.Message)"
    }
}

Remove-Item -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\WhatsAppMCP" `
    -Recurse -Force -ErrorAction SilentlyContinue

$escapedRoot = $installRoot.Replace("'", "''")
$cleanupCommand = "Start-Sleep -Seconds 2; Remove-Item -LiteralPath '$escapedRoot' -Recurse -Force"
$encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cleanupCommand))
Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @(
    "-NoProfile", "-WindowStyle", "Hidden", "-EncodedCommand", $encodedCommand
)

if (-not $Quiet) {
    Write-Host "WhatsApp MCP was removed."
}
