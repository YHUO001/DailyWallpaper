[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\Common.ps1')
. (Join-Path $PSScriptRoot 'lib\State.ps1')
. (Join-Path $PSScriptRoot 'lib\Weather.ps1')
. (Join-Path $PSScriptRoot 'lib\Wallhaven.ps1')
. (Join-Path $PSScriptRoot 'lib\WallpaperEngine.ps1')
. (Join-Path $PSScriptRoot 'lib\Workflow.ps1')

$paths = $null
$config = $null
$lock = $null
try {
    $projectRoot = Get-ProjectRoot -ScriptRoot $PSScriptRoot
    $paths = Get-DailyWallpaperPaths -ProjectRoot $projectRoot
    $config = Get-Config -Paths $paths
    Ensure-DirectoryStructure -Paths $paths

    $lock = Enter-DailyWallpaperLock
    if ($null -eq $lock) {
        Write-Host 'DailyWallpaper is already running; this invocation will exit without changing state.'
        exit 0
    }

    try {
        [void](Invoke-DailyUpdate -Config $config -Paths $paths)
    }
    finally {
        Exit-DailyWallpaperLock -Lock $lock
        $lock = $null
    }
}
catch {
    if ($null -ne $config -and $null -ne $paths) {
        Write-DailyWallpaperLog -Config $config -Paths $paths -Level 'ERROR' -Message $_.Exception.Message
    }
    Write-Error $_.Exception.Message
    if ($null -ne $lock) {
        Exit-DailyWallpaperLock -Lock $lock
    }
    exit 1
}

