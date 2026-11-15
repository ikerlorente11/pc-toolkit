# update.ps1 - Actualizaciones de la app El Puntero ("updates" en tool.json; el contrato está en
# core\Toolkit.psm1). La última versión es la última release "puntero-v*" de GitHub (una llamada a la API).
# No cuenta como «en uso»: vive en la bandeja, así que se para, se actualiza y se vuelve a arrancar oculta.
param(
    [Parameter(Mandatory)][ValidateSet('info', 'latest', 'update')][string]$Action,
    [switch]$Auto
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

switch ($Action) {
    'info' {
        [pscustomobject]@{ Installed = Get-PunteroVersion; InUse = $false; Elevated = $false }
    }
    'latest' {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        (Get-PunteroLatest).Version
    }
    'update' {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $before = Get-PunteroVersion
        Set-ToolStatus 'Descargando e instalando El Puntero...'
        try {
            if (-not (Install-Puntero)) { Write-PunteroLog "El Puntero $before ya estaba al día" }
        } catch {
            Write-PunteroLog "ERROR al actualizar El Puntero: $($_.Exception.Message)"
            throw
        }
        Get-PunteroVersion
    }
}
