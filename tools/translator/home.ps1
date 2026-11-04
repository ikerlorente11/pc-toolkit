# home.ps1 - Bloque del Traductor en la portada del gestor: idioma de destino, atajo y botón Abrir.

. (Join-Path $PSScriptRoot 'common.ps1')

$script:HomeSignatures['translator'] = {
    $path = Join-Path $script:TranslatorData 'config.json'
    "$(if (Test-Path $path) { (Get-Item $path).LastWriteTimeUtc.Ticks })|$(Get-ToolHotkey ($tools | Where-Object id -eq 'translator'))"
}

$cfg  = Get-TranslatorConfig
$keys = Get-ToolHotkey ($tools | Where-Object id -eq 'translator')
$row = New-Ui @'
<Grid Margin="36,8,0,0">
  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
  <StackPanel VerticalAlignment="Center" Margin="0,0,8,0">
    <TextBlock x:Name="Name" FontSize="12.5" Foreground="{StaticResource TextBrush}" TextTrimming="CharacterEllipsis"/>
    <TextBlock x:Name="Info" Style="{StaticResource Caption}" TextWrapping="NoWrap" TextTrimming="CharacterEllipsis"/>
  </StackPanel>
  <Button x:Name="Open" Grid.Column="1" Style="{StaticResource SubtleButton}" Padding="8,4" VerticalAlignment="Center"
          AutomationProperties.Name="Abrir traductor">
    <StackPanel Orientation="Horizontal">
      <TextBlock Style="{StaticResource Icon}" Text="&#xE8A7;" FontSize="12"/>
      <TextBlock Text="Abrir" FontSize="12" Margin="6,0,0,0" VerticalAlignment="Center"/>
    </StackPanel>
  </Button>
</Grid>
'@
$row.FindName('Name').Text = "A $($(Get-TranslatorLanguageName $cfg.Target).ToLower())"
$row.FindName('Info').Text = if ($keys) { "Atajo: $(Format-Hotkey $keys)" } else { 'Sin atajo de teclado' }
$row.FindName('Open').Add_Click({
    param($s, $e)
    $e.Handled = $true   # que no abra la página de la herramienta
    Invoke-Safe {
        . (Join-Path $script:TranslatorDir 'window.ps1')
        Show-Translator   # al activarse, el panel se oculta solo
    }
})
$row
