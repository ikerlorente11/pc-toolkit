# Everything.ps1 - Acción de la tarea "PcToolkitEverything" (al iniciar sesión y al activar la herramienta):
# arranca Everything en la bandeja si no está en marcha, porque es el que responde a las búsquedas.

. (Join-Path $PSScriptRoot 'common.ps1')

if (-not (Get-EverythingExe)) { Write-EverythingLog 'Everything no está instalado'; return }
if (Test-EverythingClient) { return }
try {
    Start-EverythingClient
    Write-EverythingLog 'Everything iniciado en la bandeja'
} catch { Write-EverythingLog "ERROR al iniciar Everything: $($_.Exception.Message)" }
