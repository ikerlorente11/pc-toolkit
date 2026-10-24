# settings.ps1 - Página de ajustes de HDR por juego dentro del gestor: HDR de cada pantalla y lista de juegos.
# El vigilante lee la lista en cada vuelta, así que los cambios se aplican solos.

. (Join-Path $PSScriptRoot 'common.ps1')

# Repintar al cambiar el HDR (desde aquí, Windows o el vigilante) o al abrir/cerrar un juego
$script:PageSignature = {
    $displays = (Get-HdrDisplays | ForEach-Object { "$($_.Key)=$($_.Enabled)" }) -join ','
    "$displays|$((Get-RunningHdrGame (Get-HdrGamesConfig).Games).Exe)"
}

function script:Add-HdrGame([string]$Exe, [string]$Name) {
    $Exe = $Exe.Trim().Trim('"')
    if (-not $Exe) { return }
    $Exe = [IO.Path]::GetFileName($Exe)   # vale pegar la ruta completa
    if ($Exe -notmatch '\.exe$') { $Exe += '.exe' }
    $cfg = Get-HdrGamesConfig
    if ($cfg.Games | Where-Object { $_.Exe -eq $Exe }) { return }
    if (-not $Name) { $Name = [IO.Path]::GetFileNameWithoutExtension($Exe) }
    $cfg.Games = @($cfg.Games) + [pscustomobject]@{ Exe = $Exe; Name = $Name }
    Save-HdrGamesConfig $cfg
    Update-Page
}

function script:Remove-HdrGame([string]$Exe) {
    $cfg = Get-HdrGamesConfig
    $cfg.Games = @($cfg.Games | Where-Object { $_.Exe -ne $Exe })
    Save-HdrGamesConfig $cfg
    Update-Page
}

# Programas abiertos con ventana (para elegir el juego sin saber cómo se llama su .exe)
function script:Get-WindowedPrograms {
    $own = [Diagnostics.Process]::GetCurrentProcess().ProcessName
    Get-Process | Where-Object { $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle -and $_.ProcessName -notin $own, 'explorer', 'ApplicationFrameHost', 'TextInputHost' } |
        Sort-Object MainWindowTitle | ForEach-Object {
            $desc = try { $_.MainModule.FileVersionInfo.FileDescription } catch {}
            [pscustomobject]@{ Exe = "$($_.ProcessName).exe"; Name = $(if ($desc) { $desc } else { $_.MainWindowTitle }) }
        } | Sort-Object Exe -Unique
}

$cfg     = Get-HdrGamesConfig
$running = Get-RunningHdrGame $cfg.Games
$panel   = New-Ui '<StackPanel/>'

# 1. HDR de cada pantalla (también se puede cambiar a mano)
$detail = if ($running) { "$($running.Name) está abierto: el HDR se volverá a activar al cerrarlo." }
          else { 'Se desactiva solo mientras haya abierto un juego de la lista.' }
[void]$panel.Children.Add((New-SectionHeader 'HDR ahora' $detail))
$displays = Get-HdrDisplays
if (-not $displays) { [void]$panel.Children.Add((New-Hint 'Ninguna pantalla conectada admite HDR.')) }
for ($i = 0; $i -lt $displays.Count; $i++) {
    $d = $displays[$i]
    [void]$panel.Children.Add((New-ToggleRow $d.Name "Pantalla $($i + 1) de $($displays.Count)" $d.Enabled {
        param($display, $on)
        if (-not [PcToolkit.Hdr.Native]::Set($display, $on)) { throw "Windows no ha dejado cambiar el HDR de $($display.Name)." }
    } $d))
}

# 2. Juegos de la lista
[void]$panel.Children.Add((New-SectionHeader 'Juegos' 'Mientras alguno de estos esté abierto, el HDR estará desactivado.'))
if (-not $cfg.Games) { [void]$panel.Children.Add((New-Hint 'No hay ningún juego en la lista.')) }
foreach ($g in $cfg.Games) {
    $row = New-Ui @'
<Border Style="{StaticResource Card}">
  <Grid>
    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
    <TextBlock x:Name="Icon" Style="{StaticResource Icon}" Text="&#xE7FC;" Foreground="{StaticResource SubBrush}"/>
    <StackPanel Grid.Column="1" Margin="12,0" VerticalAlignment="Center">
      <TextBlock x:Name="T" Style="{StaticResource Body}" TextTrimming="CharacterEllipsis"/>
      <TextBlock x:Name="D" Style="{StaticResource Caption}" TextTrimming="CharacterEllipsis"/>
    </StackPanel>
    <Button x:Name="Remove" Grid.Column="2" Style="{StaticResource IconButton}" Content="&#xE74D;"/>
  </Grid>
</Border>
'@
    $row.FindName('T').Text = $g.Name
    $row.FindName('D').Text = if ($running -and $running.Exe -eq $g.Exe) { "$($g.Exe)  ·  abierto ahora" } else { $g.Exe }
    if ($running -and $running.Exe -eq $g.Exe) { $row.FindName('Icon').Foreground = $app.Resources['AccentBrush'] }
    $remove = $row.FindName('Remove')
    [Windows.Automation.AutomationProperties]::SetName($remove, "Quitar $($g.Name)")
    $remove.Tag = $g.Exe
    $remove.Add_Click({ param($s, $e) Invoke-Safe { Remove-HdrGame $s.Tag } })
    [void]$panel.Children.Add($row)
}

