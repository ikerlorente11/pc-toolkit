# Puntero.ps1 - Acción de la tarea "PcToolkitPuntero" (al iniciar sesión y al activar la herramienta):
# arranca El Puntero oculto en la bandeja, si no lo está ya.

. (Join-Path $PSScriptRoot 'common.ps1')

if (-not (Get-PunteroExe)) { Write-PunteroLog 'El Puntero no está instalado'; return }
Remove-PunteroAutostart
if (Test-PunteroRunning) { return }
try {
    Start-Puntero -Hidden
    Write-PunteroLog 'El Puntero arrancado en la bandeja'
} catch { Write-PunteroLog "ERROR al arrancar El Puntero: $($_.Exception.Message)" }
