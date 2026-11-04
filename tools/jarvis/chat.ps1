# chat.ps1 - Abre el chat de voz de OpenJarvis ("jarvis chat --voice") con la voz y el modelo del panel.
# Lo lanza el botón "Abrir chat de voz" en una ventana de consola propia. La clave de ElevenLabs se
# descifra aquí para no pasarla por la línea de comandos.

. (Join-Path $PSScriptRoot 'common.ps1')
$Host.UI.RawUI.WindowTitle = 'Jarvis'
Set-JarvisEnvironment -WithKey
Write-JarvisToml (Get-JarvisConfig)
& $script:JarvisPython (Join-Path $PSScriptRoot 'chat.py') $script:JarvisData
