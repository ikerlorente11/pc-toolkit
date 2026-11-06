# window.ps1 - Ventana de búsqueda de Everything. Se carga con "." dentro del gestor (atajo, portada y página
# de ajustes); la ventana se crea una sola vez y después solo se muestra u oculta, así que abre al instante.
# Busca mientras se escribe en el índice de Everything (por su IPC, ver Everything.cs) y abre el resultado,
# su ubicación o copia su ruta con el teclado. Sale arriba, centrada, como el buscador de Windows.

. (Join-Path $PSScriptRoot 'common.ps1')

if (-not ('PcToolkit.Everything.Client' -as [type])) {
    $refs = [Windows.Interop.HwndSource].Assembly.Location, [Windows.Threading.Dispatcher].Assembly.Location
    Add-Type -Path (Join-Path $PSScriptRoot 'Everything.cs') -ReferencedAssemblies $refs
}

$script:EvMaxResults = 100

function script:Set-EverythingStatus([string]$Text, [switch]$Start) {
    $script:EvUi.Status.Text = $Text
    $script:EvUi.StartEverything.Visibility = if ($Start) { 'Visible' } else { 'Collapsed' }
}

function script:Clear-EverythingResults {
    $script:EvUi.List.ItemsSource = $null
    $script:EvUi.List.Visibility = 'Collapsed'
    $script:EvUi.Actions.Visibility = 'Collapsed'
    Set-EverythingStatus ''
}

# Lanza la búsqueda (sin esperar: la respuesta llega con el evento Completed del cliente)
function script:Start-EverythingSearch {
    $script:EvDebounce.Stop()
    $script:EvRetry.Stop()
    $text = $script:EvUi.Input.Text.Trim()
    if (-not $text) { Clear-EverythingResults; return }
    if (-not [PcToolkit.Everything.Client]::IsRunning) {
        $msg = if (Get-EverythingExe) { 'Everything no está en marcha.' } else { 'Everything no está instalado.' }
        Set-EverythingStatus $msg -Start:([bool](Get-EverythingExe))
        $script:EvRetry.Start()
        return
    }
    if (-not [PcToolkit.Everything.Client]::IsDbLoaded) {
        Set-EverythingStatus 'Everything está cargando su índice...'
        $script:EvRetry.Start()
        return
    }
    $query = if ($script:EvCfg.Folders) { $text } else { "file: $text" }
    if ($script:EvCfg.HideRecycleBin) { $query += ' !"$recycle.bin\"' }   # lo que hay dentro de la papelera
    $flags = if ($script:EvCfg.MatchPath) { [PcToolkit.Everything.Client]::MatchPath } else { [uint32]0 }
    $sort  = [uint32]$script:EverythingSorts[$script:EvCfg.Sort][1]
    if (-not $script:EvClient.Search($query, $flags, $sort, $script:EvMaxResults)) {
        Set-EverythingStatus 'Everything no responde.'
        $script:EvRetry.Start()
    }
}

function script:Receive-EverythingResults {
    if (-not $script:EvUi.Input.Text.Trim()) { return }   # se borró el texto mientras buscaba
    $results = $script:EvClient.Results
    $list = $script:EvUi.List
    $list.ItemsSource = $results
    $any = $results.Count -gt 0
    $list.Visibility = if ($any) { 'Visible' } else { 'Collapsed' }
    $script:EvUi.Actions.Visibility = if ($any) { 'Visible' } else { 'Collapsed' }
    if ($any) { $list.SelectedIndex = 0; $list.ScrollIntoView($results[0]) }
    $total = $script:EvClient.Total
    Set-EverythingStatus $(
        if ($total -eq 0) { 'Sin resultados' }
        elseif ($total -eq 1) { '1 resultado' }
        elseif ($total -gt $results.Count) { '{0:N0} resultados (se muestran los {1} primeros)' -f $total, $results.Count }
        else { '{0:N0} resultados' -f $total })
}

function script:Move-EverythingSelection([int]$Delta) {
    $list = $script:EvUi.List
    $n = $list.Items.Count
    if (-not $n) { return }
    $list.SelectedIndex = [Math]::Max(0, [Math]::Min($n - 1, $list.SelectedIndex + $Delta))
    $list.ScrollIntoView($list.SelectedItem)
}

