# install.ps1 - Instala la herramienta El Puntero (lo llaman el instalador global y el gestor).
# Descarga la última release de la app y la instala para el usuario actual (sin permisos de administrador).
# La tarea la arranca oculta en la bandeja al iniciar sesión (y al activar la herramienta).

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\core\Toolkit.psm1')
. (Join-Path $PSScriptRoot 'common.ps1')

Set-ToolStatus 'Descargando e instalando El Puntero...'
if (-not (Install-Puntero)) { Write-PunteroLog "El Puntero $(Get-PunteroVersion) ya estaba al día" }

$user     = Get-CurrentUserId
$action   = New-HiddenTaskAction (Join-Path $PSScriptRoot 'Puntero.ps1')
$trigger  = New-ScheduledTaskTrigger -AtLogOn -User $user
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName 'PcToolkitPuntero' -Action $action -Trigger $trigger -Settings $settings `
    -Description 'PC Toolkit: arranca El Puntero oculto en la bandeja para que el móvil pueda controlar el PC' -Force | Out-Null
