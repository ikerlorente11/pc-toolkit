# settings.ps1 - Página de ajustes de la Barra de tareas dentro del gestor.
# Dos perfiles: normal y, opcional, Escritorio remoto. Los cambios del perfil en uso se aplican al
# momento (la posición, que reinicia Explorer, se aplica en segundo plano con la tarea programada).

. (Join-Path $PSScriptRoot 'common.ps1')

# $Key: 'Local|AutoHide', 'Remote|Position'... o 'RemoteEnabled'
function script:Set-TaskbarSetting([string]$Key, $Value) {
    $name, $field = $Key -split '\|'
    $cfg = Get-TaskbarConfig
    if ($field) { $cfg[$name][$field] = $Value } else { $cfg[$name] = $Value }
    Save-TaskbarConfig $cfg
    $tool = $tools | Where-Object id -eq 'taskbar'
    if ((Get-ToolState $tool) -eq 'Enabled') {
        $active = Get-ActiveTaskbarProfileName $cfg
        Invoke-TaskbarProfile $cfg[$active] -SkipPosition
        if (Test-TaskbarPositionPending $cfg[$active]) {
            Start-ScheduledTask -TaskName $tool.task   # reinicia Explorer sin bloquear el panel
            Show-Osd ([string][char]0xE7F4) 'Aplicando la posición de la barra de tareas...' 'El Explorador de Windows se reiniciará'
        }
    }
    Update-Page
}

# Opciones excluyentes en botones. Con dos opciones van a la derecha del título; con más, debajo.
function script:New-TaskbarSegmentRow([string]$Title, [string]$Detail, [string]$Key, [string]$Value, $Options) {
    $row = New-Ui @'
<Border Style="{StaticResource Card}">
  <Grid>
    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <StackPanel VerticalAlignment="Center" Margin="0,0,12,0">
      <TextBlock x:Name="T" Style="{StaticResource Body}"/>
      <TextBlock x:Name="D" Style="{StaticResource Caption}"/>
    </StackPanel>
    <Border x:Name="Box" Grid.Column="1" BorderBrush="{StaticResource StrokeBrush}" BorderThickness="1" CornerRadius="6" Padding="2"
            HorizontalAlignment="Left" VerticalAlignment="Center">
      <StackPanel x:Name="Options" Orientation="Horizontal"/>
    </Border>
  </Grid>
</Border>
'@
    $row.FindName('T').Text = $Title
    if ($Detail) { $row.FindName('D').Text = $Detail } else { $row.FindName('D').Visibility = 'Collapsed' }
    if ($Options.Count -gt 2) {
        $box = $row.FindName('Box')
        [Windows.Controls.Grid]::SetColumn($box, 0); [Windows.Controls.Grid]::SetRow($box, 1)
        [Windows.Controls.Grid]::SetColumnSpan($box, 2)
        $box.Margin = '0,8,0,0'
    }
    foreach ($o in $Options) {
        $style = if ($o[0] -eq $Value) { 'AccentButton' } else { 'SubtleButton' }
        $b = New-Ui "<Button Style=`"{StaticResource $style}`" Padding=`"10,3`" FontSize=`"12`"/>"
        $b.Content = $o[1]
        $b.Tag = @($Key, $o[0])
        [Windows.Automation.AutomationProperties]::SetName($b, "$Title`: $($o[1])")
        $b.Add_Click({ param($s, $e) Invoke-Safe { Set-TaskbarSetting $s.Tag[0] $s.Tag[1] } })
        [void]$row.FindName('Options').Children.Add($b)
    }
    $row
}

