# install.ps1 - Instala la herramienta La Estantería (lo llaman el instalador global y el gestor).
# Descarga la última release de la app y la instala para el usuario actual (sin permisos de administrador);
# si ya está, la actualiza, salvo que esté abierta (al actualizar PC Toolkit no se cierra: la actualizará el
# gestor cuando se cierre, ver update.ps1). No hay proceso en segundo plano: la app la abre el atajo o el Explorador.

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\core\Toolkit.psm1')
. (Join-Path $PSScriptRoot 'common.ps1')

if ((Get-EstanteriaExe) -and (Test-EstanteriaRunning)) {
    Write-EstanteriaLog "La Estantería $(Get-EstanteriaVersion) está abierta: no se actualiza al reinstalar la herramienta"
} else {
    Set-ToolStatus 'Descargando e instalando La Estantería...'
    if (-not (Install-Estanteria)) { Write-EstanteriaLog "La Estantería $(Get-EstanteriaVersion) ya estaba al día" }
}

$action   = New-HiddenTaskAction (Join-Path $PSScriptRoot 'Estanteria.ps1')
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName 'PcToolkitEstanteria' -Action $action -Settings $settings `
    -Description 'PC Toolkit: La Estantería (la abre el gestor con un atajo de teclado o el Explorador)' -Force | Out-Null
