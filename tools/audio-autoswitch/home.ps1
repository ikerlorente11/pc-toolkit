# home.ps1 - Cambio rápido en la tarjeta de Audio AutoSwitch de la portada del gestor.
# La carga el gestor igual que settings.ps1 y muestra lo que devuelve debajo de la tarjeta.
# Una sola fila con el que suena; al pulsarla se despliega un menú flotante con los dispositivos
# habilitados conectados para elegir directamente. La tarjeta mide siempre lo mismo.

. (Join-Path $PSScriptRoot 'common.ps1')

# Repintar la portada al encender/apagar algo, cambiar el que suena o (des)habilitar dispositivos
$script:HomeSignatures['audio-autoswitch'] = {
    $cfgPath = Join-Path $script:AudioDataDir 'config.json'
    $stamp = if (Test-Path $cfgPath) { (Get-Item $cfgPath).LastWriteTimeUtc.Ticks }
    (([PcToolkit.Audio.Endpoints]::List(0) | ForEach-Object { "$($_.Id)$($_.IsDefault)" }) -join ';') + "|$stamp"
}

$devices = Get-EnabledAudioDevices
$current = @([PcToolkit.Audio.Endpoints]::List(0) | Where-Object IsDefault)[0]   # puede no estar habilitado
$root = New-Ui @'
<Grid Margin="28,8,0,0">
  <Button x:Name="Pick" Style="{StaticResource SubtleButton}" HorizontalContentAlignment="Stretch" Padding="8,5"
          AutomationProperties.Name="Elegir dispositivo de sonido">
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <StackPanel VerticalAlignment="Center">
        <TextBlock x:Name="Name" FontSize="12.5" Foreground="{StaticResource TextBrush}" TextTrimming="CharacterEllipsis"/>
        <TextBlock x:Name="Info" Style="{StaticResource Caption}"/>
      </StackPanel>
      <TextBlock x:Name="Arrow" Grid.Column="1" Style="{StaticResource Icon}" Text="&#xE70D;" FontSize="10" Margin="10,0,2,0" Foreground="{StaticResource SubBrush}"/>
    </Grid>
  </Button>
  <Popup x:Name="Menu" PlacementTarget="{Binding ElementName=Pick}" Placement="Bottom" StaysOpen="False"
         AllowsTransparency="True" PopupAnimation="Fade" VerticalOffset="4">
    <Border Background="{StaticResource OsdBrush}" BorderBrush="{StaticResource StrokeBrush}" BorderThickness="1" CornerRadius="8" Padding="4">
      <ScrollViewer MaxHeight="230" VerticalScrollBarVisibility="Auto">
        <StackPanel x:Name="List"/>
      </ScrollViewer>
    </Border>
  </Popup>
</Grid>
'@
$pick = $root.FindName('Pick')
$menu = $root.FindName('Menu')
$root.FindName('Name').Text = if ($current) { $current.Name } else { 'Ningún dispositivo de sonido' }
$root.FindName('Info').Text = switch ($devices.Count) {
    0       { 'No hay dispositivos habilitados conectados' }
    1       { 'Sonando  ·  1 habilitado conectado' }
    default { "Sonando  ·  $_ habilitados conectados" }
}
foreach ($d in $devices) {
    [void]$root.FindName('List').Children.Add((New-ChoiceRow $d.Name '' $d.IsDefault {
        param($id)
        [PcToolkit.Audio.Endpoints]::SetDefault($id)
        Update-Page
    } $d.Id -Compact))
}
if (-not $devices) { $root.FindName('Arrow').Visibility = 'Hidden' }
$pick.IsEnabled = $devices.Count -gt 0
$pick.Tag = $menu
$pick.Add_Click({
    param($s, $e)
    $s.Tag.Child.Width = $s.ActualWidth   # el menú, del mismo ancho que la fila
    $s.Tag.IsOpen = -not $s.Tag.IsOpen
    $e.Handled = $true
})
$root
