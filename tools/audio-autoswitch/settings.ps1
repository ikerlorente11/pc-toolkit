# settings.ps1 - Página de ajustes de Audio AutoSwitch dentro del gestor.
# La carga el gestor con "." y muestra lo que devuelve (ver los helpers en manager\PcToolkit.ps1).
# Los cambios se guardan en config.json y el vigilante los aplica solo, sin reiniciarlo.

. (Join-Path $PSScriptRoot 'common.ps1')

# Dispositivos de salida: los conectados y los emparejados pero apagados (sin los perfiles "manos libres")
function script:Get-AudioDevices {
    @([PcToolkit.Audio.Endpoints]::List(0, $true) | Where-Object { -not $_.IsHandsFree } | Sort-Object { -not $_.IsActive }, Name)
}

# Repintar al encender/apagar algo, cambiar el que suena o tocar la configuración
$script:PageSignature = { Get-AudioSignature }

$cfg     = Get-AudioConfig
$devices = Get-AudioDevices
$panel   = New-Ui '<StackPanel/>'

# 1. Cambio manual entre los habilitados conectados (y el que suene, aunque no lo esté)
[void]$panel.Children.Add((New-SectionHeader 'Salida actual' 'Dispositivos habilitados y conectados. Selecciona uno para usarlo como salida de audio.'))
$playable = @(Get-EnabledAudioDevices)
$current = @($devices | Where-Object IsDefault)[0]
if ($current -and $playable.Id -notcontains $current.Id) { $playable = @($current) + $playable }
if (-not $playable) { [void]$panel.Children.Add((New-Hint 'No hay ningún dispositivo habilitado conectado.')) }
foreach ($d in $playable) {
    $detail = if (-not (Test-AudioEnabled $d $cfg)) { 'No habilitado' }
    [void]$panel.Children.Add((New-ChoiceRow $d.Name $detail $d.IsDefault {
        param($id)
        [PcToolkit.Audio.Endpoints]::SetDefault($id)
        Update-Page
    } $d.Id))
}

# 2. Habilitados: cambian solos al encenderse y son los del cambio rápido y el atajo
[void]$panel.Children.Add((New-SectionHeader 'Dispositivos habilitados' 'Al conectarse, pasan a ser la salida de audio; al desconectarse, se vuelve al anterior disponible. También son los que aparecen en el cambio rápido y entre los que alterna el atajo de teclado.'))
foreach ($d in $devices) {
    $on = Test-AudioEnabled $d $cfg
    $detail = if ($d.IsActive) { 'Conectado' } else { 'Desconectado' }
    [void]$panel.Children.Add((New-ToggleRow $d.Name $detail $on {
        param($id, $isOn)
        $c = Get-AudioConfig
        $c.Auto[$id] = $isOn
        Save-AudioConfig $c
        Update-Page   # que la salida actual y la portada lo reflejen al momento
    } $d.Id))
}

# 3. Dispositivo por defecto (cuando ya no queda ninguno de los anteriores encendido)
[void]$panel.Children.Add((New-SectionHeader 'Dispositivo predeterminado' 'Salida que se usa cuando no queda ningún dispositivo habilitado conectado. Si no se define, la elige Windows.'))
$setDefault = {
    param($id)
    $c = Get-AudioConfig
    $c.DefaultRenderId = if ($id) { $id } else { $null }
    Save-AudioConfig $c
    Update-Page
}
[void]$panel.Children.Add((New-ChoiceRow 'Ninguno (lo decide Windows)' '' (-not $cfg.DefaultRenderId) $setDefault ''))
foreach ($d in $devices) {
    $detail = if ($d.IsActive) { '' } else { 'Desconectado' }
    [void]$panel.Children.Add((New-ChoiceRow $d.Name $detail ($cfg.DefaultRenderId -eq $d.Id) $setDefault $d.Id))
}

# 4. Micrófono
[void]$panel.Children.Add((New-SectionHeader 'Micrófono'))
[void]$panel.Children.Add((New-ToggleRow 'Cambiar también el micrófono' 'Usa como entrada el micrófono del mismo dispositivo. En dispositivos Bluetooth, usar el micrófono puede reducir la calidad del sonido.' $cfg.FollowMic {
    param($a, $isOn)
    $c = Get-AudioConfig
    $c.FollowMic = $isOn
    Save-AudioConfig $c
} $null))

$panel
