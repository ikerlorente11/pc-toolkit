# PcToolkit.ps1 - Gestor de PC Toolkit: icono en la bandeja y panel flotante estilo PowerToys
# (abajo a la derecha, redondeado, fondo acrílico) para instalar, activar y configurar herramientas.
# Lo lanza core\run-hidden.vbs al iniciar sesión (solo bandeja) y desde el menú Inicio (-Show).
#
# Páginas de ajustes de las herramientas: si una herramienta tiene settings.ps1, se carga con
# "." (en un bloque propio) al abrir su página y lo que devuelva se muestra. Puede usar estos helpers:
#   New-Ui <xaml>                          crea un elemento desde XAML (estilos de theme.xaml)
#   New-SectionHeader <texto> [<detalle>]  título de sección
#   New-Hint <texto>                       texto secundario
#   New-ToggleRow <título> <detalle> <activado> <acción> <arg>   -> & acción arg activado
#   New-ChoiceRow <título> <detalle> <elegido> <acción> <arg> [-Compact]  -> & acción arg
#   Update-Page                            vuelve a pintar la página
# Las funciones que use una acción deben declararse como "function script:Nombre".
# Si define $script:PageSignature (scriptblock), la página se repinta sola cuando su valor cambia.
#
# Otras extensiones de una herramienta:
#   home.ps1   igual que settings.ps1, pero se muestra dentro de su tarjeta en la portada. Para
#              repintar sola, $script:HomeSignatures['<id>'] = { ... }
#   "hotkey" en tool.json: { "keys": "Ctrl+Alt+A", "script": "x.ps1", "description": "..." }
#              atajo global mientras la herramienta esté activa; el script devuelve el texto
#              del aviso que aparece abajo en el centro (si no devuelve nada, no hay aviso).
param([switch]$Show)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, System.Windows.Forms, System.Drawing
Import-Module (Join-Path $PSScriptRoot '..\core\Toolkit.psm1') -Force

# Una sola instancia: si ya hay una abierta, se le pide que muestre el panel
$showEvent = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::AutoReset, 'PcToolkit.Manager.Show')
$mutex     = New-Object Threading.Mutex($false, 'PcToolkit.Manager')
try { $owned = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) { [void]$showEvent.Set(); return }

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class Native {
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd, int cmd);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr hwnd, int index);
    [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr hwnd, int index, int value);
    public static void RemoveSystemMenu(IntPtr hwnd) { SetWindowLong(hwnd, -16, GetWindowLong(hwnd, -16) & ~0x80000); }   // sin la X fantasma de Windows
    public static void SetDwm(IntPtr hwnd, int attr, int value) { DwmSetWindowAttribute(hwnd, attr, ref value, 4); }
    /* Aviso que no se activa ni sale en Alt+Tab */
    public static void SetNoActivate(IntPtr hwnd) { SetWindowLong(hwnd, -20, GetWindowLong(hwnd, -20) | 0x08000000 | 0x80); }
}
"@

# Atajos de teclado globales (RegisterHotKey en una ventana oculta de solo mensajes)
$wpfRefs = [Windows.Interop.HwndSource].Assembly.Location, [Windows.Threading.Dispatcher].Assembly.Location
Add-Type -ReferencedAssemblies $wpfRefs -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Windows.Interop;
public class GlobalHotkeys {
    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr hwnd, int id, uint mods, uint vk);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr hwnd, int id);
    readonly HwndSource source;
    public int LastId;
    public event EventHandler Pressed;
    public GlobalHotkeys() {
        HwndSourceParameters p = new HwndSourceParameters("PcToolkitHotkeys");
        p.ParentWindow = new IntPtr(-3);   /* HWND_MESSAGE */
        p.WindowStyle = 0;
        source = new HwndSource(p);
        source.AddHook(Hook);
    }
    public bool Register(int id, uint mods, uint vk) { return RegisterHotKey(source.Handle, id, mods | 0x4000 /* MOD_NOREPEAT */, vk); }
    public void Unregister(int id) { UnregisterHotKey(source.Handle, id); }
    IntPtr Hook(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled) {
        if (msg == 0x0312) {   /* WM_HOTKEY */
            LastId = wParam.ToInt32();
            if (Pressed != null) Pressed(this, EventArgs.Empty);
            handled = true;
        }
        return IntPtr.Zero;
    }
}
"@

$LogFile = Join-Path (Get-ToolkitRoot) 'manager.log'
function Write-ManagerLog($msg) {
    try { Add-Content $LogFile ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg) -Encoding UTF8 } catch {}
}

# --- Tema: claro u oscuro, color de acento de Windows y cristal (acrílico) en Windows 11 ---

$dark  = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -ErrorAction SilentlyContinue).AppsUseLightTheme -eq 0
$glass = [Environment]::OSVersion.Version.Build -ge 22621

function Get-AccentColor {
    $palette = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent' -ErrorAction SilentlyContinue).AccentPalette
    if ($palette -and $palette.Length -ge 32) {
        $i = if ($dark) { 1 } else { 4 }   # como Windows: acento claro en tema oscuro, oscuro en tema claro
        return '{0:X2}{1:X2}{2:X2}' -f $palette[$i * 4], $palette[$i * 4 + 1], $palette[$i * 4 + 2]
    }
    if ($dark) { '4CC2FF' } else { '005FB8' }
}
$accent = Get-AccentColor
$T = if ($dark) {
    @{ Text = '#FFFFFF'; Sub = '#C5FFFFFF'; Card = '#10FFFFFF'; CardHover = '#1AFFFFFF'; Stroke = '#14FFFFFF'; Subtle = '#15FFFFFF'
       OnAccent = '#000000'; Danger = '#FF99A4'; Ok = '#6CCB5F'; Warn = '#FCE100'; Osd = '#FF2C2C2C'; Tint = $(if ($glass) { '#30202020' } else { '#FF202020' }) }
} else {
    @{ Text = '#1A1A1A'; Sub = '#A0000000'; Card = '#B3FFFFFF'; CardHover = '#80F6F6F6'; Stroke = '#12000000'; Subtle = '#0D000000'
       OnAccent = '#FFFFFF'; Danger = '#C42B1C'; Ok = '#0F7B0F'; Warn = '#9D5D00'; Osd = '#FFF9F9F9'; Tint = $(if ($glass) { '#40F3F3F3' } else { '#FFF3F3F3' }) }
}
$T.Accent      = "#FF$accent"
$T.AccentHover = "#E0$accent"

function ConvertFrom-Xaml([string]$xaml) {
    foreach ($k in $T.Keys) { $xaml = $xaml.Replace("@$k@", $T[$k]) }
    [Windows.Markup.XamlReader]::Parse($xaml)
}
$XamlNs = 'xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"'
function New-Ui([string]$xaml) { ConvertFrom-Xaml ([regex]::Replace($xaml.Trim(), '^<([\w\.]+)', "<`$1 $XamlNs")) }

$app = New-Object Windows.Application
$app.ShutdownMode = 'OnExplicitShutdown'
$app.Resources = ConvertFrom-Xaml (Get-Content (Join-Path $PSScriptRoot 'theme.xaml') -Raw -Encoding UTF8)
$app.Add_DispatcherUnhandledException({
    param($s, $e)
    Write-ManagerLog "ERROR: $($e.Exception.Message)"
    $e.Handled = $true
})

