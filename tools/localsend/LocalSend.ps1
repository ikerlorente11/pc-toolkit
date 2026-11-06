# LocalSend.ps1 - Acción de la tarea "PcToolkitLocalSend" (al iniciar sesión y al activar la herramienta):
# pone (o quita) LocalSend en el menú Enviar a y lo arranca oculto en la bandeja para poder recibir.

. (Join-Path $PSScriptRoot 'common.ps1')

if (-not (Get-LocalSendExe)) { Write-LocalSendLog 'LocalSend no está instalado'; return }
try { Set-LocalSendSendTo (Get-LocalSendConfig).SendTo }
catch { Write-LocalSendLog "ERROR en el menú Enviar a: $($_.Exception.Message)" }
if (Test-LocalSendRunning) { return }
try {
    Start-LocalSend -Hidden
    Write-LocalSendLog 'LocalSend iniciado en la bandeja'
} catch { Write-LocalSendLog "ERROR al iniciar LocalSend: $($_.Exception.Message)" }
