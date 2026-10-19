# Taskbar.ps1 - Aplica el perfil de la barra de tareas que toque (Normal o Escritorio Remoto).
# Lo lanza la tarea programada "PcToolkitTaskbar" al iniciar sesión, al conectar por Escritorio Remoto
# y al volver a la consola local.
#   -Refresh        refresca la barra (por si se queda escondida)
#   -AlwaysVisible  deja la barra siempre visible (lo usa disable.ps1)

. (Join-Path $PSScriptRoot 'common.ps1')

if ($args -contains '-AlwaysVisible') { [PcToolkit.Taskbar.Native]::SetAutoHide($false); return }
if ($args -contains '-Refresh') { Invoke-TaskbarRefresh; return }

# Al iniciar sesión, Explorer puede tardar en tener la barra lista
if (-not [PcToolkit.Taskbar.Native]::TrayReady) {
    for ($i = 0; $i -lt 30 -and -not [PcToolkit.Taskbar.Native]::TrayReady; $i++) { Start-Sleep -Seconds 1 }
    Start-Sleep -Seconds 2
}

$name = Invoke-ActiveTaskbarProfile
$cfg = Get-TaskbarConfig

New-Item -ItemType Directory -Force -Path $script:TaskbarDataDir | Out-Null
$log = Join-Path $script:TaskbarDataDir 'Taskbar.log'
if ((Test-Path $log) -and (Get-Item $log).Length -gt 100KB) { Clear-Content $log }
"$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  Perfil $(Get-TaskbarProfileLabel $name): $(Get-TaskbarProfileSummary $cfg[$name])" | Add-Content $log -Encoding UTF8
