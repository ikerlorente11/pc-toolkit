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
[void]$panel.Children.Add((New-SectionHeader 'Sonando ahora' 'Tus dispositivos habilitados que están conectados. Pulsa uno para que suene.'))
$playable = @(Get-EnabledAudioDevices)
$current = @($devices | Where-Object IsDefault)[0]
if ($current -and $playable.Id -notcontains $current.Id) { $playable = @($current) + $playable }
if (-not $playable) { [void]$panel.Children.Add((New-Hint 'No hay ningún dispositivo habilitado conectado.')) }
foreach ($d in $playable) {
    $detail = if (-not (Test-AudioEnabled $d $cfg)) { 'No está habilitado' }
    [void]$panel.Children.Add((New-ChoiceRow $d.Name $detail $d.IsDefault {
        param($id)
        [PcToolkit.Audio.Endpoints]::SetDefault($id)
        Update-Page
    } $d.Id))
}

# 2. Habilitados: cambian solos al encenderse y son los del cambio rápido y el atajo
[void]$panel.Children.Add((New-SectionHeader 'Dispositivos habilitados' 'El sonido pasa a estos en cuanto se encienden (y vuelve al anterior al apagarlos). Son también los que salen en el cambio rápido de la portada y entre los que salta el atajo.'))
foreach ($d in $devices) {
    $on = Test-AudioEnabled $d $cfg
    $detail = if ($d.IsActive) { 'Conectado' } else { 'Apagado o desconectado' }
    [void]$panel.Children.Add((New-ToggleRow $d.Name $detail $on {
        param($id, $isOn)
        $c = Get-AudioConfig
        $c.Auto[$id] = $isOn
        Save-AudioConfig $c
        Update-Page   # que "Sonando ahora" y la portada lo reflejen al momento
    } $d.Id))
}

# 3. Dispositivo por defecto (cuando ya no queda ninguno de los anteriores encendido)
[void]$panel.Children.Add((New-SectionHeader 'Dispositivo por defecto' 'Al que se vuelve cuando apagas todos. Sin dispositivo por defecto, decide Windows.'))
$setDefault = {
    param($id)
    $c = Get-AudioConfig
    $c.DefaultRenderId = if ($id) { $id } else { $null }
    Save-AudioConfig $c
    Update-Page
}
[void]$panel.Children.Add((New-ChoiceRow 'Sin dispositivo por defecto' '' (-not $cfg.DefaultRenderId) $setDefault ''))
foreach ($d in $devices) {
    $detail = if ($d.IsActive) { '' } else { 'Apagado o desconectado' }
    [void]$panel.Children.Add((New-ChoiceRow $d.Name $detail ($cfg.DefaultRenderId -eq $d.Id) $setDefault $d.Id))
}

# 4. Micrófono
[void]$panel.Children.Add((New-SectionHeader 'Micrófono'))
[void]$panel.Children.Add((New-ToggleRow 'Usar también su micrófono' 'Al cambiar de dispositivo, el micro pasa a ser el del mismo aparato. En Bluetooth el sonido pierde calidad mientras se usa el micro.' $cfg.FollowMic {
    param($a, $isOn)
    $c = Get-AudioConfig
    $c.FollowMic = $isOn
    Save-AudioConfig $c
} $null))

$panel
