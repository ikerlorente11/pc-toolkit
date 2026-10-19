# refresh.ps1 - Atajo de la Barra de tareas: la refresca cuando se queda escondida.
# Lo ejecuta el gestor al pulsar el atajo y muestra el texto que devuelve.

. (Join-Path $PSScriptRoot 'common.ps1')
Invoke-TaskbarRefresh
'Barra de tareas refrescada'
