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

# Habilitados: los del cambio rápido y entre los que salta el atajo. Por defecto solo los conectados;
# con -IncludeDisconnected también los apagados (para mostrarlos en gris), conectados primero.
function script:Get-EnabledAudioDevices([switch]$IncludeDisconnected) {
    $cfg = Get-AudioConfig
    @([PcToolkit.Audio.Endpoints]::List(0, [bool]$IncludeDisconnected) |
        Where-Object { -not $_.IsHandsFree -and (Test-AudioEnabled $_ $cfg) } |
        Sort-Object { -not $_.IsActive })
}

# Firma para repintar: cambia al encender/apagar algo, cambiar el que suena o tocar la configuración
function script:Get-AudioSignature {
    $cfgPath = Join-Path $script:AudioDataDir 'config.json'
    $stamp = if (Test-Path $cfgPath) { (Get-Item $cfgPath).LastWriteTimeUtc.Ticks }
    (([PcToolkit.Audio.Endpoints]::List(0) | ForEach-Object { "$($_.Id)$($_.IsDefault)" }) -join ';') + "|$stamp"
}
