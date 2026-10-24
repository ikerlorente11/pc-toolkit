# settings.ps1 - Página de ajustes de Juegos dentro del gestor: HDR de cada pantalla y, por juego,
# si apaga el HDR y si va en ventana sin bordes (y en qué pantalla).
# El vigilante lee la lista en cada vuelta, así que los cambios se aplican solos.

. (Join-Path $PSScriptRoot 'common.ps1')

# Repintar al cambiar el HDR (desde aquí, Windows o el vigilante) o al abrir/cerrar un juego
$script:PageSignature = {
    $displays = (Get-HdrDisplays | ForEach-Object { "$($_.Key)=$($_.Enabled)" }) -join ','
    "$displays|$((Get-RunningGame (Get-GamesConfig).Games).Exe)"
}

function script:Add-Game([string]$Exe, [string]$Name) {
    $Exe = $Exe.Trim().Trim('"')
    if (-not $Exe) { return }
    $Exe = [IO.Path]::GetFileName($Exe)   # vale pegar la ruta completa
    if ($Exe -notmatch '\.exe$') { $Exe += '.exe' }
    $cfg = Get-GamesConfig
    if ($cfg.Games | Where-Object { $_.Exe -eq $Exe }) { return }
    if (-not $Name) { $Name = [IO.Path]::GetFileNameWithoutExtension($Exe) }
    $cfg.Games = @($cfg.Games) + [pscustomobject]@{ Exe = $Exe; Name = $Name; Hdr = $true; Borderless = $true; Screen = 'primary' }
    Save-GamesConfig $cfg
    Update-Page
}

function script:Remove-Game([string]$Exe) {
    $cfg = Get-GamesConfig
    $cfg.Games = @($cfg.Games | Where-Object { $_.Exe -ne $Exe })
    Save-GamesConfig $cfg
    Update-Page
}