$win = ConvertFrom-Xaml (Get-Content (Join-Path $PSScriptRoot 'flyout.xaml') -Raw -Encoding UTF8)
$ui = @{}
foreach ($n in 'Root', 'Anim', 'Slide', 'BackButton', 'Logo', 'HeaderTitle', 'ViewButton', 'SettingsButton', 'Banner', 'BannerText', 'Scroll', 'Page') { $ui[$n] = $win.FindName($n) }
# Imagen cargada en memoria (OnLoad) para no dejar el archivo bloqueado durante las actualizaciones
$logo = New-Object Windows.Media.Imaging.BitmapImage
$logo.BeginInit()
$logo.CacheOption = 'OnLoad'
$logo.UriSource = [Uri]::new([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\assets\pc-toolkit.png')))
$logo.EndInit()
$ui.Logo.Source = $logo
# Como mucho 640 px de alto (o lo que quepa): a partir de ahí, el contenido se desplaza
$ui.Scroll.MaxHeight = [Math]::Min([Windows.SystemParameters]::WorkArea.Height - 120, 640)
if (-not $glass) { [Windows.Shell.WindowChrome]::GetWindowChrome($win).GlassFrameThickness = 0 }

$win.Add_SourceInitialized({
    $hwnd = (New-Object Windows.Interop.WindowInteropHelper $win).Handle
    [Native]::RemoveSystemMenu($hwnd)
    [Native]::SetDwm($hwnd, 20, [int]$dark)   # DWMWA_USE_IMMERSIVE_DARK_MODE
    [Native]::SetDwm($hwnd, 33, 2)            # DWMWA_WINDOW_CORNER_PREFERENCE: esquinas redondeadas
    if ($glass) {
        [Windows.Interop.HwndSource]::FromHwnd($hwnd).CompositionTarget.BackgroundColor = [Windows.Media.Colors]::Transparent
        [Native]::SetDwm($hwnd, 38, 3)        # DWMWA_SYSTEMBACKDROP_TYPE: acrílico
    }
})

# --- Mostrar / ocultar el panel ---

$script:hiddenAt = [datetime]::MinValue

function Move-Flyout {
    $wa = [Windows.SystemParameters]::WorkArea
    $win.Left = $wa.Right - $win.ActualWidth - 12
    $win.Top  = $wa.Bottom - $win.ActualHeight - 12
}

# Abrir es inmediato: se enseña la portada ya hecha (se prepara al arrancar y se mantiene al día) y, justo
# después, el reloj mira si algo cambió y solo entonces la rehace. Rehacerla cuesta segundos (el XAML de cada
# tarjeta y los home.ps1), y hacerlo antes de enseñar el panel era lo que hacía que tardara en abrirse.
function Show-Flyout {
    if ($script:page -ne 'home' -or -not $script:homeReady) { Show-Home }
    $script:ticks = 4                       # el siguiente tic del reloj comprueba la firma de la página
    $ui.Anim.Opacity = 0
    $win.Show()
    # Lanzado oculto (run-hidden.vbs), Windows aplica SW_HIDE al primer ShowWindow del proceso: se repite
    [void][Native]::ShowWindow((New-Object Windows.Interop.WindowInteropHelper $win).Handle, 5)
    $win.UpdateLayout()
    Move-Flyout
    $win.Activate()
    $ease  = New-Object Windows.Media.Animation.CubicEase -Property @{ EasingMode = 'EaseOut' }
    $slide = New-Object Windows.Media.Animation.DoubleAnimation(30, 0, [TimeSpan]::FromMilliseconds(250))
    $slide.EasingFunction = $ease
    $fade  = New-Object Windows.Media.Animation.DoubleAnimation(0, 1, [TimeSpan]::FromMilliseconds(180))
    $ui.Slide.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, $slide)
    $ui.Anim.BeginAnimation([Windows.UIElement]::OpacityProperty, $fade)
}

function Hide-Flyout {
    if ($script:capturing) { $script:capturing = $null; $script:captureHint = $null; Update-Hotkeys }
    $win.Hide()
    $script:hiddenAt = Get-Date
}

function Switch-Flyout {
    if ($win.IsVisible) { Hide-Flyout }
    elseif (((Get-Date) - $script:hiddenAt).TotalMilliseconds -gt 300) { Show-Flyout }   # el clic que lo acaba de cerrar no lo reabre
}

function Exit-Manager {
    $tray.Visible = $false
    $app.Shutdown()
}

$win.Add_Deactivated({ Hide-Flyout })
$win.Add_SizeChanged({ Move-Flyout })
$win.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Escape') { Hide-Flyout } })

# --- Piezas de la interfaz (también para los settings.ps1 de las herramientas) ---

function ConvertTo-Glyph([string]$hex) { if ($hex) { [string][char][Convert]::ToInt32($hex, 16) } else { [string][char]0xE90F } }

function New-SectionHeader([string]$Text, [string]$Detail) {
    $p = New-Ui '<StackPanel/>'
    $h = New-Ui '<TextBlock Style="{StaticResource SectionHeader}"/>'
    $h.Text = $Text
    [void]$p.Children.Add($h)
    if ($Detail) {
        $d = New-Hint $Detail
        $d.Margin = '4,-4,0,8'
        [void]$p.Children.Add($d)
    }
    $p
}

function New-Hint([string]$Text) {
    $t = New-Ui '<TextBlock Style="{StaticResource Caption}" Margin="4,0,0,8"/>'
    $t.Text = $Text
    $t
}

function New-ProgressBar {
    New-Ui @'
<Grid Height="3" ClipToBounds="True" Margin="0,10,0,0">
  <Border Background="{StaticResource StrokeBrush}" CornerRadius="1.5"/>
  <Border Width="90" HorizontalAlignment="Left" Background="{StaticResource AccentBrush}" CornerRadius="1.5">
    <Border.RenderTransform><TranslateTransform/></Border.RenderTransform>
    <Border.Triggers>
      <EventTrigger RoutedEvent="FrameworkElement.Loaded">
        <BeginStoryboard><Storyboard RepeatBehavior="Forever">
          <DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="-90" To="360" Duration="0:0:1.1"/>
        </Storyboard></BeginStoryboard>
      </EventTrigger>
    </Border.Triggers>
  </Border>
</Grid>
'@
}

# Fila con interruptor. Al cambiarlo: & $Action $Arg $activado
function New-ToggleRow([string]$Title, [string]$Detail, [bool]$Checked, [scriptblock]$Action, $Arg) {
    $row = New-Ui @'
<Border Style="{StaticResource Card}">
  <Grid>
    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
    <StackPanel VerticalAlignment="Center" Margin="0,0,12,0">
      <TextBlock x:Name="T" Style="{StaticResource Body}"/>
      <TextBlock x:Name="D" Style="{StaticResource Caption}"/>
    </StackPanel>
    <CheckBox x:Name="Toggle" Grid.Column="1" Style="{StaticResource Toggle}"/>
  </Grid>
</Border>
'@
    $row.FindName('T').Text = $Title
    if ($Detail) { $row.FindName('D').Text = $Detail } else { $row.FindName('D').Visibility = 'Collapsed' }
    $toggle = $row.FindName('Toggle')
    $toggle.IsChecked = $Checked
    [Windows.Automation.AutomationProperties]::SetName($toggle, $Title)
    $toggle.Tag = @{ Action = $Action; Arg = $Arg }
    # Checked/Unchecked (no Click) para que funcione igual con ratón, teclado o lector de pantalla
    $onToggle = { param($s, $e) Invoke-Safe { & $s.Tag.Action $s.Tag.Arg ([bool]$s.IsChecked) } }
    $toggle.Add_Checked($onToggle)
    $toggle.Add_Unchecked($onToggle)
    $row
}

# Fila elegible (tipo radio). Al pulsarla: & $Action $Arg
function New-ChoiceRow([string]$Title, [string]$Detail, [bool]$Selected, [scriptblock]$Action, $Arg, [switch]$Compact) {
    $xaml = if ($Compact) { $CompactChoiceXaml } else { $ChoiceXaml }
    $row = New-Ui $xaml
    $row.FindName('T').Text = $Title
    if ($Detail) { $row.FindName('D').Text = $Detail } else { $row.FindName('D').Visibility = 'Collapsed' }
    if ($Selected) {
        $row.FindName('Ring').Stroke = $app.Resources['AccentBrush']
        $row.FindName('Dot').Visibility = 'Visible'
    }
    $row.Tag = @{ Action = $Action; Arg = $Arg }
    [Windows.Automation.AutomationProperties]::SetName($row, $Title)
    $row.Add_Click({ param($s, $e) Invoke-Safe { & $s.Tag.Action $s.Tag.Arg } })
    $row
}

# Versión pequeña (sin tarjeta) para listas dentro de otra tarjeta, como la portada
$CompactChoiceXaml = @'
<Button Style="{StaticResource SubtleButton}" Padding="8,5" HorizontalContentAlignment="Stretch" Margin="0,1,0,0">
  <Grid>
    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
    <Grid Width="14" Height="14" VerticalAlignment="Center">
      <Ellipse x:Name="Ring" Stroke="{StaticResource SubBrush}" StrokeThickness="1.3"/>
      <Ellipse x:Name="Dot" Width="6" Height="6" Fill="{StaticResource AccentBrush}" Visibility="Collapsed"/>
    </Grid>
    <StackPanel Grid.Column="1" Margin="10,0,0,0" VerticalAlignment="Center">
      <TextBlock x:Name="T" FontSize="12.5" Foreground="{StaticResource TextBrush}" TextTrimming="CharacterEllipsis"/>
      <TextBlock x:Name="D" Style="{StaticResource Caption}"/>
    </StackPanel>
  </Grid>
</Button>
'@

$ChoiceXaml = @'
<Button Style="{StaticResource CardButton}">
  <Grid>
    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
    <Grid Width="18" Height="18" VerticalAlignment="Center">
      <Ellipse x:Name="Ring" Stroke="{StaticResource SubBrush}" StrokeThickness="1.5"/>
      <Ellipse x:Name="Dot" Width="8" Height="8" Fill="{StaticResource AccentBrush}" Visibility="Collapsed"/>
    </Grid>
    <StackPanel Grid.Column="1" Margin="12,0,0,0" VerticalAlignment="Center">
      <TextBlock x:Name="T" Style="{StaticResource Body}"/>
      <TextBlock x:Name="D" Style="{StaticResource Caption}"/>
    </StackPanel>
  </Grid>
</Button>
'@

function Show-Error([string]$Text) {
    $ui.BannerText.Text = $Text
    $ui.Banner.Visibility = 'Visible'
    $script:bannerUntil = (Get-Date).AddSeconds(8)
    Write-ManagerLog "ERROR: $Text"
}

function Invoke-Safe([scriptblock]$Block) {
    try { & $Block } catch { Show-Error $_.Exception.Message }
}

# --- Acciones en segundo plano (no bloquean el panel) ---

$tools  = @(Get-Tools)
$busy   = @{}   # id -> acción en curso (proceso + archivo de progreso)
$errors = @{}   # id -> último error

function Start-Action($Tool, [string]$Action) {
    if ($busy.ContainsKey($Tool.id)) { return }
    $errors.Remove($Tool.id)
    $busy[$Tool.id] = Start-ToolAction $Tool $Action
    Update-Page
}

function Get-BusyText($id) {
    $b = $busy[$id]
    $text = if (Test-Path $b.StatusFile) { (Get-Content $b.StatusFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue) }
    if ($text) { $text.Trim() } else { 'Un momento...' }
}

function Update-Busy {
    $changed = $false
    foreach ($id in @($busy.Keys)) {
        $b = $busy[$id]
        if ($b.Process.HasExited) {
            $text = Get-BusyText $id
            $code = $b.Process.ExitCode
            $isUpdate = $b.Action -in 'update', 'autoupdate'
            if ($code -ne 0 -and -not $isUpdate) { $errors[$id] = $text -replace '^ERROR:\s*', '' }
            Remove-Item $b.StatusFile -ErrorAction SilentlyContinue
            $busy.Remove($id)
            $changed = $true
            Update-Hotkeys
            if ($isUpdate) { Complete-AppUpdate $id $b.Action $code $text }
        }
    }
    $changed
}

# --- Páginas ---

$script:page = 'home'
$script:HomeSignatures = @{}
$script:PageSignature = $null
$script:settingsSignature = $null

function Set-Page($Element, [string]$Title, [bool]$Back) {
    $ui.Page.Content = $Element
    $ui.HeaderTitle.Text = $Title
    $ui.BackButton.Visibility = if ($Back) { 'Visible' } else { 'Collapsed' }
    $ui.Logo.Visibility = if ($Back) { 'Collapsed' } else { 'Visible' }
    $ui.ViewButton.Visibility = if ($Back) { 'Collapsed' } else { 'Visible' }
}

function Update-Page {
    switch -Wildcard ($script:page) {
        'home'     { Show-Home }
        'settings' { Show-SettingsPage }
        'tool:*'   { Show-ToolPage ($script:page.Substring(5)) }
        'log:*'    { Show-LogPage ($script:page.Substring(4)) }
        'order'    { Show-OrderPage }
    }
}

function Get-StatusText($Tool, [string]$State) {
    if ($busy.ContainsKey($Tool.id)) { return @((Get-BusyText $Tool.id), 'SubBrush') }
    if ($errors.ContainsKey($Tool.id)) { return @($errors[$Tool.id], 'DangerBrush') }
    if ($State -eq 'Disabled') { return @('Desactivada', 'SubBrush') }
    if (-not $Tool.process) { return @('Activa', 'OkBrush') }
    if (Get-ToolProcess $Tool) { @('Activa · en marcha', 'OkBrush') } else { @('Activa · no está en marcha', 'WarnBrush') }
}

# Firma de la página de inicio: si no cambia, no se repinta
function Get-HomeSignature {
    # Una sola consulta de procesos para todas las herramientas (una por herramienta tardaba medio segundo)
    $cmds = if ($tools | Where-Object process) {
        @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -Property CommandLine | ForEach-Object CommandLine)
    }
    (($tools | ForEach-Object {
        $busyText = if ($busy.ContainsKey($_.id)) { Get-BusyText $_.id }
        $own = if ($script:HomeSignatures.ContainsKey($_.id)) { & $script:HomeSignatures[$_.id] }
        $running = if ($_.process) { $p = $_.process; [bool]($cmds | Where-Object { $_ -match $p }) }
        "$($_.id)=$(Get-ToolState $_)|$busyText|$($errors[$_.id])|$running|$own"
    }) -join ';') + "|upd=$(Get-UpdatesSignature)"
}

# Firma de la página de una herramienta: su estado + lo que diga su settings.ps1
function Get-ToolPageSignature {
    $t = $tools | Where-Object id -eq $script:page.Substring(5)
    $busyText = if ($busy.ContainsKey($t.id)) { Get-BusyText $t.id }
    $own = if ($script:settingsSignature) { & $script:settingsSignature }
    $upd = if ($t.HasUpdates) { Get-UpdatesSignature $t.id }
    "$(Get-ToolState $t)|$busyText|$($errors[$t.id])|$(if ($t.process) { [bool](Get-ToolProcess $t) })|$own|$upd"
}

# Preferencias del gestor en data\manager.json: las de la portada (vista lista/cuadrícula, grupos plegados y
# orden), «Actualizar automáticamente» de PC Toolkit ('pctoolkit') y de cada herramienta con app (id -> bool)
# y la última versión de PC Toolkit que se abrió (para avisar de que se ha actualizado)
$PrefsFile = Join-Path (Get-ToolkitRoot) 'data\manager.json'

function Get-HomePrefs {
    $p = @{ View = 'list'; Collapsed = @{}; Order = @(); AutoUpdate = @{}; LastVersion = '' }
    if (Test-Path $PrefsFile) {
        try {
            $j = Get-Content $PrefsFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($j.View -in 'list', 'grid') { $p.View = $j.View }
            if ($j.Collapsed) { foreach ($c in $j.Collapsed.PSObject.Properties) { $p.Collapsed[$c.Name] = [bool]$c.Value } }
            if ($j.Order) { $p.Order = @($j.Order | ForEach-Object { [string]$_ }) }
            if ($j.AutoUpdate) { foreach ($c in $j.AutoUpdate.PSObject.Properties) { $p.AutoUpdate[$c.Name] = [bool]$c.Value } }
            if ($j.LastVersion) { $p.LastVersion = [string]$j.LastVersion }
        } catch {}
    }
    $p
}

