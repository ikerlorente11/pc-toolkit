# install.ps1 - Instala Sonidos de dispositivos (lo llaman el instalador global y el gestor).
# No hay proceso en segundo plano: la tarea solo vuelve a aplicar los sonidos al iniciar sesión.

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\core\Toolkit.psm1')

$action   = New-HiddenTaskAction (Join-Path $PSScriptRoot 'Apply.ps1')
$trigger  = New-ScheduledTaskTrigger -AtLogOn -User (Get-CurrentUserId)
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName 'PcToolkitDeviceSounds' -Action $action -Trigger $trigger -Settings $settings `
    -Description 'PC Toolkit: sonidos personalizados al conectar y desconectar dispositivos' -Force | Out-Null
