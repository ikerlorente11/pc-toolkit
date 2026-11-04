# settings.ps1 - Página de ajustes del Traductor dentro del gestor: idiomas y comportamiento de la ventana.

. (Join-Path $PSScriptRoot 'common.ps1')

$cfg   = Get-TranslatorConfig
$panel = New-Ui '<StackPanel/>'

$open = New-Ui @'
<Button Style="{StaticResource AccentButton}" HorizontalAlignment="Left" Margin="0,4,0,0" AutomationProperties.Name="Abrir traductor">
  <StackPanel Orientation="Horizontal">
    <TextBlock Style="{StaticResource Icon}" Text="&#xF2B7;" FontSize="13" Foreground="{StaticResource OnAccentBrush}"/>
    <TextBlock Text="Abrir traductor" Margin="8,0,0,0" VerticalAlignment="Center"/>
  </StackPanel>
</Button>
'@
$open.Add_Click({
    Invoke-Safe {
        . (Join-Path $script:TranslatorDir 'window.ps1')
        Show-Translator   # al activarse, el panel se oculta solo
    }
})
[void]$panel.Children.Add($open)

# Fila con un texto a la izquierda y el selector de idioma a la derecha
function script:New-TranslatorLanguageRow([string]$Title, [string]$Detail, [string]$Setting, [switch]$Auto) {
    $row = New-Ui @'
<Border Style="{StaticResource Card}" Padding="14,6,6,6">
  <Grid>
    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="170"/></Grid.ColumnDefinitions>
    <StackPanel VerticalAlignment="Center" Margin="0,0,12,0">
      <TextBlock x:Name="T" Style="{StaticResource Body}"/>
      <TextBlock x:Name="D" Style="{StaticResource Caption}"/>
    </StackPanel>
    <ContentControl x:Name="Picker" Grid.Column="1" Focusable="False" VerticalAlignment="Center"/>
  </Grid>
</Border>
'@
    $row.FindName('T').Text = $Title
    if ($Detail) { $row.FindName('D').Text = $Detail } else { $row.FindName('D').Visibility = 'Collapsed' }
    $onPick = [scriptblock]::Create("param(`$code) Set-TranslatorSetting '$Setting' `$code; Update-Page")
    $row.FindName('Picker').Content = New-TranslatorLanguagePicker (Get-TranslatorConfig)[$Setting] $onPick $Title -Auto:$Auto
    $row
}

[void]$panel.Children.Add((New-SectionHeader 'Idiomas por defecto' 'Con los que empieza la ventana cada vez que se abre; en ella se pueden cambiar para ese momento.'))
[void]$panel.Children.Add((New-TranslatorLanguageRow 'Traducir desde' '' 'Source' -Auto))
[void]$panel.Children.Add((New-TranslatorLanguageRow 'Traducir a' '' 'Target'))
$alt = New-TranslatorLanguageRow 'Si ya está en ese idioma, a' 'Por ejemplo, del español al inglés.' 'Alternative'
$alt.IsEnabled = $cfg.Source -eq 'auto'
[void]$panel.Children.Add($alt)

[void]$panel.Children.Add((New-SectionHeader 'Ventana'))
[void]$panel.Children.Add((New-ToggleRow 'Cerrar al hacer clic fuera' 'La ventana se oculta al pasar a otra aplicación. El texto se conserva para la próxima vez.' $cfg.CloseOnBlur {
    param($a, $on)
    Set-TranslatorSetting 'CloseOnBlur' $on
    if ($script:TrCfg) { $script:TrCfg.CloseOnBlur = $on }
} $null))

$panel
