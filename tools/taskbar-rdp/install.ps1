# install.ps1 - Instala Taskbar RDP (lo llaman el instalador global y el gestor)
# No hay proceso en segundo plano: la tarea lanza el script al iniciar sesion,
# al conectar por Escritorio Remoto y al volver a la consola local.

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\core\Toolkit.psm1')

$user = Get-CurrentUserId
$sessionClass = Get-CimClass -Namespace Root/Microsoft/Windows/TaskScheduler -ClassName MSFT_TaskSessionStateChangeTrigger
function New-SessionTrigger($state) {
    # StateChange: 1 = ConsoleConnect, 3 = RemoteConnect
    New-CimInstance -CimClass $sessionClass -ClientOnly -Property @{ StateChange = $state; UserId = $user; Enabled = $true }
}
$triggers = @(
    (New-ScheduledTaskTrigger -AtLogOn -User $user),
    (New-SessionTrigger 3),
    (New-SessionTrigger 1)
)

$action   = New-HiddenTaskAction (Join-Path $PSScriptRoot 'TaskbarRdp.ps1')
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -MultipleInstances Queue
Register-ScheduledTask -TaskName 'TaskbarRdp' -Action $action -Trigger $triggers -Settings $settings `
    -Description 'PC Toolkit: barra de tareas visible en Escritorio Remoto, autoocultable en local' -Force | Out-Null
