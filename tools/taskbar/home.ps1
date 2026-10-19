# home.ps1 - Bloque de la Barra de tareas en la portada del gestor: perfil en uso + botón Refrescar.

. (Join-Path $PSScriptRoot 'common.ps1')

# Repintar al conectar/desconectar por Escritorio Remoto o al cambiar la configuración
$script:HomeSignatures['taskbar'] = {
    $path = Join-Path $script:TaskbarDataDir 'config.json'
    "$([PcToolkit.Taskbar.Native]::IsRemote)|$(if (Test-Path $path) { (Get-Item $path).LastWriteTimeUtc.Ticks })"
}

$cfg  = Get-TaskbarConfig
$name = Get-ActiveTaskbarProfileName $cfg
$row = New-Ui @'
<Grid Margin="36,8,0,0">
  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
  <StackPanel VerticalAlignment="Center" Margin="0,0,8,0">
    <TextBlock x:Name="Name" FontSize="12.5" Foreground="{StaticResource TextBrush}" TextTrimming="CharacterEllipsis"/>
    <TextBlock x:Name="Info" Style="{StaticResource Caption}" TextWrapping="NoWrap" TextTrimming="CharacterEllipsis"/>
  </StackPanel>
  <Button x:Name="Refresh" Grid.Column="1" Style="{StaticResource SubtleButton}" Padding="8,4" VerticalAlignment="Center"
          AutomationProperties.Name="Refrescar barra de tareas">
    <StackPanel Orientation="Horizontal">
      <TextBlock Style="{StaticResource Icon}" Text="&#xE72C;" FontSize="12"/>
      <TextBlock Text="Refrescar" FontSize="12" Margin="6,0,0,0" VerticalAlignment="Center"/>
    </StackPanel>
  </Button>
</Grid>
'@
$row.FindName('Name').Text = "Perfil $(Get-TaskbarProfileLabel $name)"
$row.FindName('Info').Text = Get-TaskbarProfileSummary $cfg[$name]
$row.FindName('Refresh').Add_Click({
    param($s, $e)
    $e.Handled = $true   # que no abra la página de la herramienta
    Invoke-Safe {
        Invoke-TaskbarRefresh
        Show-Osd ([string][char]0xE72C) 'Barra de tareas refrescada' 'PC Toolkit'
    }
})
$row
