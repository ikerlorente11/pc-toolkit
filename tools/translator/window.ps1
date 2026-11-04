# window.ps1 - Ventana del Traductor. Se carga con "." dentro del gestor (atajo, portada y página de
# ajustes); la ventana se crea una sola vez y después solo se muestra u oculta, así que abre al instante.
# Traduce mientras se escribe (con una pequeña pausa), detecta el idioma y, si el texto ya está en el
# idioma de destino, lo traduce al alternativo (p. ej. español -> inglés en vez de español -> español).
# Se abre abajo a la derecha (como el panel) y crece hacia arriba. Los idiomas elegidos en la ventana
# duran hasta cerrarla: al abrirla vuelve a los idiomas por defecto de los ajustes.

. (Join-Path $PSScriptRoot 'common.ps1')

function script:Write-TranslatorLog($msg) {
    try {
        New-Item -ItemType Directory -Force -Path $script:TranslatorData | Out-Null
        $log = Join-Path $script:TranslatorData 'Translator.log'
        if ((Test-Path $log) -and (Get-Item $log).Length -gt 100KB) { Clear-Content $log }
        Add-Content -Path $log -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg) -Encoding UTF8
    } catch {}
}

function script:Update-TranslatorPickers {
    $script:TrUi.SourceHost.Content = New-TranslatorLanguagePicker $script:TrSource {
        param($code)
        $script:TrSource = $code
        Update-TranslatorPickers
        Start-Translation
        [void]$script:TrUi.Input.Focus()
    } 'Idioma de origen' -Auto -Card
    $script:TrUi.TargetHost.Content = New-TranslatorLanguagePicker $script:TrTarget {
        param($code)
        $script:TrTarget = $code
        Update-TranslatorPickers
        Start-Translation
        [void]$script:TrUi.Input.Focus()
    } 'Idioma de destino' -Card
}

function script:Clear-TranslatorOutput {
    $script:TrPending = $null
    $script:TrLast = $null
    $script:TrUi.Output.Text = ''
    $script:TrUi.Status.Text = ''
    $script:TrUi.Dictionary.Children.Clear()
    $script:TrUi.Dictionary.Visibility = 'Collapsed'
}

# Lanza la petición (sin esperar). $Target solo se pasa al reintentar con el idioma alternativo.
function script:Start-Translation([string]$Target) {
    $script:TrDebounce.Stop()
    $text = $script:TrUi.Input.Text
    if (-not $text.Trim()) { Clear-TranslatorOutput; return }
    $to = if ($Target) { $Target } else { $script:TrTarget }
    $script:TrPending = @{
        Text      = $text
        Source    = $script:TrSource
        Target    = $to
        Retry     = [bool]$Target
        Task      = [PcToolkit.Translator.Http]::Translate($text, $script:TrSource, $to, 'es')
    }
    $script:TrUi.Status.Text = 'Traduciendo...'
    $script:TrPoll.Start()
}

# Lo llama el reloj hasta que llega la respuesta de la última petición (las anteriores se descartan)
function script:Receive-Translation {
    $p = $script:TrPending
    if (-not $p) { $script:TrPoll.Stop(); return }
    if (-not $p.Task.IsCompleted) { return }
    $script:TrPoll.Stop()
    $script:TrPending = $null
    if ($p.Task.IsFaulted -or $p.Task.IsCanceled) {
        $err = if ($p.Task.Exception) { $p.Task.Exception.GetBaseException().Message } else { 'tiempo de espera agotado' }
        Write-TranslatorLog "ERROR: $err"
        $script:TrCopyWhenReady = $false
        $script:TrUi.Status.Text = 'No se pudo traducir. Comprueba la conexión a Internet.'
        return
    }
    $j = ConvertFrom-Json -InputObject $p.Task.Result
    $detected = [string]$j[2]
    if ($detected -eq 'he') { $detected = 'iw' }

    # Ya está en el idioma de destino: se traduce al alternativo
    if ($p.Source -eq 'auto' -and -not $p.Retry -and $detected -eq $p.Target -and $script:TrCfg.Alternative -ne $p.Target) {
        Start-Translation $script:TrCfg.Alternative
        return
    }

    $translation = -join @($j[0] | ForEach-Object { $_[0] })
    $script:TrUi.Output.Text = $translation
    $from = if ($p.Source -eq 'auto') { "$(Get-TranslatorLanguageName $detected) (detectado)" } else { Get-TranslatorLanguageName $p.Source }
    $script:TrUi.Status.Text = "$from  →  $(Get-TranslatorLanguageName $p.Target)"
    $script:TrLast = @{ Detected = $(if ($p.Source -eq 'auto') { $detected } else { $p.Source }); Target = $p.Target }

    # Palabras sueltas: otras traducciones por categoría (sustantivo, verbo...)
    $dict = $script:TrUi.Dictionary
    $dict.Children.Clear()
    foreach ($entry in @($j[1])) {
        if (-not $entry -or -not $entry[1]) { continue }
        $tb = New-Ui '<TextBlock Style="{StaticResource Caption}" Margin="0,2,0,0"/>'
        $pos = New-Object Windows.Documents.Run "$([string]$entry[0])   "
        $pos.FontWeight = 'SemiBold'
        $pos.Foreground = $app.Resources['TextBrush']
        $tb.Inlines.Add($pos)
        $tb.Inlines.Add((New-Object Windows.Documents.Run (@($entry[1] | Select-Object -First 8) -join ', ')))
        [void]$dict.Children.Add($tb)
    }
    $dict.Visibility = if ($dict.Children.Count) { 'Visible' } else { 'Collapsed' }

    # "Copiar y cerrar" pulsado mientras traducía: se hace ahora
    if ($script:TrCopyWhenReady) {
        $script:TrCopyWhenReady = $false
        if (Copy-Translation) { Hide-Translator }
    }
}

