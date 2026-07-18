' Supervises the WhatsApp bridge with no visible window or PowerShell host.
' Used by the "WhatsAppMCPBridge" scheduled task to auto-start on login.
' Location-independent: resolves paths relative to this script's folder.
Option Explicit

Dim fso, scriptDir, sh, binary, exitCode, delayMilliseconds
Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
Set sh = CreateObject("WScript.Shell")
sh.CurrentDirectory = scriptDir
binary = scriptDir & "\whatsapp-bridge.exe"

Do
    If Not fso.FileExists(binary) Then
        WScript.Quit 1
    End If

    ' 0 = hidden window, True = wait so Task Scheduler owns the supervisor lifetime.
    exitCode = sh.Run("""" & binary & """", 0, True)
    If exitCode = 0 Then
        delayMilliseconds = 2000
    Else
        delayMilliseconds = 5000
    End If
    WScript.Sleep delayMilliseconds
Loop
