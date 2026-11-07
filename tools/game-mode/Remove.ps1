# Remove.ps1 - Parte con administrador al desinstalar Modo juegos: borra la entrada de arranque
# "Windows (modo juegos)" (antes deja la normal por defecto y devuelve VBS) y la tarea elevada.
param([Parameter(Mandatory)][string]$DataDir)
. (Join-Path $PSScriptRoot 'vbs.ps1')

$ErrorActionPreference = 'Stop'
$errFile = Join-Path $DataDir 'elevated-error.txt'
Remove-Item $errFile -ErrorAction SilentlyContinue
try {
    Set-GameModeVbs $DataDir $true
    $statePath = Join-Path $DataDir 'state.json'
    if (Test-Path $statePath) {
        $state = Get-Content $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $id = $state.EntryId
        # Si estaba en modo juegos, la normal vuelve a ser la de por defecto antes de borrar la otra
        if ($state.NormalId) {
            bcdedit /enum $state.NormalId *> $null
            if ($LASTEXITCODE -eq 0) { bcdedit /default $state.NormalId *> $null }
        }
        if ($id) {
            bcdedit /enum $id *> $null
            if ($LASTEXITCODE -eq 0) {
                $out = (bcdedit /delete $id) -join ' '
                if ($LASTEXITCODE -ne 0) { throw "bcdedit /delete: $out" }
            }
        }
        Remove-Item $statePath -Force
    }
    if (Get-ScheduledTask -TaskName 'PcToolkitGameModeBoot' -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName 'PcToolkitGameModeBoot' -Confirm:$false
    }
    exit 0
} catch {
    $_.Exception.Message | Set-Content $errFile -Encoding UTF8
    exit 1
}
