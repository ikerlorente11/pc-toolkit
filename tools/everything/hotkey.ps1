# hotkey.ps1 - Atajo de Everything: abre o cierra la ventana de búsqueda. Lo ejecuta el gestor al pulsar el
# atajo; no devuelve texto, así que no sale el aviso.

. (Join-Path $PSScriptRoot 'window.ps1')
Switch-Everything
