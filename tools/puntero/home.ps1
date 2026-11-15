# home.ps1 - Bloque de El Puntero en la portada del gestor: versión, si está en marcha y botón para abrir su
# ventana (el QR para emparejar un móvil y los móviles emparejados).

. (Join-Path $PSScriptRoot 'common.ps1')

$script:HomeSignatures['puntero'] = { "$(Get-PunteroVersion)|$(Test-PunteroRunning)" }

$version = Get-PunteroVersion
$row = New-Ui @'
<Grid Margin="36,8,0,0">
  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
  <StackPanel VerticalAlignment="Center" Margin="0,0,8,0">
    <TextBlock x:Name="Name" FontSize="12.5" Foreground="{StaticResource TextBrush}" TextTrimming="CharacterEllipsis"/>
    <TextBlock x:Name="Info" Style="{StaticResource Caption}" TextWrapping="NoWrap" TextTrimming="CharacterEllipsis"/>
  </StackPanel>
  <Button x:Name="Open" Grid.Column="1" Style="{StaticResource SubtleButton}" Padding="8,4" VerticalAlignment="Center"
          AutomationProperties.Name="Abrir El Puntero" ToolTip="El QR para emparejar un móvil y los móviles emparejados">
    <StackPanel Orientation="Horizontal">
      <TextBlock Style="{StaticResource Icon}" Text="&#xED14;" FontSize="12"/>
      <TextBlock Text="Emparejar" FontSize="12" Margin="6,0,0,0" VerticalAlignment="Center"/>
    </StackPanel>
  </Button>
</Grid>
'@
if ($version) {
    $row.FindName('Name').Text = "El Puntero $version"
    $row.FindName('Info').Text = if (Test-PunteroRunning) { 'En la bandeja, atento al móvil' } else { 'Parado: actívala para usarla desde el móvil' }
} else {
    $row.FindName('Name').Text = 'El Puntero no está instalado'
    $row.FindName('Name').Foreground = $app.Resources['WarnBrush']
    $row.FindName('Info').Text = 'Reinstala la herramienta para instalarlo'
    $row.FindName('Open').Visibility = 'Collapsed'
}
$row.FindName('Open').Add_Click({
    param($s, $e)
    $e.Handled = $true   # que no abra la página de la herramienta
    Invoke-Safe { Start-Puntero }
})
$row
