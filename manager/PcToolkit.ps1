# PcToolkit.ps1 - Gestor de PC Toolkit: icono en la bandeja del sistema y panel (estilo PowerToys)
# para activar, configurar, instalar y desinstalar las herramientas.
# Lo lanza core\run-hidden.vbs al iniciar sesión (solo bandeja) y desde el menú Inicio (-Show).
param([switch]$Show)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Import-Module (Join-Path $PSScriptRoot '..\core\Toolkit.psm1') -Force

# Una sola instancia: si ya hay una abierta, se le pide que muestre su ventana
$showEvent = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::AutoReset, 'PcToolkit.Manager.Show')
$mutex     = New-Object Threading.Mutex($false, 'PcToolkit.Manager')
try { $owned = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) { [void]$showEvent.Set(); return }

Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @"
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;

// Interruptor estilo Windows 11
public class ToggleSwitch : CheckBox {
    public Color OnColor = Color.FromArgb(0, 103, 192);
    public Color OffColor = Color.Gray;
    public Color KnobOnColor = Color.White;
    public ToggleSwitch() {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                 ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        AutoSize = false;
        Size = new Size(44, 22);
        Cursor = Cursors.Hand;
    }
    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        g.Clear(Parent != null ? Parent.BackColor : BackColor);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        float w = Width - 3, h = Height - 3;
        using (GraphicsPath track = new GraphicsPath()) {
            track.AddArc(1, 1, h, h, 90, 180);
            track.AddArc(1 + w - h, 1, h, h, 270, 180);
            track.CloseFigure();
            if (Checked) { using (SolidBrush b = new SolidBrush(OnColor)) g.FillPath(b, track); }
            else { using (Pen p = new Pen(OffColor, Math.Max(1f, h / 16f))) g.DrawPath(p, track); }
        }
        float k = h * 0.56f, pad = (h - k) / 2;
        float x = Checked ? 1 + w - pad - k : 1 + pad;
        using (SolidBrush b = new SolidBrush(Checked ? KnobOnColor : OffColor)) g.FillEllipse(b, x, 1 + pad, k, k);
    }
}

public static class Native {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd, int cmd);
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
    public static void SetDarkTitleBar(IntPtr hwnd, bool dark) {
        int v = dark ? 1 : 0;
        DwmSetWindowAttribute(hwnd, 20, ref v, 4);   // DWMWA_USE_IMMERSIVE_DARK_MODE
    }
}
"@

[void][Native]::SetProcessDPIAware()
[Windows.Forms.Application]::EnableVisualStyles()

# --- Tema (claro u oscuro, el que use Windows) ---

$dark = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -ErrorAction SilentlyContinue).AppsUseLightTheme -eq 0
function Hex($h) { [Drawing.ColorTranslator]::FromHtml($h) }
$C = if ($dark) {
    @{ Bg = Hex '#202020'; Card = Hex '#2b2b2b'; Border = Hex '#3a3a3a'; Button = Hex '#373737'; ButtonHover = Hex '#3f3f3f'
       Text = Hex '#ffffff'; Sub = Hex '#a6a6a6'; Accent = Hex '#4cc2ff'; Knob = Hex '#000000'; Ok = Hex '#6ccb5f'; Warn = Hex '#fce100' }
} else {
    @{ Bg = Hex '#f3f3f3'; Card = Hex '#ffffff'; Border = Hex '#e5e5e5'; Button = Hex '#fbfbfb'; ButtonHover = Hex '#f0f0f0'
       Text = Hex '#1a1a1a'; Sub = Hex '#5f5f5f'; Accent = Hex '#0067c0'; Knob = Hex '#ffffff'; Ok = Hex '#0f7b0f'; Warn = Hex '#9d5d00' }
}
$fontBase  = New-Object Drawing.Font('Segoe UI', 9.5)
$fontSmall = New-Object Drawing.Font('Segoe UI', 9)
$fontName  = New-Object Drawing.Font('Segoe UI Semibold', 11.5)
$fontTitle = New-Object Drawing.Font('Segoe UI Semibold', 20)

