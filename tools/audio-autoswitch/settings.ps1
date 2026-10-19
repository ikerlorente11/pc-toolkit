# settings.ps1 - Página de ajustes de Audio AutoSwitch dentro del gestor.
# La carga el gestor con "." y muestra lo que devuelve (ver los helpers en manager\PcToolkit.ps1).
# Los cambios se guardan en config.json y el vigilante los aplica solo, sin reiniciarlo.

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

# Dispositivos de salida: los conectados y los emparejados pero apagados (sin los perfiles "manos libres")
function script:Get-AudioDevices {
    @([PcToolkit.Audio.Endpoints]::List(0, $true) | Where-Object { -not $_.IsHandsFree } | Sort-Object { -not $_.IsActive }, Name)
}

# Repintar solo cuando se enciende/apaga algo o cambia el que suena
$script:PageSignature = { ([PcToolkit.Audio.Endpoints]::List(0) | ForEach-Object { "$($_.Id)$($_.IsDefault)" }) -join ';' }

$cfg     = Get-AudioConfig
$devices = Get-AudioDevices
$active  = @($devices | Where-Object IsActive)
$panel   = New-Ui '<StackPanel/>'

# 1. Cambio manual entre los conectados
[void]$panel.Children.Add((New-SectionHeader 'Sonando ahora' 'Pulsa otro para cambiar a mano sin apagar nada.'))
foreach ($d in $active) {
    [void]$panel.Children.Add((New-ChoiceRow $d.Name '' $d.IsDefault {
        param($id)
        [PcToolkit.Audio.Endpoints]::SetDefault($id)
        Update-Page
    } $d.Id))
}

# 2. Cuáles cambian solos al encenderse
[void]$panel.Children.Add((New-SectionHeader 'Cambiar solo al encender' 'El sonido pasa a estos en cuanto se encienden. Al apagarlos vuelve al anterior que siga encendido.'))
foreach ($d in $devices) {
    $on = if ($cfg.Auto.ContainsKey($d.Id)) { $cfg.Auto[$d.Id] } else { $d.AutoByDefault }
    $detail = if ($d.IsActive) { 'Conectado' } else { 'Apagado o desconectado' }
    [void]$panel.Children.Add((New-ToggleRow $d.Name $detail $on {
        param($id, $isOn)
        $c = Get-AudioConfig
        $c.Auto[$id] = $isOn
        Save-AudioConfig $c
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

# 4. Atajo de teclado (lo registra el gestor; ver "hotkey" en tool.json)
[void]$panel.Children.Add((New-SectionHeader 'Atajo de teclado'))
$hk = New-Ui @'
<Border Style="{StaticResource Card}">
  <StackPanel>
    <TextBlock x:Name="Keys" Style="{StaticResource Body}" FontWeight="SemiBold"/>
    <TextBlock x:Name="Info" Style="{StaticResource Caption}"/>
  </StackPanel>
</Border>
'@
$hk.FindName('Keys').Text = 'Ctrl + Alt + A'
$hk.FindName('Info').Text = switch ($hotkeyStatus['audio-autoswitch']) {
    'ok'      { 'Pasa al siguiente dispositivo conectado y muestra un aviso abajo. Funciona mientras PC Toolkit esté en la bandeja.' }
    'ocupado' { 'Otra aplicación ya usa este atajo, así que ahora no funciona.' }
    default   { 'Se activa cuando Audio AutoSwitch está activado.' }
}
if ($hotkeyStatus['audio-autoswitch'] -eq 'ocupado') { $hk.FindName('Info').Foreground = $app.Resources['DangerBrush'] }
[void]$panel.Children.Add($hk)

# 5. Micrófono
[void]$panel.Children.Add((New-SectionHeader 'Micrófono'))
[void]$panel.Children.Add((New-ToggleRow 'Usar también su micrófono' 'Al cambiar de dispositivo, el micro pasa a ser el del mismo aparato. En Bluetooth el sonido pierde calidad mientras se usa el micro.' $cfg.FollowMic {
    param($a, $isOn)
    $c = Get-AudioConfig
    $c.FollowMic = $isOn
    Save-AudioConfig $c
} $null))

$panel
