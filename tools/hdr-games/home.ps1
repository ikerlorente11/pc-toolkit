# home.ps1 - Bloque de HDR por juego en la portada del gestor: si el HDR está activado y qué juego lo ha quitado.

. (Join-Path $PSScriptRoot 'common.ps1')

$script:HomeSignatures['hdr-games'] = {
    $displays = (Get-HdrDisplays | ForEach-Object { "$($_.Key)=$($_.Enabled)" }) -join ','
    "$displays|$((Get-RunningHdrGame (Get-HdrGamesConfig).Games).Exe)"
}

$cfg      = Get-HdrGamesConfig
$running  = Get-RunningHdrGame $cfg.Games
$displays = Get-HdrDisplays
$on       = @($displays | Where-Object Enabled)
$row = New-Ui @'
<StackPanel Margin="36,8,0,0">
  <TextBlock x:Name="Name" FontSize="12.5" Foreground="{StaticResource TextBrush}" TextTrimming="CharacterEllipsis"/>
  <TextBlock x:Name="Info" Style="{StaticResource Caption}" TextWrapping="NoWrap" TextTrimming="CharacterEllipsis"/>
</StackPanel>
'@
$row.FindName('Name').Text = if (-not $displays) { 'Ninguna pantalla admite HDR' }
                             elseif ($on.Count -eq $displays.Count) { 'HDR activado' }
                             elseif ($on) { "HDR activado en $($on.Count) de $($displays.Count) pantallas" }
                             else { 'HDR desactivado' }
$games = if ($cfg.Games.Count -eq 1) { '1 juego en la lista' } else { "$($cfg.Games.Count) juegos en la lista" }
$row.FindName('Info').Text = if ($running) { "$($running.Name) abierto  ·  $games" } else { $games }
$row
