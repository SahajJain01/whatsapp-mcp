$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$setup = Get-Content -LiteralPath (Join-Path $repoRoot "setup.ps1") -Raw
$launcher = Get-Content -LiteralPath (
    Join-Path $repoRoot "whatsapp-bridge\run-bridge-hidden.vbs"
) -Raw

if ($setup -notmatch 'New-ScheduledTaskAction\s+-Execute\s+"wscript\.exe"') {
    throw "The logon task must use the windowless Windows Script Host executable."
}
if ($setup -notmatch '//B\s+//NoLogo') {
    throw "The logon task must run Windows Script Host in batch mode without a logo."
}
if ($launcher -match 'powershell\.exe|run-bridge-supervisor\.ps1') {
    throw "The startup chain must not create a persistent PowerShell process."
}
if ($launcher -notmatch 'binary\s*=.+whatsapp-bridge\.exe' -or
    $launcher -notmatch 'Do\s+[\s\S]+sh\.Run\([\s\S]+Loop') {
    throw "The windowless launcher must supervise the bridge process itself."
}

Write-Output "Windows startup launcher regression check passed."
