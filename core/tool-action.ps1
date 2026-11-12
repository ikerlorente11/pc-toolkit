# tool-action.ps1 - Ejecuta una accion sobre una herramienta en un proceso aparte (lo usa el gestor
# para no congelarse). Va escribiendo el progreso en -StatusFile; si falla, deja "ERROR: ..." y sale con 1.
# update/autoupdate (actualizar la app de la herramienta, ver update.ps1 en Toolkit.psm1): al terminar deja
# "OK <version instalada>"; autoupdate con la app abierta no la toca, deja "EN USO" y sale con 2.
param(
    [Parameter(Mandatory)][ValidateSet('install', 'uninstall', 'enable', 'disable', 'update', 'autoupdate')][string]$Action,
    [Parameter(Mandatory)][string]$Id,
    [Parameter(Mandatory)][string]$StatusFile
)

$ErrorActionPreference = 'Stop'
function Set-Status($text) { Set-Content -Path $StatusFile -Value $text -Encoding UTF8 }
$env:PCTOOLKIT_STATUS = $StatusFile   # para que el install.ps1 de la herramienta cuente su progreso (Set-ToolStatus)

try {
    Import-Module (Join-Path $PSScriptRoot 'Toolkit.psm1')
    $tool = Get-Tools | Where-Object id -eq $Id
    if (-not $tool) { throw "No existe la herramienta '$Id'." }
    $result = 'OK'
    switch ($Action) {
        'install'   { Set-Status 'Instalando...';    Install-Tool $tool }
        'uninstall' { Set-Status 'Desinstalando...'; Uninstall-Tool $tool }
        'enable'    { Set-Status 'Activando...';     Enable-Tool $tool }
        'disable'   { Set-Status 'Desactivando...';  Disable-Tool $tool }
        'update'    { Set-Status 'Actualizando...';  $result = "OK $(Update-ToolApp $tool)" }
        'autoupdate' {
            if ((Get-ToolAppInfo $tool).InUse) { Set-Status 'EN USO'; exit 2 }
            Set-Status 'Actualizando...'
            $result = "OK $(Update-ToolApp $tool -Auto)"
        }
    }
    Set-Status $result
    exit 0
} catch {
    Set-Status "ERROR: $($_.Exception.Message)"
    exit 1
}
