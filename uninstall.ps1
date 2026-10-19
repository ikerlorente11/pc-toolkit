# uninstall.ps1 - Desinstala PC Toolkit y todas sus herramientas de este ordenador
# Se puede ejecutar desde el repo o desde %LOCALAPPDATA%\PcToolkit\app:
#   powershell -ExecutionPolicy Bypass -File .\uninstall.ps1

$ErrorActionPreference = 'Stop'
$root   = Join-Path $env:LOCALAPPDATA 'PcToolkit'
$module = Join-Path $root 'app\core\Toolkit.psm1'
if (-not (Test-Path $module)) { Write-Host 'PC Toolkit no esta instalado.'; return }

Import-Module $module -Force
foreach ($t in Get-Tools) {
    if ((Get-ToolState $t) -ne 'NotInstalled') {
        Write-Host "Desinstalando $($t.name)..."
        Uninstall-Tool $t
    }
}
Unregister-Manager
Remove-Module Toolkit

Set-Location $env:USERPROFILE   # por si se lanzo desde dentro de la carpeta a borrar
Remove-Item $root -Recurse -Force
Write-Host 'PC Toolkit desinstalado.' -ForegroundColor Green
if (Get-Module -ListAvailable AudioDeviceCmdlets) {
    Write-Host '(El modulo AudioDeviceCmdlets sigue instalado; quitalo con: Uninstall-Module AudioDeviceCmdlets)'
}
Start-Sleep -Seconds 3   # que se pueda leer si se lanzo desde Configuracion > Aplicaciones
