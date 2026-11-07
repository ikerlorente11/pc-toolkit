# settings.ps1 - Página de Modo juegos en el gestor: modo actual, reiniciar a mano, cuándo preguntar
# y qué programas cuentan como emulador o como contenedor.

. (Join-Path $PSScriptRoot 'common.ps1')

if ($null -eq $script:GameModeHv) { $script:GameModeHv = Test-HypervisorRunning }
$cfg   = Get-GameModeConfig
$panel = New-Ui '<StackPanel/>'

$now = if ($script:GameModeHv) { 'Modo juegos DESACTIVADO: Windows está con el hipervisor (WSL y Docker funcionan; los emuladores van más lentos). Se mantiene en cada reinicio hasta que lo actives.' }
       else { 'Modo juegos ACTIVADO: Windows está sin hipervisor (los emuladores van rápidos; WSL y Docker no funcionan). Se mantiene en cada reinicio hasta que lo desactives.' }
[void]$panel.Children.Add((New-Hint $now))
if (-not (Test-GameModeReady)) {
    [void]$panel.Children.Add((New-Hint 'Falta la parte con administrador (entrada de arranque y tarea). Desinstala e instala la herramienta para repetirla.'))
}

$button = New-Ui @'
<Button Style="{StaticResource AccentButton}" HorizontalAlignment="Left" Margin="0,4,0,8">
  <StackPanel Orientation="Horizontal">
    <TextBlock Style="{StaticResource Icon}" Text="&#xE777;" FontSize="13" Foreground="{StaticResource OnAccentBrush}"/>
    <TextBlock x:Name="Label" Margin="8,0,0,0" VerticalAlignment="Center"/>
  </StackPanel>
</Button>
'@
$button.FindName('Label').Text = if ($script:GameModeHv) { 'Activar modo juegos y reiniciar' } else { 'Desactivar modo juegos y reiniciar' }
[Windows.Automation.AutomationProperties]::SetName($button, $button.FindName('Label').Text)
$button.Add_Click({
    Invoke-Safe { Invoke-GameModeSwitch $script:GameModeHv }
})
[void]$panel.Children.Add($button)

[void]$panel.Children.Add((New-SectionHeader 'Preguntar al abrir'))
[void]$panel.Children.Add((New-ToggleRow 'Un emulador con el hipervisor activo' 'Ofrece activar el modo juegos y reiniciar.' ([bool]$cfg.AskOnEmulator) {
    param($a, $on) Set-GameModeSetting 'AskOnEmulator' $on } $null))
[void]$panel.Children.Add((New-ToggleRow 'Docker o WSL en modo juegos' 'Ofrece desactivar el modo juegos y reiniciar.' ([bool]$cfg.AskOnContainer) {
    param($a, $on) Set-GameModeSetting 'AskOnContainer' $on } $null))

# Lista editable de programas (separados por comas); se guarda al salir del cuadro
function script:New-GameModeListRow([string]$Title, [string]$Setting) {
    $row = New-Ui @'
<Border Style="{StaticResource Card}">
  <StackPanel>
    <TextBlock x:Name="T" Style="{StaticResource Body}"/>
    <TextBlock Style="{StaticResource Caption}" Text="Nombres de proceso separados por comas"/>
    <TextBox x:Name="Box" Style="{StaticResource Input}" Tag="programa.exe" Margin="0,8,0,0"/>
  </StackPanel>
</Border>
'@
    $row.FindName('T').Text = $Title
    $box = $row.FindName('Box')
    $box.Text = ((Get-GameModeConfig)[$Setting]) -join ', '
    [Windows.Automation.AutomationProperties]::SetName($box, $Title)
    $box.Uid = $Setting
    $box.Add_LostFocus({
        param($s, $e)
        Invoke-Safe {
            $list = @($s.Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } |
                ForEach-Object { if ($_ -notmatch '\.exe$') { "$_.exe" } else { $_ } })
            Set-GameModeSetting $s.Uid $list
        }
    })
    $row
}

[void]$panel.Children.Add((New-SectionHeader 'Programas'))
[void]$panel.Children.Add((New-GameModeListRow 'Emuladores' 'Emulators'))
[void]$panel.Children.Add((New-GameModeListRow 'Contenedores (necesitan el hipervisor)' 'Containers'))

$panel
