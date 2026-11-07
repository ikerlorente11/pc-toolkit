# home.ps1 - Bloque de Modo juegos en la portada del gestor: si está activado (Windows sin hipervisor)
# y botón para cambiarlo (pide confirmación y reinicia).

. (Join-Path $PSScriptRoot 'common.ps1')

if ($null -eq $script:GameModeHv) { $script:GameModeHv = Test-HypervisorRunning }   # no cambia sin reiniciar
$row = New-Ui @'
<Grid Margin="36,8,0,0">
  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
  <StackPanel VerticalAlignment="Center" Margin="0,0,8,0">
    <TextBlock x:Name="Name" FontSize="12.5" Foreground="{StaticResource TextBrush}" TextTrimming="CharacterEllipsis"/>
    <TextBlock x:Name="Info" Style="{StaticResource Caption}" TextWrapping="NoWrap" TextTrimming="CharacterEllipsis"/>
  </StackPanel>
  <Button x:Name="Switch" Grid.Column="1" Style="{StaticResource SubtleButton}" Padding="8,4" VerticalAlignment="Center">
    <StackPanel Orientation="Horizontal">
      <TextBlock Style="{StaticResource Icon}" Text="&#xE777;" FontSize="12"/>
      <TextBlock x:Name="SwitchText" FontSize="12" Margin="6,0,0,0" VerticalAlignment="Center"/>
    </StackPanel>
  </Button>
</Grid>
'@
if ($script:GameModeHv) {
    $row.FindName('Name').Text = 'Modo juegos: desactivado'
    $row.FindName('Info').Text = 'Con hipervisor  ·  WSL y Docker disponibles, emuladores más lentos'
    $row.FindName('SwitchText').Text = 'Activar'
} else {
    $row.FindName('Name').Text = 'Modo juegos: activado'
    $row.FindName('Info').Text = 'Sin hipervisor  ·  WSL y Docker no disponibles'
    $row.FindName('SwitchText').Text = 'Desactivar'
}
$switch = $row.FindName('Switch')
[Windows.Automation.AutomationProperties]::SetName($switch, "$($row.FindName('SwitchText').Text) modo juegos y reiniciar")
$switch.IsEnabled = [bool](Test-GameModeReady)
$switch.Add_Click({
    param($s, $e)
    $e.Handled = $true   # que no abra la página de la herramienta
    Invoke-Safe { Invoke-GameModeSwitch $script:GameModeHv }
})
$row
