Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-WallhavenSearchUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config,

        [Parameter(Mandatory = $true)]
        [string]$Query,

        [Parameter(Mandatory = $true)]
        [int]$Page,

        [AllowNull()]
        [string]$Seed
    )

    $image = Get-PropertyValue -Object $Config -Name 'image'
    $pool = Get-PropertyValue -Object $Config -Name 'pool'
    $wallhaven = Get-PropertyValue -Object $Config -Name 'wallhaven'
    $baseUrl = [string](Get-PropertyValue -Object $wallhaven -Name 'baseUrl' -Default 'https://wallhaven.cc/api/v1')
    $baseUrl = $baseUrl.TrimEnd('/')
    $minimumWidth = Get-ConfiguredInt -Object $image -Name 'minimumWidth' -Default 3840 -Minimum 1
    $minimumHeight = Get-ConfiguredInt -Object $image -Name 'minimumHeight' -Default 2160 -Minimum 1
    $aspectRatio = [string](Get-PropertyValue -Object $image -Name 'aspectRatio' -Default '16x9')
    $categories = [string](Get-PropertyValue -Object $image -Name 'categories' -Default '100')
    $purity = [string](Get-PropertyValue -Object $image -Name 'purity' -Default '100')
    $sorting = [string](Get-PropertyValue -Object $wallhaven -Name 'sorting' -Default 'random')
    if ([string]::IsNullOrWhiteSpace($sorting)) {
        $sorting = 'random'
    }

    $parameters = New-Object 'System.Collections.Generic.List[string]'
    [void]$parameters.Add('atleast=' + [Uri]::EscapeDataString("${minimumWidth}x${minimumHeight}"))
    [void]$parameters.Add('ratios=' + [Uri]::EscapeDataString($aspectRatio))
    [void]$parameters.Add('purity=' + [Uri]::EscapeDataString($purity))
    [void]$parameters.Add('categories=' + [Uri]::EscapeDataString($categories))
    [void]$parameters.Add('sorting=' + [Uri]::EscapeDataString($sorting))
    [void]$parameters.Add('page=' + [string]$Page)
    if (-not [string]::IsNullOrWhiteSpace($Query)) {
        [void]$parameters.Add('q=' + [Uri]::EscapeDataString($Query))
    }
    if (-not [string]::IsNullOrWhiteSpace($Seed)) {
        [void]$parameters.Add('seed=' + [Uri]::EscapeDataString($Seed))
    }

    $apiKey = [string](Get-PropertyValue -Object $wallhaven -Name 'apiKey' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($apiKey)) {
        [void]$parameters.Add('apikey=' + [Uri]::EscapeDataString($apiKey))
    }

    return "$baseUrl/search?$(($parameters -join '&'))"
}

function Get-WallhavenCandidates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config,

        [Parameter(Mandatory = $true)]
        [string]$Query,

        [int]$TargetCount = 72
    )

    $pool = Get-PropertyValue -Object $Config -Name 'pool'
    $schedule = Get-PropertyValue -Object $Config -Name 'schedule'
    $requestedTarget = [Math]::Max(1, $TargetCount)
    $maxPages = Get-ConfiguredInt -Object $pool -Name 'maxSearchPages' -Default 5 -Minimum 1
    $timeoutSeconds = Get-ConfiguredInt -Object $schedule -Name 'requestTimeoutSeconds' -Default 30 -Minimum 1
    $results = New-Object 'System.Collections.Generic.List[object]'
    $seenIds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $seed = $null
    $page = 1

    while ($page -le $maxPages -and $results.Count -lt $requestedTarget) {
        $uri = Get-WallhavenSearchUri -Config $Config -Query $Query -Page $page -Seed $seed
        $response = Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec $timeoutSeconds
        if ($null -eq $response) {
            throw "Wallhaven returned an empty response for query '$Query'."
        }

        if ($null -eq $seed) {
            $meta = Get-PropertyValue -Object $response -Name 'meta'
            $returnedSeed = Get-PropertyValue -Object $meta -Name 'seed'
            if ($null -ne $returnedSeed) {
                $seed = [string]$returnedSeed
            }
        }

        $data = @((Get-PropertyValue -Object $response -Name 'data' -Default @()))
        foreach ($candidate in $data) {
            $id = [string](Get-PropertyValue -Object $candidate -Name 'id' -Default '')
            if (-not [string]::IsNullOrWhiteSpace($id) -and $seenIds.Add($id)) {
                [void]$results.Add($candidate)
            }
        }

        $meta = Get-PropertyValue -Object $response -Name 'meta'
        $lastPage = Get-ConfiguredInt -Object $meta -Name 'last_page' -Default $page -Minimum 1
        if ($page -ge $lastPage -or $data.Count -eq 0) {
            break
        }
        $page++
    }

    return $results.ToArray()
}

