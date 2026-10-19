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
#              del aviso que aparece abajo en el centro.
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
foreach ($n in 'Root', 'Anim', 'Slide', 'BackButton', 'Logo', 'HeaderTitle', 'SettingsButton', 'Banner', 'BannerText', 'Scroll', 'Page') { $ui[$n] = $win.FindName($n) }
# Imagen cargada en memoria (OnLoad) para no dejar el archivo bloqueado durante las actualizaciones
$logo = New-Object Windows.Media.Imaging.BitmapImage
$logo.BeginInit()
$logo.CacheOption = 'OnLoad'
$logo.UriSource = [Uri]::new([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\assets\pc-toolkit.png')))
$logo.EndInit()
$ui.Logo.Source = $logo
$ui.Scroll.MaxHeight = [Windows.SystemParameters]::WorkArea.Height - 120
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

function Show-Flyout {
    Show-Home
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
            if ($b.Process.ExitCode -ne 0) { $errors[$id] = $text -replace '^ERROR:\s*', '' }
            Remove-Item $b.StatusFile -ErrorAction SilentlyContinue
            $busy.Remove($id)
            $changed = $true
            Update-Hotkeys
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
}

function Update-Page {
    switch -Wildcard ($script:page) {
        'home'     { Show-Home }
        'settings' { Show-SettingsPage }
        'tool:*'   { Show-ToolPage ($script:page.Substring(5)) }
        'log:*'    { Show-LogPage ($script:page.Substring(4)) }
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
    ($tools | ForEach-Object {
        $busyText = if ($busy.ContainsKey($_.id)) { Get-BusyText $_.id }
        $own = if ($script:HomeSignatures.ContainsKey($_.id)) { & $script:HomeSignatures[$_.id] }
        "$($_.id)=$(Get-ToolState $_)|$busyText|$($errors[$_.id])|$(if ($_.process) { [bool](Get-ToolProcess $_) })|$own"
    }) -join ';'
}

# Firma de la página de una herramienta: su estado + lo que diga su settings.ps1
function Get-ToolPageSignature {
    $t = $tools | Where-Object id -eq $script:page.Substring(5)
    $busyText = if ($busy.ContainsKey($t.id)) { Get-BusyText $t.id }
    $own = if ($script:settingsSignature) { & $script:settingsSignature }
    "$(Get-ToolState $t)|$busyText|$($errors[$t.id])|$(if ($t.process) { [bool](Get-ToolProcess $t) })|$own"
}

function Show-Home {
    $script:page = 'home'
    $script:PageSignature = { Get-HomeSignature }
    $panel = New-Ui '<StackPanel/>'
    $states = @{}
    foreach ($t in $tools) { $states[$t.id] = Get-ToolState $t }
    $installed = @($tools | Where-Object { $states[$_.id] -ne 'NotInstalled' })
    $available = @($tools | Where-Object { $states[$_.id] -eq 'NotInstalled' })

    [void]$panel.Children.Add((New-SectionHeader 'Instaladas'))
    if (-not $installed) { [void]$panel.Children.Add((New-Hint 'Todavía no hay ninguna. Instálalas desde la lista de abajo.')) }
    foreach ($t in $installed) {
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
      </StackPanel>
      <CheckBox x:Name="Toggle" Grid.Column="2" Style="{StaticResource Toggle}"/>
      <TextBlock Grid.Column="3" Style="{StaticResource Icon}" Text="&#xE76C;" FontSize="12" Margin="14,0,0,0" Foreground="{StaticResource SubBrush}"/>
    </Grid>
    <ContentControl x:Name="Extra" Focusable="False"/>
  </StackPanel>
</Button>
'@
        $card.FindName('Icon').Text = ConvertTo-Glyph $t.icon
        $card.FindName('Name').Text = $t.name
        $status = Get-StatusText $t $states[$t.id]
        $card.FindName('Status').Text = $status[0]
        $card.FindName('Status').Foreground = $app.Resources[$status[1]]
        $toggle = $card.FindName('Toggle')
        $toggle.IsChecked = $states[$t.id] -eq 'Enabled'
        [Windows.Automation.AutomationProperties]::SetName($toggle, "Activar $($t.name)")
        $toggle.Tag = $t
        $onToggle = { param($s, $e) Start-Action $s.Tag $(if ($s.IsChecked) { 'enable' } else { 'disable' }) }
        $toggle.Add_Checked($onToggle)
        $toggle.Add_Unchecked($onToggle)
        if ($busy.ContainsKey($t.id)) {
            $toggle.IsEnabled = $false
            $card.FindName('Extra').Content = New-ProgressBar
        } elseif ($t.HasHome) {
            try {
                $extra = & { param($path) . $path } (Join-Path $t.Dir 'home.ps1')
                $card.FindName('Extra').Content = @($extra | Where-Object { $_ -is [Windows.UIElement] })[0]
            } catch { Write-ManagerLog "ERROR home.ps1 de $($t.id): $($_.Exception.Message)" }
        }
        $card.Tag = $t
        [Windows.Automation.AutomationProperties]::SetName($card, $t.name)
        # Solo clics en la propia tarjeta: los de su interruptor o su bloque de portada también llegan aquí (burbujean)
        $card.Add_Click({ param($s, $e) if ($e.OriginalSource -eq $s) { Show-ToolPage $s.Tag.id } })
        [void]$panel.Children.Add($card)
    }

    if ($available) {
        [void]$panel.Children.Add((New-SectionHeader 'Disponibles'))
        foreach ($t in $available) {
            $card = New-Ui @'
<Border Style="{StaticResource Card}">
  <StackPanel>
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <TextBlock x:Name="Icon" Style="{StaticResource ToolIcon}" VerticalAlignment="Top" Margin="0,2,0,0"/>
      <StackPanel Grid.Column="1" Margin="12,0">
        <TextBlock x:Name="Name" Style="{StaticResource Title}"/>
        <TextBlock x:Name="Desc" Style="{StaticResource Caption}" Margin="0,2,0,0"/>
      </StackPanel>
      <Button x:Name="Install" Grid.Column="2" Style="{StaticResource AccentButton}" Content="Instalar" VerticalAlignment="Top"/>
    </Grid>
    <ContentControl x:Name="Extra" Focusable="False"/>
  </StackPanel>
</Border>
'@
            $card.FindName('Icon').Text = ConvertTo-Glyph $t.icon
            $card.FindName('Name').Text = $t.name
            $card.FindName('Desc').Text = $t.description
            $btn = $card.FindName('Install')
            $btn.Tag = $t
            [Windows.Automation.AutomationProperties]::SetName($btn, "Instalar $($t.name)")
            $btn.Add_Click({ param($s, $e) Start-Action $s.Tag 'install' })
            if ($busy.ContainsKey($t.id)) {
                $btn.Visibility = 'Collapsed'
                $p = New-Ui '<StackPanel/>'
                [void]$p.Children.Add((New-ProgressBar))
                $h = New-Hint (Get-BusyText $t.id); $h.Margin = '0,6,0,0'
                [void]$p.Children.Add($h)
                $card.FindName('Extra').Content = $p
            } elseif ($errors.ContainsKey($t.id)) {
                $h = New-Hint $errors[$t.id]; $h.Margin = '0,8,0,0'; $h.Foreground = $app.Resources['DangerBrush']
                $card.FindName('Extra').Content = $h
            }
            [void]$panel.Children.Add($card)
        }
    }
    Set-Page $panel 'PC Toolkit' $false
    $script:lastSignature = Get-HomeSignature
}

function Show-ToolPage([string]$Id) {
    $t = $tools | Where-Object id -eq $Id
    $state = Get-ToolState $t
    if ($state -eq 'NotInstalled' -and -not $busy.ContainsKey($Id)) { Show-Home; return }
    $first = $script:page -ne "tool:$Id"
    $script:page = "tool:$Id"
    $script:PageSignature = $null

    $panel = New-Ui '<StackPanel/>'
    $desc = New-Hint $t.description
    $desc.Margin = '4,4,0,12'
    [void]$panel.Children.Add($desc)

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

function Show-SettingsPage {
    $script:page = 'settings'
    $script:PageSignature = $null
    $panel = New-Ui '<StackPanel/>'
    [void]$panel.Children.Add((New-SectionHeader 'General'))
    [void]$panel.Children.Add((New-ToggleRow 'Iniciar con Windows' 'Deja el icono en la bandeja al iniciar sesión.' (Test-ManagerAutostart) { param($a, $on) Set-ManagerAutostart $on } $null))

    [void]$panel.Children.Add((New-SectionHeader 'Actualizaciones'))
    $card = New-Ui @'
<Border Style="{StaticResource Card}">
  <Grid>
    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
    <StackPanel VerticalAlignment="Center">
      <TextBlock x:Name="T" Style="{StaticResource Body}"/>
      <TextBlock x:Name="D" Style="{StaticResource Caption}" Text="Se descargan de GitHub."/>
    </StackPanel>
    <Button x:Name="Check" Grid.Column="1" Style="{StaticResource SubtleButton}" Content="Buscar"/>
  </Grid>
</Border>
'@
    $card.FindName('T').Text = "Versión $(Get-ToolkitVersion)"
    $script:updateCard = $card
    $card.FindName('Check').Add_Click({ param($s, $e) Start-UpdateCheck $s })
    [void]$panel.Children.Add($card)

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

    Set-Page $panel 'Ajustes' $true
    $ui.Scroll.ScrollToTop()
}

# Comprobar versión: se deja pintar "Buscando..." y luego se consulta
function Start-UpdateCheck($Button) {
    if ($Button.Content -eq 'Actualizar') {
        $script:updateCard.FindName('D').Text = 'Actualizando... PC Toolkit se volverá a abrir solo.'
        $Button.IsEnabled = $false
        Start-ToolkitUpdate
        $script:exitAt = (Get-Date).AddSeconds(1)
        return
    }
    $script:updateCard.FindName('D').Text = 'Buscando...'
    $Button.IsEnabled = $false
    $script:checkUpdateAt = (Get-Date).AddMilliseconds(80)
}

function Invoke-UpdateCheck {
    $d = $script:updateCard.FindName('D')
    $b = $script:updateCard.FindName('Check')
    $b.IsEnabled = $true
    try {
        $remote = Get-ToolkitRemoteVersion
        if ([version]$remote -gt [version](Get-ToolkitVersion)) {
            $d.Text = "Hay una versión nueva: $remote"
            $b.Content = 'Actualizar'
            $b.Style = $app.Resources['AccentButton']
        } else {
            $d.Text = 'Ya tienes la última versión.'
        }
    } catch { $d.Text = 'No se pudo comprobar (¿sin conexión?).' }
}

$ui.BackButton.Add_Click({ if ($script:page -like 'log:*') { Show-ToolPage ($script:page.Substring(4)) } else { Show-Home } })
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
        Show-Error "$(Format-Hotkey $wanted) ya lo usa otra aplicación. Se mantiene $(Format-Hotkey $previous)."
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
        $script:captureHint = 'Usa Ctrl, Alt o Win junto a una letra, un número o una tecla F.'
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
        $card.FindName('Keys').Text = 'Pulsa la nueva combinación...'
        $card.FindName('Keys').Foreground = $app.Resources['AccentBrush']
        $info.Text = if ($script:captureHint) { $script:captureHint } else { 'Por ejemplo Ctrl + Alt + A. Esc para cancelar.' }
        $card.FindName('Change').Content = 'Cancelar'
        $card.FindName('More').Visibility = 'Collapsed'
    } else {
        $card.FindName('Keys').Text = if ($keys) { Format-Hotkey $keys } else { 'Sin atajo' }
        $info.Text = if (-not $keys) { 'Desactivado.' }
                     elseif ($hotkeyStatus[$Tool.id] -eq 'ok') { 'Funciona mientras PC Toolkit esté en la bandeja.' }
                     elseif ($hotkeyStatus[$Tool.id] -eq 'ocupado') { 'Otra aplicación ya usa este atajo, así que ahora no funciona.' }
                     else { 'Funcionará cuando la herramienta esté activada.' }
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
function Show-Osd([string]$Glyph, [string]$Text, [string]$Detail) {
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
    $script:osdUntil = (Get-Date).AddSeconds(2)
}

$hotkeys.Add_Pressed({
    param($s, $e)
    $t = $hotkeyTools[$s.LastId - 1]
    try {
        $text = & { param($path) . $path } (Join-Path $t.Dir $t.hotkey.script)
        Show-Osd (ConvertTo-Glyph $t.icon) ([string]@($text)[-1]) "$(Format-Hotkey (Get-ToolHotkey $t))  ·  $($t.name)"
        if ($win.IsVisible) { Update-Page }
    } catch { Write-ManagerLog "ERROR atajo de $($t.id): $($_.Exception.Message)" }
})
Update-Hotkeys

# --- Reloj: otra instancia pide mostrar, progreso de acciones, refresco del estado ---

$script:ticks = 0
$script:checkUpdateAt = $null
$script:exitAt = $null
$script:bannerUntil = $null
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(400)
$timer.Add_Tick({
    try {
        if ($showEvent.WaitOne(0)) { Show-Flyout }
        if ($script:exitAt -and (Get-Date) -ge $script:exitAt) { Exit-Manager; return }
        if ($script:checkUpdateAt -and (Get-Date) -ge $script:checkUpdateAt) { $script:checkUpdateAt = $null; Invoke-UpdateCheck }
        if ($script:bannerUntil -and (Get-Date) -ge $script:bannerUntil) { $script:bannerUntil = $null; $ui.Banner.Visibility = 'Collapsed' }
        if ($script:osdUntil -and (Get-Date) -ge $script:osdUntil) { $script:osdUntil = $null; $osd.Hide() }

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

if ($Show) { Show-Flyout }
$app.Run()

$timer.Stop()
$tray.Dispose()
$mutex.ReleaseMutex()
