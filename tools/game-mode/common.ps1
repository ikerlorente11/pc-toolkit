# common.ps1 - Configuración y funciones de Modo juegos. Lo cargan con "." el vigilante (GameMode.ps1),
# install.ps1, uninstall.ps1, settings.ps1 y home.ps1. Funciones "script:" para que sigan vivas en los botones del gestor.
#
# Cómo funciona:
#   - Setup.ps1 (con admin, una vez) copia la entrada de arranque normal como "Windows (modo juegos)"
#     con hypervisorlaunchtype off y registra la tarea elevada PcToolkitGameModeBoot.
#   - Para reiniciar en modo juegos se escribe request.json y se lanza esa tarea (sin UAC): hace
#     "bcdedit /default" con la entrada del modo pedido y reinicia: el modo se mantiene hasta cambiarlo.

$script:GameModeDir  = $PSScriptRoot
$script:GameModeData = Join-Path $env:LOCALAPPDATA 'PcToolkit\data\game-mode'
$script:GameModeBootTask = 'PcToolkitGameModeBoot'

function script:Get-GameModeConfig {
    $path = Join-Path $script:GameModeData 'config.json'
    $c = if (Test-Path $path) { try { Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }
    $defaults = [ordered]@{
        AskOnEmulator  = $true
        AskOnContainer = $true
        Emulators      = @('kyty_launcher.exe', 'kyty_emulator.exe')
        Containers     = @('Docker Desktop.exe', 'wsl.exe')
    }
    $cfg = [ordered]@{}
    foreach ($k in $defaults.Keys) {
        $cfg[$k] = if ($c -and $null -ne $c.$k) { $c.$k } else { $defaults[$k] }
    }
    $cfg.Emulators  = @($cfg.Emulators  | Where-Object { $_ })
    $cfg.Containers = @($cfg.Containers | Where-Object { $_ })
    $cfg
}

function script:Set-GameModeSetting([string]$Name, $Value) {
    $cfg = Get-GameModeConfig
    $cfg[$Name] = $Value
    New-Item -ItemType Directory -Force -Path $script:GameModeData | Out-Null
    $cfg | ConvertTo-Json -Depth 3 | Set-Content (Join-Path $script:GameModeData 'config.json') -Encoding UTF8
}

# Datos de la instalación elevada (GUID de la entrada de arranque), los escribe Setup.ps1
function script:Get-GameModeState {
    $path = Join-Path $script:GameModeData 'state.json'
    if (Test-Path $path) { try { Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }
}

# $true si Windows está corriendo sobre el hipervisor (modo normal)
function script:Test-HypervisorRunning {
    [bool](Get-CimInstance Win32_ComputerSystem -Property HypervisorPresent).HypervisorPresent
}

function script:Test-GameModeReady {
    $s = Get-GameModeState
    $s -and $s.EntryId -and (Get-ScheduledTask -TaskName $script:GameModeBootTask -ErrorAction SilentlyContinue)
}

# Versión de los ajustes que aplica Setup.ps1; si la instalada es anterior, install.ps1 lo repite.
# 2: también vsmlaunchtype off (con VBS activado el hipervisor arrancaba igualmente).
# 3: apunta la entrada normal (NormalId): el modo se cambia con la entrada por defecto y se mantiene.
$script:GameModeSetupVersion = 3
function script:Test-GameModeSetupCurrent {
    $s = Get-GameModeState
    (Test-GameModeReady) -and [int]$s.SetupVersion -ge $script:GameModeSetupVersion
}

# Hora del último reinicio pedido en modo juegos (la apunta Boot.ps1) para comprobar al iniciar
# sesión si de verdad arrancó sin hipervisor
$script:GameModePendingFile = Join-Path $script:GameModeData 'games-boot.json'

function script:Get-RunningExe([string[]]$Exes) {
    foreach ($exe in $Exes) {
        $procs = [Diagnostics.Process]::GetProcessesByName([IO.Path]::GetFileNameWithoutExtension($exe))
        $found = $procs.Count -gt 0
        foreach ($p in $procs) { $p.Dispose() }
        if ($found) { return $exe }
    }
}

# Pide a la tarea elevada que pase a 'games' (sin hipervisor) o 'normal' y reinicie
function script:Request-GameModeRestart([ValidateSet('games', 'normal')][string]$Mode) {
    if (-not (Test-GameModeReady)) { throw 'Modo juegos no está preparado: vuelve a instalar la herramienta desde el gestor.' }
    New-Item -ItemType Directory -Force -Path $script:GameModeData | Out-Null
    @{ Mode = $Mode; Time = (Get-Date).ToString('o') } | ConvertTo-Json | Set-Content (Join-Path $script:GameModeData 'request.json') -Encoding UTF8
    Start-ScheduledTask -TaskName $script:GameModeBootTask
}

# Botón del gestor (tarjeta y ajustes): confirma y cambia al otro modo ($Hypervisor = modo actual)
function script:Invoke-GameModeSwitch([bool]$Hypervisor) {
    $mode = if ($Hypervisor) { 'games' } else { 'normal' }
    $msg = if ($mode -eq 'games') {
        "¿Activar el modo juegos y reiniciar ahora?`n`nWindows arrancará sin hipervisor (los emuladores van mucho más rápidos; " +
        "WSL y Docker no funcionan) en cada reinicio hasta que lo desactives.`n`nGuarda lo que tengas abierto."
    } else {
        "¿Desactivar el modo juegos y reiniciar ahora?`n`nWindows volverá a arrancar con el hipervisor (WSL y Docker funcionan).`n`n" +
        "Guarda lo que tengas abierto."
    }
    if ([Windows.MessageBox]::Show($msg, 'Modo juegos', 'YesNo', 'Question') -eq 'Yes') { Request-GameModeRestart $mode }
}

# Lanza Setup.ps1 / Remove.ps1 con permisos de administrador (aviso de UAC) y espera
function script:Invoke-GameModeElevated([string]$Script) {
    $p = Start-Process powershell.exe -Verb RunAs -Wait -PassThru -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $script:GameModeDir $Script)`"",
        '-DataDir', "`"$script:GameModeData`"")
    if ($p.ExitCode -ne 0) {
        $err = Join-Path $script:GameModeData 'elevated-error.txt'
        $msg = if (Test-Path $err) { (Get-Content $err -Raw -Encoding UTF8).Trim() } else { "código $($p.ExitCode)" }
        throw "No se pudo completar la parte con administrador: $msg"
    }
}

function script:Register-GameModeTask {
    Import-Module (Join-Path $script:GameModeDir '..\..\core\Toolkit.psm1')
    Register-ScheduledTask -TaskName 'PcToolkitGameMode' -Force `
        -Action (New-HiddenTaskAction (Join-Path $script:GameModeDir 'GameMode.ps1')) `
        -Trigger (New-ScheduledTaskTrigger -AtLogOn -User (Get-CurrentUserId)) `
        -Settings (New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)) `
        -Description 'PC Toolkit: ofrece reiniciar sin hipervisor al abrir un emulador' | Out-Null
}
