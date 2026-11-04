# settings.ps1 - Página de ajustes de Jarvis dentro del gestor: estado, clave de ElevenLabs, voz,
# calidad de voz, modelo de Ollama y el chat de voz. El asistente relee config.json en cada pregunta,
# así que los cambios se aplican sin reiniciarlo.

. (Join-Path $PSScriptRoot 'common.ps1')

$script:PageSignature = {
    $s = Join-Path $script:JarvisData 'status.json'
    $c = Join-Path $script:JarvisData 'config.json'
    "$(if (Test-Path $s) { (Get-Item $s).LastWriteTimeUtc.Ticks })|$(if (Test-Path $c) { (Get-Item $c).LastWriteTimeUtc.Ticks })|$(Test-OllamaRunning)"
}

function script:Set-JarvisSetting([string]$Name, $Value) {
    $c = Get-JarvisConfig
    $c[$Name] = $Value
    Save-JarvisConfig $c
    Update-Page
}

function script:New-JarvisButton([string]$Text, [string]$Style = 'SubtleButton') {
    $b = New-Ui "<Button Style=`"{StaticResource $Style}`" Margin=`"0,0,8,0`"/>"
    $b.Content = $Text
    $b
}

$cfg     = Get-JarvisConfig
$status  = Get-JarvisStatus
$hasKey  = [bool]$cfg.ApiKey
$running = Test-OllamaRunning
$models  = if ($running) { @(Get-OllamaModels) } else { @() }
$panel   = New-Ui '<StackPanel/>'

# 1. Estado
$state = switch ($status.State) {
    'listening' { 'Escuchando...' }
    'thinking'  { 'Pensando...' }
    'speaking'  { 'Hablando' }
    'idle'      { 'Preparado' }
    'starting'  { 'Arrancando (cargando Whisper)...' }
    'error'     { 'No ha podido arrancar' }
    default     { 'Parado' }
}
$problems = @()
if (-not (Test-Path $script:JarvisPython)) { $problems += 'Falta el entorno de Python: desinstala y vuelve a instalar Jarvis.' }
if (-not $running) { $problems += 'Ollama no está en marcha: Jarvis lo abre solo al arrancar.' }
elseif (-not $models) { $problems += 'Ollama no tiene ningún modelo. Descarga uno, por ejemplo: ollama pull qwen3:8b' }
if (-not $hasKey -and -not (Test-LocalVoice $cfg.Voice)) { $problems += 'Sin clave de ElevenLabs habla con la voz Dave (local).' }
if ($status.Error) { $problems += "Último error: $($status.Error)" }
[void]$panel.Children.Add((New-SectionHeader 'Estado' $state))
foreach ($p in $problems) { [void]$panel.Children.Add((New-Hint $p)) }
if ($status.Question) {
    $last = New-Ui @'
<Border Style="{StaticResource Card}">
  <StackPanel>
    <TextBlock x:Name="Q" Style="{StaticResource Caption}" TextWrapping="Wrap"/>
    <TextBlock x:Name="A" Style="{StaticResource Body}" TextWrapping="Wrap" Margin="0,4,0,0"/>
  </StackPanel>
</Border>
'@
    $last.FindName('Q').Text = "Tú: $($status.Question)"
    $last.FindName('A').Text = if ($status.Answer) { $status.Answer } else { '...' }
    [void]$panel.Children.Add($last)
}

# 2. Clave de ElevenLabs
$keyDetail = if ($hasKey) { 'Guardada y cifrada para tu usuario de Windows.' }
             else { 'Solo para las voces de ElevenLabs. En elevenlabs.io: tu perfil → API Keys → Create, con el permiso de Text to Speech.' }
[void]$panel.Children.Add((New-SectionHeader 'Clave de ElevenLabs' $keyDetail))
$keyRow = New-Ui @'
<Grid Margin="0,0,0,8">
  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
  <PasswordBox x:Name="Key" Background="{StaticResource CardBrush}" Foreground="{StaticResource TextBrush}" CaretBrush="{StaticResource TextBrush}"
               BorderBrush="{StaticResource StrokeBrush}" BorderThickness="1" Padding="10,7" FontSize="13" VerticalContentAlignment="Center"
               AutomationProperties.Name="Clave de ElevenLabs"/>
  <Button x:Name="Save" Grid.Column="1" Style="{StaticResource AccentButton}" Content="Guardar" Margin="8,0,0,0"/>
</Grid>
'@
$keyBox = $keyRow.FindName('Key')
$saveKey = { param($box) if ($box.Password.Trim()) { Set-JarvisApiKey $box.Password; $box.Clear(); Update-Page } }
$keyRow.FindName('Save').Tag = @{ Box = $keyBox; Save = $saveKey }
$keyRow.FindName('Save').Add_Click({ param($s, $e) Invoke-Safe { & $s.Tag.Save $s.Tag.Box } })
$keyBox.Tag = $saveKey
$keyBox.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return') { Invoke-Safe { & $s.Tag $s } } })
[void]$panel.Children.Add($keyRow)
$keyActions = New-Ui '<StackPanel Orientation="Horizontal" Margin="0,0,0,4"/>'
$web = New-JarvisButton 'Abrir ElevenLabs'
$web.Add_Click({ Start-Process 'https://elevenlabs.io/app/settings/api-keys' })
[void]$keyActions.Children.Add($web)
if ($hasKey) {
    $forget = New-JarvisButton 'Quitar clave' 'DangerButton'
    $forget.Add_Click({ Invoke-Safe { Set-JarvisApiKey ''; Update-Page } })
    [void]$keyActions.Children.Add($forget)
}
[void]$panel.Children.Add($keyActions)