function script:Add-TaskbarProfileRows($Panel, [string]$Name, $TaskbarProfile) {
    $set = { param($key, $on) Set-TaskbarSetting $key $on }
    $positions = @(Get-TaskbarPositions | ForEach-Object { , @($_, $script:TaskbarPositionLabels[$_]) })
    $positionDetail = 'Cambiar la posición reinicia el Explorador de Windows.' + $(if ($script:IsWindows11) { ' Windows 11 no admite la barra en los laterales.' })
    [void]$Panel.Children.Add((New-TaskbarSegmentRow 'Posición' $positionDetail "$Name|Position" $TaskbarProfile.Position $positions))
    [void]$Panel.Children.Add((New-ToggleRow 'Ocultar automáticamente' 'La barra se oculta y aparece al acercar el puntero al borde de la pantalla.' $TaskbarProfile.AutoHide $set "$Name|AutoHide"))
    [void]$Panel.Children.Add((New-TaskbarSegmentRow 'Alineación de los iconos' '' "$Name|Alignment" $TaskbarProfile.Alignment @(@('left', 'Izquierda'), @('center', 'Centro'))))
    [void]$Panel.Children.Add((New-TaskbarSegmentRow 'Tamaño de los iconos' 'Automático: se reducen solo cuando la barra está llena.' "$Name|IconSize" $TaskbarProfile.IconSize @(@('small', 'Pequeños'), @('normal', 'Normales'), @('auto', 'Automático'))))
    [void]$Panel.Children.Add((New-TaskbarSegmentRow 'Búsqueda' '' "$Name|Search" $TaskbarProfile.Search @(@('hidden', 'Oculta'), @('icon', 'Icono'), @('box', 'Cuadro de búsqueda'))))
    [void]$Panel.Children.Add((New-ToggleRow 'Mostrar en todas las pantallas' 'Si está desactivado, la barra solo aparece en la pantalla principal.' $TaskbarProfile.AllScreens $set "$Name|AllScreens"))
}

# Repintar al conectar/desconectar por Escritorio remoto o al cambiar la configuración
$script:PageSignature = {
    $path = Join-Path $script:TaskbarDataDir 'config.json'
    "$([PcToolkit.Taskbar.Native]::IsRemote)|$([PcToolkit.Taskbar.Native]::GetEdge())|$(if (Test-Path $path) { (Get-Item $path).LastWriteTimeUtc.Ticks })"
}

$cfg    = Get-TaskbarConfig
$active = Get-ActiveTaskbarProfileName $cfg
$panel  = New-Ui '<StackPanel/>'

# 1. Restablecer
[void]$panel.Children.Add((New-SectionHeader 'Restablecer'))
$refresh = New-Ui @'
<Border Style="{StaticResource Card}">
  <Grid>
    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
    <StackPanel VerticalAlignment="Center" Margin="0,0,12,0">
      <TextBlock Style="{StaticResource Body}" Text="Refrescar la barra de tareas"/>
      <TextBlock Style="{StaticResource Caption}" Text="Útil cuando la barra con ocultación automática no aparece al acercar el puntero."/>
    </StackPanel>
    <Button x:Name="Refresh" Grid.Column="1" Style="{StaticResource AccentButton}" Content="Refrescar" VerticalAlignment="Center"/>
  </Grid>
</Border>
'@
$refresh.FindName('Refresh').Add_Click({
    param($s, $e)
    Invoke-Safe {
        Invoke-TaskbarRefresh
        Show-Osd ([string][char]0xE72C) 'Barra de tareas refrescada' 'PC Toolkit'
    }
})
[void]$panel.Children.Add($refresh)

# 2. Perfil normal
$detail = 'Se aplica en las sesiones locales.' + $(if ($active -eq 'Local') { '  ·  En uso' })
[void]$panel.Children.Add((New-SectionHeader 'Perfil normal' $detail))
Add-TaskbarProfileRows $panel 'Local' $cfg.Local

# 3. Perfil de Escritorio remoto
$detail = 'Se aplica al conectarse a este equipo mediante Escritorio remoto.' + $(if ($active -eq 'Remote') { '  ·  En uso' })
[void]$panel.Children.Add((New-SectionHeader 'Perfil de Escritorio remoto' $detail))
[void]$panel.Children.Add((New-ToggleRow 'Usar un perfil independiente' 'Si está desactivado, en Escritorio remoto se aplica el perfil normal.' $cfg.RemoteEnabled { param($key, $on) Set-TaskbarSetting $key $on } 'RemoteEnabled'))
if ($cfg.RemoteEnabled) { Add-TaskbarProfileRows $panel 'Remote' $cfg.Remote }

$panel
