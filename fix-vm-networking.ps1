<#
.SYNOPSIS
  Fixes broken TLS/HTTP-2 connectivity on KVM/QEMU (VirtIO) Windows VMs.

.DESCRIPTION
  On some VirtIO-backed VMs the host mishandles TCP segmentation offload, so
  the first/large TLS handshakes are silently dropped: HTTPS hangs ~15s,
  HTTP/2 black-holes, the Microsoft Store gets stuck on "checking
  dependencies", `gh`/Go apps time out -- while ping and small requests work.

  This disables NIC hardware offloads and a few TCP features that trigger the
  bug. It is system-wide (fixes ALL apps), persistent across reboots, and
  reversible (see the bottom of this file). Must be run as Administrator.

  After running, the per-app workaround in whatsapp-bridge/main.go becomes a
  no-op -- but it's harmless to keep for portability to un-fixed machines.

.NOTES
  Run:  powershell -ExecutionPolicy Bypass -File .\fix-vm-networking.ps1
#>

$ErrorActionPreference = "Continue"
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Please run this script in an elevated (Administrator) PowerShell."
}

$adapters = Get-NetAdapter | Where-Object Status -eq 'Up'
foreach ($a in $adapters) {
    $n = $a.Name
    Write-Host "Disabling hardware offloads on '$n'..." -ForegroundColor Cyan
    Disable-NetAdapterLso            -Name $n -ErrorAction SilentlyContinue
    Disable-NetAdapterRsc            -Name $n -ErrorAction SilentlyContinue
    Disable-NetAdapterChecksumOffload -Name $n -ErrorAction SilentlyContinue
    foreach ($kw in @('*LsoV2IPv4','*LsoV2IPv6','*LsoV1IPv4',
                      '*TCPUDPChecksumOffloadIPv4','*TCPUDPChecksumOffloadIPv6',
                      '*IPChecksumOffloadIPv4','*RscIPv4','*RscIPv6',
                      'Offload.TxLSO','Offload.TxChecksum','Offload.RxChecksum')) {
        Set-NetAdapterAdvancedProperty -Name $n -RegistryKeyword $kw -RegistryValue 0 -ErrorAction SilentlyContinue
    }
    # Conservative MTU avoids any residual oversized-packet drops.
    netsh interface ipv4 set subinterface "$n" mtu=1400 store=persistent | Out-Null
}

Write-Host "Disabling TCP offload / RSC / autotuning quirks globally..." -ForegroundColor Cyan
netsh int tcp set global rsc=disabled            | Out-Null
netsh int tcp set global chimney=disabled 2>$null | Out-Null
netsh int tcp set global autotuninglevel=disabled | Out-Null
netsh int tcp set global ecncapability=disabled  | Out-Null
netsh int tcp set global timestamps=disabled      | Out-Null
New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" `
    -Name "DisableTaskOffload" -PropertyType DWord -Value 1 -Force | Out-Null

Write-Host "`nDone. All changes persist across reboot." -ForegroundColor Green
Write-Host "Test with:  (Invoke-WebRequest https://github.com -UseBasicParsing).StatusCode" -ForegroundColor Green

<#
TO REVERT (run as Administrator):

  foreach ($n in (Get-NetAdapter | Where-Object Status -eq 'Up').Name) {
      Enable-NetAdapterLso            -Name $n
      Enable-NetAdapterRsc            -Name $n
      Enable-NetAdapterChecksumOffload -Name $n
      netsh interface ipv4 set subinterface "$n" mtu=1500 store=persistent
  }
  netsh int tcp set global rsc=default
  netsh int tcp set global autotuninglevel=normal
  netsh int tcp set global ecncapability=default
  netsh int tcp set global timestamps=default
  Remove-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" -Name "DisableTaskOffload"
#>
