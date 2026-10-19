# tool-action.ps1 - Ejecuta una accion sobre una herramienta en un proceso aparte (lo usa el gestor
# para no congelarse). Va escribiendo el progreso en -StatusFile; si falla, deja "ERROR: ..." y sale con 1.
param(
    [Parameter(Mandatory)][ValidateSet('install', 'uninstall', 'enable', 'disable')][string]$Action,
    [Parameter(Mandatory)][string]$Id,
    [Parameter(Mandatory)][string]$StatusFile
)

$ErrorActionPreference = 'Stop'
function Set-Status($text) { Set-Content -Path $StatusFile -Value $text -Encoding UTF8 }

try {
    Import-Module (Join-Path $PSScriptRoot 'Toolkit.psm1')
    $tool = Get-Tools | Where-Object id -eq $Id
    if (-not $tool) { throw "No existe la herramienta '$Id'." }
    switch ($Action) {
        'install'   { Set-Status 'Instalando...';    Install-Tool $tool }
        'uninstall' { Set-Status 'Desinstalando...'; Uninstall-Tool $tool }
        'enable'    { Set-Status 'Activando...';     Enable-Tool $tool }
        'disable'   { Set-Status 'Desactivando...';  Disable-Tool $tool }
    }
    Set-Status 'OK'
    exit 0
} catch {
    Set-Status "ERROR: $($_.Exception.Message)"
    exit 1
}