# Cambia un ajuste (Hdr, Borderless, Screen) de un juego
function script:Set-GameSetting([string]$Exe, [string]$Name, $Value) {
    $cfg = Get-GamesConfig
    foreach ($g in $cfg.Games) { if ($g.Exe -eq $Exe) { $g.$Name = $Value } }
    Save-GamesConfig $cfg
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

# Botón con menú flotante debajo (el XAML debe tener un Button x:Name="Pick")
function script:New-PopupButton([string]$Xaml) {
    New-Ui @"
<Grid>
  $Xaml
  <Popup x:Name="Menu" PlacementTarget="{Binding ElementName=Pick}" Placement="Bottom" StaysOpen="False"
         AllowsTransparency="True" PopupAnimation="Fade" VerticalOffset="4">
    <Border Background="{StaticResource OsdBrush}" BorderBrush="{StaticResource StrokeBrush}" BorderThickness="1" CornerRadius="8" Padding="4">
      <ScrollViewer MaxHeight="260" VerticalScrollBarVisibility="Auto">
        <StackPanel x:Name="List"/>
      </ScrollViewer>
    </Border>
  </Popup>
</Grid>
"@
}

# Interruptor pequeño dentro de la tarjeta de un juego. Al cambiarlo: Set-GameSetting exe nombre activado
function script:New-GameOption([string]$Title, [bool]$Checked, [string]$Exe, [string]$Name) {
    $opt = New-Ui @'
<Grid Margin="0,8,0,0">
  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
  <TextBlock x:Name="T" FontSize="12.5" Foreground="{StaticResource TextBrush}" VerticalAlignment="Center"/>
  <CheckBox x:Name="Toggle" Grid.Column="1" Style="{StaticResource Toggle}"/>
</Grid>
'@
    $opt.FindName('T').Text = $Title
    $toggle = $opt.FindName('Toggle')
    $toggle.IsChecked = $Checked
    [Windows.Automation.AutomationProperties]::SetName($toggle, $Title)
    $toggle.Tag = @{ Exe = $Exe; Name = $Name }
    $onToggle = { param($s, $e) Invoke-Safe { Set-GameSetting $s.Tag.Exe $s.Tag.Name ([bool]$s.IsChecked) } }
    $toggle.Add_Checked($onToggle)
    $toggle.Add_Unchecked($onToggle)
    $opt
}

$cfg     = Get-GamesConfig
$running = Get-RunningGame $cfg.Games
$hdrGame = Get-RunningGame $cfg.Games -Hdr
$panel   = New-Ui '<StackPanel/>'

# 1. Juegos de la lista y sus opciones
[void]$panel.Children.Add((New-SectionHeader 'Juegos' 'Se aplica solo al abrir cada juego. Para la ventana sin bordes, ponlo en modo ventana dentro del juego.'))
if (-not $cfg.Games) { [void]$panel.Children.Add((New-Hint 'No hay ningún juego en la lista.')) }
foreach ($g in $cfg.Games) {
    $card = New-Ui @'
<Border Style="{StaticResource Card}">
  <StackPanel>
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <TextBlock x:Name="Icon" Style="{StaticResource Icon}" Text="&#xE7FC;" Foreground="{StaticResource SubBrush}"/>
      <StackPanel Grid.Column="1" Margin="12,0" VerticalAlignment="Center">
        <TextBlock x:Name="T" Style="{StaticResource Body}" TextTrimming="CharacterEllipsis"/>
        <TextBlock x:Name="D" Style="{StaticResource Caption}" TextTrimming="CharacterEllipsis"/>
      </StackPanel>
      <Button x:Name="Remove" Grid.Column="2" Style="{StaticResource IconButton}" Content="&#xE74D;"/>
    </Grid>
    <StackPanel x:Name="Options" Margin="30,0,0,0"/>
  </StackPanel>
</Border>
'@
    $isOpen = $running -and $running.Exe -eq $g.Exe
    $card.FindName('T').Text = $g.Name
    $card.FindName('D').Text = if ($isOpen) { "$($g.Exe)  ·  abierto ahora" } else { $g.Exe }
    if ($isOpen) { $card.FindName('Icon').Foreground = $app.Resources['AccentBrush'] }
    $remove = $card.FindName('Remove')
    [Windows.Automation.AutomationProperties]::SetName($remove, "Quitar $($g.Name)")
    $remove.Tag = $g.Exe
    $remove.Add_Click({ param($s, $e) Invoke-Safe { Remove-Game $s.Tag } })

    $options = $card.FindName('Options')
    [void]$options.Children.Add((New-GameOption 'Desactivar el HDR mientras está abierto' $g.Hdr $g.Exe 'Hdr'))
    [void]$options.Children.Add((New-GameOption 'Ventana sin bordes a pantalla completa' $g.Borderless $g.Exe 'Borderless'))

    # Pantalla de la ventana sin bordes: botón con la elegida y menú con todas
    if ($g.Borderless) {
        $screen = Get-GameScreen $g.Screen
        $pickRoot = New-PopupButton @'
  <Button x:Name="Pick" Style="{StaticResource SubtleButton}" HorizontalContentAlignment="Stretch" Padding="8,5" Margin="0,6,0,0">
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <TextBlock Style="{StaticResource Icon}" Text="&#xE7F4;" FontSize="12" Foreground="{StaticResource SubBrush}"/>
      <TextBlock x:Name="Screen" Grid.Column="1" FontSize="12.5" Margin="10,0,0,0" VerticalAlignment="Center" Foreground="{StaticResource TextBrush}"/>
      <TextBlock Grid.Column="2" Style="{StaticResource Icon}" Text="&#xE70D;" FontSize="10" Foreground="{StaticResource SubBrush}"/>
    </Grid>
  </Button>
'@
        $pickRoot.FindName('Screen').Text = "Pantalla: $(Get-ScreenLabel $screen)"
        foreach ($s in ([Windows.Forms.Screen]::AllScreens | Sort-Object { $_.Bounds.X })) {
            $value = if ($s.Primary) { 'primary' } else { $s.DeviceName }
            $choice = New-ChoiceRow (Get-ScreenLabel $s) '' ($s.DeviceName -eq $screen.DeviceName) {
                param($arg) Set-GameSetting $arg.Exe 'Screen' $arg.Screen
            } @{ Exe = $g.Exe; Screen = $value } -Compact
            [void]$pickRoot.FindName('List').Children.Add($choice)
        }
        $pick = $pickRoot.FindName('Pick')
        [Windows.Automation.AutomationProperties]::SetName($pick, "Pantalla de $($g.Name)")
        $pick.Tag = $pickRoot.FindName('Menu')
        $pick.Add_Click({ param($s, $e) $s.Tag.Child.Width = $s.ActualWidth; $s.Tag.IsOpen = -not $s.Tag.IsOpen })
        [void]$options.Children.Add($pickRoot)
    }
    [void]$panel.Children.Add($card)
}

# 2. Añadir: eligiendo un programa abierto o escribiendo el nombre de su .exe
[void]$panel.Children.Add((New-SectionHeader 'Añadir juego' 'Abre el juego y elígelo en la lista, o escribe el nombre de su .exe.'))
$add = New-PopupButton @'
  <StackPanel>
    <Button x:Name="Pick" Style="{StaticResource SubtleButton}" HorizontalContentAlignment="Stretch" Padding="10,7"
            AutomationProperties.Name="Elegir un programa abierto">
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <TextBlock Text="Elegir un programa abierto" FontSize="13" VerticalAlignment="Center"/>
        <TextBlock Grid.Column="1" Style="{StaticResource Icon}" Text="&#xE70D;" FontSize="10" Foreground="{StaticResource SubBrush}"/>
      </Grid>
    </Button>
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
        $known = @((Get-GamesConfig).Games | ForEach-Object Exe)
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
            $item.Add_Click({ param($s2, $e2) Invoke-Safe { Add-Game $s2.Tag.Exe $s2.Tag.Name } })
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
$addBtn.Add_Click({ param($s, $e) Invoke-Safe { Add-Game $s.Tag.Text } })
$exeBox.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return') { Invoke-Safe { Add-Game $s.Text } } })
[void]$panel.Children.Add($add)

# 3. HDR de cada pantalla (también se puede cambiar a mano)
$detail = if ($hdrGame) { "$($hdrGame.Name) está abierto: el HDR se volverá a activar al cerrarlo." }
          else { 'Para cambiarlo a mano (como Win + Alt + B).' }
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

$panel
