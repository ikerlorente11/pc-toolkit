# AudioAutoSwitch.ps1 - Vigilante de Audio AutoSwitch.
# Lo ultimo que enciendes pasa a sonar. Al apagarlo vuelve al anterior que siga encendido y, si no
# queda ninguno, al dispositivo por defecto de la configuracion (si no hay, no toca nada).
# Si cambias a mano (gestor o menu de sonido de Windows), ese pasa a ser el actual.
# Lo lanza oculto la tarea programada "AudioAutoSwitch" al iniciar sesion.

Add-Type -Path (Join-Path $PSScriptRoot 'AudioEndpoints.cs')

$DataDir    = Join-Path $env:LOCALAPPDATA 'PcToolkit\data\audio-autoswitch'
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
$ConfigPath = Join-Path $DataDir 'config.json'
$LogFile    = Join-Path $DataDir 'AudioAutoSwitch.log'

# Evitar instancias duplicadas
$mutex = New-Object System.Threading.Mutex($false, 'PcToolkit.AudioAutoSwitch')
try { if (-not $mutex.WaitOne(0)) { exit } } catch [System.Threading.AbandonedMutexException] {}

function Write-Log($msg) {
    try {
        if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 100KB) { Clear-Content $LogFile }
        Add-Content -Path $LogFile -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg) -Encoding UTF8
    } catch {}
}

# Configuracion: se vuelve a leer sola cuando el gestor la cambia
$script:cfg = $null
$script:cfgStamp = $null
function Update-Config {
    $stamp = if (Test-Path $ConfigPath) { (Get-Item $ConfigPath).LastWriteTimeUtc } else { 0 }
    if ($script:cfg -and $stamp -eq $script:cfgStamp) { return }
    $script:cfgStamp = $stamp
    $c = $null
    if (Test-Path $ConfigPath) { try { $c = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }
    $script:cfg = @{ DefaultRenderId = $c.DefaultRenderId; FollowMic = [bool]$c.FollowMic; Auto = @{} }
    if ($c.Auto) { foreach ($p in $c.Auto.PSObject.Properties) { $script:cfg.Auto[$p.Name] = [bool]$p.Value } }
}

function Test-Auto($dev) {
    if ($script:cfg.Auto.ContainsKey($dev.Id)) { $script:cfg.Auto[$dev.Id] } else { $dev.AutoByDefault }
}

# Micro del mismo aparato (mismo ContainerId), si se ha pedido
function Set-MicFor($dev) {
    if (-not $script:cfg.FollowMic) { return }
    $mic = [PcToolkit.Audio.Endpoints]::List(1) | Where-Object { $_.ContainerId -eq $dev.ContainerId } | Select-Object -First 1
    if ($mic -and -not $mic.IsDefault) {
        [PcToolkit.Audio.Endpoints]::SetDefault($mic.Id)
        Write-Log "  micro: $($mic.Name)"
    }
}

function Switch-To($dev, $reason) {
    [PcToolkit.Audio.Endpoints]::SetDefault($dev.Id)
    $script:lastSet = $dev.Id
    Write-Log "$reason -> $($dev.Name)"
    Set-MicFor $dev
}

# Pila: el de arriba es el que deberia sonar
$stack   = New-Object System.Collections.Generic.List[string]
$prev    = $null
$script:lastSet = $null

Write-Log 'Vigilante iniciado'
while ($true) {
    try {
        Update-Config
        $renders = @([PcToolkit.Audio.Endpoints]::List(0))
        $active = @{}
        foreach ($d in $renders) { $active[$d.Id] = $d }
        $current = [PcToolkit.Audio.Endpoints]::GetDefaultId(0)

        if ($null -eq $prev) {
            # Arranque: si suena algo con cambio automatico se respeta; si no, el dispositivo por defecto
            if ($current) { $stack.Add($current) }
            $script:lastSet = $current
            $def = $script:cfg.DefaultRenderId
            if ($def -and $active.ContainsKey($def) -and $current -ne $def -and -not ($current -and $active.ContainsKey($current) -and (Test-Auto $active[$current]))) {
                $stack.Clear(); $stack.Add($def)
                Switch-To $active[$def] 'Inicio (dispositivo por defecto)'
            }
        } else {
            # 1. Apagados: se quitan de la pila; si era el que sonaba, vuelve al anterior encendido
            $lostCurrent = $script:lastSet -and -not $active.ContainsKey($script:lastSet)
            for ($i = $stack.Count - 1; $i -ge 0; $i--) { if (-not $active.ContainsKey($stack[$i])) { $stack.RemoveAt($i) } }
            if ($lostCurrent) {
                $name = if ($prev.ContainsKey($script:lastSet)) { $prev[$script:lastSet].Name } else { 'el dispositivo' }
                $target = if ($stack.Count) { $stack[$stack.Count - 1] }
                elseif ($script:cfg.DefaultRenderId -and $active.ContainsKey($script:cfg.DefaultRenderId)) { $script:cfg.DefaultRenderId }
                if ($target) {
                    if ($stack.Count -eq 0) { $stack.Add($target) }
                    Switch-To $active[$target] "Apagado $name"
                } else {
                    $script:lastSet = $current
                    Write-Log "Apagado $name -> lo decide Windows"
                }
            }
            # 2a. Windows ha cambiado solo a algo que se acaba de conectar (p. ej. un monitor HDMI al despertar):
            #     si no tiene cambio automatico, se mantiene lo que sonaba; si lo tiene, lo resuelve el paso 3
            elseif ($current -and $current -ne $script:lastSet -and $active.ContainsKey($current) -and -not $prev.ContainsKey($current)) {
                if (-not (Test-Auto $active[$current]) -and $script:lastSet -and $active.ContainsKey($script:lastSet)) {
                    Switch-To $active[$script:lastSet] "Windows cambio a $($active[$current].Name), se mantiene"
                }
            }
            # 2b. Cambio hecho a mano (gestor o menu de sonido de Windows): ese pasa a ser el actual
            elseif ($current -and $current -ne $script:lastSet -and $active.ContainsKey($current)) {
                [void]$stack.Remove($current); $stack.Add($current)
                $script:lastSet = $current
                Write-Log "Elegido a mano -> $($active[$current].Name)"
                Set-MicFor $active[$current]
            }

            # 3. Encendidos con cambio automatico: pasan a sonar (del mismo aparato, mejor estereo que manos libres)
            $added = @($renders | Where-Object { -not $prev.ContainsKey($_.Id) -and (Test-Auto $_) })
            $added = @($added | Where-Object {
                $dev = $_
                -not ($dev.IsHandsFree -and ($renders | Where-Object { -not $_.IsHandsFree -and $_.ContainerId -eq $dev.ContainerId }))
            })
            if ($added) {
                $pick = @($added | Sort-Object IsHandsFree)[0]
                [void]$stack.Remove($pick.Id); $stack.Add($pick.Id)
                Switch-To $pick 'Encendido'
            }
        }
        $prev = $active
    } catch {
        Write-Log "ERROR: $($_.Exception.Message)"
    }
    Start-Sleep -Milliseconds 1500
}
