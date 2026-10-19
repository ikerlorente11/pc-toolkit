# home.ps1 - Cambio rápido en la tarjeta de Audio AutoSwitch de la portada del gestor.
# La carga el gestor igual que settings.ps1 y muestra lo que devuelve debajo de la tarjeta.
# Una sola fila (el que suena + anterior/siguiente) para que la tarjeta no crezca con muchos dispositivos.

if (-not ('PcToolkit.Audio.Endpoints' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'AudioEndpoints.cs') }

# Mismo orden que el atajo Ctrl+Alt+A
function script:Get-QuickAudioDevices { @([PcToolkit.Audio.Endpoints]::List(0) | Where-Object { -not $_.IsHandsFree }) }

function script:Switch-QuickAudio([int]$Step) {
    $devices = Get-QuickAudioDevices
    if (-not $devices) { return }
    $i = [array]::IndexOf(@($devices | ForEach-Object Id), [PcToolkit.Audio.Endpoints]::GetDefaultId(0))
    $next = $devices[($i + $Step + $devices.Count) % $devices.Count]
    [PcToolkit.Audio.Endpoints]::SetDefault($next.Id)
    Update-Page
}

# Repintar la portada cuando se enciende/apaga algo o cambia el que suena
$script:HomeSignatures['audio-autoswitch'] = { ([PcToolkit.Audio.Endpoints]::List(0) | ForEach-Object { "$($_.Id)$($_.IsDefault)" }) -join ';' }

$devices = Get-QuickAudioDevices
$current = @($devices | Where-Object IsDefault)[0]
$row = New-Ui @'
<Grid Margin="36,10,0,0">
  <Grid.ColumnDefinitions>
    <ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/>
  </Grid.ColumnDefinitions>
  <StackPanel VerticalAlignment="Center">
    <TextBlock x:Name="Name" FontSize="12.5" Foreground="{StaticResource TextBrush}" TextTrimming="CharacterEllipsis"/>
    <TextBlock x:Name="Pos" Style="{StaticResource Caption}"/>
  </StackPanel>
  <Button x:Name="Prev" Grid.Column="1" Style="{StaticResource IconButton}" Content="&#xE76B;" FontSize="11" Width="28" Height="28" AutomationProperties.Name="Dispositivo anterior"/>
  <Button x:Name="Next" Grid.Column="2" Style="{StaticResource IconButton}" Content="&#xE76C;" FontSize="11" Width="28" Height="28" AutomationProperties.Name="Dispositivo siguiente"/>
</Grid>
'@
if ($current) {
    $row.FindName('Name').Text = $current.Name
    $row.FindName('Pos').Text = "Sonando  ·  $([array]::IndexOf(@($devices | ForEach-Object Id), $current.Id) + 1) de $($devices.Count)"
} else {
    $row.FindName('Name').Text = 'Ningún dispositivo de sonido'
    $row.FindName('Pos').Text = ''
}
$canSwitch = $devices.Count -gt 1
foreach ($b in @(@($row.FindName('Prev'), -1), @($row.FindName('Next'), 1))) {
    $b[0].IsEnabled = $canSwitch
    $b[0].Tag = $b[1]
    $b[0].Add_Click({ param($s, $e) Invoke-Safe { Switch-QuickAudio $s.Tag } })
}
$row
