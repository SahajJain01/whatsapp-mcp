' Launches the WhatsApp bridge with no visible window.
' Used by the "WhatsAppBridge" scheduled task to auto-start on login.
' Location-independent: resolves paths relative to this script's folder.
Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
Set sh = CreateObject("WScript.Shell")
sh.CurrentDirectory = scriptDir
' 0 = hidden window, False = don't wait
sh.Run """" & scriptDir & "\whatsapp-bridge.exe""", 0, False
