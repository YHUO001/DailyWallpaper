Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-History {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $data = Read-JsonSafe -Path $Path
    if ($null -eq $data) {
        return @()
    }
    if ($data -isnot [System.Array]) {
        throw "History state must be a JSON array: $Path"
    }

    return @($data)
}

function Prune-History {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [object[]]$Entries,

        [Parameter(Mandatory = $true)]
        [int]$RetentionDays,

        [DateTimeOffset]$Now = (Get-LocalNow)
    )

    $retention = [Math]::Max(1, $RetentionDays)
    $cutoff = $Now.Date.AddDays(-$retention)
    $kept = New-Object 'System.Collections.Generic.List[object]'
    $removed = 0
    foreach ($entry in @($Entries)) {
        $shownAtText = [string](Get-PropertyValue -Object $entry -Name 'shownAt' -Default '')
        $shownAt = [DateTimeOffset]::MinValue
        if ([DateTimeOffset]::TryParse($shownAtText, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeLocal, [ref]$shownAt)) {
            if ($shownAt.Date -lt $cutoff) {
                $removed++
                continue
            }
        }
        [void]$kept.Add($entry)
    }

    return [PSCustomObject]@{
        Entries = $kept.ToArray()
        RemovedCount = $removed
    }
}

function Add-HistoryEntry {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [object[]]$Entries,

        [Parameter(Mandatory = $true)]
        [string]$WallpaperId,

        [Parameter(Mandatory = $true)]
        [string]$ShownAt,

        [Parameter(Mandatory = $true)]
        [string]$Reason,

        [AllowNull()]
        [string]$Query
    )

    $result = New-Object 'System.Collections.Generic.List[object]'
    foreach ($entry in @($Entries)) {
        [void]$result.Add($entry)
        $entryId = [string](Get-PropertyValue -Object $entry -Name 'id' -Default '')
        $entryShownAt = [string](Get-PropertyValue -Object $entry -Name 'shownAt' -Default '')
        if ($entryId.Equals($WallpaperId, [StringComparison]::OrdinalIgnoreCase) -and $entryShownAt -eq $ShownAt) {
            return $result.ToArray()
        }
    }

    [void]$result.Add([PSCustomObject]@{
        id = $WallpaperId
        shownAt = $ShownAt
        reason = $Reason
        query = $Query
    })
    return $result.ToArray()
}

function Get-HistoryIds {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [object[]]$Entries
    )

    $ids = New-Object 'System.Collections.Generic.List[string]'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in @($Entries)) {
        $id = [string](Get-PropertyValue -Object $entry -Name 'id' -Default '')
        if (-not [string]::IsNullOrWhiteSpace($id) -and $seen.Add($id)) {
            [void]$ids.Add($id)
        }
    }
    return $ids.ToArray()
}

function Get-CurrentState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return Read-JsonSafe -Path $Path
}

function Set-CurrentState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [object]$State
    )

    Write-JsonAtomic -Path $Path -Data $State
}

function Get-Pool {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return Read-JsonSafe -Path $Path
}

function Set-Pool {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [object]$Pool
    )

    Write-JsonAtomic -Path $Path -Data $Pool
}

function Set-History {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [AllowEmptyCollection()]
        [object[]]$Entries
    )

    Write-JsonAtomic -Path $Path -Data @($Entries)
}

function Get-WeatherState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return Read-JsonSafe -Path $Path
}

function Set-WeatherState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [object]$State
    )

    Write-JsonAtomic -Path $Path -Data $State
}

