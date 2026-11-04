# common.ps1 - Idiomas, configuración y selector de idioma del Traductor. Lo cargan con "." window.ps1,
# settings.ps1 y home.ps1 (todos dentro del gestor). Funciones "script:" para que sigan vivas en los
# botones y en la ventana del traductor.

if (-not ('PcToolkit.Translator.Http' -as [type])) {
    Add-Type -AssemblyName System.Net.Http
    Add-Type -Path (Join-Path $PSScriptRoot 'Translator.cs') -ReferencedAssemblies ([System.Net.Http.HttpClient].Assembly.Location)
}
$script:TranslatorDir  = $PSScriptRoot
$script:TranslatorData = Join-Path $env:LOCALAPPDATA 'PcToolkit\data\translator'

# Idiomas (código de Google -> nombre), por orden alfabético del nombre
$script:TranslatorLanguages = [ordered]@{
    de = 'Alemán';  ar = 'Árabe';  bg = 'Búlgaro';  ca = 'Catalán';  cs = 'Checo'
    'zh-CN' = 'Chino (simplificado)';  'zh-TW' = 'Chino (tradicional)';  ko = 'Coreano';  hr = 'Croata'
    da = 'Danés';  sk = 'Eslovaco';  es = 'Español';  eu = 'Euskera';  fi = 'Finés';  fr = 'Francés'
    gl = 'Gallego';  el = 'Griego';  iw = 'Hebreo';  hi = 'Hindi';  hu = 'Húngaro';  id = 'Indonesio'
    en = 'Inglés';  ga = 'Irlandés';  it = 'Italiano';  ja = 'Japonés';  la = 'Latín';  nl = 'Neerlandés'
    no = 'Noruego';  fa = 'Persa';  pl = 'Polaco';  pt = 'Portugués';  ro = 'Rumano';  ru = 'Ruso'
    sv = 'Sueco';  th = 'Tailandés';  tr = 'Turco';  uk = 'Ucraniano';  vi = 'Vietnamita'
}

function script:Get-TranslatorLanguageName([string]$Code) {
    if ($Code -eq 'auto') { return 'Detectar idioma' }
    if ($Code -eq 'he') { $Code = 'iw' }
    if ($script:TranslatorLanguages.Contains($Code)) { $script:TranslatorLanguages[$Code] } else { $Code.ToUpper() }
}

