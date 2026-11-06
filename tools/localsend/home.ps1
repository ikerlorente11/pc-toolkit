# home.ps1 - Bloque de LocalSend en la portada del gestor: con qué nombre se ve el PC y botones Enviar y Abrir.

. (Join-Path $PSScriptRoot 'common.ps1')

$script:HomeSignatures['localsend'] = { "$([bool](Get-LocalSendExe))|$(Test-LocalSendRunning)|$(Get-LocalSendAlias)" }

$installed = [bool](Get-LocalSendExe)
$running = Test-LocalSendRunning
$alias = Get-LocalSendAlias
$row = New-Ui @'
<Grid Margin="36,8,0,0">
  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
  <StackPanel VerticalAlignment="Center" Margin="0,0,8,0">
    <TextBlock x:Name="Name" FontSize="12.5" Foreground="{StaticResource TextBrush}" TextTrimming="CharacterEllipsis"/>
    <TextBlock x:Name="Info" Style="{StaticResource Caption}" TextWrapping="NoWrap" TextTrimming="CharacterEllipsis"/>
  </StackPanel>
  <Button x:Name="Send" Grid.Column="1" Style="{StaticResource SubtleButton}" Padding="8,4" VerticalAlignment="Center"
          AutomationProperties.Name="Enviar archivos con LocalSend" ToolTip="Elegir archivos y enviarlos">
    <StackPanel Orientation="Horizontal">
      <TextBlock Style="{StaticResource Icon}" Text="&#xE724;" FontSize="12"/>
      <TextBlock Text="Enviar" FontSize="12" Margin="6,0,0,0" VerticalAlignment="Center"/>
    </StackPanel>
  </Button>
  <Button x:Name="Open" Grid.Column="2" Style="{StaticResource IconButton}" Content="&#xE8A7;" FontSize="12" Width="28" Height="28"
          VerticalAlignment="Center" AutomationProperties.Name="Abrir LocalSend" ToolTip="Abrir LocalSend"/>
</Grid>
'@
if ($running) {
    $row.FindName('Name').Text = if ($alias) { "Visible como «$alias»" } else { 'Listo para recibir' }
    $row.FindName('Info').Text = 'Enviar a › LocalSend en el Explorador'
} elseif (-not $installed) {
    $row.FindName('Name').Text = 'LocalSend no está instalado'
    $row.FindName('Name').Foreground = $app.Resources['WarnBrush']
    $row.FindName('Info').Text = 'Reinstala la herramienta para instalarlo'
    $row.FindName('Send').Visibility = 'Collapsed'
    $row.FindName('Open').Visibility = 'Collapsed'
} else {
    $row.FindName('Name').Text = 'LocalSend no está en marcha'
    $row.FindName('Name').Foreground = $app.Resources['WarnBrush']
    $row.FindName('Info').Text = 'No recibe archivos hasta que se abra'
}
$row.FindName('Send').Add_Click({
    param($s, $e)
    $e.Handled = $true   # que no abra la página de la herramienta
    Invoke-Safe { Invoke-LocalSendPick }
})
$row.FindName('Open').Add_Click({
    param($s, $e)
    $e.Handled = $true
    Invoke-Safe { Start-LocalSend }
})
$row
