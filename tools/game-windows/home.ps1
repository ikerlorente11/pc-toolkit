# home.ps1 - Bloque de Ventanas de juegos en la portada del gestor: juegos de la lista y cuál está abierto.

. (Join-Path $PSScriptRoot 'common.ps1')

function script:Get-OpenGameWindow {
    foreach ($g in (Get-GameWindowsConfig).Games) {
        $procs = [Diagnostics.Process]::GetProcessesByName([IO.Path]::GetFileNameWithoutExtension($g.Exe))
        $found = $procs.Count -gt 0
        foreach ($p in $procs) { $p.Dispose() }
        if ($found) { return $g }
    }
}

$script:HomeSignatures['game-windows'] = { "$((Get-OpenGameWindow).Exe)|$((Get-GameWindowsConfig).Games.Count)" }

$cfg  = Get-GameWindowsConfig
$open = Get-OpenGameWindow
$row = New-Ui @'
<StackPanel Margin="36,8,0,0">
  <TextBlock x:Name="Name" FontSize="12.5" Foreground="{StaticResource TextBrush}" TextTrimming="CharacterEllipsis"/>
  <TextBlock x:Name="Info" Style="{StaticResource Caption}" TextWrapping="NoWrap" TextTrimming="CharacterEllipsis"/>
</StackPanel>
'@
$row.FindName('Name').Text = if ($open) { "$($open.Name) abierto" }
                             elseif ($cfg.Games.Count -eq 1) { $cfg.Games[0].Name }
                             else { "$($cfg.Games.Count) juegos en la lista" }
$row.FindName('Info').Text = if ($open) { "Sin bordes en: $(Get-ScreenLabel (Get-GameScreen $open.Screen))" }
                             else { 'Se pondrá sin bordes al abrirse' }
$row