function script:Copy-Translation {
    $text = $script:TrUi.Output.Text
    if (-not $text) { return $false }
    try { [Windows.Clipboard]::SetText($text); $true }
    catch { $script:TrUi.Status.Text = 'No se pudo copiar: el portapapeles está ocupado.'; $false }
}

# Intercambia idiomas: la traducción pasa a ser el texto original
function script:Switch-TranslatorLanguages {
    $from = if ($script:TrSource -ne 'auto') { $script:TrSource } elseif ($script:TrLast) { $script:TrLast.Detected } else { return }
    $to   = if ($script:TrLast) { $script:TrLast.Target } else { $script:TrTarget }
    if (-not $script:TranslatorLanguages.Contains($from) -or $from -eq $to) { return }
    $script:TrSource = $to
    $script:TrTarget = $from
    Update-TranslatorPickers
    if ($script:TrUi.Output.Text) { $script:TrUi.Input.Text = $script:TrUi.Output.Text }   # TextChanged ya traduce
    Start-Translation
    [void]$script:TrUi.Input.Focus()
    $script:TrUi.Input.CaretIndex = $script:TrUi.Input.Text.Length
}

# Abajo a la derecha, en la esquina (salvo que se haya arrastrado a otro sitio)
function script:Move-Translator {
    if ($script:TrMoved) { return }
    $wa = [Windows.SystemParameters]::WorkArea
    $script:TrWin.Left = $wa.Right - $script:TrWin.ActualWidth - 12
    $script:TrWin.Top  = $wa.Bottom - $script:TrWin.ActualHeight - 12
}

function script:Show-Translator {
    $w = $script:TrWin
    $script:TrCfg = Get-TranslatorConfig
    # Cada vez que se abre: los idiomas por defecto de los ajustes
    $changed = $script:TrSource -ne $script:TrCfg.Source -or $script:TrTarget -ne $script:TrCfg.Target
    $script:TrSource = $script:TrCfg.Source
    $script:TrTarget = $script:TrCfg.Target
    Update-TranslatorPickers
    $w.Show()
    # Lanzado oculto (run-hidden.vbs), Windows aplica SW_HIDE al primer ShowWindow del proceso: se repite
    [void][Native]::ShowWindow((New-Object Windows.Interop.WindowInteropHelper $w).Handle, 5)
    $w.UpdateLayout()
    Move-Translator
    [void]$w.Activate()
    [void]$script:TrUi.Input.Focus()
    $script:TrUi.Input.SelectAll()   # escribir directamente sustituye el texto anterior
    # Si han cambiado los idiomas, se vuelve a traducir lo que haya
    if ($changed -and $script:TrUi.Input.Text.Trim()) { Start-Translation }
}

function script:Hide-Translator {
    $script:TrWin.Hide()
}

function script:Switch-Translator {
    if ($script:TrWin.IsVisible -and $script:TrWin.IsActive) { Hide-Translator } else { Show-Translator }
}

# --- Creación de la ventana (una sola vez) ---

