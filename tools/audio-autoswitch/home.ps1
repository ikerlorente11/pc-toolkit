# home.ps1 - Cambio rápido en la tarjeta de Audio AutoSwitch de la portada del gestor.
# La carga el gestor igual que settings.ps1 y muestra lo que devuelve debajo de la tarjeta.
# Una sola fila con el que suena; al pulsarla se despliega un menú flotante con los dispositivos
# habilitados (los apagados en gris) para elegir directamente. La tarjeta mide siempre lo mismo.

. (Join-Path $PSScriptRoot 'common.ps1')

# Repintar la portada al encender/apagar algo, cambiar el que suena o (des)habilitar dispositivos
$script:HomeSignatures['audio-autoswitch'] = { Get-AudioSignature }

$all     = Get-EnabledAudioDevices -IncludeDisconnected   # los apagados salen en gris
$devices = @($all | Where-Object IsActive)
$current = @([PcToolkit.Audio.Endpoints]::List(0) | Where-Object IsDefault)[0]   # puede no estar habilitado
$root = New-Ui @'
<Grid Margin="28,8,0,0">
  <Button x:Name="Pick" Style="{StaticResource SubtleButton}" HorizontalContentAlignment="Stretch" Padding="8,5"
          AutomationProperties.Name="Elegir dispositivo de sonido">
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <StackPanel VerticalAlignment="Center">
        <TextBlock x:Name="Name" FontSize="12.5" Foreground="{StaticResource TextBrush}" TextTrimming="CharacterEllipsis"/>
        <TextBlock x:Name="Info" Style="{StaticResource Caption}" TextWrapping="NoWrap" TextTrimming="CharacterEllipsis"/>
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
$root.FindName('Name').Text = if ($current) { $current.Name } else { 'Sin dispositivo de audio' }
$root.FindName('Info').Text = if (-not $all) { 'No hay dispositivos habilitados' }
                              else { "Salida actual  ·  $($devices.Count) de $($all.Count) conectados" }
foreach ($d in $all) {
    $detail = if (-not $d.IsActive) { 'Desconectado' }
    $row = New-ChoiceRow $d.Name $detail $d.IsDefault {
        param($id)
        [PcToolkit.Audio.Endpoints]::SetDefault($id)
        Update-Page
    } $d.Id -Compact
    $row.IsEnabled = $d.IsActive   # no se puede cambiar a uno apagado: sale en gris
    [void]$root.FindName('List').Children.Add($row)
}
if (-not $all) { $root.FindName('Arrow').Visibility = 'Hidden' }
$pick.IsEnabled = $all.Count -gt 0
$pick.Tag = $menu
$pick.Add_Click({
    param($s, $e)
    $s.Tag.Child.Width = [Math]::Max($s.ActualWidth, 280)   # el menú, como la fila (o más ancho en un mosaico estrecho)
    $s.Tag.IsOpen = -not $s.Tag.IsOpen
    $e.Handled = $true
})
$root
