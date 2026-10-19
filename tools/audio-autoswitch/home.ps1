# home.ps1 - Cambio rápido en la tarjeta de Audio AutoSwitch de la portada del gestor.
# La carga el gestor igual que settings.ps1 y muestra lo que devuelve debajo de la tarjeta.
# Una sola fila con el que suena; al pulsarla se despliega un menú flotante con todos para elegir
# directamente. La tarjeta mide siempre lo mismo aunque haya muchos dispositivos.

if (-not ('PcToolkit.Audio.Endpoints' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'AudioEndpoints.cs') }

# Repintar la portada cuando se enciende/apaga algo o cambia el que suena
$script:HomeSignatures['audio-autoswitch'] = { ([PcToolkit.Audio.Endpoints]::List(0) | ForEach-Object { "$($_.Id)$($_.IsDefault)" }) -join ';' }

$devices = @([PcToolkit.Audio.Endpoints]::List(0) | Where-Object { -not $_.IsHandsFree })
$current = @($devices | Where-Object IsDefault)[0]
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
      <TextBlock Grid.Column="1" Style="{StaticResource Icon}" Text="&#xE70D;" FontSize="10" Margin="10,0,2,0" Foreground="{StaticResource SubBrush}"/>
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
if ($current) {
    $root.FindName('Name').Text = $current.Name
    $root.FindName('Info').Text = "Sonando  ·  $($devices.Count) conectados"
} else {
    $root.FindName('Name').Text = 'Ningún dispositivo de sonido'
}
foreach ($d in $devices) {
    [void]$root.FindName('List').Children.Add((New-ChoiceRow $d.Name '' $d.IsDefault {
        param($id)
        [PcToolkit.Audio.Endpoints]::SetDefault($id)
        Update-Page
    } $d.Id -Compact))
}
$pick.IsEnabled = $devices.Count -gt 0
$pick.Tag = $menu
$pick.Add_Click({
    param($s, $e)
    $s.Tag.Child.Width = $s.ActualWidth   # el menú, del mismo ancho que la fila
    $s.Tag.IsOpen = -not $s.Tag.IsOpen
    $e.Handled = $true
})
$root