if (-not $script:TrWin) {
    $script:TrWin = ConvertFrom-Xaml (Get-Content (Join-Path $PSScriptRoot 'window.xaml') -Raw -Encoding UTF8)
    $script:TrUi = @{}
    foreach ($n in 'Header', 'Close', 'SourceHost', 'Swap', 'TargetHost', 'Input', 'Output', 'Dictionary', 'Status', 'Copy') {
        $script:TrUi[$n] = $script:TrWin.FindName($n)
    }
    $script:TrSource  = $script:TrCfg.Source
    $script:TrPending = $null
    $script:TrLast    = $null
    $script:TrMoved   = $false
    $script:TrCfg     = Get-TranslatorConfig
    $script:TrTarget  = $script:TrCfg.Target

    if (-not $glass) { [Windows.Shell.WindowChrome]::GetWindowChrome($script:TrWin).GlassFrameThickness = 0 }
    $script:TrWin.Add_SourceInitialized({
        $hwnd = (New-Object Windows.Interop.WindowInteropHelper $script:TrWin).Handle
        [Native]::RemoveSystemMenu($hwnd)
        [Native]::SetDwm($hwnd, 20, [int]$dark)   # DWMWA_USE_IMMERSIVE_DARK_MODE
        [Native]::SetDwm($hwnd, 33, 2)            # esquinas redondeadas
        if ($glass) {
            [Windows.Interop.HwndSource]::FromHwnd($hwnd).CompositionTarget.BackgroundColor = [Windows.Media.Colors]::Transparent
            [Native]::SetDwm($hwnd, 38, 3)        # acrílico
        }
    })

    # Pausa tras la última tecla antes de traducir, y reloj que espera la respuesta
    $script:TrDebounce = New-Object Windows.Threading.DispatcherTimer
    $script:TrDebounce.Interval = [TimeSpan]::FromMilliseconds(450)
    $script:TrDebounce.Add_Tick({ Start-Translation })
    $script:TrPoll = New-Object Windows.Threading.DispatcherTimer
    $script:TrPoll.Interval = [TimeSpan]::FromMilliseconds(60)
    $script:TrPoll.Add_Tick({
        try { Receive-Translation }
        catch { Write-TranslatorLog "ERROR: $($_.Exception.Message)"; $script:TrUi.Status.Text = 'No se pudo leer la traducción.' }
    })

    $script:TrUi.Input.Add_TextChanged({
        if ($script:TrUi.Input.Text.Trim()) { $script:TrDebounce.Stop(); $script:TrDebounce.Start() }
        else { $script:TrDebounce.Stop(); Clear-TranslatorOutput }
    })
    $script:TrUi.Input.Add_PreviewKeyDown({
        param($s, $e)
        if ($e.Key -ne 'Return') { return }
        $mods = [Windows.Input.Keyboard]::Modifiers
        if ($mods -band [Windows.Input.ModifierKeys]::Shift) { return }   # nueva línea
        $e.Handled = $true
        if ($mods -band [Windows.Input.ModifierKeys]::Control) {
            # Copiar y cerrar (si aún está traduciendo, se espera a que termine con lo que haya)
            if ($script:TrDebounce.IsEnabled) { Start-Translation }
            if ($script:TrPending) { $script:TrCopyWhenReady = $true }
            elseif (Copy-Translation) { Hide-Translator }
        } else { Start-Translation }
    })
    $script:TrWin.Add_PreviewKeyDown({
        param($s, $e)
        $key = [string]$(if ($e.Key -eq 'System') { $e.SystemKey } else { $e.Key })
        $mods = [Windows.Input.Keyboard]::Modifiers
        if ($key -eq 'Escape') {
            $e.Handled = $true
            $open = @($script:TrUi.SourceHost.Content, $script:TrUi.TargetHost.Content | ForEach-Object { $_.FindName('Menu') } | Where-Object IsOpen)
            if ($open) { foreach ($m in $open) { $m.IsOpen = $false }; [void]$script:TrUi.Input.Focus() } else { Hide-Translator }
        } elseif ($key -eq 'S' -and $mods -eq ([Windows.Input.ModifierKeys]::Control -bor [Windows.Input.ModifierKeys]::Shift)) {
            $e.Handled = $true
            Switch-TranslatorLanguages
        }
    })

    $script:TrUi.Copy.Add_Click({ if (Copy-Translation) { $script:TrUi.Status.Text = 'Traducción copiada al portapapeles' } })
    $script:TrUi.Swap.Add_Click({ Switch-TranslatorLanguages })
    $script:TrUi.Close.Add_Click({ Hide-Translator })
    # Arrastrar por la cabecera; si se ha movido, se queda ahí hasta cerrar el gestor
    $script:TrUi.Header.Add_MouseLeftButtonDown({
        $before = "$($script:TrWin.Left),$($script:TrWin.Top)"
        $script:TrWin.DragMove()
        if ("$($script:TrWin.Left),$($script:TrWin.Top)" -ne $before) { $script:TrMoved = $true }
    })
    $script:TrWin.Add_SizeChanged({ Move-Translator })   # al crecer, sigue pegada a la esquina
    $script:TrWin.Add_Deactivated({
        $script:TrCopyWhenReady = $false
        if ($script:TrCfg.CloseOnBlur) { Hide-Translator }
    })
}
