# GameBar.ps1 - Barra flotante de Juegos: al dejar el ratón arriba del todo en la pantalla de un juego
# en ventana sin bordes, aparece arriba en el centro con ◀ ▶ para pasarlo a otra pantalla. Desaparece
# al apartar el ratón. No toca la ventana del juego ni le quita el foco.
# La carga Games.ps1 con "." (usa su Update-All, Set-GameScreen y $script:GameScreens).

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$light = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -ErrorAction SilentlyContinue).AppsUseLightTheme -ne 0
$c = if ($light) { @{ Bg = '#F2F9F9F9'; Text = '#1A1A1A'; Sub = '#A0000000'; Hover = '#14000000'; Stroke = '#1A000000' } }
     else        { @{ Bg = '#F22C2C2C'; Text = '#FFFFFF'; Sub = '#C5FFFFFF'; Hover = '#1FFFFFFF'; Stroke = '#26FFFFFF' } }
$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent" Topmost="True" ShowInTaskbar="False"
        ShowActivated="False" SizeToContent="WidthAndHeight" ResizeMode="NoResize" Title="PC Toolkit - Juegos">
  <Window.Resources>
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Foreground" Value="$($c.Text)"/>
      <Setter Property="FontFamily" Value="Segoe Fluent Icons, Segoe MDL2 Assets"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Width" Value="34"/>
      <Setter Property="Height" Value="30"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="Transparent" CornerRadius="5">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="$($c.Hover)"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Border Background="$($c.Bg)" BorderBrush="$($c.Stroke)" BorderThickness="1" CornerRadius="8" Padding="4" Margin="8">
    <Border.Effect><DropShadowEffect BlurRadius="14" ShadowDepth="2" Opacity="0.35"/></Border.Effect>
    <StackPanel Orientation="Horizontal">
      <Button x:Name="Prev" Style="{StaticResource Btn}" Content="&#xE76B;" ToolTip="Pantalla anterior"/>
      <StackPanel VerticalAlignment="Center" Margin="10,0">
        <TextBlock x:Name="Game" Foreground="$($c.Text)" FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="12.5" HorizontalAlignment="Center"/>
        <TextBlock x:Name="Screen" Foreground="$($c.Sub)" FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="11" HorizontalAlignment="Center"/>
      </StackPanel>
      <Button x:Name="Next" Style="{StaticResource Btn}" Content="&#xE76C;" ToolTip="Pantalla siguiente"/>
    </StackPanel>
  </Border>
</Window>
"@
$script:Bar = [Windows.Markup.XamlReader]::Parse($xaml)
$script:BarHwnd = (New-Object Windows.Interop.WindowInteropHelper $script:Bar).EnsureHandle()
[PcToolkit.GameWindows.Native]::SetNoActivate($script:BarHwnd)
$script:BarFor   = $null   # @{ Game; Screen } que muestra ahora
$script:BarSince = $null   # desde cuándo está el ratón arriba (para no saltar con un roce)
$script:BarAway  = $null   # desde cuándo está el ratón fuera de la barra

function Show-GameBar($entry) {
    $script:BarFor = $entry
    $script:Bar.FindName('Game').Text = $entry.Game.Name
    $script:Bar.FindName('Screen').Text = Get-ScreenLabel $entry.Screen
    $script:Bar.Show()
    $script:Bar.UpdateLayout()
    # El vigilante es "DPI aware" de sistema: píxeles reales = unidades de WPF x escala del sistema
    $scale = [Windows.PresentationSource]::FromVisual($script:Bar).CompositionTarget.TransformToDevice.M11
    $w = [int]($script:Bar.ActualWidth * $scale)
    $h = [int]($script:Bar.ActualHeight * $scale)
    $b = $entry.Screen.Bounds
    $x = [int]($b.X + ($b.Width - $w) / 2)
    [PcToolkit.GameWindows.Native]::MoveTo($script:BarHwnd, $x, $b.Y)
    # Zona en la que el ratón la mantiene abierta (la barra y un margen alrededor), en píxeles reales
    $script:BarZone = New-Object Drawing.Rectangle ($x - 40), $b.Y, ($w + 80), ($h + 40)
    $script:BarAway = $null
}

function Hide-GameBar {
    $script:Bar.Hide()
    $script:BarFor = $null
    $script:BarAway = $null
}

function Move-GameFromBar([int]$Delta) {
    if (-not $script:BarFor) { return }
    $entry = $script:BarFor
    $next = Get-NextScreen $entry.Screen $Delta
    Set-GameScreen $entry.Game.Exe $next
    Write-Log "$($entry.Game.Name): pasado a $(Get-ScreenLabel $next) desde la barra"
    Hide-GameBar
    Update-All   # mover ya, sin esperar al siguiente repaso
    $script:BarSince = $null
}
$script:Bar.FindName('Prev').Add_Click({ try { Move-GameFromBar -1 } catch { Write-Log "ERROR barra: $($_.Exception.Message)" } })
$script:Bar.FindName('Next').Add_Click({ try { Move-GameFromBar 1 } catch { Write-Log "ERROR barra: $($_.Exception.Message)" } })

function Update-GameBar {
    $p = [PcToolkit.GameWindows.Native]::GetCursor()
    if (-not $p) { return }
    $now = Get-Date

    if ($script:BarFor) {
        # Fuera de la barra (con un margen) durante medio segundo, o el juego ya no está: se oculta
        $inside = $script:BarZone.Contains($p[0], $p[1])
        $still = $script:GameScreens | Where-Object { $_.Game.Exe -eq $script:BarFor.Game.Exe }
        if ($inside -and $still) { $script:BarAway = $null; return }
        if (-not $script:BarAway) { $script:BarAway = $now }
        if (-not $still -or ($now - $script:BarAway).TotalMilliseconds -ge 500) { Hide-GameBar }
        return
    }

    # Ratón pegado arriba en la pantalla de un juego sin bordes durante 0,3 s: se muestra
    $entry = $script:GameScreens | Where-Object {
        $b = $_.Screen.Bounds
        $p[1] -le $b.Y + 1 -and $p[0] -ge $b.X -and $p[0] -lt $b.Right -and $p[1] -ge $b.Y
    } | Select-Object -First 1
    if (-not $entry) { $script:BarSince = $null; return }
    if (-not $script:BarSince) { $script:BarSince = $now; return }
    if (($now - $script:BarSince).TotalMilliseconds -ge 300) { $script:BarSince = $null; Show-GameBar $entry }
}

$mouseTimer = New-Object Windows.Threading.DispatcherTimer
$mouseTimer.Interval = [TimeSpan]::FromMilliseconds(100)
$mouseTimer.Add_Tick({ try { Update-GameBar } catch { Write-Log "ERROR barra: $($_.Exception.Message)" } })
$mouseTimer.Start()