function Get-WallpaperDimensionsFromCandidate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Candidate
    )

    $width = 0
    $height = 0
    $widthValue = Get-PropertyValue -Object $Candidate -Name 'dimension_x' -Default 0
    $heightValue = Get-PropertyValue -Object $Candidate -Name 'dimension_y' -Default 0
    $widthParsed = [int]::TryParse([string]$widthValue, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$width)
    $heightParsed = [int]::TryParse([string]$heightValue, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$height)

    if (-not $widthParsed -or -not $heightParsed -or $width -le 0 -or $height -le 0) {
        $resolution = [string](Get-PropertyValue -Object $Candidate -Name 'resolution' -Default '')
        if ($resolution -match '^(?<width>\d+)\s*x\s*(?<height>\d+)$') {
            $width = [int]$Matches['width']
            $height = [int]$Matches['height']
        }
    }

    return [PSCustomObject]@{
        Width = $width
        Height = $height
    }
}

function Test-WallpaperCandidate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Candidate,

        [Parameter(Mandatory = $true)]
        [object]$Config
    )

    $image = Get-PropertyValue -Object $Config -Name 'image'
    $id = [string](Get-PropertyValue -Object $Candidate -Name 'id' -Default '')
    $path = [string](Get-PropertyValue -Object $Candidate -Name 'path' -Default '')
    if ([string]::IsNullOrWhiteSpace($id) -or $id -notmatch '^[A-Za-z0-9_-]+$' -or [string]::IsNullOrWhiteSpace($path)) {
        return $false
    }

    $sourceUri = $null
    try {
        $sourceUri = [Uri]$path
    }
    catch {
        return $false
    }
    if ($sourceUri.Scheme -ne 'https' -or ($sourceUri.Host -ne 'wallhaven.cc' -and -not $sourceUri.Host.EndsWith('.wallhaven.cc', [StringComparison]::OrdinalIgnoreCase))) {
        return $false
    }
    if (-not $sourceUri.AbsolutePath.ToLowerInvariant().Contains($id.ToLowerInvariant())) {
        return $false
    }

    $fileType = ([string](Get-PropertyValue -Object $Candidate -Name 'file_type' -Default '')).ToLowerInvariant()
    $extension = [IO.Path]::GetExtension($sourceUri.AbsolutePath).ToLowerInvariant()
    $acceptedType = $fileType -in @('', 'image/jpeg', 'image/jpg', 'image/png')
    $acceptedExtension = $extension -in @('.jpg', '.jpeg', '.png')
    if (-not $acceptedType -or -not $acceptedExtension) {
        return $false
    }

    $purity = ([string](Get-PropertyValue -Object $Candidate -Name 'purity' -Default '')).ToLowerInvariant()
    if ($purity -notin @('sfw', '100')) {
        return $false
    }

    $category = ([string](Get-PropertyValue -Object $Candidate -Name 'category' -Default '')).ToLowerInvariant()
    if (-not [string]::IsNullOrWhiteSpace($category) -and $category -ne 'general') {
        return $false
    }

    $dimensions = Get-WallpaperDimensionsFromCandidate -Candidate $Candidate
    $minimumWidth = Get-ConfiguredInt -Object $image -Name 'minimumWidth' -Default 3840 -Minimum 1
    $minimumHeight = Get-ConfiguredInt -Object $image -Name 'minimumHeight' -Default 2160 -Minimum 1
    if ($dimensions.Width -lt $minimumWidth -or $dimensions.Height -lt $minimumHeight) {
        return $false
    }

    $ratioText = [string](Get-PropertyValue -Object $image -Name 'aspectRatio' -Default '16x9')
    if ($ratioText -notmatch '^(?<width>\d+(?:\.\d+)?)x(?<height>\d+(?:\.\d+)?)$') {
        return $false
    }
    $targetRatio = [double]$Matches['width'] / [double]$Matches['height']
    $actualRatio = [double]$dimensions.Width / [double]$dimensions.Height
    $tolerancePercent = Get-ConfiguredDouble -Object $image -Name 'aspectTolerancePercent' -Default 2 -Minimum 0
    $allowedDifference = $targetRatio * ($tolerancePercent / 100.0)
    if ([Math]::Abs($actualRatio - $targetRatio) -gt $allowedDifference) {
        return $false
    }

    return $true
}