function Get-NextPoolItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Pool,

        [AllowEmptyCollection()]
        [object[]]$HistoryEntries
    )

    $items = @((Get-PropertyValue -Object $Pool -Name 'items' -Default @()))
    if ($items.Count -eq 0) {
        return $null
    }

    $historyIds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in @($HistoryEntries)) {
        $entryId = [string](Get-PropertyValue -Object $entry -Name 'id' -Default '')
        if (-not [string]::IsNullOrWhiteSpace($entryId)) {
            [void]$historyIds.Add($entryId)
        }
    }

    $currentIndex = Get-ConfiguredInt -Object $Pool -Name 'index' -Default -1 -Minimum -1
    $firstIndex = [Math]::Max(0, $currentIndex + 1)
    for ($index = $firstIndex; $index -lt $items.Count; $index++) {
        $item = $items[$index]
        $itemId = [string](Get-PropertyValue -Object $item -Name 'id' -Default '')
        if (-not [string]::IsNullOrWhiteSpace($itemId) -and -not $historyIds.Contains($itemId)) {
            return [PSCustomObject]@{
                Index = $index
                Item = $item
            }
        }
    }

    return $null
}

function Test-PoolStructure {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Pool,

        [Parameter(Mandatory = $true)]
        [string]$ProjectRoot,

        [Parameter(Mandatory = $true)]
        [object]$Config
    )

    if ($null -eq $Pool) {
        return $false
    }
    $items = @((Get-PropertyValue -Object $Pool -Name 'items' -Default @()))
    if ($items.Count -eq 0) {
        return $false
    }

    $cacheRoot = [IO.Path]::GetFullPath((Join-Path $ProjectRoot 'cache')).TrimEnd('\') + '\'
    foreach ($item in $items) {
        $id = [string](Get-PropertyValue -Object $item -Name 'id' -Default '')
        $relativePath = [string](Get-PropertyValue -Object $item -Name 'file' -Default '')
        if ([string]::IsNullOrWhiteSpace($id) -or [string]::IsNullOrWhiteSpace($relativePath)) {
            return $false
        }
        try {
            $fullPath = Resolve-ProjectPath -ProjectRoot $ProjectRoot -Path $relativePath
        }
        catch {
            return $false
        }
        if (-not $fullPath.StartsWith($cacheRoot, [StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }
        if ($null -eq (Test-LocalWallpaperFile -Path $fullPath -Config $Config)) {
            return $false
        }
    }

    $index = Get-ConfiguredInt -Object $Pool -Name 'index' -Default -1 -Minimum -1
    return ($index -ge 0 -and $index -lt $items.Count)
}

function Clear-UnusedCache {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$CachePath,

        [AllowNull()]
        [object]$Pool,

        [AllowNull()]
        [object]$Current,

        [Parameter(Mandatory = $true)]
        [string]$ProjectRoot,

        [Parameter(Mandatory = $true)]
        [string]$LogPath
    )

    if (-not (Test-Path -LiteralPath $CachePath -PathType Container)) {
        return
    }

    $keep = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $gitKeep = Join-Path $CachePath '.gitkeep'
    [void]$keep.Add([IO.Path]::GetFullPath($gitKeep))
    foreach ($item in @((Get-PropertyValue -Object $Pool -Name 'items' -Default @()))) {
        $relativePath = [string](Get-PropertyValue -Object $item -Name 'file' -Default '')
        if (-not [string]::IsNullOrWhiteSpace($relativePath)) {
            try {
                [void]$keep.Add([IO.Path]::GetFullPath((Resolve-ProjectPath -ProjectRoot $ProjectRoot -Path $relativePath)))
            }
            catch {
                # Invalid state is handled by the caller; do not delete broadly.
            }
        }
    }

    $currentFile = [string](Get-PropertyValue -Object $Current -Name 'file' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($currentFile)) {
        try {
            [void]$keep.Add([IO.Path]::GetFullPath((Resolve-ProjectPath -ProjectRoot $ProjectRoot -Path $currentFile)))
        }
        catch {
        }
    }

    foreach ($file in @(Get-ChildItem -LiteralPath $CachePath -File -ErrorAction SilentlyContinue)) {
        $fullPath = [IO.Path]::GetFullPath($file.FullName)
        if (-not $keep.Contains($fullPath)) {
            try {
                Remove-Item -LiteralPath $fullPath -Force
            }
            catch {
                Write-Log -Path $LogPath -Level 'WARN' -Message "Cache cleanup failed for '$fullPath': $($_.Exception.Message)"
            }
        }
    }
}
