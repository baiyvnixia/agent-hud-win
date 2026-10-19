' Agent HUD Lite - start with no console window at all (this is the normal way).
' Double-click this file, or put a shortcut to it in:
'   %APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup
' to have the dots come up automatically at logon.
Option Explicit
Dim sh, fso, here
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)
sh.CurrentDirectory = here
sh.Run "powershell -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & here & "\hud.ps1""", 0, False
