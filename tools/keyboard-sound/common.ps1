# common.ps1 - Configuración de Keyboard Sound y registro de su tarea. Lo cargan con "." el vigilante,
# install.ps1 y settings.ps1. Funciones "script:" para que sigan vivas en los botones del gestor.

if (-not ('PcToolkit.KeyboardSound.Player' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'KeyboardSound.cs') }
$script:KeyboardSoundDir  = $PSScriptRoot
$script:KeyboardSoundData = Join-Path $env:LOCALAPPDATA 'PcToolkit\data\keyboard-sound'

# Sonidos incluidos (sounds\<id>.mp3) y su nombre en el panel
$script:KeyboardSounds = [ordered]@{
    quack = 'Pato'
    frog  = 'Rana'
    miau1 = 'Maullido 1'
    miau2 = 'Maullido 2'
    moan  = 'Gemido'
}

function script:Get-KeyboardSoundConfig {
    $path = Join-Path $script:KeyboardSoundData 'config.json'
    $c = if (Test-Path $path) { try { Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }
    @{
        Sound            = if ($script:KeyboardSounds.Contains([string]$c.Sound)) { [string]$c.Sound } else { 'quack' }
        Volume           = if ($null -ne $c.Volume) { [Math]::Max(0, [Math]::Min(100, [int]$c.Volume)) } else { 60 }
        StartWithWindows = if ($null -ne $c.StartWithWindows) { [bool]$c.StartWithWindows } else { $true }
    }
}

function script:Save-KeyboardSoundConfig($Config) {
    New-Item -ItemType Directory -Force -Path $script:KeyboardSoundData | Out-Null
    $Config | ConvertTo-Json | Set-Content (Join-Path $script:KeyboardSoundData 'config.json') -Encoding UTF8
}

function script:Get-KeyboardSoundFile([string]$Sound) { Join-Path $script:KeyboardSoundDir "sounds\$Sound.mp3" }

# Tarea del vigilante: con "Iniciar con Windows" arranca al iniciar sesión; si no, solo cuando se activa.
# Se respeta si estaba desactivada. Necesita Toolkit.psm1 (New-HiddenTaskAction).
function script:Register-KeyboardSoundTask([bool]$StartWithWindows) {
    $wasDisabled = (Get-ScheduledTask -TaskName 'PcToolkitKeyboardSound' -ErrorAction SilentlyContinue).State -eq 'Disabled'
    $params = @{
        TaskName    = 'PcToolkitKeyboardSound'
        Action      = New-HiddenTaskAction (Join-Path $script:KeyboardSoundDir 'KeyboardSound.ps1')
        Settings    = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
        Description = 'PC Toolkit: reproduce un sonido al pulsar teclas'
        Force       = $true
    }
    if ($StartWithWindows) { $params.Trigger = New-ScheduledTaskTrigger -AtLogOn -User (Get-CurrentUserId) }
    Register-ScheduledTask @params | Out-Null
    if ($wasDisabled) { Disable-ScheduledTask -TaskName 'PcToolkitKeyboardSound' | Out-Null }
}