function Save-HomePrefs {
    New-Item -ItemType Directory -Force -Path (Split-Path $PrefsFile) | Out-Null
    $script:prefs | ConvertTo-Json | Set-Content $PrefsFile -Encoding UTF8
}

$script:prefs = Get-HomePrefs

# Orden de las herramientas: el guardado por el usuario; las que no estén en él (o todas, si no hay
# orden guardado) van detrás por orden alfabético del nombre visible
function Update-ToolOrder {
    $order = @($script:prefs.Order)
    $script:tools = @($script:tools | Sort-Object @{ Expression = { $i = [array]::IndexOf($order, $_.id); if ($i -ge 0) { $i } else { [int]::MaxValue } } }, name)
}

function Move-Tool([string]$Id, [int]$Delta) {
    $ids = @($script:tools | ForEach-Object id)
    $i = [array]::IndexOf($ids, $Id)
    $j = $i + $Delta
    if ($i -lt 0 -or $j -lt 0 -or $j -ge $ids.Count) { return }
    $ids[$i], $ids[$j] = $ids[$j], $ids[$i]
    $script:prefs.Order = $ids
    Save-HomePrefs
    Update-ToolOrder
    Show-OrderPage
}

function Reset-ToolOrder {
    $script:prefs.Order = @()
    Save-HomePrefs
    Update-ToolOrder
    Show-OrderPage
}

Update-ToolOrder

function Switch-HomeView {
    $script:prefs.View = if ($script:prefs.View -eq 'grid') { 'list' } else { 'grid' }
    Save-HomePrefs
    Show-Home
}

# Si un grupo está plegado: lo que eligió el usuario; si nunca lo tocó, «Disponibles» empieza plegado
function Test-GroupCollapsed([string]$Key) {
    if ($script:prefs.Collapsed.ContainsKey($Key)) { [bool]$script:prefs.Collapsed[$Key] } else { $Key -eq 'available' }
}

# Título de grupo plegable: flecha + nombre + número de herramientas
function New-GroupHeader([string]$Key, [string]$Title, [int]$Count) {
    $collapsed = Test-GroupCollapsed $Key
    $h = New-Ui $GroupHeaderXaml
    $h.FindName('Chevron').Text = if ($collapsed) { [string][char]0xE76C } else { [string][char]0xE70D }
    $h.FindName('Title').Text = $Title
    $h.FindName('Count').Text = "$Count"
    $h.Tag = $Key
    [Windows.Automation.AutomationProperties]::SetName($h, "$Title ($Count), $(if ($collapsed) { 'plegado' } else { 'desplegado' })")
    $h.Add_Click({
        param($s, $e)
        $script:prefs.Collapsed[$s.Tag] = -not (Test-GroupCollapsed $s.Tag)
        Save-HomePrefs
        Show-Home
    })
    $h
}

$GroupHeaderXaml = @'
<Button Style="{StaticResource SubtleButton}" HorizontalContentAlignment="Stretch" Padding="6,5" Margin="-2,10,0,4">
  <StackPanel Orientation="Horizontal">
    <TextBlock x:Name="Chevron" Style="{StaticResource Icon}" FontSize="10" Width="14" Foreground="{StaticResource SubBrush}"/>
    <TextBlock x:Name="Title" FontSize="13" FontWeight="SemiBold" Margin="6,0,0,0" VerticalAlignment="Center"/>
    <Border Background="{StaticResource CardBrush}" CornerRadius="8" Padding="7,0" Margin="8,0,0,0" VerticalAlignment="Center">
      <TextBlock x:Name="Count" Style="{StaticResource Caption}"/>
    </Border>
  </StackPanel>
</Button>
'@

# Descripción corta para la portada ("summary" de tool.json; si falta, el principio de la larga)
function Get-ToolSummary($Tool) {
    if ($Tool.summary) { $Tool.summary } else { ($Tool.description -split '[.;,(]')[0] }
}

# Interruptor de activar/desactivar común a la tarjeta y al mosaico
function Connect-ToolToggle($Toggle, $Tool, [string]$State) {
    $Toggle.IsChecked = $State -eq 'Enabled'
    [Windows.Automation.AutomationProperties]::SetName($Toggle, "Activar $($Tool.name)")
    $Toggle.Tag = $Tool
    $onToggle = { param($s, $e) Start-Action $s.Tag $(if ($s.IsChecked) { 'enable' } else { 'disable' }) }
    $Toggle.Add_Checked($onToggle)
    $Toggle.Add_Unchecked($onToggle)
    if ($busy.ContainsKey($Tool.id)) { $Toggle.IsEnabled = $false }
}

# Al pulsar la tarjeta/mosaico se abre su página (solo clics en ella misma: los de dentro burbujean)
function Connect-ToolOpen($Card, $Tool) {
    $Card.Tag = $Tool
    [Windows.Automation.AutomationProperties]::SetName($Card, $Tool.name)
    $Card.Add_Click({ param($s, $e) if ($e.OriginalSource -eq $s) { Show-ToolPage $s.Tag.id } })
}

# Botón Instalar común; mientras instala se cambia por barra de progreso + texto, y si falla, el error
function Connect-ToolInstall($Card, $Tool) {
    $btn = $Card.FindName('Install')
    $btn.Tag = $Tool
    [Windows.Automation.AutomationProperties]::SetName($btn, "Instalar $($Tool.name)")
    $btn.Add_Click({ param($s, $e) Start-Action $s.Tag 'install' })
    if ($busy.ContainsKey($Tool.id)) {
        $btn.Visibility = 'Collapsed'
        $p = New-Ui '<StackPanel/>'
        [void]$p.Children.Add((New-ProgressBar))
        $h = New-Hint (Get-BusyText $Tool.id); $h.Margin = '0,6,0,0'
        [void]$p.Children.Add($h)
        $Card.FindName('Extra').Content = $p
    } elseif ($errors.ContainsKey($Tool.id)) {
        $h = New-Hint $errors[$Tool.id]; $h.Margin = '0,8,0,0'; $h.Foreground = $app.Resources['DangerBrush']
        $Card.FindName('Extra').Content = $h
    }
}

# Bloque home.ps1 de la herramienta (p. ej. el selector de audio), o $null si no tiene o falla
function Get-ToolHomeBlock($Tool) {
    if (-not $Tool.HasHome -or $busy.ContainsKey($Tool.id)) { return }
    try {
        $extra = & { param($path) . $path } (Join-Path $Tool.Dir 'home.ps1')
        @($extra | Where-Object { $_ -is [Windows.UIElement] })[0]
    } catch { Write-ManagerLog "ERROR home.ps1 de $($Tool.id): $($_.Exception.Message)" }
}

# --- Vista de lista: tarjetas anchas con descripción y el bloque home.ps1 de la herramienta ---

function New-InstalledCard($Tool, [string]$State) {
    $card = New-Ui @'
<Button Style="{StaticResource CardButton}">
  <StackPanel>
    <Grid>
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <TextBlock x:Name="Icon" Style="{StaticResource ToolIcon}"/>
      <StackPanel Grid.Column="1" Margin="12,0" VerticalAlignment="Center">
        <TextBlock x:Name="Name" Style="{StaticResource Title}"/>
        <TextBlock x:Name="Status" Style="{StaticResource Caption}"/>
        <TextBlock x:Name="UpdateNote" Style="{StaticResource Caption}" Foreground="{StaticResource AccentBrush}" Visibility="Collapsed"/>
      </StackPanel>
      <CheckBox x:Name="Toggle" Grid.Column="2" Style="{StaticResource Toggle}"/>
      <TextBlock Grid.Column="3" Style="{StaticResource Icon}" Text="&#xE76C;" FontSize="12" Margin="14,0,0,0" Foreground="{StaticResource SubBrush}"/>
    </Grid>
    <ContentControl x:Name="Extra" Focusable="False"/>
  </StackPanel>
</Button>
'@
    $card.FindName('Icon').Text = ConvertTo-Glyph $Tool.icon
    $card.FindName('Name').Text = $Tool.name
    $status = Get-StatusText $Tool $State
    $card.FindName('Status').Text = $status[0]
    $card.FindName('Status').Foreground = $app.Resources[$status[1]]
    Set-UpdateNote $card.FindName('UpdateNote') $Tool
    Connect-ToolToggle $card.FindName('Toggle') $Tool $State
    if ($busy.ContainsKey($Tool.id)) { $card.FindName('Extra').Content = New-ProgressBar }
    else { $card.FindName('Extra').Content = Get-ToolHomeBlock $Tool }
    Connect-ToolOpen $card $Tool
    $card
}

function New-AvailableCard($Tool) {
    $card = New-Ui @'
<Button Style="{StaticResource CardButton}">
  <StackPanel>
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <TextBlock x:Name="Icon" Style="{StaticResource ToolIcon}"/>
      <StackPanel Grid.Column="1" Margin="12,0" VerticalAlignment="Center">
        <TextBlock x:Name="Name" Style="{StaticResource Title}"/>
        <TextBlock x:Name="Desc" Style="{StaticResource Caption}" TextWrapping="NoWrap" TextTrimming="CharacterEllipsis"/>
      </StackPanel>
      <Button x:Name="Install" Grid.Column="2" Style="{StaticResource AccentButton}" Content="Instalar" VerticalAlignment="Center"/>
    </Grid>
    <ContentControl x:Name="Extra" Focusable="False"/>
  </StackPanel>
</Button>
'@
    $card.FindName('Icon').Text = ConvertTo-Glyph $Tool.icon
    $card.FindName('Name').Text = $Tool.name
    $card.FindName('Desc').Text = Get-ToolSummary $Tool
    Connect-ToolInstall $card $Tool
    Connect-ToolOpen $card $Tool
    $card
}

# --- Vista de cuadrícula: mosaicos compactos de 2 en 2 ---

function New-InstalledTile($Tool, [string]$State) {
    $tile = New-Ui @'
<Button Style="{StaticResource CardButton}" Margin="0,0,4,4" Padding="12,10" VerticalContentAlignment="Stretch">
  <StackPanel>
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <TextBlock x:Name="Icon" Style="{StaticResource ToolIcon}" HorizontalAlignment="Left" TextAlignment="Left"/>
      <CheckBox x:Name="Toggle" Grid.Column="1" Style="{StaticResource Toggle}"/>
    </Grid>
    <TextBlock x:Name="Name" Style="{StaticResource Title}" Margin="0,12,0,0"/>
    <TextBlock x:Name="Status" Style="{StaticResource Caption}" TextWrapping="NoWrap" TextTrimming="CharacterEllipsis"/>
    <TextBlock x:Name="UpdateNote" Style="{StaticResource Caption}" Foreground="{StaticResource AccentBrush}" Visibility="Collapsed"
               TextWrapping="NoWrap" TextTrimming="CharacterEllipsis"/>
    <ContentControl x:Name="Extra" Focusable="False"/>
  </StackPanel>
</Button>
'@
    $tile.FindName('Icon').Text = ConvertTo-Glyph $Tool.icon
    $tile.FindName('Name').Text = $Tool.name
    $status = Get-StatusText $Tool $State
    $tile.FindName('Status').Text = $status[0] -replace ' · en marcha$', ''   # en el mosaico, corto
    $tile.FindName('Status').Foreground = $app.Resources[$status[1]]
    Set-UpdateNote $tile.FindName('UpdateNote') $Tool -Short
    Connect-ToolToggle $tile.FindName('Toggle') $Tool $State
    if ($busy.ContainsKey($Tool.id)) { $tile.FindName('Extra').Content = New-ProgressBar }
    else {
        # En el mosaico, el bloque de portada (selector de audio...) ocupa todo el ancho, sin sangría
        $block = Get-ToolHomeBlock $Tool
        if ($block) { $block.Margin = '-8,6,-8,-4'; $tile.FindName('Extra').Content = $block }
    }
    Connect-ToolOpen $tile $Tool
    $tile
}

