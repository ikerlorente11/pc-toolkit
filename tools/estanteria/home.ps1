# home.ps1 - Bloque de La Estantería en la portada del gestor: versión instalada y botón Abrir.

. (Join-Path $PSScriptRoot 'common.ps1')

$script:HomeSignatures['estanteria'] = { "$(Get-EstanteriaVersion)|$(Test-EstanteriaRunning)" }

$version = Get-EstanteriaVersion
$row = New-Ui @'
<Grid Margin="36,8,0,0">
  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
  <StackPanel VerticalAlignment="Center" Margin="0,0,8,0">
    <TextBlock x:Name="Name" FontSize="12.5" Foreground="{StaticResource TextBrush}" TextTrimming="CharacterEllipsis"/>
    <TextBlock x:Name="Info" Style="{StaticResource Caption}" TextWrapping="NoWrap" TextTrimming="CharacterEllipsis"/>
  </StackPanel>
  <Button x:Name="Open" Grid.Column="1" Style="{StaticResource SubtleButton}" Padding="8,4" VerticalAlignment="Center"
          AutomationProperties.Name="Abrir La Estantería" ToolTip="Abrir La Estantería (Ctrl+Alt+L)">
    <StackPanel Orientation="Horizontal">
      <TextBlock Style="{StaticResource Icon}" Text="&#xE82D;" FontSize="12"/>
      <TextBlock Text="Abrir" FontSize="12" Margin="6,0,0,0" VerticalAlignment="Center"/>
    </StackPanel>
  </Button>
</Grid>
'@
if ($version) {
    $row.FindName('Name').Text = "La Estantería $version"
    $row.FindName('Info').Text = if (Test-EstanteriaRunning) { 'Abierta' } else { 'Tus cómics y libros de El Archivador' }
} else {
    $row.FindName('Name').Text = 'La Estantería no está instalada'
    $row.FindName('Name').Foreground = $app.Resources['WarnBrush']
    $row.FindName('Info').Text = 'Reinstala la herramienta para instalarla'
    $row.FindName('Open').Visibility = 'Collapsed'
}
$row.FindName('Open').Add_Click({
    param($s, $e)
    $e.Handled = $true   # que no abra la página de la herramienta
    Invoke-Safe { Start-Estanteria }
})
$row
