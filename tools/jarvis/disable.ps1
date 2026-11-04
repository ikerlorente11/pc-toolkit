# disable.ps1 - Al desactivar o desinstalar, cierra también el asistente de Python (el gestor solo
# cierra el lanzador de PowerShell; el asistente se iría solo en un segundo, pero así se libera ya).
. (Join-Path $PSScriptRoot 'common.ps1')
Stop-JarvisAssistant