function Get-CandidateQualityScore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Candidate
    )

    $favorites = 0.0
    $views = 0.0
    [void][double]::TryParse(([string](Get-PropertyValue -Object $Candidate -Name 'favorites' -Default 0)), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$favorites)
    [void][double]::TryParse(([string](Get-PropertyValue -Object $Candidate -Name 'views' -Default 0)), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$views)
    $favorites = [Math]::Max(0, $favorites)
    $views = [Math]::Max(0, $views)
    return (3.0 * [Math]::Log($favorites + 1.0)) + [Math]::Log($views + 1.0)
}

function Get-ImageMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    try {
        [void](Add-Type -AssemblyName System.Drawing -ErrorAction Stop)
    }
    catch {
        throw 'System.Drawing is required for image validation on Windows.'
    }

    $stream = $null
    $image = $null
    try {
        $stream = [IO.File]::OpenRead($Path)
        $image = [System.Drawing.Image]::FromStream($stream, $true, $true)
        return [PSCustomObject]@{
            Width = $image.Width
            Height = $image.Height
            RawFormat = [string]$image.RawFormat.Guid
        }
    }
    finally {
        if ($null -ne $image) {
            $image.Dispose()
        }
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }
}

function Test-LocalWallpaperFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [object]$Config
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    $extension = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($extension -notin @('.jpg', '.jpeg', '.png')) {
        return $null
    }

    $image = Get-PropertyValue -Object $Config -Name 'image'
    $minimumSizeKB = Get-ConfiguredInt -Object $image -Name 'minimumFileSizeKB' -Default 100 -Minimum 1
    if ((Get-Item -LiteralPath $Path).Length -lt ([long]$minimumSizeKB * 1KB)) {
        return $null
    }

    try {
        $metadata = Get-ImageMetadata -Path $Path
    }
    catch {
        return $null
    }
    if ($null -eq $metadata) {
        return $null
    }

    $minimumWidth = Get-ConfiguredInt -Object $image -Name 'minimumWidth' -Default 3840 -Minimum 1
    $minimumHeight = Get-ConfiguredInt -Object $image -Name 'minimumHeight' -Default 2160 -Minimum 1
    if ($metadata.Width -lt $minimumWidth -or $metadata.Height -lt $minimumHeight) {
        return $null
    }

    $ratioText = [string](Get-PropertyValue -Object $image -Name 'aspectRatio' -Default '16x9')
    if ($ratioText -notmatch '^(?<width>\d+(?:\.\d+)?)x(?<height>\d+(?:\.\d+)?)$') {
        return $null
    }
    $targetRatio = [double]$Matches['width'] / [double]$Matches['height']
    $actualRatio = [double]$metadata.Width / [double]$metadata.Height
    $tolerancePercent = Get-ConfiguredDouble -Object $image -Name 'aspectTolerancePercent' -Default 2 -Minimum 0
    if ([Math]::Abs($actualRatio - $targetRatio) -gt ($targetRatio * ($tolerancePercent / 100.0))) {
        return $null
    }

    return $metadata
}

function Get-WallpaperExtension {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Candidate
    )

    $fileType = ([string](Get-PropertyValue -Object $Candidate -Name 'file_type' -Default '')).ToLowerInvariant()
    if ($fileType -eq 'image/png') {
        return '.png'
    }
    if ($fileType -in @('image/jpeg', 'image/jpg')) {
        return '.jpg'
    }

    $path = [string](Get-PropertyValue -Object $Candidate -Name 'path' -Default '')
    $extension = [IO.Path]::GetExtension(([Uri]$path).AbsolutePath).ToLowerInvariant()
    if ($extension -eq '.png') {
        return '.png'
    }
    return '.jpg'
}