function script:Get-TranslatorConfig {
    $path = Join-Path $script:TranslatorData 'config.json'
    $c = if (Test-Path $path) { try { Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }
    # Por defecto: al idioma de Windows (o español) y, si el texto ya está en él, a inglés (o español)
    $ui = [Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName
    $target = if ($script:TranslatorLanguages.Contains([string]$c.Target)) { [string]$c.Target }
              elseif ($script:TranslatorLanguages.Contains($ui)) { $ui } else { 'es' }
    $source = if ([string]$c.Source -eq 'auto' -or $script:TranslatorLanguages.Contains([string]$c.Source)) { [string]$c.Source } else { 'auto' }
    $alt = if ($script:TranslatorLanguages.Contains([string]$c.Alternative)) { [string]$c.Alternative }
           elseif ($target -ne 'en') { 'en' } else { 'es' }
    @{
        Source      = $source
        Target      = $target
        Alternative = $alt
        CloseOnBlur = if ($null -ne $c.CloseOnBlur) { [bool]$c.CloseOnBlur } else { $true }
    }
}

function script:Save-TranslatorConfig($Config) {
    New-Item -ItemType Directory -Force -Path $script:TranslatorData | Out-Null
    $Config | ConvertTo-Json | Set-Content (Join-Path $script:TranslatorData 'config.json') -Encoding UTF8
}

function script:Set-TranslatorSetting([string]$Name, $Value) {
    $cfg = Get-TranslatorConfig
    $cfg[$Name] = $Value
    Save-TranslatorConfig $cfg
}

# Sin tildes y en minúsculas, para buscar "frances" o "aleman"
function script:ConvertTo-TranslatorSearchText([string]$Text) {
    $d = $Text.ToLowerInvariant().Normalize([Text.NormalizationForm]::FormD)
    -join ($d.ToCharArray() | Where-Object { [Globalization.CharUnicodeInfo]::GetUnicodeCategory($_) -ne 'NonSpacingMark' })
}

# Botón con el idioma elegido; al pulsarlo se despliega la lista con un buscador.
# Al elegir uno: & $OnPick <código>. Con -Auto, la lista empieza por "Detectar idioma".
function script:New-TranslatorLanguagePicker([string]$Current, [scriptblock]$OnPick, [string]$Label, [switch]$Auto, [switch]$Card) {
    $xaml = @'
<Grid>
  <Button x:Name="Pick" Style="{StaticResource SubtleButton}" HorizontalContentAlignment="Stretch" Padding="10,6">
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <TextBlock x:Name="Value" FontSize="13" Foreground="{StaticResource TextBrush}" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
      <TextBlock Grid.Column="1" Style="{StaticResource Icon}" Text="&#xE70D;" FontSize="10" Margin="10,0,0,0" Foreground="{StaticResource SubBrush}"/>
    </Grid>
  </Button>
  <Popup x:Name="Menu" PlacementTarget="{Binding ElementName=Pick}" Placement="Bottom" StaysOpen="False"
         AllowsTransparency="True" PopupAnimation="Fade" VerticalOffset="4">
    <Border Background="{StaticResource OsdBrush}" BorderBrush="{StaticResource StrokeBrush}" BorderThickness="1" CornerRadius="8" Padding="4">
      <StackPanel>
        <TextBox x:Name="Search" Style="{StaticResource Input}" Tag="Buscar idioma" Margin="2,2,2,4" AutomationProperties.Name="Buscar idioma"/>
        <ScrollViewer MaxHeight="260" VerticalScrollBarVisibility="Auto">
          <StackPanel x:Name="List"/>
        </ScrollViewer>
      </StackPanel>
    </Border>
  </Popup>
</Grid>
'@
    if ($Card) { $xaml = "<Border Style=`"{StaticResource Card}`" Padding=`"4`">$xaml</Border>" }
    $root = New-Ui $xaml
    $pick = $root.FindName('Pick')
    $menu = $root.FindName('Menu')
    $list = $root.FindName('List')
    $search = $root.FindName('Search')
    $root.FindName('Value').Text = Get-TranslatorLanguageName $Current
    [Windows.Automation.AutomationProperties]::SetName($pick, "$Label`: $(Get-TranslatorLanguageName $Current)")

    $codes = @($script:TranslatorLanguages.Keys)
    if ($Auto) { $codes = @('auto') + $codes }
    $choose = { param($a) $a.Menu.IsOpen = $false; & $a.OnPick $a.Code }
    foreach ($code in $codes) {
        $name = Get-TranslatorLanguageName $code
        $row = New-ChoiceRow $name '' ($code -eq $Current) $choose @{ Menu = $menu; OnPick = $OnPick; Code = $code } -Compact
        $row.Uid = ConvertTo-TranslatorSearchText $name
        [void]$list.Children.Add($row)
    }

    # Buscador: filtra al escribir; Intro elige el primero que quede
    $search.Tag = 'Buscar idioma'
    $search.Add_TextChanged({
        param($s, $e)
        $q = ConvertTo-TranslatorSearchText $s.Text
        foreach ($r in $s.Parent.Children[1].Content.Children) { $r.Visibility = if ($r.Uid -like "*$q*") { 'Visible' } else { 'Collapsed' } }
    })
    $search.Add_PreviewKeyDown({
        param($s, $e)
        if ($e.Key -ne 'Return') { return }
        $e.Handled = $true
        $first = @($s.Parent.Children[1].Content.Children | Where-Object { $_.Visibility -eq 'Visible' })[0]
        if ($first) { Invoke-Safe { & $first.Tag.Action $first.Tag.Arg } }
    })

    $pick.Tag = $menu
    $pick.Add_Click({
        param($s, $e)
        $e.Handled = $true   # que no abra la página de la herramienta si está en una tarjeta
        $m = $s.Tag
        $m.Child.Width = [Math]::Max($s.ActualWidth, 240)
        $m.IsOpen = -not $m.IsOpen
        if ($m.IsOpen) {
            $box = $m.Child.Child.Children[0]
            $box.Text = ''
            [void]$box.Dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::Input, [Action]({ [void]$box.Focus() }.GetNewClosure()))
        }
    })
    $root
}
