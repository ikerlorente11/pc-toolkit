# Boot.ps1 - Lo ejecuta la tarea elevada PcToolkitGameModeBoot. Lee request.json, cambia la entrada de
# arranque por defecto y reinicia. El modo elegido se mantiene en los siguientes reinicios hasta cambiarlo:
#   games  -> por defecto la entrada sin hipervisor ni VBS
#   normal -> por defecto la entrada normal de Windows
$ErrorActionPreference = 'Stop'
$data = Join-Path $env:LOCALAPPDATA 'PcToolkit\data\game-mode'
$log  = Join-Path $data 'GameMode.log'
function Write-Log($msg) {
    try { Add-Content -Path $log -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg) -Encoding UTF8 } catch {}
}

. (Join-Path $PSScriptRoot 'vbs.ps1')

try {
    $reqPath = Join-Path $data 'request.json'
    if (-not (Test-Path $reqPath)) { return }
    $req = Get-Content $reqPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Remove-Item $reqPath -Force
    # Peticiones viejas (más de 2 minutos) no se atienden
    if (((Get-Date) - [datetime]$req.Time).TotalMinutes -gt 2) { Write-Log 'Petición caducada, ignorada'; return }

    $state = Get-Content (Join-Path $data 'state.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $target = if ($req.Mode -eq 'games') { $state.EntryId } else { $state.NormalId }
    if (-not $target) { throw "Falta la entrada de arranque para '$($req.Mode)': reinstala la herramienta." }
    bcdedit /deletevalue '{bootmgr}' bootsequence *> $null   # por si quedaba un arranque único pendiente
    $out = (bcdedit /default $target) -join ' '
    if ($LASTEXITCODE -ne 0) { throw "bcdedit /default: $out" }

    # Con EnableVirtualizationBasedSecurity=1 en el registro, Windows carga el hipervisor aunque la entrada
    # diga hypervisorlaunchtype/vsmlaunchtype off ("VBS Enabled, VSM Required ... due to VBS registry
    # configuration"). En modo juegos se pone a 0 y al volver se deja el valor que tenía.
    Set-GameModeVbs $data ($req.Mode -ne 'games')

    if ($req.Mode -eq 'games') {
        @{ Time = (Get-Date).ToString('o') } | ConvertTo-Json | Set-Content (Join-Path $data 'games-boot.json') -Encoding UTF8
        Write-Log 'Modo juegos activado (sin hipervisor hasta volver al normal): reiniciando'
        shutdown.exe /r /t 5 /c 'PC Toolkit: reiniciando en modo juegos (sin hipervisor)'
    } else {
        Write-Log 'Modo juegos desactivado (con hipervisor): reiniciando'
        shutdown.exe /r /t 5 /c 'PC Toolkit: reiniciando en modo normal (con hipervisor para WSL/Docker)'
    }
} catch {
    Write-Log "ERROR: $($_.Exception.Message)"
}
