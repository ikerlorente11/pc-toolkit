# home.ps1 - Bloque de Sonidos de dispositivos en la portada del gestor: los sonidos elegidos.

. (Join-Path $PSScriptRoot 'common.ps1')

$script:HomeSignatures['device-sounds'] = {
    $path = Join-Path $script:DeviceSoundsData 'config.json'
    if (Test-Path $path) { (Get-Item $path).LastWriteTimeUtc.Ticks }
}

$cfg = Get-DeviceSoundsConfig
$block = New-Ui @'
<StackPanel Margin="36,8,0,0">
  <TextBlock x:Name="Connect" FontSize="12.5" Foreground="{StaticResource TextBrush}" TextTrimming="CharacterEllipsis"/>
  <TextBlock x:Name="Disconnect" Style="{StaticResource Caption}" TextWrapping="NoWrap" TextTrimming="CharacterEllipsis"/>
</StackPanel>
'@
$block.FindName('Connect').Text = "Conectar: $(Get-DeviceSoundLabel $cfg.Connect)"
$block.FindName('Disconnect').Text = "Desconectar: $(Get-DeviceSoundLabel $cfg.Disconnect)"
$block
