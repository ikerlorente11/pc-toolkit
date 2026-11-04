# hotkey.ps1 - Atajo de Jarvis: empieza a escuchar (o le hace callar si está hablando).
# Lo ejecuta el gestor al pulsar el atajo y muestra el texto que devuelve. Solo avisa al asistente
# por un evento de Windows: el trabajo lo hace jarvis_voice.py, así el gestor no se queda esperando.

. (Join-Path $PSScriptRoot 'common.ps1')

$listen = $null
if (-not [Threading.EventWaitHandle]::TryOpenExisting('PcToolkit.Jarvis.Listen', [ref]$listen)) {
    return 'Jarvis todavía está arrancando'
}
$state = (Get-JarvisStatus).State
[void]$listen.Set()
$listen.Dispose()
switch ($state) {
    'speaking'  { 'Vale, me callo' }
    'listening' { 'Ya te estoy escuchando' }
    'thinking'  { 'Dame un segundo...' }
    'starting'  { 'Jarvis todavía está arrancando' }
    default     { 'Te escucho...' }
}
