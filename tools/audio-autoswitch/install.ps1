# install.ps1 - Instala Audio AutoSwitch (lo llaman el instalador global y el gestor)
# Los auriculares deben estar encendidos para poder elegirlos en la ventana de configuracion.

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\core\Toolkit.psm1')

# 1. Modulo AudioDeviceCmdlets (solo para el usuario actual)
if (-not (Get-Module -ListAvailable AudioDeviceCmdlets)) {
    Write-Host 'Instalando modulo AudioDeviceCmdlets...'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force | Out-Null
    }
    Install-Module AudioDeviceCmdlets -Scope CurrentUser -Force -AllowClobber
}

# 2. Dispositivos: se reutiliza la configuracion si ya existe
$config = Join-Path (Get-ToolDataDir 'audio-autoswitch') 'config.json'
if (-not (Test-Path $config)) {
    if (-not (& (Join-Path $PSScriptRoot 'configure.ps1'))) { throw 'Audio AutoSwitch: instalacion cancelada, no se eligieron dispositivos.' }
}

# 3. Tarea programada: arranca el vigilante oculto al iniciar sesion
$action   = New-HiddenTaskAction (Join-Path $PSScriptRoot 'AudioAutoSwitch.ps1')
$trigger  = New-ScheduledTaskTrigger -AtLogOn -User (Get-CurrentUserId)
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -ExecutionTimeLimit ([TimeSpan]::Zero) -StartWhenAvailable
Register-ScheduledTask -TaskName 'AudioAutoSwitch' -Action $action -Trigger $trigger -Settings $settings `
    -Description 'PC Toolkit: cambia el audio por defecto al encender/apagar los auriculares' -Force | Out-Null
