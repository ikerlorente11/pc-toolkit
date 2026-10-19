# home.ps1 - Cambio rápido en la tarjeta de Audio AutoSwitch de la portada del gestor.
# La carga el gestor igual que settings.ps1 y muestra lo que devuelve debajo de la tarjeta.

if (-not ('PcToolkit.Audio.Endpoints' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'AudioEndpoints.cs') }

# Repintar la portada cuando se enciende/apaga algo o cambia el que suena
$script:HomeSignatures['audio-autoswitch'] = { ([PcToolkit.Audio.Endpoints]::List(0) | ForEach-Object { "$($_.Id)$($_.IsDefault)" }) -join ';' }

$panel = New-Ui '<StackPanel Margin="30,8,0,0"/>'
foreach ($d in [PcToolkit.Audio.Endpoints]::List(0) | Where-Object { -not $_.IsHandsFree }) {
    [void]$panel.Children.Add((New-ChoiceRow $d.Name '' $d.IsDefault {
        param($id)
        [PcToolkit.Audio.Endpoints]::SetDefault($id)
        Update-Page
    } $d.Id -Compact))
}
$panel
