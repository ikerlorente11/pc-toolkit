# common.ps1 - Configuración de HDR por juego y control del HDR. Lo cargan con "." el vigilante,
# install.ps1, disable.ps1, settings.ps1 y home.ps1. Funciones "script:" para que sigan vivas en los botones del gestor.

if (-not ('PcToolkit.Hdr.Native' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'HdrNative.cs') }
$script:HdrGamesDir  = $PSScriptRoot
$script:HdrGamesData = Join-Path $env:LOCALAPPDATA 'PcToolkit\data\hdr-games'
# Pantallas a las que el vigilante quitó el HDR y que hay que devolver al cerrar el juego
$script:HdrRestoreFile = Join-Path $script:HdrGamesData 'restore.json'

function script:Get-HdrGamesConfig {
    $path = Join-Path $script:HdrGamesData 'config.json'
    $c = if (Test-Path $path) { try { Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }
    $games = if ($c -and $null -ne $c.Games) { @($c.Games | Where-Object { $_.Exe }) }
             else { @([pscustomobject]@{ Exe = 'isaac-ng.exe'; Name = 'The Binding of Isaac' }) }
    @{ Games = $games }
}

function script:Save-HdrGamesConfig($Config) {
    New-Item -ItemType Directory -Force -Path $script:HdrGamesData | Out-Null
    @{ Games = @($Config.Games) } | ConvertTo-Json -Depth 3 | Set-Content (Join-Path $script:HdrGamesData 'config.json') -Encoding UTF8
}

# Primer juego de la lista que esté abierto (o nada)
function script:Get-RunningHdrGame($Games) {
    foreach ($g in $Games) {
        $name = [IO.Path]::GetFileNameWithoutExtension($g.Exe)
        $procs = [Diagnostics.Process]::GetProcessesByName($name)
        $found = $procs.Count -gt 0
        foreach ($p in $procs) { $p.Dispose() }
        if ($found) { return $g }
    }
}

function script:Get-HdrDisplays { @([PcToolkit.Hdr.Native]::List() | Where-Object Supported) }

# Quita el HDR a las pantallas que lo tengan y apunta cuáles eran para devolvérselo luego
function script:Disable-HdrForGame {
    $on = @(Get-HdrDisplays | Where-Object Enabled)
    foreach ($d in $on) { [void][PcToolkit.Hdr.Native]::Set($d, $false) }
    New-Item -ItemType Directory -Force -Path $script:HdrGamesData | Out-Null
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

function script:Register-HdrGamesTask {
    Register-ScheduledTask -TaskName 'PcToolkitHdrGames' -Force `
        -Action (New-HiddenTaskAction (Join-Path $script:HdrGamesDir 'HdrGames.ps1')) `
        -Trigger (New-ScheduledTaskTrigger -AtLogOn -User (Get-CurrentUserId)) `
        -Settings (New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)) `
        -Description 'PC Toolkit: desactiva el HDR mientras hay un juego de la lista abierto' | Out-Null
}
