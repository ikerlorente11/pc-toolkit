# update.ps1 - Actualizaciones de la app La Estantería ("updates" en tool.json; el contrato está en
# core\Toolkit.psm1). La última versión es la última release "estanteria-v*" de GitHub (una llamada a la API).
param(
    [Parameter(Mandatory)][ValidateSet('info', 'latest', 'update')][string]$Action,
    [switch]$Auto
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

switch ($Action) {
    'info' {
        [pscustomobject]@{ Installed = Get-EstanteriaVersion; InUse = Test-EstanteriaRunning; Elevated = $false }
    }
    'latest' {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        (Get-EstanteriaLatest).Version
    }
    'update' {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $before = Get-EstanteriaVersion
        Set-ToolStatus 'Descargando e instalando La Estantería...'
        try {
            if (-not (Install-Estanteria -KeepOpen:$Auto)) { Write-EstanteriaLog "La Estantería $before ya estaba al día" }
        } catch {
            Write-EstanteriaLog "ERROR al actualizar La Estantería: $($_.Exception.Message)"
            throw
        }
        Get-EstanteriaVersion
    }
}
