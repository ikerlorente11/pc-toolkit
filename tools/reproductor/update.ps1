# update.ps1 - Actualizaciones de la app El Reproductor ("updates" en tool.json; el contrato está en
# core\Toolkit.psm1). La última versión es la última release "reproductor-v*" de GitHub (una llamada a la API).
param(
    [Parameter(Mandatory)][ValidateSet('info', 'latest', 'update')][string]$Action,
    [switch]$Auto
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

switch ($Action) {
    'info' {
        [pscustomobject]@{ Installed = Get-ReproductorVersion; InUse = Test-ReproductorRunning; Elevated = $false }
    }
    'latest' {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        (Get-ReproductorLatest).Version
    }
    'update' {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $before = Get-ReproductorVersion
        Set-ToolStatus 'Descargando e instalando El Reproductor...'
        try {
            if (-not (Install-Reproductor -KeepOpen:$Auto)) { Write-ReproductorLog "El Reproductor $before ya estaba al día" }
        } catch {
            Write-ReproductorLog "ERROR al actualizar El Reproductor: $($_.Exception.Message)"
            throw
        }
        Get-ReproductorVersion
    }
}