function New-AvailableTile($Tool) {
    $tile = New-Ui @'
<Button Style="{StaticResource CardButton}" Margin="0,0,4,4" Padding="12,10" VerticalContentAlignment="Stretch">
  <StackPanel>
    <TextBlock x:Name="Icon" Style="{StaticResource ToolIcon}" HorizontalAlignment="Left" TextAlignment="Left"/>
    <TextBlock x:Name="Name" Style="{StaticResource Title}" Margin="0,12,0,0"/>
    <TextBlock x:Name="Desc" Style="{StaticResource Caption}" TextWrapping="NoWrap" TextTrimming="CharacterEllipsis" Margin="0,0,0,8"/>
    <Button x:Name="Install" Style="{StaticResource AccentButton}" Content="Instalar" HorizontalAlignment="Left" Padding="12,4"/>
    <ContentControl x:Name="Extra" Focusable="False"/>
  </StackPanel>
</Button>
'@
    $tile.FindName('Icon').Text = ConvertTo-Glyph $Tool.icon
    $tile.FindName('Name').Text = $Tool.name
    $tile.FindName('Desc').Text = Get-ToolSummary $Tool
    Connect-ToolInstall $tile $Tool
    Connect-ToolOpen $tile $Tool
    $tile
}

# Orden de los temas en la portada; uno que no esté aquí va al final
$CategoryOrder = @('Sonido', 'Escritorio', 'Juegos', 'Apps', 'Otras')

function Show-Home {
    $script:page = 'home'
    $script:PageSignature = { Get-HomeSignature }
    $grid = $script:prefs.View -eq 'grid'
    $panel = New-Ui '<StackPanel/>'
    $toolkitCard = New-ToolkitUpdateCard   # solo si hay versión nueva de PC Toolkit
    if ($toolkitCard) { [void]$panel.Children.Add($toolkitCard) }
    $states = @{}
    foreach ($t in $tools) { $states[$t.id] = Get-ToolState $t }
    # Las instaladas, por temas ("category" de tool.json) cuando hay más de uno; cada grupo se pliega
    $installed = @($tools | Where-Object { $states[$_.id] -ne 'NotInstalled' })
    $cats = @($installed | ForEach-Object { if ($_.category) { $_.category } else { 'Otras' } } | Select-Object -Unique)
    $groups = @()
    if ($cats.Count -le 1) {
        $groups += @{ Key = 'installed'; Title = 'Instaladas'; Items = $installed }
    } else {
        $known = @($CategoryOrder | Where-Object { $_ -in $cats }) + @($cats | Where-Object { $_ -notin $CategoryOrder })
        foreach ($c in $known) {
            $groups += @{ Key = "cat:$c"; Title = $c; Items = @($installed | Where-Object { $(if ($_.category) { $_.category } else { 'Otras' }) -eq $c }) }
        }
    }
    $groups += @{ Key = 'available'; Title = 'Disponibles'; Items = @($tools | Where-Object { $states[$_.id] -eq 'NotInstalled' }) }
    foreach ($g in $groups) {
        if ($g.Key -eq 'available' -and -not $g.Items) { continue }
        [void]$panel.Children.Add((New-GroupHeader $g.Key $g.Title $g.Items.Count))
        if (Test-GroupCollapsed $g.Key) { continue }
        if (-not $g.Items) { [void]$panel.Children.Add((New-Hint 'No hay herramientas instaladas.')); continue }
        $container = if ($grid) { New-Ui '<UniformGrid Columns="2" Margin="0,0,-4,0"/>' } else { $panel }
        foreach ($t in $g.Items) {
            $item = if ($g.Key -ne 'available') {
                if ($grid) { New-InstalledTile $t $states[$t.id] } else { New-InstalledCard $t $states[$t.id] }
            } else {
                if ($grid) { New-AvailableTile $t } else { New-AvailableCard $t }
            }
            [void]$container.Children.Add($item)
        }
        if ($grid) { [void]$panel.Children.Add($container) }
    }
    Set-Page $panel 'PC Toolkit' $false
    $script:homeReady = $true
    # El botón de vista muestra la vista a la que se cambia
    $ui.ViewButton.Content = if ($grid) { [string][char]0xE8FD } else { [string][char]0xF0E2 }
    [Windows.Automation.AutomationProperties]::SetName($ui.ViewButton, $(if ($grid) { 'Ver como lista' } else { 'Ver como cuadrícula' }))
    $script:lastSignature = Get-HomeSignature
}

$NotInstalledCardXaml = @'
<Border Style="{StaticResource Card}">
  <StackPanel>
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <StackPanel VerticalAlignment="Center" Margin="0,0,12,0">
        <TextBlock Style="{StaticResource Body}" Text="No instalada"/>
        <TextBlock x:Name="Note" Style="{StaticResource Caption}" Text="Se instala para el usuario actual, sin permisos de administrador."/>
      </StackPanel>
      <Button x:Name="Install" Grid.Column="1" Style="{StaticResource AccentButton}" Content="Instalar" VerticalAlignment="Center"/>
    </Grid>
    <ContentControl x:Name="Extra" Focusable="False"/>
  </StackPanel>
</Border>
'@

function Show-ToolPage([string]$Id) {
    $t = $tools | Where-Object id -eq $Id
    $state = Get-ToolState $t
    $first = $script:page -ne "tool:$Id"
    $script:page = "tool:$Id"
    $script:PageSignature = $null

    $panel = New-Ui '<StackPanel/>'
    $desc = New-Hint $t.description
    $desc.Margin = '4,4,0,12'
    [void]$panel.Children.Add($desc)

    # Sin instalar: solo la descripción completa y el botón de instalar
    if ($state -eq 'NotInstalled') {
        $card = New-Ui $NotInstalledCardXaml
        if ($t.installNote) { $card.FindName('Note').Text = $t.installNote }   # p. ej., si instala un programa aparte
        Connect-ToolInstall $card $t
        [void]$panel.Children.Add($card)
        $script:settingsSignature = $null
        $script:PageSignature = { Get-ToolPageSignature }
        $script:lastSignature = Get-ToolPageSignature
        Set-Page $panel $t.name $true
        if ($first) { $ui.Scroll.ScrollToTop() }
        return
    }

    $status = Get-StatusText $t $state
    $row = New-ToggleRow 'Activada' $status[0] ($state -eq 'Enabled') { param($tool, $on) Start-Action $tool $(if ($on) { 'enable' } else { 'disable' }) } $t
    $row.FindName('D').Foreground = $app.Resources[$status[1]]
    [void]$panel.Children.Add($row)
    if ($busy.ContainsKey($Id)) {
        $row.FindName('Toggle').IsEnabled = $false
        $bar = New-ProgressBar
        $bar.Margin = '4,0,4,8'
        [void]$panel.Children.Add($bar)
    }

    # Ajustes propios de la herramienta
    if ($t.HasSettings -and $state -ne 'NotInstalled') {
        # En un bloque propio para que sus variables no pisen las de aquí ($script: sigue siendo el gestor)
        $settings = & { param($path) . $path } (Join-Path $t.Dir 'settings.ps1')
        foreach ($el in @($settings)) { if ($el -is [Windows.UIElement]) { [void]$panel.Children.Add($el) } }
    }
    if ($t.hotkey -and $state -ne 'NotInstalled') { [void]$panel.Children.Add((New-HotkeySection $t)) }
    if ($t.HasUpdates) { [void]$panel.Children.Add((New-UpdateSection $t)) }
    $script:settingsSignature = $script:PageSignature
    $script:PageSignature = { Get-ToolPageSignature }
    $script:lastSignature = Get-ToolPageSignature

    # Acciones
    $actions = New-Ui '<StackPanel Orientation="Horizontal" Margin="0,12,0,0"/>'
    if ($t.log) {
        $btnLog = New-Ui '<Button Style="{StaticResource SubtleButton}" Content="Ver registro"/>'
        $btnLog.Tag = $Id
        $btnLog.Add_Click({ param($s, $e) Show-LogPage $s.Tag })
        [void]$actions.Children.Add($btnLog)
    }
    $btnUninstall = New-Ui '<Button Style="{StaticResource DangerButton}" Content="Desinstalar"/>'
    $btnUninstall.Tag = $t
    $btnUninstall.IsEnabled = -not $busy.ContainsKey($Id)
    $btnUninstall.Add_Click({
        param($s, $e)
        if ($s.Content -eq 'Desinstalar') { $s.Content = 'Pulsa otra vez para confirmar'; return }
        Start-Action $s.Tag 'uninstall'
        Show-Home
    })
    [void]$actions.Children.Add($btnUninstall)
    [void]$panel.Children.Add($actions)

    Set-Page $panel $t.name $true
    if ($first) { $ui.Scroll.ScrollToTop() }
}

function Show-LogPage([string]$Id) {
    $t = $tools | Where-Object id -eq $Id
    $script:page = "log:$Id"
    $script:PageSignature = $null
    $log = Get-ToolLog $t
    $lines = if ($log -and (Test-Path $log)) { @(Get-Content $log -Tail 200 -Encoding UTF8) } else { @() }
    [array]::Reverse($lines)   # lo más reciente arriba
    $card = New-Ui @'
<Border Style="{StaticResource Card}" Margin="0,8,0,0">
  <TextBlock x:Name="Text" FontFamily="Cascadia Mono, Consolas" FontSize="11.5" TextWrapping="Wrap" Foreground="{StaticResource TextBrush}"/>
</Border>
'@
    $card.FindName('Text').Text = if ($lines) { $lines -join "`n" } else { 'Todavía no hay actividad.' }
    Set-Page $card "Registro · $($t.name)" $true
    $ui.Scroll.ScrollToTop()
}

function Show-OrderPage {
    $script:page = 'order'
    $script:PageSignature = $null
    $panel = New-Ui '<StackPanel/>'
    $hint = New-Hint 'Usa las flechas para cambiar la posición de cada herramienta en la portada.'
    $hint.Margin = '4,4,0,12'
    [void]$panel.Children.Add($hint)
    for ($i = 0; $i -lt $tools.Count; $i++) {
        $t = $tools[$i]
        $row = New-Ui @'
<Border Style="{StaticResource Card}" Padding="14,6,6,6">
  <Grid>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/>
    </Grid.ColumnDefinitions>
    <TextBlock x:Name="Icon" Style="{StaticResource ToolIcon}"/>
    <StackPanel Grid.Column="1" Margin="12,0" VerticalAlignment="Center">
      <TextBlock x:Name="Name" Style="{StaticResource Body}"/>
      <TextBlock x:Name="State" Style="{StaticResource Caption}"/>
    </StackPanel>
    <Button x:Name="Up" Grid.Column="2" Style="{StaticResource IconButton}" Content="&#xE70E;" FontSize="12"/>
    <Button x:Name="Down" Grid.Column="3" Style="{StaticResource IconButton}" Content="&#xE70D;" FontSize="12"/>
  </Grid>
</Border>
'@
        $row.FindName('Icon').Text = ConvertTo-Glyph $t.icon
        $row.FindName('Name').Text = $t.name
        $row.FindName('State').Text = if ((Get-ToolState $t) -eq 'NotInstalled') { 'No instalada' } else { 'Instalada' }
        foreach ($b in @(@('Up', -1, 'Subir'), @('Down', 1, 'Bajar'))) {
            $btn = $row.FindName($b[0])
            $btn.Tag = @($t.id, $b[1])
            $btn.IsEnabled = ($b[1] -lt 0 -and $i -gt 0) -or ($b[1] -gt 0 -and $i -lt $tools.Count - 1)
            [Windows.Automation.AutomationProperties]::SetName($btn, "$($b[2]) $($t.name)")
            $btn.Add_Click({ param($s, $e) Invoke-Safe { Move-Tool $s.Tag[0] $s.Tag[1] } })
        }
        [void]$panel.Children.Add($row)
    }
    $reset = New-Ui '<Button Style="{StaticResource SubtleButton}" Content="Restablecer orden alfabético" HorizontalAlignment="Left" Margin="0,8,0,0"/>'
    $reset.IsEnabled = @($script:prefs.Order).Count -gt 0
    $reset.Add_Click({ Invoke-Safe { Reset-ToolOrder } })
    [void]$panel.Children.Add($reset)
    Set-Page $panel 'Orden de las herramientas' $true
}

