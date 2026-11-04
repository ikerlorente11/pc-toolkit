# Jarvis.ps1 - Lanzador del asistente de voz (lo arranca oculto la tarea "PcToolkitJarvis").
# Pone en marcha Ollama si hace falta y mantiene vivo jarvis_voice.py (si se cae, lo vuelve a abrir).
# El asistente se cierra solo cuando se cierra este lanzador (el gestor lo para al desactivar).

. (Join-Path $PSScriptRoot 'common.ps1')

$mutex = New-Object System.Threading.Mutex($false, 'PcToolkit.Jarvis.Launcher')
try { if (-not $mutex.WaitOne(0)) { exit } } catch [System.Threading.AbandonedMutexException] {}

$LogFile = Join-Path $script:JarvisData 'Jarvis.log'
function Write-Log($msg) {
    try { Add-Content -Path $LogFile -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg) -Encoding UTF8 } catch {}
}

if (-not (Test-Path $script:JarvisPythonW)) { Write-Log 'Falta el entorno de Python: reinstala Jarvis desde el panel.'; exit 1 }
if (-not (Start-Ollama)) { Write-Log 'Ollama no está en marcha: Jarvis lo volverá a intentar al preguntarle.' }

Set-JarvisEnvironment
$script = Join-Path $PSScriptRoot 'jarvis_voice.py'
$fails = 0
while ($true) {
    Write-Log 'Arrancando el asistente...'
    $p = Start-Process $script:JarvisPythonW -PassThru -ArgumentList "`"$script`"", '--data', "`"$script:JarvisData`"", '--parent', $PID
    $p.WaitForExit()
    if ($p.ExitCode -eq 0) { break }
    $fails++
    Write-Log "El asistente se ha cerrado con el código $($p.ExitCode)"
    if ($fails -ge 5) { Write-Log 'Demasiados fallos seguidos: se deja parado (revisa el registro y reactívalo).'; exit 1 }
    Start-Sleep -Seconds (10 * $fails)
}
