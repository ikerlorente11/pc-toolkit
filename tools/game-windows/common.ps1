# common.ps1 - Configuración de Ventanas de juegos y pantallas. Lo cargan con "." el vigilante,
# install.ps1, settings.ps1 y home.ps1. Funciones "script:" para que sigan vivas en los botones del gestor.

Add-Type -AssemblyName System.Windows.Forms
if (-not ('PcToolkit.GameWindows.Native' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'WindowNative.cs') }
$script:GameWindowsDir  = $PSScriptRoot
$script:GameWindowsData = Join-Path $env:LOCALAPPDATA 'PcToolkit\data\game-windows'

function script:Get-GameWindowsConfig {
    $path = Join-Path $script:GameWindowsData 'config.json'
    $c = if (Test-Path $path) { try { Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }
    $games = if ($c -and $null -ne $c.Games) { @($c.Games | Where-Object { $_.Exe }) }
             else { @([pscustomobject]@{ Exe = 'isaac-ng.exe'; Name = 'The Binding of Isaac'; Screen = 'primary' }) }
    foreach ($g in $games) { if (-not $g.Screen) { $g | Add-Member -Force -NotePropertyName Screen -NotePropertyValue 'primary' } }
    @{ Games = $games }
}

function script:Save-GameWindowsConfig($Config) {
    New-Item -ItemType Directory -Force -Path $script:GameWindowsData | Out-Null
    @{ Games = @($Config.Games) } | ConvertTo-Json -Depth 3 | Set-Content (Join-Path $script:GameWindowsData 'config.json') -Encoding UTF8
}

# 'primary' o el nombre de Windows de la pantalla (\\.\DISPLAY2); si ya no está, la principal
function script:Get-GameScreen([string]$Screen) {
    $all = [Windows.Forms.Screen]::AllScreens
    $s = $all | Where-Object { $_.DeviceName -eq $Screen } | Select-Object -First 1
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

function script:Register-GameWindowsTask {
    Register-ScheduledTask -TaskName 'PcToolkitGameWindows' -Force `
        -Action (New-HiddenTaskAction (Join-Path $script:GameWindowsDir 'GameWindows.ps1')) `
        -Trigger (New-ScheduledTaskTrigger -AtLogOn -User (Get-CurrentUserId)) `
        -Settings (New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)) `
        -Description 'PC Toolkit: pone los juegos de la lista en ventana sin bordes a pantalla completa' | Out-Null
}
