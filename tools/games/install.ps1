# install.ps1 - Instala Juegos (lo llaman el instalador global y el gestor)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\core\Toolkit.psm1')
. (Join-Path $PSScriptRoot 'common.ps1')

Register-GamesTask
