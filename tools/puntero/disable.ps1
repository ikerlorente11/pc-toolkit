# disable.ps1 - Al desactivar o desinstalar la herramienta: El Puntero se cierra (el móvil deja de poder
# controlar el PC) y deja de arrancar solo. La app queda instalada; se quita desde Configuración › Aplicaciones.

. (Join-Path $PSScriptRoot 'common.ps1')
Remove-PunteroAutostart
Stop-Puntero
