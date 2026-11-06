# home.ps1 - Bloque de Everything en la portada del gestor: estado, atajo y botón Buscar.

. (Join-Path $PSScriptRoot 'common.ps1')

$script:HomeSignatures['everything'] = {
    "$(Test-EverythingClient)|$(Get-ToolHotkey ($tools | Where-Object id -eq 'everything'))"
}

$keys = Get-ToolHotkey ($tools | Where-Object id -eq 'everything')
$running = Test-EverythingClient
$row = New-Ui @'
<Grid Margin="36,8,0,0">
  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
  <StackPanel VerticalAlignment="Center" Margin="0,0,8,0">
    <TextBlock x:Name="Name" FontSize="12.5" Foreground="{StaticResource TextBrush}" TextTrimming="CharacterEllipsis"/>
    <TextBlock x:Name="Info" Style="{StaticResource Caption}" TextWrapping="NoWrap" TextTrimming="CharacterEllipsis"/>
  </StackPanel>
  <Button x:Name="Open" Grid.Column="1" Style="{StaticResource SubtleButton}" Padding="8,4" VerticalAlignment="Center"
          AutomationProperties.Name="Buscar archivos">
    <StackPanel Orientation="Horizontal">
      <TextBlock Style="{StaticResource Icon}" Text="&#xE721;" FontSize="12"/>
      <TextBlock Text="Buscar" FontSize="12" Margin="6,0,0,0" VerticalAlignment="Center"/>
    </StackPanel>
  </Button>
</Grid>
'@
$row.FindName('Name').Text = if ($running) { 'Everything en marcha' }
                             elseif (Get-EverythingExe) { 'Everything no está en marcha' }
                             else { 'Everything no está instalado' }
if (-not $running) { $row.FindName('Name').Foreground = $app.Resources['WarnBrush'] }
$row.FindName('Info').Text = if ($keys) { "Atajo: $(Format-Hotkey $keys)" } else { 'Sin atajo de teclado' }
$row.FindName('Open').Add_Click({
    param($s, $e)
    $e.Handled = $true   # que no abra la página de la herramienta
    Invoke-Safe {
        . (Join-Path $script:EverythingDir 'window.ps1')
        Show-Everything   # al activarse, el panel se oculta solo
    }
})
$row