# Abre el resultado elegido (o su ubicación, o como administrador) y cierra la ventana
function script:Open-EverythingResult([switch]$Location, [switch]$Admin) {
    $it = $script:EvUi.List.SelectedItem
    if (-not $it) { return }
    try {
        if ($Location -and $it.IsDrive) {
            [void][Diagnostics.Process]::Start('explorer.exe', "`"$($it.FullPath)`"")
        } elseif ($Location) {
            [void][Diagnostics.Process]::Start('explorer.exe', "/select,`"$($it.FullPath)`"")
        } else {
            $psi = New-Object Diagnostics.ProcessStartInfo $it.FullPath
            $psi.UseShellExecute = $true
            if (-not $it.IsFolder -and $it.Folder) { $psi.WorkingDirectory = $it.Folder }
            if ($Admin) { $psi.Verb = 'runas' }
            [void][Diagnostics.Process]::Start($psi)
        }
        Hide-Everything
    } catch {
        $inner = $_.Exception.GetBaseException()
        if ($inner -is [ComponentModel.Win32Exception] -and $inner.NativeErrorCode -eq 1223) { return }   # UAC rechazado
        Write-EverythingLog "ERROR al abrir $($it.FullPath): $($inner.Message)"
        Set-EverythingStatus "No se pudo abrir: $($inner.Message)"
    }
}

function script:Copy-EverythingPath {
    $it = $script:EvUi.List.SelectedItem
    if (-not $it) { return }
    try { [Windows.Clipboard]::SetText($it.FullPath); Set-EverythingStatus 'Ruta copiada al portapapeles' }
    catch { Set-EverythingStatus 'No se pudo copiar: el portapapeles está ocupado.' }
}

# Arriba y centrada en la pantalla principal (salvo que se haya arrastrado a otro sitio)
function script:Move-Everything {
    if ($script:EvMoved) { return }
    $wa = [Windows.SystemParameters]::WorkArea
    $script:EvWin.Left = $wa.Left + ($wa.Width - $script:EvWin.ActualWidth) / 2
    $script:EvWin.Top  = $wa.Top + $wa.Height * 0.16
}

function script:Show-Everything {
    $w = $script:EvWin
    $script:EvCfg = Get-EverythingConfig
    $w.Show()
    # Lanzado oculto (run-hidden.vbs), Windows aplica SW_HIDE al primer ShowWindow del proceso: se repite
    [void][Native]::ShowWindow((New-Object Windows.Interop.WindowInteropHelper $w).Handle, 5)
    $w.UpdateLayout()
    Move-Everything
    [void]$w.Activate()
    [void]$script:EvUi.Input.Focus()
    $script:EvUi.Input.SelectAll()   # escribir directamente sustituye la búsqueda anterior
    # La anterior se repite: los archivos (y quizá los ajustes) han podido cambiar
    if ($script:EvUi.Input.Text.Trim()) { Start-EverythingSearch }
}

function script:Hide-Everything {
    $script:EvRetry.Stop()
    $script:EvWin.Hide()
}

function script:Switch-Everything {
    if ($script:EvWin.IsVisible -and $script:EvWin.IsActive) { Hide-Everything } else { Show-Everything }
}

# --- Creación de la ventana (una sola vez) ---

if (-not $script:EvWin) {
    $script:EvWin = ConvertFrom-Xaml (Get-Content (Join-Path $PSScriptRoot 'window.xaml') -Raw -Encoding UTF8)
    $script:EvUi = @{}
    foreach ($n in 'Header', 'Close', 'Input', 'List', 'Status', 'StartEverything', 'Actions', 'OpenFolder', 'CopyPath') {
        $script:EvUi[$n] = $script:EvWin.FindName($n)
    }
    $script:EvCfg    = Get-EverythingConfig
    $script:EvMoved  = $false
    $script:EvClient = New-Object PcToolkit.Everything.Client
    $script:EvClient.Add_Completed({
        try { Receive-EverythingResults }
        catch { Write-EverythingLog "ERROR: $($_.Exception.Message)"; Set-EverythingStatus 'No se pudieron leer los resultados.' }
    })

    if (-not $glass) { [Windows.Shell.WindowChrome]::GetWindowChrome($script:EvWin).GlassFrameThickness = 0 }
    $script:EvWin.Add_SourceInitialized({
        $hwnd = (New-Object Windows.Interop.WindowInteropHelper $script:EvWin).Handle
        [Native]::RemoveSystemMenu($hwnd)
        [Native]::SetDwm($hwnd, 20, [int]$dark)   # DWMWA_USE_IMMERSIVE_DARK_MODE
        [Native]::SetDwm($hwnd, 33, 2)            # esquinas redondeadas
        if ($glass) {
            [Windows.Interop.HwndSource]::FromHwnd($hwnd).CompositionTarget.BackgroundColor = [Windows.Media.Colors]::Transparent
            [Native]::SetDwm($hwnd, 38, 3)        # acrílico
        }
    })

    # Pausa mínima tras cada tecla (Everything responde en milisegundos) y reintento mientras Everything
    # arranca o carga su índice
    $script:EvDebounce = New-Object Windows.Threading.DispatcherTimer
    $script:EvDebounce.Interval = [TimeSpan]::FromMilliseconds(60)
    $script:EvDebounce.Add_Tick({ Start-EverythingSearch })
    $script:EvRetry = New-Object Windows.Threading.DispatcherTimer
    $script:EvRetry.Interval = [TimeSpan]::FromMilliseconds(800)
    $script:EvRetry.Add_Tick({
        if ([PcToolkit.Everything.Client]::IsRunning -and [PcToolkit.Everything.Client]::IsDbLoaded) { Start-EverythingSearch }
    })

    $script:EvUi.Input.Add_TextChanged({
        if ($script:EvUi.Input.Text.Trim()) { $script:EvDebounce.Stop(); $script:EvDebounce.Start() }
        else { $script:EvDebounce.Stop(); $script:EvRetry.Stop(); Clear-EverythingResults }
    })
    $script:EvWin.Add_PreviewKeyDown({
        param($s, $e)
        $key = [string]$(if ($e.Key -eq 'System') { $e.SystemKey } else { $e.Key })
        $mods = [Windows.Input.Keyboard]::Modifiers
        $ctrl  = [bool]($mods -band [Windows.Input.ModifierKeys]::Control)
        $shift = [bool]($mods -band [Windows.Input.ModifierKeys]::Shift)
        $handled = $true
        switch ($key) {
            'Escape'   { Hide-Everything }
            'Down'     { Move-EverythingSelection 1 }
            'Up'       { Move-EverythingSelection -1 }
            'PageDown' { Move-EverythingSelection 8 }
            'PageUp'   { Move-EverythingSelection -8 }
            'Return'   {
                if ($script:EvDebounce.IsEnabled) { $handled = $true; break }   # aún no han llegado los resultados de lo escrito
                if ($ctrl -and $shift) { Open-EverythingResult -Admin }
                elseif ($ctrl) { Open-EverythingResult -Location }
                else { Open-EverythingResult }
            }
            'C'        { if ($ctrl -and $shift) { Copy-EverythingPath } else { $handled = $false } }
            default    { $handled = $false }
        }
        if ($handled) { $e.Handled = $true }
    })

    # Doble clic en un resultado: abrirlo
    $script:EvUi.List.Add_MouseDoubleClick({
        param($s, $e)
        $el = $e.OriginalSource
        while ($el -and -not ($el -is [Windows.Controls.ListBoxItem])) { $el = [Windows.Media.VisualTreeHelper]::GetParent($el) }
        if ($el) { Open-EverythingResult }
    })
    # Clic en un resultado: el foco sigue en el cuadro de búsqueda para seguir escribiendo
    $script:EvUi.List.Add_PreviewMouseLeftButtonUp({ [void]$script:EvUi.Input.Focus() })

    $script:EvUi.OpenFolder.Add_Click({ Open-EverythingResult -Location })
    $script:EvUi.CopyPath.Add_Click({ Copy-EverythingPath })
    $script:EvUi.StartEverything.Add_Click({
        try {
            Start-EverythingClient
            Set-EverythingStatus 'Iniciando Everything...'
            $script:EvRetry.Start()
        } catch { Set-EverythingStatus $_.Exception.Message }
    })
    $script:EvUi.Close.Add_Click({ Hide-Everything })
    # Arrastrar por la cabecera; si se ha movido, se queda ahí hasta cerrar el gestor
    $script:EvUi.Header.Add_MouseLeftButtonDown({
        $before = "$($script:EvWin.Left),$($script:EvWin.Top)"
        $script:EvWin.DragMove()
        if ("$($script:EvWin.Left),$($script:EvWin.Top)" -ne $before) { $script:EvMoved = $true }
    })
    $script:EvWin.Add_Deactivated({ if ($script:EvCfg.CloseOnBlur) { Hide-Everything } })
}
