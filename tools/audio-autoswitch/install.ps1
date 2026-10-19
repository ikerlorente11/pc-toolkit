# install.ps1 - Instala Audio AutoSwitch (lo llaman el instalador global y el gestor)
# No pide nada: funciona solo desde el principio y se ajusta despues desde el gestor.

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\core\Toolkit.psm1')

# Configuracion de la version antigua (auriculares fijos + respaldo): se convierte al formato nuevo
$config = Join-Path (Get-ToolDataDir 'audio-autoswitch') 'config.json'
if (Test-Path $config) {
    $old = Get-Content $config -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($old.PSObject.Properties.Name -contains 'HeadphoneRenderId') {
        $auto = @{}
        if ($old.HeadphoneRenderId) { $auto[$old.HeadphoneRenderId] = $true }
        [ordered]@{
            DefaultRenderId = $old.FallbackRenderId
            FollowMic       = [bool]$old.HeadphoneCaptureId
            Auto            = $auto
        } | ConvertTo-Json | Set-Content $config -Encoding UTF8
    }
}

# Tarea programada: arranca el vigilante oculto al iniciar sesion
$action   = New-HiddenTaskAction (Join-Path $PSScriptRoot 'AudioAutoSwitch.ps1')
$trigger  = New-ScheduledTaskTrigger -AtLogOn -User (Get-CurrentUserId)
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -ExecutionTimeLimit ([TimeSpan]::Zero) -StartWhenAvailable
Register-ScheduledTask -TaskName 'AudioAutoSwitch' -Action $action -Trigger $trigger -Settings $settings `
    -Description 'PC Toolkit: cambia el audio al encender/apagar auriculares' -Force | Out-Null