# 3. Añadir: eligiendo un programa abierto o escribiendo el nombre de su .exe
[void]$panel.Children.Add((New-SectionHeader 'Añadir juego' 'Abre el juego y elígelo en la lista, o escribe el nombre de su .exe.'))
$add = New-Ui @'
<StackPanel>
  <Grid>
    <Button x:Name="Pick" Style="{StaticResource SubtleButton}" HorizontalContentAlignment="Stretch" Padding="10,7"
            AutomationProperties.Name="Elegir un programa abierto">
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <TextBlock Text="Elegir un programa abierto" FontSize="13" VerticalAlignment="Center"/>
        <TextBlock Grid.Column="1" Style="{StaticResource Icon}" Text="&#xE70D;" FontSize="10" Foreground="{StaticResource SubBrush}"/>
      </Grid>
    </Button>
    <Popup x:Name="Menu" PlacementTarget="{Binding ElementName=Pick}" Placement="Bottom" StaysOpen="False"
           AllowsTransparency="True" PopupAnimation="Fade" VerticalOffset="4">
      <Border Background="{StaticResource OsdBrush}" BorderBrush="{StaticResource StrokeBrush}" BorderThickness="1" CornerRadius="8" Padding="4">
        <ScrollViewer MaxHeight="260" VerticalScrollBarVisibility="Auto">
          <StackPanel x:Name="List"/>
        </ScrollViewer>
      </Border>
    </Popup>
  </Grid>
  <Grid Margin="0,8,0,4">
    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
    <TextBox x:Name="Exe" Style="{StaticResource Input}" Tag="juego.exe" AutomationProperties.Name="Nombre del .exe del juego"/>
    <Button x:Name="Add" Grid.Column="1" Style="{StaticResource AccentButton}" Content="Añadir" Margin="8,0,0,0"/>
  </Grid>
</StackPanel>
'@
$pick = $add.FindName('Pick')
$pick.Tag = @{ Menu = $add.FindName('Menu'); List = $add.FindName('List') }
$pick.Add_Click({
    param($s, $e)
    Invoke-Safe {
        $list = $s.Tag.List
        $list.Children.Clear()
        $known = @((Get-HdrGamesConfig).Games | ForEach-Object Exe)
        foreach ($p in (Get-WindowedPrograms | Where-Object { $known -notcontains $_.Exe })) {
            $item = New-Ui @'
<Button Style="{StaticResource SubtleButton}" Padding="8,5" HorizontalContentAlignment="Stretch" Margin="0,1,0,0">
  <StackPanel>
    <TextBlock x:Name="T" FontSize="12.5" Foreground="{StaticResource TextBrush}" TextTrimming="CharacterEllipsis"/>
    <TextBlock x:Name="D" Style="{StaticResource Caption}"/>
  </StackPanel>
</Button>
'@
            $item.FindName('T').Text = $p.Name
            $item.FindName('D').Text = $p.Exe
            $item.Tag = $p
            $item.Add_Click({ param($s2, $e2) Invoke-Safe { Add-HdrGame $s2.Tag.Exe $s2.Tag.Name } })
            [void]$list.Children.Add($item)
        }
        if (-not $list.Children.Count) { [void]$list.Children.Add((New-Hint 'No hay otros programas abiertos con ventana.')) }
        $s.Tag.Menu.Child.Width = $s.ActualWidth
        $s.Tag.Menu.IsOpen = $true
    }
})
$exeBox = $add.FindName('Exe')
$addBtn = $add.FindName('Add')
$addBtn.Tag = $exeBox
$addBtn.Add_Click({ param($s, $e) Invoke-Safe { Add-HdrGame $s.Tag.Text } })
$exeBox.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return') { Invoke-Safe { Add-HdrGame $s.Text } } })
[void]$panel.Children.Add($add)

$panel
