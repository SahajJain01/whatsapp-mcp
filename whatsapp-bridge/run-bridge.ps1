$env:CGO_ENABLED = "1"
Set-Location -Path $PSScriptRoot
Write-Host "=== WhatsApp Bridge ===" -ForegroundColor Green
Write-Host "Wait ~15 seconds for the QR code to appear below." -ForegroundColor Yellow
Write-Host "Then scan it in WhatsApp: Settings -> Linked Devices -> Link a Device." -ForegroundColor Yellow
Write-Host "KEEP THIS WINDOW OPEN while you use the WhatsApp MCP." -ForegroundColor Yellow
Write-Host ""
& "$PSScriptRoot\whatsapp-bridge.exe"
Write-Host ""
Write-Host "Bridge exited. Press Enter to close." -ForegroundColor Red
Read-Host
