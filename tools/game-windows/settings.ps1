# settings.ps1 - Página de ajustes de Ventanas de juegos dentro del gestor: juegos y pantalla de cada uno.
# El vigilante lee la lista en cada vuelta, así que los cambios se aplican solos.

. (Join-Path $PSScriptRoot 'common.ps1')

function script:Add-GameWindow([string]$Exe, [string]$Name) {
    $Exe = $Exe.Trim().Trim('"')
    if (-not $Exe) { return }
    $Exe = [IO.Path]::GetFileName($Exe)   # vale pegar la ruta completa
    if ($Exe -notmatch '\.exe$') { $Exe += '.exe' }
    $cfg = Get-GameWindowsConfig
    if ($cfg.Games | Where-Object { $_.Exe -eq $Exe }) { return }
    if (-not $Name) { $Name = [IO.Path]::GetFileNameWithoutExtension($Exe) }
    $cfg.Games = @($cfg.Games) + [pscustomobject]@{ Exe = $Exe; Name = $Name; Screen = 'primary' }
    Save-GameWindowsConfig $cfg
    Update-Page
}

function script:Remove-GameWindow([string]$Exe) {
    $cfg = Get-GameWindowsConfig
    $cfg.Games = @($cfg.Games | Where-Object { $_.Exe -ne $Exe })
    Save-GameWindowsConfig $cfg
    Update-Page
}

function script:Set-GameWindowScreen($Arg) {
    $cfg = Get-GameWindowsConfig
    foreach ($g in $cfg.Games) { if ($g.Exe -eq $Arg.Exe) { $g.Screen = $Arg.Screen } }
    Save-GameWindowsConfig $cfg
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

# Menú flotante bajo un botón; $Fill rellena su lista al abrirlo
function script:New-PopupButton([string]$Xaml) {
    $root = New-Ui @"
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
    $root
}

$cfg   = Get-GameWindowsConfig
$panel = New-Ui '<StackPanel/>'

# 1. Juegos de la lista, con la pantalla en la que se ponen
[void]$panel.Children.Add((New-SectionHeader 'Juegos' 'Al abrirse, su ventana pierde los bordes y ocupa justo la pantalla elegida. Ponlos en modo ventana dentro del juego.'))
if (-not $cfg.Games) { [void]$panel.Children.Add((New-Hint 'No hay ningún juego en la lista.')) }
foreach ($g in $cfg.Games) {
    $screen = Get-GameScreen $g.Screen
    $row = New-Ui @'
<Border Style="{StaticResource Card}">
  <Grid>
    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <TextBlock Style="{StaticResource Icon}" Text="&#xE7FC;" Foreground="{StaticResource SubBrush}"/>
    <StackPanel Grid.Column="1" Margin="12,0" VerticalAlignment="Center">
      <TextBlock x:Name="T" Style="{StaticResource Body}" TextTrimming="CharacterEllipsis"/>
      <TextBlock x:Name="D" Style="{StaticResource Caption}" TextTrimming="CharacterEllipsis"/>
    </StackPanel>
    <Button x:Name="Remove" Grid.Column="2" Style="{StaticResource IconButton}" Content="&#xE74D;"/>
    <ContentControl x:Name="ScreenSlot" Grid.Row="1" Grid.ColumnSpan="3" Focusable="False"/>
  </Grid>
</Border>
'@
    $row.FindName('T').Text = $g.Name
    $row.FindName('D').Text = $g.Exe
    $remove = $row.FindName('Remove')
    [Windows.Automation.AutomationProperties]::SetName($remove, "Quitar $($g.Name)")
    $remove.Tag = $g.Exe
    $remove.Add_Click({ param($s, $e) Invoke-Safe { Remove-GameWindow $s.Tag } })

    # Pantalla: botón con la elegida y menú con todas
    $pickRoot = New-PopupButton @'
  <Button x:Name="Pick" Style="{StaticResource SubtleButton}" HorizontalContentAlignment="Stretch" Padding="8,5" Margin="0,8,0,0">
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
        $choice = New-ChoiceRow (Get-ScreenLabel $s) '' ($s.DeviceName -eq $screen.DeviceName) {
            param($arg) Set-GameWindowScreen $arg
        } @{ Exe = $g.Exe; Screen = $(if ($s.Primary) { 'primary' } else { $s.DeviceName }) } -Compact
        [void]$pickRoot.FindName('List').Children.Add($choice)
    }
    $pick = $pickRoot.FindName('Pick')
    [Windows.Automation.AutomationProperties]::SetName($pick, "Pantalla de $($g.Name)")
    $pick.Tag = $pickRoot.FindName('Menu')
    $pick.Add_Click({ param($s, $e) $s.Tag.Child.Width = $s.ActualWidth; $s.Tag.IsOpen = -not $s.Tag.IsOpen })
    $row.FindName('ScreenSlot').Content = $pickRoot
    [void]$panel.Children.Add($row)
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
        $known = @((Get-GameWindowsConfig).Games | ForEach-Object Exe)
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
            $item.Add_Click({ param($s2, $e2) Invoke-Safe { Add-GameWindow $s2.Tag.Exe $s2.Tag.Name } })
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
$addBtn.Add_Click({ param($s, $e) Invoke-Safe { Add-GameWindow $s.Tag.Text } })
$exeBox.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return') { Invoke-Safe { Add-GameWindow $s.Text } } })
[void]$panel.Children.Add($add)

$panel
