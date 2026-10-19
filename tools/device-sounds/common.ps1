# common.ps1 - Sonidos de dispositivos: biblioteca, configuración y aplicar/restaurar los sonidos de
# Windows "Conectar dispositivo" y "Desconectar dispositivo" (HKCU\AppEvents, sin admin ni procesos).
# Lo cargan con "." Apply.ps1 (tarea al iniciar sesión), disable.ps1, settings.ps1 y home.ps1.

if (-not ('PcToolkit.DeviceSounds.WavVolume' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'WavVolume.cs') }
$script:DeviceSoundsDir  = $PSScriptRoot
$script:DeviceSoundsData = Join-Path $env:LOCALAPPDATA 'PcToolkit\data\device-sounds'

# Biblioteca: sounds\<id>.wav (WAV PCM, el formato que admite Windows para los sonidos del sistema)
$script:DeviceSoundLibrary = [ordered]@{
    'desenvainar-espada' = 'Desenvainar espada'
    'envainar-espada'    = 'Envainar espada'
    'yamete-kudasai'     = 'Yamete kudasai'
    'ahh'                = 'Ahh'
    'yiahhh'             = 'Yiahhh'
    'globo'              = 'Pop de globo'
    'xp-conectar'        = 'Windows XP: conectar'
    'xp-desconectar'     = 'Windows XP: desconectar'
    'discord-entrar'     = 'Discord: entrar'
    'discord-salir'      = 'Discord: salir'
    'vine-boom'          = 'Vine boom'
    'bruh'               = 'Bruh'
}

# Eventos de Windows que se personalizan
$script:DeviceSoundEvents = [ordered]@{ Connect = 'DeviceConnect'; Disconnect = 'DeviceDisconnect' }

function script:Get-DeviceSoundLabel([string]$Id) {
    switch ($Id) { 'windows' { 'Predeterminado de Windows' } 'none' { 'Sin sonido' } default { $script:DeviceSoundLibrary[$Id] } }
}

function script:Test-DeviceSoundId([string]$Id) { $Id -in 'windows', 'none' -or $script:DeviceSoundLibrary.Contains($Id) }

function script:Get-DeviceSoundsConfig {
    $path = Join-Path $script:DeviceSoundsData 'config.json'
    $c = if (Test-Path $path) { try { Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }
    # Sonidos de espada de la v1.9.0 que se unificaron: katana -> desenvainar, espada 2 -> envainar
    $renamed = @{ 'desenvainar-katana' = 'desenvainar-espada'; 'envainar-espada-2' = 'envainar-espada' }
    foreach ($k in 'Connect', 'Disconnect') { if ($c -and $renamed.ContainsKey([string]$c.$k)) { $c.$k = $renamed[[string]$c.$k] } }
    @{
        Connect    = if (Test-DeviceSoundId $c.Connect) { [string]$c.Connect } else { 'desenvainar-espada' }
        Disconnect = if (Test-DeviceSoundId $c.Disconnect) { [string]$c.Disconnect } else { 'envainar-espada' }
        Volume     = if ($null -ne $c.Volume) { [Math]::Max(0, [Math]::Min(100, [int]$c.Volume)) } else { 100 }
    }
}

function script:Save-DeviceSoundsConfig($Config) {
    New-Item -ItemType Directory -Force -Path $script:DeviceSoundsData | Out-Null
    $Config | ConvertTo-Json | Set-Content (Join-Path $script:DeviceSoundsData 'config.json') -Encoding UTF8
}

function script:Get-EventKey([string]$WindowsEvent, [string]$Which) { "HKCU:\AppEvents\Schemes\Apps\.Default\$WindowsEvent\$Which" }

# Sonido original de Windows para el evento (el valor de .Default, con %SystemRoot% expandido)
function script:Get-WindowsDeviceSound([string]$WindowsEvent) {
    $k = Get-Item (Get-EventKey $WindowsEvent '.Default') -ErrorAction SilentlyContinue
    if ($k) { [Environment]::ExpandEnvironmentVariables([string]$k.GetValue('')) } else { '' }
}

# Ruta del archivo para un id: un sonido de la biblioteca, el de Windows o '' (sin sonido)
function script:Get-DeviceSoundPath([string]$Id, [string]$WindowsEvent) {
    switch ($Id) {
        'windows' { Get-WindowsDeviceSound $WindowsEvent }
        'none'    { '' }
        default   { Join-Path $script:DeviceSoundsDir "sounds\$Id.wav" }
    }
}

function script:Set-EventSound([string]$WindowsEvent, [string]$Path) {
    $key = Get-EventKey $WindowsEvent '.Current'
    if (-not (Test-Path $key)) { New-Item $key -Force | Out-Null }
    Set-ItemProperty $key '(default)' $Path
}

# Archivo con el volumen elegido: al 100 % el original; si no, una copia en la carpeta de datos
# (si el formato no lo permite, también el original)
function script:Get-DeviceSoundAtVolume([string]$Path, [int]$Volume, [string]$Name) {
    if (-not $Path -or $Volume -ge 100 -or -not (Test-Path $Path)) { return $Path }
    New-Item -ItemType Directory -Force -Path $script:DeviceSoundsData | Out-Null
    $target = Join-Path $script:DeviceSoundsData "$Name.wav"
    if ([PcToolkit.DeviceSounds.WavVolume]::Scale($Path, $target, $Volume)) { $target } else { $Path }
}

# Aplica la configuración (Windows lee el registro cada vez que reproduce el sonido: efecto inmediato)
function script:Invoke-DeviceSounds {
    $cfg = Get-DeviceSoundsConfig
    foreach ($name in $script:DeviceSoundEvents.Keys) {
        $ev = $script:DeviceSoundEvents[$name]
        $path = Get-DeviceSoundPath $cfg[$name] $ev
        Set-EventSound $ev (Get-DeviceSoundAtVolume $path $cfg.Volume $name.ToLower())
    }
}

# Vuelve a los sonidos de Windows
function script:Restore-DeviceSounds {
    foreach ($ev in $script:DeviceSoundEvents.Values) { Set-EventSound $ev (Get-WindowsDeviceSound $ev) }
}

# Reproduce un archivo WAV con el volumen elegido (muestra en el gestor)
function script:Invoke-DeviceSoundPreview([string]$Path) {
    $path = Get-DeviceSoundAtVolume $Path (Get-DeviceSoundsConfig).Volume 'muestra'
    if ($path -and (Test-Path $path)) {
        $player = New-Object System.Media.SoundPlayer $path
        $player.Load()   # en memoria: la muestra siguiente puede sobrescribir el archivo
        $player.Play()
    }
}
