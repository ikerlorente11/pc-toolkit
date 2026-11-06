# disable.ps1 - Al desactivar o desinstalar: quita LocalSend del menú Enviar a. LocalSend deja de iniciarse
# solo, pero si está abierto no se cierra (podría estar pasando archivos); se cierra desde su icono.

. (Join-Path $PSScriptRoot 'common.ps1')
Set-LocalSendSendTo $false
