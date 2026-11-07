# vbs.ps1 - Ajustes del registro que obligan a cargar el hipervisor, según el modo (lo cargan Boot.ps1 y
# Remove.ps1, siempre con administrador). Aunque la entrada de arranque tenga hypervisorlaunchtype y
# vsmlaunchtype en off, Windows arranca el hipervisor si alguno de estos vale 1 ("VBS Enabled, VSM Required
# ... due to VBS registry configuration"):
#   - DeviceGuard\EnableVirtualizationBasedSecurity: VBS
#   - DeviceGuard\Scenarios\WindowsHello\Enabled: inicio de sesión mejorado de Windows Hello (ESS)
# En modo juegos se ponen a 0; los valores originales se guardan en vbs-original.json para devolverlos
# al volver al modo normal (o al desinstalar).

$script:VbsValues = @(
    @{ Key = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard'; Name = 'EnableVirtualizationBasedSecurity' },
    @{ Key = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\WindowsHello'; Name = 'Enabled' }
)

function script:Get-VbsValueId($v) { "$($v.Key)|$($v.Name)" }

function script:Set-GameModeVbs([string]$DataDir, [bool]$Restore) {
    $saved = Join-Path $DataDir 'vbs-original.json'
    $orig = @{}
    if (Test-Path $saved) {
        $json = Get-Content $saved -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($json.PSObject.Properties.Name -contains 'Values') {
            foreach ($p in $json.Values.PSObject.Properties) { $orig[$p.Name] = $p.Value }
        } else {
            # Formato de la 1.19.1: solo EnableVirtualizationBasedSecurity
            $orig[(Get-VbsValueId $script:VbsValues[0])] = $json.Value
        }
    }

    if ($Restore) {
        if (-not (Test-Path $saved)) { return }   # nunca se cambió
        foreach ($v in $script:VbsValues) {
            $id = Get-VbsValueId $v
            if (-not $orig.ContainsKey($id)) { continue }
            if ($null -eq $orig[$id]) { Remove-ItemProperty $v.Key -Name $v.Name -ErrorAction SilentlyContinue }
            else {
                if (-not (Test-Path $v.Key)) { New-Item $v.Key -Force | Out-Null }
                Set-ItemProperty $v.Key -Name $v.Name -Value ([int]$orig[$id]) -Type DWord
            }
        }
        Remove-Item $saved -Force
        return
    }

    foreach ($v in $script:VbsValues) {
        $id = Get-VbsValueId $v
        # Solo se apunta el original la primera vez (si ya estaba en modo juegos, ahí está el 0)
        if (-not $orig.ContainsKey($id)) {
            $orig[$id] = if (Test-Path $v.Key) { (Get-ItemProperty $v.Key -Name $v.Name -ErrorAction SilentlyContinue).($v.Name) }
        }
        if (-not (Test-Path $v.Key)) { continue }   # si la clave no existe, no hay nada que lo active
        Set-ItemProperty $v.Key -Name $v.Name -Value 0 -Type DWord
    }
    @{ Values = $orig } | ConvertTo-Json -Depth 3 | Set-Content $saved -Encoding UTF8
}