$iconPath = Join-Path $PSScriptRoot '..\assets\pc-toolkit.ico'
$appIcon  = New-Object Drawing.Icon($iconPath)
$trayIcon = New-Object Drawing.Icon($iconPath, [Windows.Forms.SystemInformation]::SmallIconSize)

function Pt($x, $y) { New-Object Drawing.Point($x, $y) }
function Sz($w, $h) { New-Object Drawing.Size($w, $h) }

function New-Label($text, $font, $color) {
    $l = New-Object Windows.Forms.Label
    $l.Text = $text; $l.Font = $font; $l.ForeColor = $color; $l.AutoSize = $true; $l.BackColor = [Drawing.Color]::Transparent
    $l
}

function New-Button($text) {
    $b = New-Object Windows.Forms.Button
    $b.Text = $text
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderColor = $C.Border
    $b.FlatAppearance.MouseOverBackColor = $C.ButtonHover
    $b.BackColor = $C.Button
    $b.ForeColor = $C.Text
    $b.Font = $fontSmall
    $b.AutoSize = $true
    $b.AutoSizeMode = 'GrowAndShrink'
    $b.Padding = New-Object Windows.Forms.Padding(8, 2, 8, 2)
    $b.Margin = New-Object Windows.Forms.Padding(6, 0, 0, 0)
    $b.Cursor = 'Hand'
    $b
}

function Show-Message($text, $buttons = 'OK', $icon = 'Information') {
    [Windows.Forms.MessageBox]::Show($text, 'PC Toolkit', $buttons, $icon)
}

# --- Acciones ---

$tools = @(Get-Tools)

# Ejecuta una accion con cursor de espera, muestra el error si falla y refresca la vista
function Invoke-UiAction([scriptblock]$Action) {
    $form.UseWaitCursor = $true
    [Windows.Forms.Application]::DoEvents()
    try { & $Action }
    catch { [void](Show-Message $_.Exception.Message 'OK' 'Error') }
    finally { $form.UseWaitCursor = $false; Update-View }
}

function Update-View {
    foreach ($t in $tools) {
        $ui = $cards[$t.id]
        $state = Get-ToolState $t
        $installed = $state -ne 'NotInstalled'
        $ui.Toggle.Visible  = $installed
        $ui.Toggle.Checked  = $state -eq 'Enabled'
        $ui.Config.Visible  = $installed -and $t.Configurable
        $ui.Log.Visible     = $installed -and [bool]$t.log
        $ui.Install.Text    = if ($installed) { 'Desinstalar' } else { 'Instalar' }
        if ($state -eq 'NotInstalled')  { $text = 'No instalada'; $color = $C.Sub }
        elseif ($state -eq 'Disabled')  { $text = 'Desactivada'; $color = $C.Sub }
        elseif (-not $t.process)        { $text = 'Activa'; $color = $C.Ok }
        elseif (Get-ToolProcess $t)     { $text = 'Activa · en marcha'; $color = $C.Ok }
        else                            { $text = 'Activa · no está en marcha'; $color = $C.Warn }
        $ui.Status.Text = "●  $text"
        $ui.Status.ForeColor = $color
    }
}

function Show-Main {
    Update-View
    $form.Show()
    # Lanzado oculto (run-hidden.vbs), Windows aplica SW_HIDE al primer ShowWindow del proceso: se repite
    [void][Native]::ShowWindow($form.Handle, 5)   # SW_SHOW
    if ($form.WindowState -eq 'Minimized') { $form.WindowState = 'Normal' }
    $form.TopMost = $true; $form.TopMost = $false   # traer al frente aunque lo pida otro proceso
    $form.Activate()
}

function Exit-Manager {
    $tray.Visible = $false
    [Windows.Forms.Application]::Exit()
}

# --- Ventana principal ---

