# install.ps1 - Instala la herramienta Barra de tareas (lo llaman el instalador global y el gestor)
# No hay proceso en segundo plano: la tarea aplica el perfil al iniciar sesión, al conectar por
# Escritorio Remoto y al volver a la consola local.

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\core\Toolkit.psm1')

# Versiones anteriores (Taskbar RDP): otra tarea y otra carpeta de datos
if (Get-ScheduledTask -TaskName 'TaskbarRdp' -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName 'TaskbarRdp' -Confirm:$false }
$oldData = Join-Path (Get-ToolkitRoot) 'data\taskbar-rdp'
if (Test-Path $oldData) { Remove-Item $oldData -Recurse -Force }

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

$action   = New-HiddenTaskAction (Join-Path $PSScriptRoot 'Taskbar.ps1')
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -MultipleInstances Queue
Register-ScheduledTask -TaskName 'PcToolkitTaskbar' -Action $action -Trigger $triggers -Settings $settings `
    -Description 'PC Toolkit: aplica el perfil de la barra de tareas (normal o Escritorio Remoto)' -Force | Out-Null
