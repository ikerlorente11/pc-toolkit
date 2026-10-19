# common.ps1 - Funciones compartidas por settings.ps1, home.ps1 y hotkey.ps1 (se cargan con ".").
# Se declaran "script:" para que sigan disponibles en las acciones de los botones del gestor.

if (-not ('PcToolkit.Audio.Endpoints' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'AudioEndpoints.cs') }
$script:AudioDataDir = Get-ToolDataDir 'audio-autoswitch'

function script:Get-AudioConfig {
    $path = Join-Path $script:AudioDataDir 'config.json'
    $c = if (Test-Path $path) { try { Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }
    $cfg = @{ DefaultRenderId = $c.DefaultRenderId; FollowMic = [bool]$c.FollowMic; Auto = @{} }
    if ($c.Auto) { foreach ($p in $c.Auto.PSObject.Properties) { $cfg.Auto[$p.Name] = [bool]$p.Value } }
    $cfg
}

function script:Save-AudioConfig($cfg) {
    [ordered]@{ DefaultRenderId = $cfg.DefaultRenderId; FollowMic = $cfg.FollowMic; Auto = $cfg.Auto } |
        ConvertTo-Json | Set-Content (Join-Path $script:AudioDataDir 'config.json') -Encoding UTF8
}

# ¿Está habilitado ("Cambiar solo al encender")? Lo elegido por el usuario o, si no, el valor de serie
function script:Test-AudioEnabled($Device, $Config) {
    if ($Config.Auto.ContainsKey($Device.Id)) { $Config.Auto[$Device.Id] } else { $Device.AutoByDefault }
}

# Conectados y habilitados: los que salen en el cambio rápido y entre los que salta el atajo
function script:Get-EnabledAudioDevices {
    $cfg = Get-AudioConfig
    @([PcToolkit.Audio.Endpoints]::List(0) | Where-Object { -not $_.IsHandsFree -and (Test-AudioEnabled $_ $cfg) })
}