function Show-SettingsPage {
    $first = $script:page -ne 'settings'
    $script:page = 'settings'
    $script:PageSignature = $null
    $panel = New-Ui '<StackPanel/>'
    [void]$panel.Children.Add((New-SectionHeader 'General'))
    [void]$panel.Children.Add((New-ToggleRow 'Iniciar con Windows' 'Inicia PC Toolkit en la bandeja del sistema al iniciar sesión.' (Test-ManagerAutostart) { param($a, $on) Set-ManagerAutostart $on } $null))

    [void]$panel.Children.Add((New-SectionHeader 'Portada'))
    $orderRow = New-Ui @'
<Button Style="{StaticResource CardButton}" AutomationProperties.Name="Orden de las herramientas">
  <Grid>
    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
    <StackPanel VerticalAlignment="Center">
      <TextBlock Style="{StaticResource Body}" Text="Orden de las herramientas"/>
      <TextBlock Style="{StaticResource Caption}" Text="Elige en qué orden aparecen en la portada."/>
    </StackPanel>
    <TextBlock Grid.Column="1" Style="{StaticResource Icon}" Text="&#xE76C;" FontSize="12" Foreground="{StaticResource SubBrush}"/>
  </Grid>
</Button>
'@
    $orderRow.Add_Click({ Show-OrderPage })
    [void]$panel.Children.Add($orderRow)

    $apps = @($tools | Where-Object HasUpdates | ForEach-Object name) -join ', '
    [void]$panel.Children.Add((New-SectionHeader 'Actualizaciones' "PC Toolkit y las apps que instalan sus herramientas ($apps) se revisan al arrancar y cada 6 horas."))
    [void]$panel.Children.Add((New-UpdatesCard))
    [void]$panel.Children.Add((New-ToggleRow 'Actualizar PC Toolkit automáticamente' 'Instala sola la versión nueva, con el panel cerrado, y avisa al volver a la bandeja.' (Test-AutoUpdate 'pctoolkit') { param($id, $on) Set-AutoUpdate $id $on } 'pctoolkit'))
    $hint = New-Hint 'Cada app tiene su propio «Actualizar automáticamente» en la página de su herramienta.'
    $hint.Margin = '4,4,0,8'
    [void]$panel.Children.Add($hint)

    [void]$panel.Children.Add((New-SectionHeader 'Más'))
    $more = New-Ui '<StackPanel Orientation="Horizontal"/>'
    $btnFolder = New-Ui '<Button Style="{StaticResource SubtleButton}" Content="Abrir carpeta"/>'
    $btnFolder.Add_Click({ Start-Process explorer.exe (Get-ToolkitRoot) })
    $btnRepo = New-Ui '<Button Style="{StaticResource SubtleButton}" Content="GitHub"/>'
    $btnRepo.Add_Click({ Start-Process 'https://github.com/ikerlorente11/pc-toolkit' })
    $btnExit = New-Ui '<Button Style="{StaticResource DangerButton}" Content="Salir"/>'
    $btnExit.Add_Click({ Exit-Manager })
    foreach ($b in $btnFolder, $btnRepo, $btnExit) { [void]$more.Children.Add($b) }
    [void]$panel.Children.Add($more)

    # Se repinta sola mientras busca o actualiza (y al terminar)
    $script:PageSignature = { Get-UpdatesSignature }
    $script:lastSignature = Get-UpdatesSignature
    Set-Page $panel 'Ajustes' $true
    if ($first) { $ui.Scroll.ScrollToTop() }
}

# --- Actualizaciones: PC Toolkit y las apps de las herramientas con "updates" en tool.json (update.ps1) ---
# core\update-check.ps1 consulta las últimas versiones en otro proceso (al arrancar, cada 6 h y con «Buscar
# actualizaciones») y el resultado se guarda en data\updates.json, así que repintar no vuelve a preguntar a GitHub.
# Con «Actualizar automáticamente» (data\manager.json) se instalan solas y se avisa al terminar; si la app está
# abierta no se cierra: se reintenta cada 30 min. Sin él, se marca en su tarjeta y en su página. Las que piden
# permisos de administrador (Everything) nunca se instalan solas: solo se avisa.

$UpdatesFile   = Join-Path (Get-ToolkitRoot) 'data\updates.json'
$CheckInterval = [TimeSpan]::FromHours(6)
$RetryDelay    = [TimeSpan]::FromMinutes(30)
$script:checkJob      = $null   # revisión en marcha: @{ Process; OutFile; Started }
$script:updatesRev    = 0       # sube con cada cambio (las firmas de las páginas lo incluyen para repintarse)
$script:updateRetry   = @{}     # id -> cuándo reintentar (su app estaba abierta)
$script:updateErrors  = @{}     # id -> error de su última actualización automática
$script:autoTried     = @{}     # id -> versión que ya falló en automático: no se insiste hasta la próxima revisión
$script:appInfo       = @{}     # id -> @{ At; Info }: versión instalada, en uso... (se guarda unos segundos)
$script:toolkitQueued = $null   # 'auto' o 'manual': actualizar PC Toolkit cuando acaben las demás actualizaciones
$script:toolkitUpdating = $null # cuándo se lanzó la actualización de PC Toolkit (el instalador cierra el gestor)

function Get-UpdateCache {
    $c = @{ Checked = $null; Items = @{} }
    if (Test-Path $UpdatesFile) {
        try {
            $j = Get-Content $UpdatesFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($j.Checked) { $c.Checked = [datetime]$j.Checked }
            foreach ($p in $j.Items.PSObject.Properties) { $c.Items[$p.Name] = @{ Latest = [string]$p.Value.Latest; Error = [string]$p.Value.Error } }
        } catch {}
    }
    $c
}

function Save-UpdateCache {
    New-Item -ItemType Directory -Force -Path (Split-Path $UpdatesFile) | Out-Null
    @{ Checked = $script:updates.Checked.ToString('o'); Items = $script:updates.Items } | ConvertTo-Json -Depth 4 | Set-Content $UpdatesFile -Encoding UTF8
}

$script:updates = Get-UpdateCache

function Test-AutoUpdate([string]$Id) { [bool]$script:prefs.AutoUpdate[$Id] }

function Set-AutoUpdate([string]$Id, [bool]$On) {
    $script:prefs.AutoUpdate[$Id] = $On
    Save-HomePrefs
    $script:autoTried.Remove($Id)
    $script:updateErrors.Remove($Id)
    $script:updateRetry.Remove($Id)
    $script:updatesRev++
    if ($On) { Invoke-AutoUpdates }   # si ya se sabe que hay versión nueva, no espera a la próxima revisión
}

# Herramientas instaladas cuya app se actualiza desde aquí
function Get-UpdatableTools { @($tools | Where-Object { $_.HasUpdates -and (Get-ToolState $_) -ne 'NotInstalled' }) }

# Versión instalada, si está abierta y si actualizarla pide administrador (update.ps1 -Action info), guardado
# unos segundos: las firmas de las páginas lo piden a menudo
function Get-AppInfo($Tool, [switch]$Fresh) {
    $c = $script:appInfo[$Tool.id]
    if (-not $Fresh -and $c -and ((Get-Date) - $c.At).TotalSeconds -lt 15) { return $c.Info }
    $info = try { Get-ToolAppInfo $Tool } catch {
        Write-ManagerLog "ERROR update.ps1 de $($Tool.id): $($_.Exception.Message)"
        [pscustomobject]@{ Installed = $null; InUse = $false; Elevated = $false }
    }
    $script:appInfo[$Tool.id] = @{ At = Get-Date; Info = $info }
    $info
}

# Estado de actualización de PC Toolkit ('pctoolkit') o de la app de una herramienta. La última versión es la
# de la última revisión; la instalada se mira en el momento (así, al actualizar, la marca desaparece sola).
function Get-UpdateState([string]$Id) {
    if ($Id -eq 'pctoolkit') {
        $tool = $null
        $info = [pscustomobject]@{ Installed = Get-ToolkitVersion; InUse = $false; Elevated = $false }
    } else {
        $tool = $tools | Where-Object id -eq $Id
        $info = Get-AppInfo $tool
    }
    $item = $script:updates.Items[$Id]
    $latest = if ($item) { $item.Latest }
    [pscustomobject]@{
        Id         = $Id
        Tool       = $tool
        Name       = if ($tool) { $tool.name } else { 'PC Toolkit' }
        Glyph      = if ($tool) { ConvertTo-Glyph $tool.icon } else { ConvertTo-Glyph 'E895' }
        Installed  = [string]$info.Installed
        Latest     = [string]$latest
        Available  = (Test-NewerVersion $latest $info.Installed)
        CheckError = $(if ($item) { [string]$item.Error })
        InUse      = [bool]$info.InUse
        Elevated   = [bool]$info.Elevated
    }
}

function Get-UpdateStates { @(Get-UpdateState 'pctoolkit') + @(Get-UpdatableTools | ForEach-Object { Get-UpdateState $_.id }) }

# Firma para repintar: de una herramienta ($Id) o de todo (portada y Ajustes)
function Get-UpdatesSignature([string]$Id) {
    $states = if ($Id) { @(Get-UpdateState $Id) } else { Get-UpdateStates }
    $s = ($states | ForEach-Object {
        $busyText = if ($busy.ContainsKey($_.Id)) { Get-BusyText $_.Id }
        "$($_.Id)=$($_.Installed)>$($_.Latest)|$($_.InUse)|$busyText|$($errors[$_.Id])|$($script:updateErrors[$_.Id])|$($script:updateRetry[$_.Id])"
    }) -join ';'
    "$($script:updatesRev)|$([bool]$script:checkJob)|$($script:toolkitQueued)|$([bool]$script:toolkitUpdating)|$s"
}

function Format-Ago([datetime]$When) {
    $m = ((Get-Date) - $When).TotalMinutes
    if ($m -lt 1) { 'hace un momento' }
    elseif ($m -lt 60) { "hace $([int][Math]::Floor($m)) min" }
    elseif ($m -lt 1440) { "hace $([int][Math]::Floor($m / 60)) h" }
    else { "el $($When.ToString('d/M')) a las $($When.ToString('HH:mm'))" }
}

# Icono de la bandeja: lo dice al pasar el ratón si hay algo por actualizar
function Update-TrayText {
    $n = @(Get-UpdateStates | Where-Object Available).Count
    $tray.Text = if ($n -eq 1) { 'PC Toolkit · 1 actualización disponible' }
                 elseif ($n -gt 1) { "PC Toolkit · $n actualizaciones disponibles" }
                 else { 'PC Toolkit' }
}

