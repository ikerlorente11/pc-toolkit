# hotkey.ps1 - Atajo del Traductor: abre o cierra su ventana. Lo ejecuta el gestor al pulsar el atajo;
# no devuelve texto, así que no sale el aviso.

. (Join-Path $PSScriptRoot 'window.ps1')
Switch-Translator