$form = New-Object Windows.Forms.Form
$form.SuspendLayout()
$form.AutoScaleDimensions = New-Object Drawing.SizeF(96, 96)
$form.AutoScaleMode   = 'Dpi'
$form.Text            = 'PC Toolkit'
$form.Icon            = $appIcon
$form.StartPosition   = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox     = $false
$form.BackColor       = $C.Bg
$form.ForeColor       = $C.Text
$form.Font            = $fontBase
$form.Add_HandleCreated({ [Native]::SetDarkTitleBar($form.Handle, $dark) })
$form.Add_FormClosing({ if ($_.CloseReason -eq 'UserClosing') { $_.Cancel = $true; $form.Hide() } })
$form.Add_Activated({ Update-View })

$title = New-Label 'PC Toolkit' $fontTitle $C.Text
$title.Location = Pt 18 14
$subtitle = New-Label "Utilidades para Windows  ·  v$(Get-ToolkitVersion)" $fontSmall $C.Sub
$subtitle.Location = Pt 22 56
$form.Controls.AddRange(@($title, $subtitle))

$cards = @{}
$y = 92
foreach ($t in $tools) {
    $card = New-Object Windows.Forms.Panel
    $card.Location  = Pt 20 $y
    $card.Size      = Sz 600 124
    $card.BackColor = $C.Card
    $card.Add_Paint({
        $r = $this.ClientRectangle; $r.Width--; $r.Height--
        $pen = New-Object Drawing.Pen($C.Border)
        $_.Graphics.DrawRectangle($pen, $r)
        $pen.Dispose()
    })

    $name = New-Label $t.name $fontName $C.Text
    $name.Location = Pt 18 14

    $toggle = New-Object ToggleSwitch
    $toggle.Location    = Pt 538 16
    $toggle.Size        = Sz 44 22
    $toggle.OnColor     = $C.Accent
    $toggle.OffColor    = $C.Sub
    $toggle.KnobOnColor = $C.Knob
    $toggle.Tag         = $t
    $toggle.AccessibleName = "Activar $($t.name)"
    $toggle.Add_Click({
        $tool = $this.Tag; $on = $this.Checked
        Invoke-UiAction { if ($on) { Enable-Tool $tool } else { Disable-Tool $tool } }
    })

    $desc = New-Label $t.description $fontSmall $C.Sub
    $desc.AutoSize    = $false
    $desc.Location    = Pt 18 44
    $desc.Size        = Sz 500 40

    $status = New-Label '' $fontSmall $C.Sub
    $status.Location = Pt 18 92

    $buttons = New-Object Windows.Forms.FlowLayoutPanel
    $buttons.FlowDirection = 'RightToLeft'
    $buttons.WrapContents  = $false
    $buttons.Location      = Pt 240 84
    $buttons.Size          = Sz 344 32
    $buttons.BackColor     = $C.Card

    $btnInstall = New-Button 'Instalar'
    $btnLog     = New-Button 'Ver log'
    $btnConfig  = New-Button 'Configurar'
    foreach ($b in $btnInstall, $btnLog, $btnConfig) { $b.Tag = $t }
    $buttons.Controls.AddRange(@($btnInstall, $btnLog, $btnConfig))

    $btnInstall.Add_Click({
        $tool = $this.Tag
        if ((Get-ToolState $tool) -eq 'NotInstalled') {
            Invoke-UiAction { Install-Tool $tool }
        } elseif ((Show-Message "¿Desinstalar $($tool.name)? También se borrará su configuración." 'YesNo' 'Question') -eq 'Yes') {
            Invoke-UiAction { Uninstall-Tool $tool }
        }
    })
    $btnConfig.Add_Click({ $tool = $this.Tag; Invoke-UiAction { Invoke-ToolConfigure $tool } })
    $btnLog.Add_Click({
        $log = Get-ToolLog $this.Tag
        if ($log -and (Test-Path $log)) { Start-Process notepad.exe "`"$log`"" }
        else { [void](Show-Message 'Todavía no hay registro de actividad.') }
    })

    $card.Controls.AddRange(@($name, $toggle, $desc, $status, $buttons))
    $form.Controls.Add($card)
    $cards[$t.id] = @{ Toggle = $toggle; Status = $status; Install = $btnInstall; Log = $btnLog; Config = $btnConfig }
    $y += 136
}

# Pie: arranque con Windows, carpeta y actualizaciones
$chkAuto = New-Object Windows.Forms.CheckBox
$chkAuto.Text      = 'Iniciar con Windows'
$chkAuto.AutoSize  = $true
$chkAuto.Location  = Pt 22 ($y + 6)
$chkAuto.ForeColor = $C.Text
$chkAuto.Checked   = Test-ManagerAutostart
$chkAuto.Add_Click({ Set-ManagerAutostart $this.Checked })

$footer = New-Object Windows.Forms.FlowLayoutPanel
$footer.FlowDirection = 'RightToLeft'
$footer.WrapContents  = $false
$footer.Location      = Pt 220 $y
$footer.Size          = Sz 400 34
$btnUpdate = New-Button 'Buscar actualizaciones'
$btnFolder = New-Button 'Abrir carpeta'
$footer.Controls.AddRange(@($btnUpdate, $btnFolder))
$btnFolder.Add_Click({ Start-Process explorer.exe (Get-ToolkitRoot) })
$btnUpdate.Add_Click({
    Invoke-UiAction {
        $local  = Get-ToolkitVersion
        $remote = Get-ToolkitRemoteVersion
        if ([version]$remote -le [version]$local) { [void](Show-Message "Ya tienes la última versión (v$local)."); return }
        if ((Show-Message "Hay una versión nueva: v$remote (tienes la v$local).`n¿Actualizar ahora?" 'YesNo' 'Question') -eq 'Yes') {
            Start-ToolkitUpdate
            Exit-Manager
        }
    }
})
$form.Controls.AddRange(@($chkAuto, $footer))
$form.ClientSize = Sz 640 ($y + 50)
$form.ResumeLayout($false)

