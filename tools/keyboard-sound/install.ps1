# install.ps1 - Instala Keyboard Sound (lo llaman el instalador global y el gestor)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\core\Toolkit.psm1')
. (Join-Path $PSScriptRoot 'common.ps1')

Register-KeyboardSoundTask (Get-KeyboardSoundConfig).StartWithWindows
