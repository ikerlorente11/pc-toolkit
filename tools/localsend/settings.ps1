# settings.ps1 - Página de ajustes de LocalSend dentro del gestor: enviar, estado y menú Enviar a.

. (Join-Path $PSScriptRoot 'common.ps1')

$cfg   = Get-LocalSendConfig
$exe   = Get-LocalSendExe
$panel = New-Ui '<StackPanel/>'
$script:PageSignature = { "$(Test-LocalSendRunning)|$(Get-LocalSendAlias)|$([bool](Get-LocalSendExe))" }

$buttons = New-Ui @'
<StackPanel Orientation="Horizontal" Margin="0,4,0,0">
  <Button x:Name="Send" Style="{StaticResource AccentButton}" AutomationProperties.Name="Enviar archivos">
    <StackPanel Orientation="Horizontal">
      <TextBlock Style="{StaticResource Icon}" Text="&#xE724;" FontSize="13" Foreground="{StaticResource OnAccentBrush}"/>
      <TextBlock Text="Enviar archivos..." Margin="8,0,0,0" VerticalAlignment="Center"/>
    </StackPanel>
  </Button>
  <Button x:Name="Open" Style="{StaticResource SubtleButton}" Content="Abrir LocalSend" Margin="6,0,0,0"/>
</StackPanel>
'@
$buttons.FindName('Send').Add_Click({ Invoke-Safe { Invoke-LocalSendPick } })
$buttons.FindName('Open').Add_Click({ Invoke-Safe { Start-LocalSend } })
$buttons.IsEnabled = [bool]$exe
[void]$panel.Children.Add($buttons)

# Estado: versión, si está en marcha (para recibir hay que tenerlo abierto) y con qué nombre se ve
[void]$panel.Children.Add((New-SectionHeader 'LocalSend' 'Con la herramienta activada, se inicia oculto en la bandeja al iniciar sesión para poder recibir archivos. La primera vez, Windows puede preguntar si le permites acceder a la red: acéptalo para las redes privadas.'))
$card = New-Ui @'
<Border Style="{StaticResource Card}">
  <Grid>
    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
    <StackPanel VerticalAlignment="Center" Margin="0,0,12,0">
      <TextBlock x:Name="T" Style="{StaticResource Body}"/>
      <TextBlock x:Name="D" Style="{StaticResource Caption}"/>
    </StackPanel>
    <Button x:Name="Start" Grid.Column="1" Style="{StaticResource SubtleButton}" Content="Iniciar" VerticalAlignment="Center" Visibility="Collapsed"/>
  </Grid>
</Border>
'@
if ($exe) {
    $running = Test-LocalSendRunning
    $alias = Get-LocalSendAlias
    $card.FindName('T').Text = "LocalSend $((Get-Item $exe).VersionInfo.ProductVersion)"
    $card.FindName('D').Text = if ($running -and $alias) { "En marcha · los demás dispositivos ven este PC como «$alias»" }
                               elseif ($running) { 'En marcha · listo para recibir' }
                               else { 'No está en marcha: no recibe archivos.' }
    if (-not $running) {
        $card.FindName('D').Foreground = $app.Resources['WarnBrush']
        $start = $card.FindName('Start')
        $start.Visibility = 'Visible'
        $start.Add_Click({ Invoke-Safe { Start-LocalSend -Hidden; Update-Page } })
    }
} else {
    $card.FindName('T').Text = 'LocalSend no está instalado'
    $card.FindName('D').Text = 'Desinstala y vuelve a instalar esta herramienta para instalarlo con winget.'
    $card.FindName('D').Foreground = $app.Resources['WarnBrush']
}
[void]$panel.Children.Add($card)

[void]$panel.Children.Add((New-SectionHeader 'Explorador'))
[void]$panel.Children.Add((New-ToggleRow 'LocalSend en el menú Enviar a' 'Clic derecho en archivos o carpetas › Enviar a › LocalSend, para mandarlos sin abrir nada antes.' $cfg.SendTo {
    param($a, $on)
    Set-LocalSendSetting 'SendTo' $on
    # Se aplica ya si la herramienta está activada; si no, al activarla
    if ((Get-ToolState ($tools | Where-Object id -eq 'localsend')) -eq 'Enabled') { Set-LocalSendSendTo $on }
} $null))

$panel
