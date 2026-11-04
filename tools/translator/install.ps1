# install.ps1 - Instala el Traductor (lo llaman el instalador global y el gestor).
# No hay proceso en segundo plano ni disparadores: la ventana la abre el gestor con el atajo.

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\core\Toolkit.psm1')

$action   = New-HiddenTaskAction (Join-Path $PSScriptRoot 'Translator.ps1')
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName 'PcToolkitTranslator' -Action $action -Settings $settings `
    -Description 'PC Toolkit: traductor (lo abre el gestor con un atajo de teclado)' -Force | Out-Null
