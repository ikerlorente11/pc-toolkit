# configure.ps1 - Ventana para elegir los auriculares y los dispositivos de respaldo.
# Guarda config.json en la carpeta de datos y devuelve $true si se guardó.

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
Import-Module AudioDeviceCmdlets
Import-Module (Join-Path $PSScriptRoot '..\..\core\Toolkit.psm1')

$configPath = Join-Path (Get-ToolDataDir 'audio-autoswitch') 'config.json'
$current    = if (Test-Path $configPath) { Get-Content $configPath -Raw | ConvertFrom-Json }

$form = New-Object Windows.Forms.Form
$form.SuspendLayout()
$form.AutoScaleDimensions = New-Object Drawing.SizeF(96, 96)
$form.AutoScaleMode   = 'Dpi'
$form.Text            = 'Audio AutoSwitch - Dispositivos'
$form.StartPosition   = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox     = $false
$form.MinimizeBox     = $false
$form.TopMost         = $true
$form.Font            = New-Object Drawing.Font('Segoe UI', 9.5)
$form.ClientSize      = New-Object Drawing.Size(460, 340)

$hint = New-Object Windows.Forms.Label
$hint.Location = New-Object Drawing.Point(16, 12)
$hint.Size     = New-Object Drawing.Size(428, 40)
$hint.Text     = 'Enciende los auriculares antes de elegirlos. Si no salen en la lista, enciéndelos y pulsa Actualizar.'
$form.Controls.Add($hint)

# Cada fila: etiqueta + desplegable. Ids guarda el ID del dispositivo de cada opción ($null = no cambiar).
$rows = @(
    @{ Key = 'HeadphoneRenderId';  Type = 'Playback';  Optional = $false; Label = 'Auriculares Bluetooth (salida de sonido)' }
    @{ Key = 'HeadphoneCaptureId'; Type = 'Recording'; Optional = $true;  Label = 'Micrófono al encender los auriculares' }
    @{ Key = 'FallbackRenderId';   Type = 'Playback';  Optional = $false; Label = 'Altavoces al apagar los auriculares' }
    @{ Key = 'FallbackCaptureId';  Type = 'Recording'; Optional = $true;  Label = 'Micrófono al apagar los auriculares' }
)
$y = 60
foreach ($row in $rows) {
    $label = New-Object Windows.Forms.Label
    $label.Location = New-Object Drawing.Point(16, $y)
    $label.AutoSize = $true
    $label.Text     = $row.Label
    $combo = New-Object Windows.Forms.ComboBox
    $combo.Location      = New-Object Drawing.Point(16, ($y + 22))
    $combo.Width         = 428
    $combo.DropDownStyle = 'DropDownList'
    $form.Controls.AddRange(@($label, $combo))
    $row.Combo = $combo
    $row.Ids   = @()
    $y += 62
}

function Get-Selected($row) {
    $i = $row.Combo.SelectedIndex
    if ($i -ge 0) { $row.Ids[$i] }
}

function Update-Lists {
    $devices = @(Get-AudioDevice -List)
    foreach ($row in $rows) {
        $prev = if ($row.Combo.SelectedIndex -ge 0) { Get-Selected $row } elseif ($current) { $current.($row.Key) }
        $row.Ids = @()
        $row.Combo.Items.Clear()
        if ($row.Optional) { $row.Ids += $null; [void]$row.Combo.Items.Add('(no cambiar)') }
        foreach ($d in $devices | Where-Object Type -eq $row.Type) {
            $row.Ids += $d.ID
            [void]$row.Combo.Items.Add($d.Name)
        }
        $i = [array]::IndexOf($row.Ids, $prev)
        if ($i -lt 0 -and $row.Combo.Items.Count) { $i = 0 }
        $row.Combo.SelectedIndex = $i
    }
}

function New-DialogButton($text, $x) {
    $b = New-Object Windows.Forms.Button
    $b.Text     = $text
    $b.Location = New-Object Drawing.Point($x, ($y + 6))
    $b.Size     = New-Object Drawing.Size(100, 30)
    $form.Controls.Add($b)
    $b
}
$btnRefresh = New-DialogButton 'Actualizar' 16
$btnSave    = New-DialogButton 'Guardar' 236
$btnCancel  = New-DialogButton 'Cancelar' 344
$form.AcceptButton = $btnSave
$form.CancelButton = $btnCancel
$btnCancel.DialogResult = 'Cancel'

$btnRefresh.Add_Click({ Update-Lists })
$btnSave.Add_Click({
    $hp = Get-Selected $rows[0]
    $fb = Get-Selected $rows[2]
    $msg = if (-not $hp -or -not $fb) { 'Elige los auriculares y los altavoces.' }
           elseif ($hp -eq $fb) { 'Los auriculares y los altavoces deben ser dispositivos distintos.' }
           elseif ($hp -notmatch '\{0\.0\.0\.00000000\}\.(\{[0-9a-fA-F-]+\})') { "No se pudo leer el identificador de: $($rows[0].Combo.Text)" }
    if ($msg) { [void][Windows.Forms.MessageBox]::Show($msg, 'Audio AutoSwitch', 'OK', 'Warning'); return }

    [ordered]@{
        HeadphoneLabel     = $rows[0].Combo.Text
        HeadphoneRenderId  = $hp
        HeadphoneCaptureId = Get-Selected $rows[1]
        FallbackLabel      = $rows[2].Combo.Text
        FallbackRenderId   = $fb
        FallbackCaptureId  = Get-Selected $rows[3]
        RenderGuid         = $Matches[1]
    } | ConvertTo-Json | Out-File $configPath -Encoding utf8
    $form.DialogResult = 'OK'
})

$form.ClientSize = New-Object Drawing.Size(460, ($y + 50))
$form.ResumeLayout($false)
Update-Lists
$form.ShowDialog() -eq 'OK'
