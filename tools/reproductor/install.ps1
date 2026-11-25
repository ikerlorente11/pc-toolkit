# install.ps1 - Instala la herramienta El Reproductor (lo llaman el instalador global y el gestor).
# Descarga la última release de la app y la instala para el usuario actual (sin permisos de administrador);
# si ya está, la actualiza, salvo que esté abierta (al actualizar PC Toolkit no se cierra: la actualizará el
# gestor cuando se cierre, ver update.ps1). No hay proceso en segundo plano: la app la abre el atajo o el Explorador (las canciones).

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\core\Toolkit.psm1')
. (Join-Path $PSScriptRoot 'common.ps1')

if ((Get-ReproductorExe) -and (Test-ReproductorRunning)) {
    Write-ReproductorLog "El Reproductor $(Get-ReproductorVersion) está abierta: no se actualiza al reinstalar la herramienta"
} else {
    Set-ToolStatus 'Descargando e instalando El Reproductor...'
    if (-not (Install-Reproductor)) { Write-ReproductorLog "El Reproductor $(Get-ReproductorVersion) ya estaba al día" }
}

$action   = New-HiddenTaskAction (Join-Path $PSScriptRoot 'Reproductor.ps1')
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName 'PcToolkitReproductor' -Action $action -Settings $settings `
    -Description 'PC Toolkit: El Reproductor (la abre el gestor con un atajo de teclado o el Explorador)' -Force | Out-Null
