# settings.ps1 - Página de ajustes de la Barra de tareas dentro del gestor.
# Dos perfiles: Normal (delante del PC) y, opcional, Escritorio Remoto. Si se cambia el perfil que
# está en uso (y la herramienta está activada), se aplica al momento.

. (Join-Path $PSScriptRoot 'common.ps1')

# $Key: 'Local|AutoHide', 'Remote|Alignment'... o 'RemoteEnabled'
function script:Set-TaskbarSetting([string]$Key, $Value) {
    $name, $field = $Key -split '\|'
    $cfg = Get-TaskbarConfig
    if ($field) { $cfg[$name][$field] = $Value } else { $cfg[$name] = $Value }
    Save-TaskbarConfig $cfg
    $tool = $tools | Where-Object id -eq 'taskbar'
    if ((Get-ToolState $tool) -eq 'Enabled') { [void](Invoke-ActiveTaskbarProfile) }
    Update-Page
}

# Fila con opciones excluyentes en botones (p. ej. Izquierda | Centro)
function script:New-TaskbarSegmentRow([string]$Title, [string]$Key, [string]$Value, $Options) {
    $row = New-Ui @'
<Border Style="{StaticResource Card}">
  <Grid>
    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
    <TextBlock x:Name="T" Style="{StaticResource Body}" VerticalAlignment="Center"/>
    <Border Grid.Column="1" BorderBrush="{StaticResource StrokeBrush}" BorderThickness="1" CornerRadius="6" Padding="2">
      <StackPanel x:Name="Options" Orientation="Horizontal"/>
    </Border>
  </Grid>
</Border>
'@
    $row.FindName('T').Text = $Title
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
    [void]$Panel.Children.Add((New-ToggleRow 'Ocultar automáticamente' 'Se esconde y aparece al llevar el ratón abajo.' $TaskbarProfile.AutoHide $set "$Name|AutoHide"))
    [void]$Panel.Children.Add((New-TaskbarSegmentRow 'Alineación de los iconos' "$Name|Alignment" $TaskbarProfile.Alignment @(@('left', 'Izquierda'), @('center', 'Centro'))))
    [void]$Panel.Children.Add((New-ToggleRow 'Mostrar en todas las pantallas' 'Si no, solo en la pantalla principal.' $TaskbarProfile.AllScreens $set "$Name|AllScreens"))
}

# Repintar al conectar/desconectar por Escritorio Remoto o al cambiar la configuración
$script:PageSignature = {
    $path = Join-Path $script:TaskbarDataDir 'config.json'
    "$([PcToolkit.Taskbar.Native]::IsRemote)|$(if (Test-Path $path) { (Get-Item $path).LastWriteTimeUtc.Ticks })"
}

$cfg    = Get-TaskbarConfig
$active = Get-ActiveTaskbarProfileName $cfg
$panel  = New-Ui '<StackPanel/>'

# 1. Refrescar (lo primero: es lo que se busca con prisa)
[void]$panel.Children.Add((New-SectionHeader 'Refrescar'))
$refresh = New-Ui @'
<Border Style="{StaticResource Card}">
  <Grid>
    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
    <StackPanel VerticalAlignment="Center" Margin="0,0,12,0">
      <TextBlock Style="{StaticResource Body}" Text="¿Se ha quedado escondida?"/>
      <TextBlock Style="{StaticResource Caption}" Text="Hace lo mismo que desmarcar y volver a marcar Ocultar automáticamente en Windows."/>
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
$detail = 'Cuando estás delante del PC.' + $(if ($active -eq 'Local') { '  ·  En uso ahora' })
[void]$panel.Children.Add((New-SectionHeader 'Normal' $detail))
Add-TaskbarProfileRows $panel 'Local' $cfg.Local

# 3. Perfil de Escritorio Remoto
$detail = 'Cuando te conectas a este PC por Escritorio Remoto.' + $(if ($active -eq 'Remote') { '  ·  En uso ahora' })
[void]$panel.Children.Add((New-SectionHeader 'Escritorio Remoto' $detail))
[void]$panel.Children.Add((New-ToggleRow 'Usar un perfil distinto' 'Si no, en Escritorio Remoto se usa el perfil normal.' $cfg.RemoteEnabled { param($key, $on) Set-TaskbarSetting $key $on } 'RemoteEnabled'))
if ($cfg.RemoteEnabled) { Add-TaskbarProfileRows $panel 'Remote' $cfg.Remote }

$panel
