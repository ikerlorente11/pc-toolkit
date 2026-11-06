# settings.ps1 - Página de ajustes de Everything dentro del gestor: resultados, ventana y estado de Everything.

. (Join-Path $PSScriptRoot 'common.ps1')

$cfg   = Get-EverythingConfig
$exe   = Get-EverythingExe
$panel = New-Ui '<StackPanel/>'
$script:PageSignature = { "$(Test-EverythingClient)|$([bool](Get-EverythingExe))" }

$open = New-Ui @'
<Button Style="{StaticResource AccentButton}" HorizontalAlignment="Left" Margin="0,4,0,0" AutomationProperties.Name="Abrir búsqueda">
  <StackPanel Orientation="Horizontal">
    <TextBlock Style="{StaticResource Icon}" Text="&#xE721;" FontSize="13" Foreground="{StaticResource OnAccentBrush}"/>
    <TextBlock Text="Abrir búsqueda" Margin="8,0,0,0" VerticalAlignment="Center"/>
  </StackPanel>
</Button>
'@
$open.Add_Click({
    Invoke-Safe {
        . (Join-Path $script:EverythingDir 'window.ps1')
        Show-Everything   # al activarse, el panel se oculta solo
    }
})
[void]$panel.Children.Add($open)

# Cambia un ajuste y, si la ventana ya existe, también lo que está usando
function script:Set-EverythingOption([string]$Name, $Value) {
    Set-EverythingSetting $Name $Value
    if ($script:EvCfg) { $script:EvCfg[$Name] = $Value }
}

[void]$panel.Children.Add((New-SectionHeader 'Resultados' 'Se muestran los 100 primeros. En el cuadro de búsqueda vale la sintaxis de Everything (*.pdf, ext:mp4, size:>1gb...).'))
foreach ($key in $script:EverythingSorts.Keys) {
    $detail = if ($key -eq 'name') { 'El más rápido.' } elseif ($key -in 'size', 'modified') { 'Puede tardar algo más si Everything no tiene indexado ese dato.' }
    [void]$panel.Children.Add((New-ChoiceRow "Ordenar por $($script:EverythingSorts[$key][0].ToLower())" $detail ($cfg.Sort -eq $key) {
        param($k)
        Set-EverythingOption 'Sort' $k
        Update-Page
    } $key))
}
[void]$panel.Children.Add((New-ToggleRow 'Mostrar carpetas' 'Si se desactiva, solo salen archivos.' $cfg.Folders {
    param($name, $on) Set-EverythingOption $name $on
} 'Folders'))
[void]$panel.Children.Add((New-ToggleRow 'Buscar también en la ruta' 'Las palabras pueden estar en las carpetas, no solo en el nombre: "fotos playa" encuentra Fotos\Playa\img001.jpg.' $cfg.MatchPath {
    param($name, $on) Set-EverythingOption $name $on
} 'MatchPath'))
[void]$panel.Children.Add((New-ToggleRow 'Ocultar la papelera de reciclaje' 'No muestra los archivos borrados que siguen en la papelera.' $cfg.HideRecycleBin {
    param($name, $on) Set-EverythingOption $name $on
} 'HideRecycleBin'))

[void]$panel.Children.Add((New-SectionHeader 'Ventana'))
[void]$panel.Children.Add((New-ToggleRow 'Cerrar al hacer clic fuera' 'La ventana se oculta al pasar a otra aplicación. La búsqueda se conserva para la próxima vez.' $cfg.CloseOnBlur {
    param($name, $on) Set-EverythingOption $name $on
} 'CloseOnBlur'))

# Estado de Everything, con botón para iniciarlo o abrir su propia ventana
[void]$panel.Children.Add((New-SectionHeader 'Everything'))
$card = New-Ui @'
<Border Style="{StaticResource Card}">
  <Grid>
    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
    <StackPanel VerticalAlignment="Center" Margin="0,0,12,0">
      <TextBlock x:Name="T" Style="{StaticResource Body}"/>
      <TextBlock x:Name="D" Style="{StaticResource Caption}"/>
    </StackPanel>
    <Button x:Name="Action" Grid.Column="1" Style="{StaticResource SubtleButton}" VerticalAlignment="Center"/>
  </Grid>
</Border>
'@
$running = Test-EverythingClient
$btn = $card.FindName('Action')
if ($exe) {
    $card.FindName('T').Text = "Everything $((Get-Item $exe).VersionInfo.ProductVersion)"
    $card.FindName('D').Text = if ($running) { "En marcha en la bandeja · $exe" } else { "No está en marcha · $exe" }
    if (-not $running) { $card.FindName('D').Foreground = $app.Resources['WarnBrush'] }
    $btn.Content = if ($running) { 'Abrir Everything' } else { 'Iniciar' }
    $btn.Tag = @{ Exe = $exe; Running = $running }
    $btn.Add_Click({
        param($s, $e)
        Invoke-Safe {
            if ($s.Tag.Running) { Start-Process $s.Tag.Exe } else { Start-EverythingClient; Update-Page }
        }
    })
} else {
    $card.FindName('T').Text = 'Everything no está instalado'
    $card.FindName('D').Text = 'Desinstala y vuelve a instalar esta herramienta para instalarlo con winget.'
    $card.FindName('D').Foreground = $app.Resources['WarnBrush']
    $btn.Visibility = 'Collapsed'
}
[void]$panel.Children.Add($card)

$panel
