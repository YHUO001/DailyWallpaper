Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# This file is dot-sourced after the core libraries. Keep the original
# implementations so the policy wrappers can add v1 invariants without
# duplicating the large modules.
$script:DailyWallpaperOriginalNewWallpaperPool = ${function:New-WallpaperPool}
$script:DailyWallpaperOriginalGetConfig = ${function:Get-Config}

function Get-Config {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Paths
    )

    if (-not (Test-Path -LiteralPath $Paths.Config -PathType Leaf)) {
        $examplePath = Join-Path $Paths.Root 'config.example.json'
        if (Test-Path -LiteralPath $examplePath -PathType Leaf) {
            Copy-Item -LiteralPath $examplePath -Destination $Paths.Config -Force
        }
    }

    return & $script:DailyWallpaperOriginalGetConfig -Paths $Paths
}

function New-WallpaperPool {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config,

        [Parameter(Mandatory = $true)]
        [object]$Scene,

        [AllowNull()]
        [object]$HistoryIds,

        [Parameter(Mandatory = $true)]
        [string]$ProjectRoot,

        [Parameter(Mandatory = $true)]
        [string]$CachePath,

        [Parameter(Mandatory = $true)]
        [string]$LogPath
    )

    $pool = & $script:DailyWallpaperOriginalNewWallpaperPool `
        -Config $Config `
        -Scene $Scene `
        -HistoryIds @($HistoryIds) `
        -ProjectRoot $ProjectRoot `
        -CachePath $CachePath `
        -LogPath $LogPath

    $items = @((Get-PropertyValue -Object $pool -Name 'items' -Default @()))
    if ($items.Count -ne 8) {
        throw "DailyWallpaper requires a complete eight-image pool; received $($items.Count)."
    }

    return $pool
}