# 3. Voz: locales (gratis) y de ElevenLabs (gastan créditos)
$pickVoice = { param($id) Set-JarvisSetting 'Voice' $id }
[void]$panel.Children.Add((New-SectionHeader 'Voz en tu PC' 'Gratis y sin internet, con acento de España.'))
foreach ($id in $script:JarvisLocalVoices.Keys) {
    $v = $script:JarvisLocalVoices[$id]
    [void]$panel.Children.Add((New-ChoiceRow $v.Name $v.Detail ($cfg.Voice -eq $id) $pickVoice $id))
}
[void]$panel.Children.Add((New-SectionHeader 'Voz de ElevenLabs' 'Más natural, pero gasta créditos. Si falla (sin clave o sin plan para esa voz), habla con la voz Dave.'))
foreach ($id in $script:JarvisVoices.Keys) {
    $v = $script:JarvisVoices[$id]
    [void]$panel.Children.Add((New-ChoiceRow $v.Name $v.Detail ($cfg.Voice -eq $id) $pickVoice $id))
}
if (-not $script:JarvisVoices.Contains($cfg.Voice) -and -not $script:JarvisLocalVoices.Contains($cfg.Voice)) {
    [void]$panel.Children.Add((New-ChoiceRow 'Otra voz' $cfg.Voice $true $pickVoice $cfg.Voice))
}
$custom = New-Ui @'
<Grid Margin="0,4,0,8">
  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
  <TextBox x:Name="Id" Style="{StaticResource Input}" Tag="Otra voz: enlace o ID de elevenlabs.io/voices" AutomationProperties.Name="Enlace o ID de otra voz"/>
  <Button x:Name="Use" Grid.Column="1" Style="{StaticResource SubtleButton}" Content="Usar" Margin="8,0,0,0"/>
</Grid>
'@
function script:Use-JarvisVoice([string]$Text) {
    $id = ConvertTo-VoiceId $Text
    if (-not $id) { throw 'No parece un enlace o ID de voz de ElevenLabs (20 letras y números).' }
    Set-JarvisSetting 'Voice' $id
}
# (el Tag del cuadro de texto es su texto de ayuda: el botón guarda el cuadro en el suyo)
$custom.FindName('Use').Tag = $custom.FindName('Id')
$custom.FindName('Use').Add_Click({ param($s, $e) Invoke-Safe { Use-JarvisVoice $s.Tag.Text } })
$custom.FindName('Id').Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return') { Invoke-Safe { Use-JarvisVoice $s.Text } } })
[void]$panel.Children.Add($custom)
$test = New-JarvisButton 'Probar voz' 'AccentButton'
$test.HorizontalAlignment = 'Left'
$test.Add_Click({ Invoke-Safe { Start-JarvisSay 'Hola, soy Jarvis. Pulsa control, alt y jota cuando me necesites y te escucho.' } })
[void]$panel.Children.Add($test)

# 4. Calidad de la voz (modelo de ElevenLabs)
[void]$panel.Children.Add((New-SectionHeader 'Modelo de ElevenLabs' 'Solo para las voces de ElevenLabs.'))
foreach ($id in $script:JarvisTtsModels.Keys) {
    $m = $script:JarvisTtsModels[$id]
    [void]$panel.Children.Add((New-ChoiceRow $m.Name $m.Detail ($cfg.TtsModel -eq $id) { param($id) Set-JarvisSetting 'TtsModel' $id } $id))
}

# 5. Cerebro: modelo de Ollama
[void]$panel.Children.Add((New-SectionHeader 'Modelo de IA (Ollama)' 'Se ejecuta en tu PC. Los más grandes responden mejor pero tardan más.'))
$current = Get-JarvisModel $cfg
if (-not $models) { [void]$panel.Children.Add((New-Hint "Usando $current. Abre Ollama para ver y elegir tus modelos.")) }
foreach ($m in $models) {
    [void]$panel.Children.Add((New-ChoiceRow $m.Name "$($m.Size) GB" ($current -eq $m.Name) { param($n) Set-JarvisSetting 'Model' $n } $m.Name))
}

# 6. Chat de voz completo de OpenJarvis
[void]$panel.Children.Add((New-SectionHeader 'Chat de voz' 'Conversación continua en una ventana, con el chat de OpenJarvis (jarvis chat --voice).'))
$chat = New-JarvisButton 'Abrir chat de voz'
$chat.HorizontalAlignment = 'Left'
$chat.Add_Click({
    Invoke-Safe {
        if (-not (Test-Path $script:JarvisPython)) { throw 'Jarvis no está instalado del todo: reinstálalo.' }
        Start-Process powershell.exe -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $script:JarvisDir 'chat.ps1')`""
    }
})
[void]$panel.Children.Add($chat)

$panel