# --- Icono de la bandeja ---

$menu = New-Object Windows.Forms.ContextMenuStrip
$miOpen = $menu.Items.Add('Abrir PC Toolkit')
$miOpen.Font = New-Object Drawing.Font($menu.Font, [Drawing.FontStyle]::Bold)
$miOpen.Add_Click({ Show-Main })
[void]$menu.Items.Add('-')
$trayItems = @{}
foreach ($t in $tools) {
    $mi = $menu.Items.Add($t.name)
    $mi.Tag = $t
    $mi.Add_Click({
        $tool = $this.Tag; $on = -not $this.Checked
        Invoke-UiAction { if ($on) { Enable-Tool $tool } else { Disable-Tool $tool } }
    })
    $trayItems[$t.id] = $mi
}
[void]$menu.Items.Add('-')
$miExit = $menu.Items.Add('Salir')
$miExit.Add_Click({ Exit-Manager })
$menu.Add_Opening({
    foreach ($t in $tools) {
        $state = Get-ToolState $t
        $trayItems[$t.id].Visible = $state -ne 'NotInstalled'
        $trayItems[$t.id].Checked = $state -eq 'Enabled'
    }
})

$tray = New-Object Windows.Forms.NotifyIcon
$tray.Icon             = $trayIcon
$tray.Text             = 'PC Toolkit'
$tray.ContextMenuStrip = $menu
$tray.Add_MouseClick({ if ($_.Button -eq 'Left') { Show-Main } })
$tray.Visible = $true

# Peticiones de otra instancia para mostrar la ventana + refresco periodico del estado
$script:ticks = 0
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 500
$timer.Add_Tick({
    if ($showEvent.WaitOne(0)) { Show-Main }
    $script:ticks++
    if ($form.Visible -and $script:ticks % 10 -eq 0) { Update-View }
})
$timer.Start()

if ($Show) { Show-Main }
[Windows.Forms.Application]::Run()

$timer.Stop()
$tray.Dispose()
$mutex.ReleaseMutex()
