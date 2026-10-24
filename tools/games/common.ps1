# common.ps1 - Configuración de Juegos, control del HDR y pantallas. Lo cargan con "." el vigilante,
# install.ps1, disable.ps1, settings.ps1 y home.ps1. Funciones "script:" para que sigan vivas en los botones del gestor.

Add-Type -AssemblyName System.Windows.Forms
if (-not ('PcToolkit.Hdr.Native' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'HdrNative.cs') }
if (-not ('PcToolkit.GameWindows.Native' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'WindowNative.cs') }
$script:GamesDir  = $PSScriptRoot
$script:GamesData = Join-Path $env:LOCALAPPDATA 'PcToolkit\data\games'
# Pantallas a las que el vigilante quitó el HDR y que hay que devolver al cerrar el juego
$script:HdrRestoreFile = Join-Path $script:GamesData 'restore.json'

# Cada juego: Exe, Name, Hdr (desactivar el HDR mientras está abierto), Borderless y Screen
function script:Get-GamesConfig {
    $path = Join-Path $script:GamesData 'config.json'
    $c = if (Test-Path $path) { try { Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }
    $games = if ($c -and $null -ne $c.Games) { @($c.Games | Where-Object { $_.Exe }) }
             else { @([pscustomobject]@{ Exe = 'isaac-ng.exe'; Name = 'The Binding of Isaac' }) }
    $defaults = @{ Hdr = $true; Borderless = $true; Screen = 'primary' }
    foreach ($g in $games) {
        foreach ($k in $defaults.Keys) {
            if ($null -eq $g.$k) { $g | Add-Member -Force -NotePropertyName $k -NotePropertyValue $defaults[$k] }
        }
    }
    @{ Games = $games }
}

function script:Save-GamesConfig($Config) {
    New-Item -ItemType Directory -Force -Path $script:GamesData | Out-Null
    @{ Games = @($Config.Games) } | ConvertTo-Json -Depth 3 | Set-Content (Join-Path $script:GamesData 'config.json') -Encoding UTF8
}

function script:Test-ProcessRunning([string]$Exe) {
    $procs = [Diagnostics.Process]::GetProcessesByName([IO.Path]::GetFileNameWithoutExtension($Exe))
    $found = $procs.Count -gt 0
    foreach ($p in $procs) { $p.Dispose() }
    $found
}

# Primer juego de la lista que esté abierto (o nada); con -Hdr, solo los que apagan el HDR
function script:Get-RunningGame($Games, [switch]$Hdr) {
    foreach ($g in $Games) {
        if ($Hdr -and -not $g.Hdr) { continue }
        if (Test-ProcessRunning $g.Exe) { return $g }
    }
}

# --- HDR ---

function script:Get-HdrDisplays { @([PcToolkit.Hdr.Native]::List() | Where-Object Supported) }

# Quita el HDR a las pantallas que lo tengan y apunta cuáles eran para devolvérselo luego
function script:Disable-HdrForGame {
    $on = @(Get-HdrDisplays | Where-Object Enabled)
    foreach ($d in $on) { [void][PcToolkit.Hdr.Native]::Set($d, $false) }
    New-Item -ItemType Directory -Force -Path $script:GamesData | Out-Null
    ConvertTo-Json @($on | ForEach-Object Key) | Set-Content $script:HdrRestoreFile -Encoding UTF8
    $on
}

# Devuelve el HDR a las pantallas apuntadas (si siguen conectadas)
function script:Restore-Hdr {
    if (-not (Test-Path $script:HdrRestoreFile)) { return }
    # En PowerShell 5.1 ConvertFrom-Json devuelve la lista como un solo objeto: hay que desplegarla
    $keys = @(try { (Get-Content $script:HdrRestoreFile -Raw -Encoding UTF8 | ConvertFrom-Json) | ForEach-Object { "$_" } } catch {})
    $back = @(Get-HdrDisplays | Where-Object { $keys -contains $_.Key -and -not $_.Enabled })
    foreach ($d in $back) { [void][PcToolkit.Hdr.Native]::Set($d, $true) }
    Remove-Item $script:HdrRestoreFile -Force
    $back
}

# --- Pantallas para la ventana sin bordes ---

# 'primary' o el nombre de Windows de la pantalla (\\.\DISPLAY2); si ya no está, la principal
function script:Get-GameScreen([string]$Screen) {
    $s = [Windows.Forms.Screen]::AllScreens | Where-Object { $_.DeviceName -eq $Screen } | Select-Object -First 1
    if ($s) { $s } else { [Windows.Forms.Screen]::PrimaryScreen }
}

# Texto para el panel: "Principal · 2560 × 1440" o "A la derecha · 2560 × 1440"
function script:Get-ScreenLabel($Screen) {
    $p = [Windows.Forms.Screen]::PrimaryScreen.Bounds
    $b = $Screen.Bounds
    $where = if ($Screen.Primary) { 'Principal' }
             elseif ($b.Left -ge $p.Right) { 'A la derecha' }
             elseif ($b.Right -le $p.Left) { 'A la izquierda' }
             elseif ($b.Bottom -le $p.Top) { 'Arriba' }
             else { 'Abajo' }
    "$where  ·  $($b.Width) × $($b.Height)"
}

function script:Register-GamesTask {
    Register-ScheduledTask -TaskName 'PcToolkitGames' -Force `
        -Action (New-HiddenTaskAction (Join-Path $script:GamesDir 'Games.ps1')) `
        -Trigger (New-ScheduledTaskTrigger -AtLogOn -User (Get-CurrentUserId)) `
        -Settings (New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)) `
        -Description 'PC Toolkit: HDR y ventana sin bordes de los juegos de la lista' | Out-Null
}
