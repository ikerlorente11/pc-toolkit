' run-hidden.vbs - Ejecuta un script de PowerShell sin mostrar ninguna ventana.
' Uso: wscript.exe run-hidden.vbs "C:\ruta\script.ps1" [argumentos...]
Set args = WScript.Arguments
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & args(0) & """"
For i = 1 To args.Count - 1
    cmd = cmd & " " & args(i)
Next
CreateObject("WScript.Shell").Run cmd, 0, False