function Download-Wallpaper {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Candidate,

        [Parameter(Mandatory = $true)]
        [object]$Config,

        [Parameter(Mandatory = $true)]
        [string]$CachePath,

        [double]$QualityScore = 1
    )

    [void](New-Item -ItemType Directory -Force -Path $CachePath)
    $id = [string](Get-PropertyValue -Object $Candidate -Name 'id' -Default '')
    $sourceUrl = [string](Get-PropertyValue -Object $Candidate -Name 'path' -Default '')
    $sourceUri = [Uri]$sourceUrl
    $extension = Get-WallpaperExtension -Candidate $Candidate
    $destination = Join-Path $CachePath ($id + $extension)

    $existingMetadata = Test-LocalWallpaperFile -Path $destination -Config $Config
    if ($null -ne $existingMetadata) {
        return [PSCustomObject]@{
            Id = $id
            FullPath = $destination
            Extension = $extension
            Width = $existingMetadata.Width
            Height = $existingMetadata.Height
            Favorites = [long](Get-PropertyValue -Object $Candidate -Name 'favorites' -Default 0)
            Views = [long](Get-PropertyValue -Object $Candidate -Name 'views' -Default 0)
            SourceUrl = $sourceUrl
            QualityScore = $QualityScore
        }
    }

    if (Test-Path -LiteralPath $destination -PathType Leaf) {
        Remove-Item -LiteralPath $destination -Force
    }

    $schedule = Get-PropertyValue -Object $Config -Name 'schedule'
    $timeoutSeconds = Get-ConfiguredInt -Object $schedule -Name 'requestTimeoutSeconds' -Default 30 -Minimum 1
    $temporaryPath = "$destination.tmp.$([Guid]::NewGuid().ToString('N'))$extension"
    try {
        Invoke-WebRequest -Uri $sourceUri.AbsoluteUri -Method Get -TimeoutSec $timeoutSeconds -UseBasicParsing -Headers @{ 'User-Agent' = 'DailyWallpaper/1.0' } -OutFile $temporaryPath
        $metadata = Test-LocalWallpaperFile -Path $temporaryPath -Config $Config
        if ($null -eq $metadata) {
            throw "Downloaded file failed image validation for wallpaper '$id'."
        }

        [IO.File]::Move($temporaryPath, $destination)
        return [PSCustomObject]@{
            Id = $id
            FullPath = $destination
            Extension = $extension
            Width = $metadata.Width
            Height = $metadata.Height
            Favorites = [long](Get-PropertyValue -Object $Candidate -Name 'favorites' -Default 0)
            Views = [long](Get-PropertyValue -Object $Candidate -Name 'views' -Default 0)
            SourceUrl = $sourceUrl
            QualityScore = $QualityScore
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-SceneQueryFallbacks {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Scene
    )

    $queries = New-Object 'System.Collections.Generic.List[string]'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($value in @(
        (Get-PropertyValue -Object $Scene -Name 'Query' -Default ''),
        (Get-PropertyValue -Object $Scene -Name 'Keyword' -Default ''),
        ([string](Get-PropertyValue -Object $Scene -Name 'Weather' -Default '')).ToLowerInvariant(),
        ([string](Get-PropertyValue -Object $Scene -Name 'Topic' -Default '')).ToLowerInvariant(),
        'landscape',
        'wallpaper'
    )) {
        $text = ([string]$value).Trim()
        if (-not [string]::IsNullOrWhiteSpace($text) -and $seen.Add($text)) {
            [void]$queries.Add($text)
        }
    }
    return $queries.ToArray()
}

function New-WallpaperPool {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config,

        [Parameter(Mandatory = $true)]
        [object]$Scene,

        [AllowEmptyCollection()]
        [object[]]$HistoryIds,

        [Parameter(Mandatory = $true)]
        [string]$ProjectRoot,

        [Parameter(Mandatory = $true)]
        [string]$CachePath,

        [Parameter(Mandatory = $true)]
        [string]$LogPath
    )

    $poolConfig = Get-PropertyValue -Object $Config -Name 'pool'
    $poolSize = Get-ConfiguredInt -Object $poolConfig -Name 'size' -Default 8 -Minimum 1
    $candidateTarget = Get-ConfiguredInt -Object $poolConfig -Name 'candidateTarget' -Default 72 -Minimum 1
    $highQualityCount = Get-ConfiguredInt -Object $poolConfig -Name 'highQualityCandidateCount' -Default 24 -Minimum 1
    $historySet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($historyId in @($HistoryIds)) {
        $historyText = [string]$historyId
        if (-not [string]::IsNullOrWhiteSpace($historyText)) {
            [void]$historySet.Add($historyText)
        }
    }

    $scoredCandidates = New-Object 'System.Collections.Generic.List[object]'
    $candidateIds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $queries = Get-SceneQueryFallbacks -Scene $Scene
    $successfulSearch = $false
    foreach ($query in @($queries)) {
        try {
            $candidates = Get-WallhavenCandidates -Config $Config -Query $query -TargetCount $candidateTarget
            $successfulSearch = $true
            foreach ($candidate in @($candidates)) {
                if (-not (Test-WallpaperCandidate -Candidate $candidate -Config $Config)) {
                    continue
                }

                $id = [string](Get-PropertyValue -Object $candidate -Name 'id' -Default '')
                if ($historySet.Contains($id) -or -not $candidateIds.Add($id)) {
                    continue
                }

                $qualityScore = Get-CandidateQualityScore -Candidate $candidate
                $weight = [Math]::Max(1.0, $qualityScore)
                [void]$scoredCandidates.Add([PSCustomObject]@{
                    Candidate = $candidate
                    QualityScore = $qualityScore
                    Weight = $weight
                })
            }
            if ($scoredCandidates.Count -ge $candidateTarget) {
                break
            }
        }
        catch {
            Write-Log -Path $LogPath -Level 'WARN' -Message "Wallhaven search failed for query '$query': $($_.Exception.Message)"
        }
    }

    if ($scoredCandidates.Count -eq 0) {
        if (-not $successfulSearch) {
            throw 'Wallhaven was unavailable for every fallback query.'
        }
        throw 'Wallhaven returned no valid 4K 16:9 candidates outside the 60-day history.'
    }

    $qualitySubsetCount = [Math]::Min($highQualityCount, $scoredCandidates.Count)
    $qualitySubset = @($scoredCandidates | Sort-Object -Property QualityScore -Descending | Select-Object -First $qualitySubsetCount)
    $qualityOrder = @(Select-WeightedRandom -Items $qualitySubset -Count $qualitySubset.Count -WeightProperty 'Weight')
    $qualityIds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($qualityItem in $qualitySubset) {
        [void]$qualityIds.Add([string](Get-PropertyValue -Object $qualityItem.Candidate -Name 'id' -Default ''))
    }

    $remainder = @($scoredCandidates | Where-Object {
        $candidateId = [string](Get-PropertyValue -Object $_.Candidate -Name 'id' -Default '')
        -not $qualityIds.Contains($candidateId)
    })
    $remainderOrder = @()
    if ($remainder.Count -gt 0) {
        $remainderOrder = @(Select-WeightedRandom -Items $remainder -Count $remainder.Count -WeightProperty 'Weight')
    }

    $candidateOrder = @($qualityOrder + $remainderOrder)
    $items = New-Object 'System.Collections.Generic.List[object]'
    foreach ($scored in $candidateOrder) {
        if ($items.Count -ge $poolSize) {
            break
        }

        try {
            $downloaded = Download-Wallpaper -Candidate $scored.Candidate -Config $Config -CachePath $CachePath -QualityScore $scored.QualityScore
            $relativePath = Get-RelativeProjectPath -ProjectRoot $ProjectRoot -Path $downloaded.FullPath
            [void]$items.Add([PSCustomObject]@{
                id = $downloaded.Id
                file = $relativePath
                favorites = $downloaded.Favorites
                views = $downloaded.Views
                width = $downloaded.Width
                height = $downloaded.Height
                qualityScore = $downloaded.QualityScore
                sourceUrl = $downloaded.SourceUrl
            })
        }
        catch {
            $failedId = [string](Get-PropertyValue -Object $scored.Candidate -Name 'id' -Default 'unknown')
            Write-Log -Path $LogPath -Level 'WARN' -Message "Wallpaper download/validation failed for '$failedId': $($_.Exception.Message)"
        }
    }

    if ($items.Count -eq 0) {
        throw 'No valid wallpaper could be downloaded from the candidate set.'
    }

    $sceneForState = [PSCustomObject]@{
        weather = [string](Get-PropertyValue -Object $Scene -Name 'Weather' -Default 'CLOUDY')
        time = [string](Get-PropertyValue -Object $Scene -Name 'Time' -Default 'DAY')
        topic = [string](Get-PropertyValue -Object $Scene -Name 'Topic' -Default 'NATURE')
        keyword = [string](Get-PropertyValue -Object $Scene -Name 'Keyword' -Default '')
        query = [string](Get-PropertyValue -Object $Scene -Name 'Query' -Default '')
    }

    return [PSCustomObject]@{
        createdAt = (Get-LocalNow).ToString('o')
        scene = $sceneForState
        index = 0
        items = $items.ToArray()
    }
}
