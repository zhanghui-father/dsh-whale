' whale-shot launcher - starts the floating widget with no console window.
Option Explicit
Dim fso, shell, here, exe, cmd
Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")
here = fso.GetParentFolderName(WScript.ScriptFullName)
exe = shell.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
cmd = """" & exe & """ -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & here & "\whale-shot.ps1"""
shell.Run cmd, 0, False
