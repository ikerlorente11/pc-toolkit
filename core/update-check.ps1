# update-check.ps1 - Busca versiones nuevas en un proceso aparte (lo lanza el gestor al arrancar, cada 6 h y
# con el boton "Buscar actualizaciones", para no congelarse esperando a la red).
# Mira PC Toolkit (VERSION de GitHub) y la app de cada herramienta instalada con "updates" en tool.json
# (update.ps1 -Action latest). Deja en -OutFile un JSON: { "pctoolkit": { "Latest": "1.4.1", "Error": null }, "<id>": ... }
# Son pocas llamadas (una por app) para no gastar el límite de la API de GitHub sin token (60 por hora).
# (UTF-8 con BOM: los textos de error se ven tal cual en el gestor.)
param([Parameter(Mandatory)][string]$OutFile)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Toolkit.psm1')
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Get-ErrorText($err) {
    $msg = $err.Exception.Message
    if ($msg -match 'rate limit|\(403\)') { return 'GitHub ha limitado las consultas; se reintentará más tarde.' }
    if ($err.Exception -is [Net.WebException]) { return 'No se pudo comprobar (¿sin conexión?).' }
    $msg
}

$items = [ordered]@{}
try { $items['pctoolkit'] = @{ Latest = Get-ToolkitRemoteVersion; Error = $null } }
catch { $items['pctoolkit'] = @{ Latest = $null; Error = Get-ErrorText $_ } }

foreach ($t in (Get-Tools | Where-Object HasUpdates)) {
    if ((Get-ToolState $t) -eq 'NotInstalled') { continue }
    try { $items[$t.id] = @{ Latest = Get-ToolAppLatest $t; Error = $null } }
    catch { $items[$t.id] = @{ Latest = $null; Error = Get-ErrorText $_ } }
}

$items | ConvertTo-Json -Depth 3 | Set-Content -Path $OutFile -Encoding UTF8
