# home.ps1 - Bloque de Juegos en la portada del gestor: juego abierto (o los de la lista) y estado del HDR.

. (Join-Path $PSScriptRoot 'common.ps1')

$script:HomeSignatures['games'] = {
    $displays = (Get-HdrDisplays | ForEach-Object { "$($_.Key)=$($_.Enabled)" }) -join ','
    $cfg = Get-GamesConfig
    "$displays|$((Get-RunningGame $cfg.Games).Exe)|$($cfg.Games.Count)"
}

$cfg      = Get-GamesConfig
$open     = Get-RunningGame $cfg.Games
$displays = Get-HdrDisplays
$on       = @($displays | Where-Object Enabled)
$row = New-Ui @'
<StackPanel Margin="36,8,0,0">
  <TextBlock x:Name="Name" FontSize="12.5" Foreground="{StaticResource TextBrush}" TextTrimming="CharacterEllipsis"/>
  <TextBlock x:Name="Info" Style="{StaticResource Caption}" TextWrapping="NoWrap" TextTrimming="CharacterEllipsis"/>
</StackPanel>
'@
$row.FindName('Name').Text = if ($open) { "$($open.Name) abierto" }
                             elseif ($cfg.Games.Count -eq 1) { $cfg.Games[0].Name }
                             else { "$($cfg.Games.Count) juegos en la lista" }
$hdr = if (-not $displays) { 'Sin pantallas HDR' }
       elseif ($on.Count -eq $displays.Count) { 'HDR activado' }
       elseif ($on) { "HDR activado en $($on.Count) de $($displays.Count) pantallas" }
       else { 'HDR desactivado' }
$row.FindName('Info').Text = if ($open -and $open.Borderless) { "$hdr  ·  sin bordes en $((Get-ScreenLabel (Get-GameScreen $open.Screen)).ToLower())" }
                             else { $hdr }
$row
