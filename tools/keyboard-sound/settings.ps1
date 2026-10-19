# settings.ps1 - Página de ajustes de Keyboard Sound dentro del gestor: sonido, volumen e inicio.
# El vigilante aplica solo los cambios de sonido y volumen en un par de segundos.

. (Join-Path $PSScriptRoot 'common.ps1')

# Muestra del sonido en el propio gestor (se reutiliza mientras no cambie el sonido)
function script:Invoke-KeyboardSoundPreview {
    $cfg = Get-KeyboardSoundConfig
    if ($script:KsPreviewSound -ne $cfg.Sound) {
        if ($script:KsPreview) { $script:KsPreview.Dispose() }
        $script:KsPreview = New-Object PcToolkit.KeyboardSound.Player((Get-KeyboardSoundFile $cfg.Sound), 4)
        $script:KsPreviewSound = $cfg.Sound
    }
    $script:KsPreview.SetVolume($cfg.Volume)
    $script:KsPreview.Play()
}

function script:Set-KeyboardSoundSetting([string]$Name, $Value) {
    $cfg = Get-KeyboardSoundConfig
    $cfg[$Name] = $Value
    Save-KeyboardSoundConfig $cfg
}

$cfg   = Get-KeyboardSoundConfig
$panel = New-Ui '<StackPanel/>'

# 1. Sonido
[void]$panel.Children.Add((New-SectionHeader 'Sonido' 'Al seleccionar uno se reproduce una muestra.'))
foreach ($id in $script:KeyboardSounds.Keys) {
    [void]$panel.Children.Add((New-ChoiceRow $script:KeyboardSounds[$id] '' ($cfg.Sound -eq $id) {
        param($sound)
        Set-KeyboardSoundSetting 'Sound' $sound
        Invoke-KeyboardSoundPreview
        Update-Page
    } $id))
}

# 2. Volumen (solo el de este sonido, no el del sistema)
[void]$panel.Children.Add((New-SectionHeader 'Volumen' 'Ajusta el volumen de los sonidos sin cambiar el volumen del sistema.'))
$vol = New-Ui @'
<Border Style="{StaticResource Card}">
  <Grid>
    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
    <TextBlock Style="{StaticResource Icon}" Text="&#xE993;" Foreground="{StaticResource SubBrush}"/>
    <Slider x:Name="Volume" Grid.Column="1" Style="{StaticResource Slider}" Minimum="0" Maximum="100" Margin="12,0"
            SmallChange="1" LargeChange="10" AutomationProperties.Name="Volumen"/>
    <TextBlock x:Name="Value" Grid.Column="2" Style="{StaticResource Body}" Width="40" TextAlignment="Right" VerticalAlignment="Center"/>
  </Grid>
</Border>
'@
$slider = $vol.FindName('Volume')
$slider.Value = $cfg.Volume
$slider.Tag = $vol.FindName('Value')
$slider.Tag.Text = "$($cfg.Volume) %"
# Se guarda (y suena la muestra) 0,4 s después del último cambio, venga del ratón, del teclado o de
# un lector de pantalla, y no en cada paso del arrastre
if (-not $script:KsVolumeTimer) {
    $script:KsVolumeTimer = New-Object Windows.Threading.DispatcherTimer
    $script:KsVolumeTimer.Interval = [TimeSpan]::FromMilliseconds(400)
    $script:KsVolumeTimer.Add_Tick({
        $script:KsVolumeTimer.Stop()
        Invoke-Safe { Set-KeyboardSoundSetting 'Volume' $script:KsPendingVolume; Invoke-KeyboardSoundPreview }
    })
}
$slider.Add_ValueChanged({
    param($s, $e)
    $s.Tag.Text = "$([int]$s.Value) %"
    $script:KsPendingVolume = [int]$s.Value
    $script:KsVolumeTimer.Stop(); $script:KsVolumeTimer.Start()
})
[void]$panel.Children.Add($vol)

# 3. Probar escribiendo
[void]$panel.Children.Add((New-SectionHeader 'Probar' 'Escribe aquí para escuchar el sonido y el volumen elegidos.'))
$test = New-Ui '<TextBox Style="{StaticResource Input}" Tag="Escribe algo..." Margin="0,0,0,4" AutomationProperties.Name="Campo de prueba de sonido"/>'
$test.Add_PreviewKeyDown({
    param($s, $e)
    if ($e.IsRepeat) { return }
    # Con la herramienta activa ya suena por el vigilante (escucha todo el teclado): aquí no, para no duplicarlo
    $tool = $tools | Where-Object id -eq 'keyboard-sound'
    if ((Get-ToolState $tool) -eq 'Enabled' -and (Get-ToolProcess $tool)) { return }
    Invoke-Safe { Invoke-KeyboardSoundPreview }
})
[void]$panel.Children.Add($test)

# 4. Inicio
[void]$panel.Children.Add((New-SectionHeader 'Inicio'))
[void]$panel.Children.Add((New-ToggleRow 'Iniciar con Windows' 'Activa los sonidos automáticamente al iniciar sesión.' $cfg.StartWithWindows {
    param($a, $on)
    Set-KeyboardSoundSetting 'StartWithWindows' $on
    Register-KeyboardSoundTask $on
} $null))

$panel
