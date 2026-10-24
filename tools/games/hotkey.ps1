# hotkey.ps1 - Atajo de Juegos: pasa el juego abierto (con ventana sin bordes) a la siguiente pantalla,
# de izquierda a derecha y vuelta a empezar. Lo ejecuta el gestor al pulsar el atajo y muestra el texto
# que devuelve. Solo cambia la configuración: el vigilante mueve la ventana (y el HDR) en un segundo.

. (Join-Path $PSScriptRoot 'common.ps1')

$game = Get-RunningGame @((Get-GamesConfig).Games | Where-Object Borderless)
if (-not $game) { return 'No hay ningún juego abierto' }

$next = Get-NextScreen (Get-GameScreen $game.Screen)
Set-GameScreen $game.Exe $next
"$($game.Name): $(Get-ScreenLabel $next)"
