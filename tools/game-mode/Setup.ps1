# Setup.ps1 - Parte con administrador de Modo juegos (la lanza install.ps1 con UAC, solo si falta o es antigua):
#   1. Copia la entrada de arranque normal como "Windows (modo juegos)" con el hipervisor y VBS apagados.
#      Si la entrada ya existe, solo vuelve a aplicar los ajustes (se puede repetir sin problema).
#   2. Apunta cuál es la entrada normal (NormalId), para poder volver a ella.
#   3. Registra la tarea PcToolkitGameModeBoot (privilegios máximos, para el usuario actual) que
#      ejecuta Boot.ps1; el usuario puede lanzarla después sin aviso de UAC.
# No cambia la entrada por defecto: eso solo lo hace Boot.ps1 cuando el usuario cambia de modo.
param([Parameter(Mandatory)][string]$DataDir)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
$errFile = Join-Path $DataDir 'elevated-error.txt'
Remove-Item $errFile -ErrorAction SilentlyContinue

function Test-Entry([string]$Id) { bcdedit /enum $Id *> $null; $LASTEXITCODE -eq 0 }
# GUID real de una entrada con nombre ({default}, {current}...)
function Get-EntryGuid([string]$Name) {
    $out = (bcdedit /enum $Name /v) -join "`n"
    if ($out -match '(\{[0-9a-fA-F-]{36}\})') { $Matches[1].ToLower() }
}

try {
    $statePath = Join-Path $DataDir 'state.json'
    $state = if (Test-Path $statePath) { Get-Content $statePath -Raw -Encoding UTF8 | ConvertFrom-Json }
    $id = if ($state.EntryId -and (Test-Entry $state.EntryId)) { $state.EntryId.ToLower() }
    $normal = if ($state.NormalId -and (Test-Entry $state.NormalId)) { $state.NormalId.ToLower() }

    if (-not $normal) {
        $def = Get-EntryGuid '{default}'
        if ($def -and $def -ne $id) { $normal = $def }
        else {
            # La de por defecto es la de juegos: la normal es otra entrada de Windows
            $all = (bcdedit /enum osloader /v) -join "`n"
            $normal = [regex]::Matches($all, '\{[0-9a-fA-F-]{36}\}') | ForEach-Object { $_.Value.ToLower() } |
                Where-Object { $_ -ne $id } | Select-Object -First 1
        }
        if (-not $normal) { throw 'No se encontró la entrada de arranque normal de Windows.' }
    }
    if (-not $id) {
        $out = (bcdedit /copy $normal /d 'Windows (modo juegos)') -join ' '
        if ($LASTEXITCODE -ne 0 -or $out -notmatch '(\{[0-9a-fA-F-]{36}\})') { throw "bcdedit /copy: $out" }
        $id = $Matches[1].ToLower()
    }
    # Con VBS activado (registro DeviceGuard), el hipervisor se carga aunque hypervisorlaunchtype esté
    # en off: hay que apagar también VSM en esa entrada
    foreach ($setting in 'hypervisorlaunchtype', 'vsmlaunchtype') {
        $out = (bcdedit /set $id $setting off) -join ' '
        if ($LASTEXITCODE -ne 0) { throw "bcdedit /set $setting`: $out" }
    }
    @{ EntryId = $id; NormalId = $normal; SetupVersion = 3 } | ConvertTo-Json | Set-Content $statePath -Encoding UTF8

    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $vbs  = Join-Path $PSScriptRoot '..\..\core\run-hidden.vbs'
    $boot = Join-Path $PSScriptRoot 'Boot.ps1'
    Register-ScheduledTask -TaskName 'PcToolkitGameModeBoot' -Force `
        -Action (New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$vbs`" `"$boot`"") `
        -Principal (New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest) `
        -Settings (New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 2)) `
        -Description 'PC Toolkit: cambia el modo de arranque (juegos / normal) y reinicia' | Out-Null
    exit 0
} catch {
    $_.Exception.Message | Set-Content $errFile -Encoding UTF8
    exit 1
}