# Revisión en segundo plano (no espera a la red: el reloj recoge el resultado al terminar)
function Start-UpdateCheck {
    if ($script:checkJob) { return }
    $out = Join-Path $env:TEMP "pctoolkit-updates-$([guid]::NewGuid().ToString('N')).json"
    $psi = New-Object Diagnostics.ProcessStartInfo 'powershell.exe'
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $PSScriptRoot '..\core\update-check.ps1')`" -OutFile `"$out`""
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow  = $true
    $script:checkJob = @{ Process = [Diagnostics.Process]::Start($psi); OutFile = $out; Started = Get-Date }
    $script:nextCheckAt = (Get-Date) + $CheckInterval
    $script:updatesRev++
}

function Complete-UpdateCheck {
    $job = $script:checkJob
    $script:checkJob = $null
    $result = $null
    if (Test-Path $job.OutFile) {
        try { $result = Get-Content $job.OutFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
        Remove-Item $job.OutFile -ErrorAction SilentlyContinue
    }
    if ($result) {
        $items = @{}
        foreach ($p in $result.PSObject.Properties) {
            $latest = [string]$p.Value.Latest
            # si esta vez no se pudo consultar, se conserva la última versión conocida
            if (-not $latest -and $script:updates.Items[$p.Name]) { $latest = $script:updates.Items[$p.Name].Latest }
            $items[$p.Name] = @{ Latest = $latest; Error = [string]$p.Value.Error }
        }
        $script:updates = @{ Checked = Get-Date; Items = $items }
        Save-UpdateCache
        $script:autoTried = @{}
        $script:appInfo = @{}
        $found = @(Get-UpdateStates | Where-Object Available | ForEach-Object { "$($_.Name) $($_.Latest)" })
        Write-ManagerLog "Actualizaciones revisadas: $(if ($found) { $found -join ', ' } else { 'todo al día' })"
    } else {
        Write-ManagerLog 'ERROR: la revisión de actualizaciones no terminó bien'
    }
    $script:updatesRev++
    Invoke-AutoUpdates
    Update-TrayText
}

# Instala solas las versiones nuevas con «Actualizar automáticamente» (si la app está abierta, lo reintenta en
# 30 min). PC Toolkit va al final, cuando no queda nada actualizándose y con el panel cerrado (ver el reloj).
function Invoke-AutoUpdates {
    foreach ($t in Get-UpdatableTools) {
        if (-not (Test-AutoUpdate $t.id) -or $busy.ContainsKey($t.id) -or $script:updateRetry.ContainsKey($t.id)) { continue }
        $s = Get-UpdateState $t.id
        if (-not $s.Available -or $s.Elevated -or $script:autoTried[$t.id] -eq $s.Latest) { continue }
        if ((Get-AppInfo $t -Fresh).InUse) { Set-UpdateRetry $t; continue }
        Write-ManagerLog "Actualizando $($t.name) $($s.Installed) -> $($s.Latest) (automático)"
        Start-Action $t 'autoupdate'
    }
    $tk = Get-UpdateState 'pctoolkit'
    if ((Test-AutoUpdate 'pctoolkit') -and $tk.Available -and -not $script:toolkitQueued -and -not $script:toolkitUpdating -and
        $script:autoTried['pctoolkit'] -ne $tk.Latest) { $script:toolkitQueued = 'auto' }
}

function Set-UpdateRetry($Tool) {
    $script:updateRetry[$Tool.id] = (Get-Date) + $RetryDelay
    Write-ManagerLog "$($Tool.name): la app está abierta; se reintentará actualizarla a las $($script:updateRetry[$Tool.id].ToString('HH:mm'))"
    $script:updatesRev++
}

# Al terminar una actualización de app (Update-Busy). Estado: "OK <versión>", "EN USO" (código 2) o "ERROR: ..."
function Complete-AppUpdate([string]$Id, [string]$Action, [int]$Code, [string]$Text) {
    $t = $tools | Where-Object id -eq $Id
    $script:appInfo.Remove($Id)
    $script:updatesRev++
    if ($Code -eq 0) {
        $v = ($Text -replace '^OK\s*', '').Trim()
        $script:updateErrors.Remove($Id)
        $script:updateRetry.Remove($Id)
        Write-ManagerLog "$($t.name): app actualizada a $v$(if ($Action -eq 'autoupdate') { ' (automático)' })"
        if ($Action -eq 'autoupdate' -or -not $win.IsVisible) { Show-Osd (ConvertTo-Glyph $t.icon) "$($t.name) $v" 'Actualización instalada' -Seconds 6 }
    } else {
        $msg = $Text -replace '^ERROR:\s*', ''
        if ($Action -eq 'update') {
            $errors[$Id] = $msg
            Write-ManagerLog "ERROR al actualizar $($t.name): $msg"
        } elseif ($Code -eq 2 -or (Get-AppInfo $t -Fresh).InUse) {
            Set-UpdateRetry $t   # la abrieron justo antes o durante la descarga
        } else {
            # no se insiste con esta versión hasta la próxima revisión
            $script:updateErrors[$Id] = $msg
            $script:autoTried[$Id] = (Get-UpdateState $Id).Latest
            Write-ManagerLog "ERROR al actualizar $($t.name) (automático): $msg"
        }
    }
    Update-TrayText
}

# Botón Actualizar de una app (la cierra si está abierta: lo ha pedido el usuario)
function Start-AppUpdate($Tool) {
    $script:updateErrors.Remove($Tool.id)
    $script:updateRetry.Remove($Tool.id)
    Start-Action $Tool 'update'
}

# Botón Actualizar de PC Toolkit: si hay apps actualizándose, espera a que acaben (el instalador reinstala las
# herramientas y cierra el gestor)
function Request-ToolkitUpdate {
    $script:toolkitQueued = 'manual'
    $script:updatesRev++
    Invoke-ToolkitQueue
    Update-Page
}

function Invoke-ToolkitQueue {
    if (-not $script:toolkitQueued -or $busy.Count -or $script:checkJob) { return }
    $auto = $script:toolkitQueued -eq 'auto'
    if ($auto -and $win.IsVisible) { return }   # en automático, con el panel cerrado
    $script:toolkitQueued = $null
    $s = Get-UpdateState 'pctoolkit'
    Write-ManagerLog "Actualizando PC Toolkit $($s.Installed) -> $($s.Latest)$(if ($auto) { ' (automático)' })"
    $script:toolkitUpdating = Get-Date
    $script:autoTried['pctoolkit'] = $s.Latest   # si el instalador falla, no se repite en bucle
    $script:updatesRev++
    Start-ToolkitUpdate -NoShow:$auto
    # El instalador cierra el gestor y lo vuelve a abrir. Con el botón, como siempre, se cierra ya.
    if (-not $auto) { $script:exitAt = (Get-Date).AddSeconds(1) }
}

function Update-AllApps {
    foreach ($s in @(Get-UpdateStates | Where-Object Available)) {
        if ($s.Tool) { if (-not $busy.ContainsKey($s.Id)) { Start-AppUpdate $s.Tool } }
        else { $script:toolkitQueued = 'manual' }
    }
    $script:updatesRev++
    Invoke-ToolkitQueue
    Update-Page
}

# Lo que se dice de una app bajo su versión (página de la herramienta y lista de Ajustes): texto y color
function Get-UpdateDetail($State) {
    $id = $State.Id
    if ($busy.ContainsKey($id)) { return @((Get-BusyText $id), 'SubBrush') }
    if ($id -eq 'pctoolkit' -and $script:toolkitUpdating) { return @('Actualizando... PC Toolkit se volverá a abrir solo.', 'SubBrush') }
    if ($id -eq 'pctoolkit' -and $script:toolkitQueued) { return @('Se actualizará en cuanto terminen las demás actualizaciones.', 'SubBrush') }
    if ($errors.ContainsKey($id)) { return @($errors[$id], 'DangerBrush') }
    if ($script:updateErrors.ContainsKey($id)) { return @("No se pudo actualizar sola: $($script:updateErrors[$id])", 'DangerBrush') }
    if ($script:updateRetry.ContainsKey($id)) {
        return @("La app está abierta: se actualizará cuando la cierres (lo vuelve a intentar a las $($script:updateRetry[$id].ToString('HH:mm'))).", 'SubBrush')
    }
    if ($State.Available) {
        if ($State.Elevated) { return @('Actualizarla pide permisos de administrador: Windows preguntará.', 'SubBrush') }
        if ($State.InUse) { return @('La app está abierta: se cerrará un momento para actualizarla.', 'SubBrush') }
        if (Test-AutoUpdate $id) { return @('Se instalará sola en breve.', 'SubBrush') }
        return @('Hay una versión nueva.', 'SubBrush')
    }
    if ($script:checkJob) { return @('Buscando actualizaciones...', 'SubBrush') }
    if ($State.CheckError) { return @($State.CheckError, 'WarnBrush') }
    if ($script:updates.Checked) { return @("Comprobado $(Format-Ago $script:updates.Checked).", 'SubBrush') }
    @('Todavía no se ha comprobado.', 'SubBrush')
}

# «Actualización disponible» en la tarjeta (o el mosaico, -Short) de una herramienta con versión nueva de su app
function Set-UpdateNote($TextBlock, $Tool, [switch]$Short) {
    if (-not $Tool.HasUpdates -or $busy.ContainsKey($Tool.id)) { return }
    $s = Get-UpdateState $Tool.id
    if (-not $s.Available) { return }
    $TextBlock.Text = if ($Short) { 'Actualización disponible' } else { "Actualización disponible · $($s.Latest)" }
    $TextBlock.Visibility = 'Visible'
}

$UpdateRowXaml = @'
<Grid Margin="0,8,0,0">
  <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
  <TextBlock x:Name="Icon" Style="{StaticResource Icon}" FontSize="16" VerticalAlignment="Center" Foreground="{StaticResource AccentBrush}"/>
  <StackPanel Grid.Column="1" Margin="12,0" VerticalAlignment="Center">
    <TextBlock x:Name="T" Style="{StaticResource Body}"/>
    <TextBlock x:Name="D" Style="{StaticResource Caption}" TextWrapping="Wrap"/>
  </StackPanel>
  <Button x:Name="Update" Grid.Column="2" Style="{StaticResource AccentButton}" Content="Actualizar" VerticalAlignment="Center"/>
</Grid>
'@

# Pulsar Actualizar en una fila (de PC Toolkit o de una app)
$OnUpdateClick = {
    param($s, $e)
    $e.Handled = $true   # en la portada, que no abra la página de la herramienta
    Invoke-Safe { if ($s.Tag) { Start-AppUpdate $s.Tag } else { Request-ToolkitUpdate } }
}

# Fila «PC Toolkit 1.4.0 → 1.4.1 [Actualizar]» de la lista de Ajustes
function New-UpdateRow($State) {
    $row = New-Ui $UpdateRowXaml
    $row.FindName('Icon').Text = $State.Glyph
    $row.FindName('T').Text = "$($State.Name) $($State.Installed) → $($State.Latest)"
    $d = Get-UpdateDetail $State
    $row.FindName('D').Text = $d[0]
    $row.FindName('D').Foreground = $app.Resources[$d[1]]
    $btn = $row.FindName('Update')
    $btn.Tag = $State.Tool
    [Windows.Automation.AutomationProperties]::SetName($btn, "Actualizar $($State.Name)")
    $btn.IsEnabled = -not ($busy.ContainsKey($State.Id) -or ($State.Id -eq 'pctoolkit' -and ($script:toolkitQueued -or $script:toolkitUpdating)))
    $btn.Add_Click($OnUpdateClick)
    $row
}

# Ajustes › Actualizaciones: versión de PC Toolkit, «Buscar actualizaciones» (revisa ya PC Toolkit y todas las
# apps, sin mirar lo guardado) y la lista de lo que tiene versión nueva, con «Actualizar todo» si hay varias
function New-UpdatesCard {
    $card = New-Ui @'
<Border Style="{StaticResource Card}">
  <StackPanel>
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <StackPanel VerticalAlignment="Center" Margin="0,0,12,0">
        <TextBlock x:Name="T" Style="{StaticResource Body}"/>
        <TextBlock x:Name="D" Style="{StaticResource Caption}" TextWrapping="Wrap"/>
      </StackPanel>
      <Button x:Name="Check" Grid.Column="1" Style="{StaticResource SubtleButton}" Content="Buscar actualizaciones" VerticalAlignment="Center"/>
    </Grid>
    <ContentControl x:Name="Progress" Focusable="False"/>
    <StackPanel x:Name="List"/>
    <Button x:Name="All" Style="{StaticResource AccentButton}" Content="Actualizar todo" HorizontalAlignment="Left" Margin="0,12,0,0" Visibility="Collapsed"/>
  </StackPanel>
</Border>
'@
    $states = Get-UpdateStates
    $pending = @($states | Where-Object { $_.Available -or ($busy.ContainsKey($_.Id) -and $busy[$_.Id].Action -in 'update', 'autoupdate') })
    $card.FindName('T').Text = "PC Toolkit $(Get-ToolkitVersion)"
    $d = $card.FindName('D')
    $check = $card.FindName('Check')
    $check.Add_Click({ Invoke-Safe { Start-UpdateCheck; Update-Page } })
    if ($script:checkJob) {
        $d.Text = 'Buscando actualizaciones...'
        $check.IsEnabled = $false
        $card.FindName('Progress').Content = New-ProgressBar
    } elseif (-not $script:updates.Checked) {
        $d.Text = 'Todavía no se ha buscado.'
    } else {
        $when = "Última revisión $(Format-Ago $script:updates.Checked)"
        $d.Text = if ($pending) { "$when · $(if ($pending.Count -eq 1) { 'hay 1 actualización' } else { "hay $($pending.Count) actualizaciones" })" }
                  else { "$when · todo al día" }
    }
    $list = $card.FindName('List')
    foreach ($s in $pending) { [void]$list.Children.Add((New-UpdateRow $s)) }
    # Las que no se pudieron comprobar
    foreach ($s in @($states | Where-Object { $_.CheckError -and -not $_.Available })) {
        $h = New-Hint "$($s.Name): $($s.CheckError)"
        $h.Margin = '0,8,0,0'
        $h.Foreground = $app.Resources['WarnBrush']
        [void]$list.Children.Add($h)
    }
    if (@($pending | Where-Object { -not $busy.ContainsKey($_.Id) }).Count -ge 2) {
        $all = $card.FindName('All')
        $all.Visibility = 'Visible'
        $all.Add_Click({ Invoke-Safe { Update-AllApps } })
    }
    $card
}

# Página de una herramienta con app: versión instalada y última, Actualizar y «Actualizar automáticamente»
function New-UpdateSection($Tool) {
    $s = Get-UpdateState $Tool.id
    $p = New-Ui '<StackPanel/>'
    [void]$p.Children.Add((New-SectionHeader 'Actualizaciones'))
    $card = New-Ui @'
<Border Style="{StaticResource Card}">
  <StackPanel>
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <StackPanel VerticalAlignment="Center" Margin="0,0,12,0">
        <TextBlock x:Name="T" Style="{StaticResource Body}"/>
        <TextBlock x:Name="D" Style="{StaticResource Caption}" TextWrapping="Wrap"/>
      </StackPanel>
      <Button x:Name="Update" Grid.Column="1" Style="{StaticResource SubtleButton}" Content="Actualizar" VerticalAlignment="Center"/>
    </Grid>
    <ContentControl x:Name="Progress" Focusable="False"/>
  </StackPanel>
</Border>
'@
    $card.FindName('T').Text = if (-not $s.Installed) { 'La app no está instalada' }
                               elseif ($s.Available) { "Versión instalada $($s.Installed) · última $($s.Latest)" }
                               elseif ($s.Latest) { "Versión $($s.Installed) · al día" }
                               else { "Versión $($s.Installed)" }
    $d = Get-UpdateDetail $s
    $card.FindName('D').Text = $d[0]
    $card.FindName('D').Foreground = $app.Resources[$d[1]]
    $btn = $card.FindName('Update')
    $btn.Tag = $Tool
    [Windows.Automation.AutomationProperties]::SetName($btn, "Actualizar $($Tool.name)")
    if ($s.Available) { $btn.Style = $app.Resources['AccentButton'] }
    $btn.IsEnabled = $s.Available -and -not $busy.ContainsKey($Tool.id)
    $btn.Add_Click($OnUpdateClick)
    if ($busy.ContainsKey($Tool.id)) { $card.FindName('Progress').Content = New-ProgressBar }
    [void]$p.Children.Add($card)
    if ($s.Elevated) {
        $h = New-Hint 'Actualizar esta app pide permisos de administrador, así que no se actualiza sola: cuando hay versión nueva se avisa en su tarjeta y aquí.'
        $h.Margin = '4,4,0,8'
        [void]$p.Children.Add($h)
    } else {
        [void]$p.Children.Add((New-ToggleRow 'Actualizar automáticamente' 'Instala sola las versiones nuevas y avisa al terminar. Si la app está abierta, no la cierra: espera a que la cierres.' (Test-AutoUpdate $Tool.id) { param($id, $on) Set-AutoUpdate $id $on } $Tool.id))
    }
    $p
}

# Portada: aviso de versión nueva de PC Toolkit (o $null si no la hay)
function New-ToolkitUpdateCard {
    $s = Get-UpdateState 'pctoolkit'
    if (-not $s.Available) { return }
    $card = New-Ui '<Border Style="{StaticResource Card}" Padding="16,4,16,12" Margin="0,8,0,0"/>'
    $card.Child = New-UpdateRow $s
    $card.Child.FindName('T').Text = "PC Toolkit $($s.Latest) disponible"
    $card
}

$ui.BackButton.Add_Click({
    if ($script:page -like 'log:*') { Show-ToolPage ($script:page.Substring(4)) }
    elseif ($script:page -eq 'order') { Show-SettingsPage }
    else { Show-Home }
})
$ui.ViewButton.Add_Click({ Switch-HomeView })
$ui.SettingsButton.Add_Click({ if ($script:page -eq 'settings') { Show-Home } else { Show-SettingsPage } })

# --- Icono de la bandeja ---

$iconPath = Join-Path $PSScriptRoot '..\assets\pc-toolkit.ico'
$tray = New-Object Windows.Forms.NotifyIcon
$tray.Icon = New-Object Drawing.Icon($iconPath, [Windows.Forms.SystemInformation]::SmallIconSize)
$tray.Text = 'PC Toolkit'
$tray.Add_MouseUp({ Switch-Flyout })
$tray.Visible = $true

# --- Atajos de teclado de las herramientas y aviso flotante ---

$hotkeyStatus = @{}   # id -> 'ok' | 'ocupado' | 'inactivo' (para mostrarlo en su página)
$hotkeyActive = @{}   # id -> combinación registrada ahora mismo
$hotkeys = New-Object GlobalHotkeys
$hotkeyTools = @($tools | Where-Object { $_.hotkey })
$HotkeysFile = Join-Path (Get-ToolkitRoot) 'data\hotkeys.json'
$script:capturing = $null     # id de la herramienta cuyo atajo se está grabando
$script:captureHint = $null

# Atajos elegidos por el usuario: id -> "Ctrl+Alt+S", o "" si lo ha desactivado
function Get-HotkeyOverrides {
    $o = @{}
    if (Test-Path $HotkeysFile) {
        try { foreach ($p in (Get-Content $HotkeysFile -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties) { $o[$p.Name] = [string]$p.Value } } catch {}
    }
    $o
}

function Get-ToolHotkey($Tool) {
    $o = Get-HotkeyOverrides
    if ($o.ContainsKey($Tool.id)) { $o[$Tool.id] } else { $Tool.hotkey.keys }
}

function Save-ToolHotkey($Tool, $Keys) {
    $o = Get-HotkeyOverrides
    if ($null -eq $Keys -or $Keys -eq $Tool.hotkey.keys) { $o.Remove($Tool.id) } else { $o[$Tool.id] = $Keys }
    New-Item -ItemType Directory -Force -Path (Split-Path $HotkeysFile) | Out-Null
    $o | ConvertTo-Json | Set-Content $HotkeysFile -Encoding UTF8
}

function Format-Hotkey([string]$Keys) { (($Keys -split '\+') | ForEach-Object { $_.Trim() }) -join ' + ' }

# Cambia el atajo ($Keys: combinación, '' para desactivar, $null para el de serie).
# Si otra aplicación ya lo usa, se queda el anterior y se avisa.
function Set-ToolHotkey($Tool, $Keys) {
    $previous = Get-ToolHotkey $Tool
    Save-ToolHotkey $Tool $Keys
    Update-Hotkeys
    if ($hotkeyStatus[$Tool.id] -eq 'ocupado') {
        $wanted = Get-ToolHotkey $Tool
        Save-ToolHotkey $Tool $previous
        Update-Hotkeys
        Show-Error "Otra aplicación está usando $(Format-Hotkey $wanted). Se mantiene $(Format-Hotkey $previous)."
    }
}

function ConvertFrom-HotkeyText([string]$Text) {
    $mods = 0; $vk = 0
    foreach ($part in $Text -split '\+') {
        $p = $part.Trim().ToUpper()
        if ($p -in 'CTRL', 'CONTROL') { $mods = $mods -bor 2 }
        elseif ($p -eq 'ALT')   { $mods = $mods -bor 1 }
        elseif ($p -eq 'SHIFT') { $mods = $mods -bor 4 }
        elseif ($p -eq 'WIN')   { $mods = $mods -bor 8 }
        elseif ($p -match '^F(\d{1,2})$') { $vk = 0x6F + [int]$Matches[1] }
        elseif ($p -match '^[A-Z0-9]$')   { $vk = [int][char]$p }
    }
    @($mods, $vk)
}

# Registra los atajos de las herramientas activas (con su combinación actual) y quita los demás.
# Mientras se graba un atajo nuevo, el de esa herramienta se suelta para poder pulsarlo.
function Update-Hotkeys {
    for ($i = 0; $i -lt $hotkeyTools.Count; $i++) {
        $t = $hotkeyTools[$i]
        $enabled = (Get-ToolState $t) -eq 'Enabled'
        $want = if ($enabled -and $script:capturing -ne $t.id) { Get-ToolHotkey $t } else { '' }
        $current = [string]$hotkeyActive[$t.id]
        if ($current -eq $want -and $hotkeyStatus.ContainsKey($t.id)) { continue }
        if ($current) { $hotkeys.Unregister($i + 1); $hotkeyActive.Remove($t.id) }
        if (-not $want) { $hotkeyStatus[$t.id] = 'inactivo'; continue }
        $k = ConvertFrom-HotkeyText $want
        if ($hotkeys.Register($i + 1, $k[0], $k[1])) {
            $hotkeyActive[$t.id] = $want
            $hotkeyStatus[$t.id] = 'ok'
        } else {
            $hotkeyStatus[$t.id] = 'ocupado'
            Write-ManagerLog "Atajo $want de $($t.id) ocupado por otra aplicación"
        }
    }
}

function Start-HotkeyCapture($Tool) {
    $script:capturing = $Tool.id
    $script:captureHint = $null
    Update-Hotkeys
    Update-Page
}

function Stop-HotkeyCapture {
    $script:capturing = $null
    $script:captureHint = $null
    Update-Hotkeys
    Update-Page
}

# Grabar la combinación: Ctrl/Alt/Win (+ Shift opcional) + letra, número o tecla F
$win.Add_PreviewKeyDown({
    param($s, $e)
    if (-not $script:capturing) { return }
    $e.Handled = $true
    $key = [string]$(if ($e.Key -eq 'System') { $e.SystemKey } else { $e.Key })
    if ($key -eq 'Escape') { Stop-HotkeyCapture; return }
    if ($key -match '^(Left|Right)(Ctrl|Alt|Shift)$|^[LR]Win$') { return }
    $name = if ($key -match '^[A-Z]$') { $key } elseif ($key -match '^D(\d)$') { $Matches[1] } elseif ($key -match '^F(\d{1,2})$') { $key }
    $mods = [Windows.Input.Keyboard]::Modifiers
    $parts = @()
    if ($mods -band [Windows.Input.ModifierKeys]::Control) { $parts += 'Ctrl' }
    if ($mods -band [Windows.Input.ModifierKeys]::Alt)     { $parts += 'Alt' }
    if ($mods -band [Windows.Input.ModifierKeys]::Shift)   { $parts += 'Shift' }
    if ($mods -band [Windows.Input.ModifierKeys]::Windows) { $parts += 'Win' }
    if (-not $name -or -not ($parts | Where-Object { $_ -ne 'Shift' })) {
        $script:captureHint = 'La combinación debe incluir Ctrl, Alt o Win y una letra, un número o una tecla de función.'
        Update-Page
        return
    }
    $tool = $tools | Where-Object id -eq $script:capturing
    $script:capturing = $null
    $script:captureHint = $null
    Set-ToolHotkey $tool (($parts + $name) -join '+')
    Update-Page
})

# Sección "Atajo de teclado" de la página de cualquier herramienta con "hotkey" en tool.json
function New-HotkeySection($Tool) {
    $p = New-Ui '<StackPanel/>'
    [void]$p.Children.Add((New-SectionHeader 'Atajo de teclado' $Tool.hotkey.description))
    $card = New-Ui $HotkeyCardXaml
    $keys = Get-ToolHotkey $Tool
    $info = $card.FindName('Info')
    if ($script:capturing -eq $Tool.id) {
        $card.FindName('Keys').Text = 'Pulsa la nueva combinación de teclas'
        $card.FindName('Keys').Foreground = $app.Resources['AccentBrush']
        $info.Text = if ($script:captureHint) { $script:captureHint } else { 'Por ejemplo, Ctrl + Alt + A. Pulsa Esc para cancelar.' }
        $card.FindName('Change').Content = 'Cancelar'
        $card.FindName('More').Visibility = 'Collapsed'
    } else {
        $card.FindName('Keys').Text = if ($keys) { Format-Hotkey $keys } else { 'Sin atajo' }
        $info.Text = if (-not $keys) { 'Desactivado.' }
                     elseif ($hotkeyStatus[$Tool.id] -eq 'ok') { 'Disponible mientras PC Toolkit esté en ejecución.' }
                     elseif ($hotkeyStatus[$Tool.id] -eq 'ocupado') { 'Otra aplicación está usando esta combinación de teclas.' }
                     else { 'Disponible cuando la herramienta está activada.' }
        if ($hotkeyStatus[$Tool.id] -eq 'ocupado' -and $keys) { $info.Foreground = $app.Resources['DangerBrush'] }
        if (-not $keys) { $card.FindName('Disable').Visibility = 'Collapsed' }
        if ($keys -eq $Tool.hotkey.keys) { $card.FindName('Reset').Visibility = 'Collapsed' }
    }
    foreach ($n in 'Change', 'Disable', 'Reset') { $card.FindName($n).Tag = $Tool }
    $card.FindName('Change').Add_Click({ param($s, $e) if ($script:capturing) { Stop-HotkeyCapture } else { Start-HotkeyCapture $s.Tag } })
    $card.FindName('Disable').Add_Click({ param($s, $e) Set-ToolHotkey $s.Tag ''; Update-Page })
    $card.FindName('Reset').Add_Click({ param($s, $e) Set-ToolHotkey $s.Tag $null; Update-Page })
    [void]$p.Children.Add($card)
    $p
}

$HotkeyCardXaml = @"
<Border Style="{StaticResource Card}">
  <StackPanel>
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <StackPanel VerticalAlignment="Center" Margin="0,0,12,0">
        <TextBlock x:Name="Keys" Style="{StaticResource Body}" FontWeight="SemiBold"/>
        <TextBlock x:Name="Info" Style="{StaticResource Caption}"/>
      </StackPanel>
      <Button x:Name="Change" Grid.Column="1" Style="{StaticResource SubtleButton}" Content="Cambiar"/>
    </Grid>
    <StackPanel x:Name="More" Orientation="Horizontal" Margin="-12,6,0,0">
      <Button x:Name="Disable" Style="{StaticResource SubtleButton}" Content="Desactivar"/>
      <Button x:Name="Reset" Style="{StaticResource SubtleButton}" Content="Restablecer"/>
    </StackPanel>
  </StackPanel>
</Border>
"@

$osd = ConvertFrom-Xaml (Get-Content (Join-Path $PSScriptRoot 'osd.xaml') -Raw -Encoding UTF8)
$osdUi = @{}
foreach ($n in 'Root', 'Icon', 'Text', 'Detail') { $osdUi[$n] = $osd.FindName($n) }
$osd.Add_SourceInitialized({
    $hwnd = (New-Object Windows.Interop.WindowInteropHelper $osd).Handle
    [Native]::RemoveSystemMenu($hwnd)
    [Native]::SetNoActivate($hwnd)
    [Native]::SetDwm($hwnd, 20, [int]$dark)
    [Native]::SetDwm($hwnd, 33, 2)
})
$script:osdUntil = $null

# Aviso abajo en el centro, como el de volumen de Windows
function Show-Osd([string]$Glyph, [string]$Text, [string]$Detail, [int]$Seconds = 2) {
    $osdUi.Icon.Text = $Glyph
    $osdUi.Text.Text = $Text
    $osdUi.Detail.Text = $Detail
    $osdUi.Root.Measure([Windows.Size]::new([double]::PositiveInfinity, [double]::PositiveInfinity))
    $osd.Width  = [Math]::Ceiling($osdUi.Root.DesiredSize.Width)
    $osd.Height = [Math]::Ceiling($osdUi.Root.DesiredSize.Height)
    $osd.Show()
    [void][Native]::ShowWindow((New-Object Windows.Interop.WindowInteropHelper $osd).Handle, 4)   # SW_SHOWNOACTIVATE
    $wa = [Windows.SystemParameters]::WorkArea
    $osd.Left = $wa.Left + ($wa.Width - $osd.Width) / 2
    $osd.Top  = $wa.Bottom - $osd.Height - 56
    $script:osdUntil = (Get-Date).AddSeconds($Seconds)
}

$hotkeys.Add_Pressed({
    param($s, $e)
    $t = $hotkeyTools[$s.LastId - 1]
    try {
        $text = [string]@(& { param($path) . $path } (Join-Path $t.Dir $t.hotkey.script))[-1]
        if ($text) { Show-Osd (ConvertTo-Glyph $t.icon) $text "$(Format-Hotkey (Get-ToolHotkey $t))  ·  $($t.name)" }
        if ($win.IsVisible) { Update-Page }
    } catch { Write-ManagerLog "ERROR atajo de $($t.id): $($_.Exception.Message)" }
})
Update-Hotkeys

# --- Reloj: otra instancia pide mostrar, progreso de acciones, refresco del estado ---

$script:ticks = 0
$script:exitAt = $null
$script:bannerUntil = $null

# Actualizaciones: primera revisión 90 s después de arrancar (para no retrasar el arranque) y luego cada 6 h.
# Si se acaba de revisar (el gestor se ha reiniciado, p. ej. al actualizarse), no se repite: a las 6 h de esa.
$script:updatesStartAt = (Get-Date).AddSeconds(90)
$script:nextCheckAt = $script:updatesStartAt
if ($script:updates.Checked -and ((Get-Date) - $script:updates.Checked).TotalMinutes -lt 30) { $script:nextCheckAt = $script:updates.Checked + $CheckInterval }

# Si PC Toolkit acaba de actualizarse (con el botón o solo), se avisa al arrancar la versión nueva
$script:startupOsd = $null
$script:startupOsdAt = (Get-Date).AddSeconds(5)   # cuando el gestor ya está en marcha
$currentVersion = Get-ToolkitVersion
if ($script:prefs.LastVersion -ne $currentVersion) {
    if (Test-NewerVersion $currentVersion $script:prefs.LastVersion) { $script:startupOsd = $currentVersion }
    $script:prefs.LastVersion = $currentVersion
    Save-HomePrefs
}

function Invoke-UpdateTimers {
    $now = Get-Date
    if ($script:startupOsd -and $now -ge $script:startupOsdAt) {
        Show-Osd (ConvertTo-Glyph 'E895') "PC Toolkit $($script:startupOsd)" 'Actualización instalada' -Seconds 6
        $script:startupOsd = $null
    }
    if ($script:checkJob) {
        $job = $script:checkJob
        # sin respuesta en 3 minutos: se da por fallida
        if (-not $job.Process.HasExited -and ($now - $job.Started).TotalMinutes -gt 3) { try { $job.Process.Kill() } catch {} }
        if ($job.Process.HasExited) {
            Complete-UpdateCheck
            if ($win.IsVisible) { Update-Page }
        }
    } elseif ($now -ge $script:nextCheckAt) {
        Start-UpdateCheck
        if ($win.IsVisible -and $script:page -eq 'settings') { Update-Page }
    }
    if ($script:updatesStartAt -and $now -ge $script:updatesStartAt) {
        # con lo guardado de la última revisión (p. ej., una app que estaba abierta al reiniciar)
        $script:updatesStartAt = $null
        Invoke-AutoUpdates
        Update-TrayText
    }
    $due = @($script:updateRetry.Keys | Where-Object { $script:updateRetry[$_] -le $now })
    if ($due) {
        foreach ($id in $due) { $script:updateRetry.Remove($id) }
        $script:updatesRev++
        Invoke-AutoUpdates
    }
    Invoke-ToolkitQueue
    # Si el instalador de PC Toolkit no llegó a cerrar el gestor en 5 minutos, ha fallado (ver update.log)
    if ($script:toolkitUpdating -and ($now - $script:toolkitUpdating).TotalMinutes -gt 5) {
        $script:toolkitUpdating = $null
        $script:updatesRev++
        Write-ManagerLog "ERROR: PC Toolkit no se pudo actualizar (mira $(Join-Path (Get-ToolkitRoot) 'update.log'))"
    }
}

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(400)
$timer.Add_Tick({
    try {
        if ($showEvent.WaitOne(0)) { Show-Flyout }
        if ($script:exitAt -and (Get-Date) -ge $script:exitAt) { Exit-Manager; return }
        if ($script:bannerUntil -and (Get-Date) -ge $script:bannerUntil) { $script:bannerUntil = $null; $ui.Banner.Visibility = 'Collapsed' }
        if ($script:osdUntil -and (Get-Date) -ge $script:osdUntil) { $script:osdUntil = $null; $osd.Hide() }
        try { Invoke-UpdateTimers } catch { Write-ManagerLog "ERROR (actualizaciones): $($_.Exception.Message)" }

        $finished = Update-Busy
        if (-not $win.IsVisible) { return }
        $script:ticks++
        if ($finished) { Update-Page; return }
        if (($busy.Count -or $script:ticks % 5 -eq 0) -and $script:PageSignature) {
            $sig = & $script:PageSignature
            if ($sig -ne $script:lastSignature) { Update-Page }
        }
    } catch { Write-ManagerLog "ERROR (reloj): $($_.Exception.Message)" }
})
$timer.Start()

# La portada se prepara ya, con el panel oculto, para que el primer clic en el icono la enseñe al instante
if ($Show) { Show-Flyout }
else { [void]$win.Dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::ApplicationIdle, [Action]{ try { Show-Home } catch { Write-ManagerLog "ERROR (portada): $($_.Exception.Message)" } }) }
$app.Run()

$timer.Stop()
$tray.Dispose()
$mutex.ReleaseMutex()
