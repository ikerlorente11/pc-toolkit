# settings.ps1 - Página de ajustes de Sonidos de dispositivos: un sonido para conectar y otro para
# desconectar, elegidos de la biblioteca en un desplegable, y botones para probar los que están en uso.

. (Join-Path $PSScriptRoot 'common.ps1')

if (-not ('PcToolkit.DeviceSounds.SystemSound' -as [type])) {
    Add-Type -Namespace PcToolkit.DeviceSounds -Name SystemSound -MemberDefinition @'
[DllImport("winmm.dll", CharSet = CharSet.Unicode)] static extern bool PlaySound(string sound, IntPtr module, uint flags);
// Reproduce un sonido de Windows por su nombre de evento, tal y como esté configurado
public static void Play(string alias) { PlaySound(alias, IntPtr.Zero, 0x10000 | 0x2 | 0x1); }   // SND_ALIAS | SND_NODEFAULT | SND_ASYNC
'@
}

function script:Set-DeviceSound([string]$Name, [string]$Id) {
    $cfg = Get-DeviceSoundsConfig
    $cfg[$Name] = $Id
    Save-DeviceSoundsConfig $cfg
    $tool = $tools | Where-Object id -eq 'device-sounds'
    if ((Get-ToolState $tool) -eq 'Enabled') { Invoke-DeviceSounds }
    Invoke-DeviceSoundPreview (Get-DeviceSoundPath $Id $script:DeviceSoundEvents[$Name])
    Update-Page
}

# Fila con el sonido elegido; al pulsarla se despliega la biblioteca para elegir otro
function script:New-DeviceSoundSelector([string]$Name, [string]$Current) {
    $root = New-Ui @'
<Border Style="{StaticResource Card}" Padding="6">
  <Grid>
    <Button x:Name="Pick" Style="{StaticResource SubtleButton}" HorizontalContentAlignment="Stretch" Padding="8,6">
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <TextBlock Style="{StaticResource Icon}" Text="&#xE767;" FontSize="14" Foreground="{StaticResource AccentBrush}"/>
        <TextBlock x:Name="Value" Grid.Column="1" Style="{StaticResource Body}" Margin="12,0,0,0" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
        <TextBlock Grid.Column="2" Style="{StaticResource Icon}" Text="&#xE70D;" FontSize="10" Margin="10,0,2,0" Foreground="{StaticResource SubBrush}"/>
      </Grid>
    </Button>
    <Popup x:Name="Menu" PlacementTarget="{Binding ElementName=Pick}" Placement="Bottom" StaysOpen="False"
           AllowsTransparency="True" PopupAnimation="Fade" VerticalOffset="4">
      <Border Background="{StaticResource OsdBrush}" BorderBrush="{StaticResource StrokeBrush}" BorderThickness="1" CornerRadius="8" Padding="4">
        <ScrollViewer MaxHeight="280" VerticalScrollBarVisibility="Auto">
          <StackPanel x:Name="List"/>
        </ScrollViewer>
      </Border>
    </Popup>
  </Grid>
</Border>
'@
    $root.FindName('Value').Text = Get-DeviceSoundLabel $Current
    $pick = $root.FindName('Pick')
    [Windows.Automation.AutomationProperties]::SetName($pick, $(if ($Name -eq 'Connect') { 'Sonido al conectar' } else { 'Sonido al desconectar' }))
    $choose = { param($arg) $parts = $arg -split '\|'; Set-DeviceSound $parts[0] $parts[1] }
    foreach ($id in @('windows', 'none') + @($script:DeviceSoundLibrary.Keys)) {
        [void]$root.FindName('List').Children.Add((New-ChoiceRow (Get-DeviceSoundLabel $id) '' ($id -eq $Current) $choose "$Name|$id" -Compact))
    }
    $pick.Tag = $root.FindName('Menu')
    $pick.Add_Click({
        param($s, $e)
        $s.Tag.Child.Width = $s.ActualWidth
        $s.Tag.IsOpen = -not $s.Tag.IsOpen
        $e.Handled = $true
    })
    $root
}

$cfg   = Get-DeviceSoundsConfig
$panel = New-Ui '<StackPanel/>'

[void]$panel.Children.Add((New-SectionHeader 'Al conectar un dispositivo' 'Al elegir un sonido se reproduce una muestra.'))
[void]$panel.Children.Add((New-DeviceSoundSelector 'Connect' $cfg.Connect))
[void]$panel.Children.Add((New-SectionHeader 'Al desconectar un dispositivo'))
[void]$panel.Children.Add((New-DeviceSoundSelector 'Disconnect' $cfg.Disconnect))

# Probar: reproduce lo que Windows tiene configurado ahora, como al conectar o desconectar algo de verdad
[void]$panel.Children.Add((New-SectionHeader 'Probar' 'Reproduce los sonidos que Windows usa ahora mismo.'))
$test = New-Ui @'
<StackPanel Orientation="Horizontal">
  <Button x:Name="Connect" Style="{StaticResource SubtleButton}" Margin="0,0,4,0">
    <StackPanel Orientation="Horizontal">
      <TextBlock Style="{StaticResource Icon}" Text="&#xE768;" FontSize="12"/>
      <TextBlock Text="Conectar" Margin="8,0,0,0" VerticalAlignment="Center"/>
    </StackPanel>
  </Button>
  <Button x:Name="Disconnect" Style="{StaticResource SubtleButton}">
    <StackPanel Orientation="Horizontal">
      <TextBlock Style="{StaticResource Icon}" Text="&#xE768;" FontSize="12"/>
      <TextBlock Text="Desconectar" Margin="8,0,0,0" VerticalAlignment="Center"/>
    </StackPanel>
  </Button>
</StackPanel>
'@
$test.FindName('Connect').Add_Click({ [PcToolkit.DeviceSounds.SystemSound]::Play('DeviceConnect') })
$test.FindName('Disconnect').Add_Click({ [PcToolkit.DeviceSounds.SystemSound]::Play('DeviceDisconnect') })
[Windows.Automation.AutomationProperties]::SetName($test.FindName('Connect'), 'Probar sonido de conectar')
[Windows.Automation.AutomationProperties]::SetName($test.FindName('Disconnect'), 'Probar sonido de desconectar')
[void]$panel.Children.Add($test)

$panel
