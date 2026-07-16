$ErrorActionPreference = "Stop"
$bridgeDir = $PSScriptRoot
$binary = Join-Path $bridgeDir "whatsapp-bridge.exe"

Set-Location $bridgeDir
while ($true) {
    if (-not (Test-Path -LiteralPath $binary)) {
        exit 1
    }
    $process = Start-Process -FilePath $binary -WorkingDirectory $bridgeDir `
        -WindowStyle Hidden -PassThru -Wait
    if ($process.ExitCode -eq 0) {
        Start-Sleep -Seconds 2
    } else {
        Start-Sleep -Seconds 5
    }
}
