# home.ps1 - Bloque de Jarvis en la portada del gestor: qué está haciendo y la última pregunta.

. (Join-Path $PSScriptRoot 'common.ps1')

$script:HomeSignatures['jarvis'] = {
    $s = Join-Path $script:JarvisData 'status.json'
    if (Test-Path $s) { (Get-Item $s).LastWriteTimeUtc.Ticks }
}

$status = Get-JarvisStatus
$row = New-Ui @'
<StackPanel Margin="36,8,0,0">
  <TextBlock x:Name="Name" FontSize="12.5" Foreground="{StaticResource TextBrush}" TextTrimming="CharacterEllipsis"/>
  <TextBlock x:Name="Info" Style="{StaticResource Caption}" TextWrapping="NoWrap" TextTrimming="CharacterEllipsis"/>
</StackPanel>
'@
$row.FindName('Name').Text = switch ($status.State) {
    'listening' { 'Escuchando...' }
    'thinking'  { 'Pensando...' }
    'speaking'  { 'Hablando' }
    'idle'      { 'Preparado' }
    'starting'  { 'Arrancando...' }
    'error'     { 'No ha podido arrancar' }
    default     { 'Parado' }
}
$row.FindName('Info').Text = if ($status.Question) { "Tú: $($status.Question)" }
                                                          else { 'Pulsa el atajo y habla' }
$row
