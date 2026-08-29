Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-DailyWallpaperLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config,

        [Parameter(Mandatory = $true)]
        [object]$Paths,

        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG')]
        [string]$Level = 'INFO'
    )

    $logging = Get-PropertyValue -Object $Config -Name 'logging'
    $enabledValue = Get-PropertyValue -Object $logging -Name 'enabled' -Default $true
    $enabled = [bool]$enabledValue
    $maxLogSizeMB = Get-ConfiguredDouble -Object $logging -Name 'maxLogSizeMB' -Default 5 -Minimum 1
    Write-Log -Path $Paths.Log -Message $Message -Level $Level -Enabled $enabled -MaxLogSizeMB $maxLogSizeMB
}

function Get-EffectiveWeatherContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config,

        [AllowNull()]
        [object]$WeatherState,

        [Parameter(Mandatory = $true)]
        [object]$Paths,

        [DateTimeOffset]$Now = (Get-LocalNow)
    )

    $isLive = $false
    $weather = $null
    $category = ''
    try {
        $weather = Get-OpenMeteoWeather -Config $Config
        $category = ([string](Get-PropertyValue -Object $weather -Name 'Category' -Default 'CLOUDY')).ToUpperInvariant()
        $isLive = $true
    }
    catch {
        $category = ([string](Get-PropertyValue -Object $WeatherState -Name 'activeCategory' -Default 'CLOUDY')).ToUpperInvariant()
        if ([string]::IsNullOrWhiteSpace($category)) {
            $category = 'CLOUDY'
        }
        $weather = [PSCustomObject]@{
            WeatherCode = $null
            Category = $category
            Temperature = $null
            CloudCover = $null
            Precipitation = $null
            CurrentTime = $null
            Sunrise = $null
            Sunset = $null
            FetchedAt = $Now.ToString('o')
        }
        Write-DailyWallpaperLog -Config $Config -Paths $Paths -Level 'WARN' -Message "Open-Meteo unavailable; using weather category '$category': $($_.Exception.Message)"
    }

    $timeState = Get-DayNightState -Weather $weather -Now $Now
    return [PSCustomObject]@{
        Weather = $weather
        Category = $category
        Time = $timeState
        IsLive = $isLive
    }
}

function Get-TopicSelection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config
    )

    $topics = Get-PropertyValue -Object $Config -Name 'topics'
    $mode = ([string](Get-PropertyValue -Object $topics -Name 'mode' -Default 'MIXED')).ToUpperInvariant()
    $supported = @('NATURE', 'CITY', 'ARCHITECTURE', 'SPACE')
    if ($mode -in $supported) {
        return $mode
    }

    $weights = Get-PropertyValue -Object $topics -Name 'weights'
    $weightedTopics = New-Object 'System.Collections.Generic.List[object]'
    if ($null -ne $weights) {
        foreach ($property in $weights.PSObject.Properties) {
            $name = ([string]$property.Name).ToUpperInvariant()
            if ($name -notin $supported) {
                continue
            }
            $weight = 0.0
            $parsedWeight = [double]::TryParse(([string]$property.Value), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$weight)
            if (-not $parsedWeight -or $weight -lt 0 -or [double]::IsNaN($weight) -or [double]::IsInfinity($weight)) {
                $weight = 0.0
            }
            [void]$weightedTopics.Add([PSCustomObject]@{
                Name = $name
                Weight = $weight
            })
        }
    }

    if ($weightedTopics.Count -eq 0) {
        foreach ($name in $supported) {
            [void]$weightedTopics.Add([PSCustomObject]@{
                Name = $name
                Weight = 1.0
            })
        }
    }

    $selection = @(Select-WeightedRandom -Items @($weightedTopics) -Count 1 -WeightProperty 'Weight')
    if ($selection.Count -eq 0) {
        return 'NATURE'
    }
    return [string]$selection[0].Name
}

function New-DailyWallpaperScene {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config,

        [Parameter(Mandatory = $true)]
        [string]$Weather,

        [Parameter(Mandatory = $true)]
        [string]$Time
    )

    $weatherCategory = $Weather.ToUpperInvariant()
    if ($weatherCategory -notin @('CLEAR', 'CLOUDY', 'RAIN', 'FOG', 'SNOW', 'STORM')) {
        $weatherCategory = 'CLOUDY'
    }
    $timeState = $Time.ToUpperInvariant()
    if ($timeState -notin @('DAY', 'NIGHT')) {
        $timeState = 'DAY'
    }
    $topic = Get-TopicSelection -Config $Config
    $keywordsRoot = Get-PropertyValue -Object $Config -Name 'keywords'
    $weatherKeywords = Get-PropertyValue -Object $keywordsRoot -Name $weatherCategory
    $topicKeywordValue = Get-PropertyValue -Object $weatherKeywords -Name $topic -Default @()
    $keywords = @($topicKeywordValue) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
    if ($keywords.Count -eq 0) {
        $keywords = @(("$weatherCategory $topic").ToLowerInvariant(), 'landscape')
    }

    $keyword = [string](Get-RandomItem -Items $keywords)
    $modifier = ''
    $random = [System.Random]::new()
    if ($timeState -eq 'DAY') {
        if ($random.NextDouble() -ge 0.70) {
            $modifier = [string](Get-RandomItem -Items @('daylight', 'sunlight', 'morning'))
        }
    }
    elseif ($timeState -eq 'NIGHT') {
        if ($random.NextDouble() -lt 0.80) {
            $modifier = 'night'
        }
    }

    $query = $keyword.Trim()
    if (-not [string]::IsNullOrWhiteSpace($modifier) -and $query.ToLowerInvariant().IndexOf($modifier.ToLowerInvariant(), [StringComparison]::OrdinalIgnoreCase) -lt 0) {
        $query = "$query $modifier"
    }

    return [PSCustomObject]@{
        Weather = $weatherCategory
        Time = $timeState
        Topic = $topic
        Keyword = $keyword
        Query = $query
    }
}

function ConvertTo-SceneFromState {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$StateObject,

        [Parameter(Mandatory = $true)]
        [object]$Config,

        [string]$FallbackWeather = 'CLOUDY',

        [string]$FallbackTime = 'DAY'
    )

    if ($null -eq $StateObject) {
        return New-DailyWallpaperScene -Config $Config -Weather $FallbackWeather -Time $FallbackTime
    }

    $weather = ([string](Get-PropertyValue -Object $StateObject -Name 'weather' -Default $FallbackWeather)).ToUpperInvariant()
    if ($weather -notin @('CLEAR', 'CLOUDY', 'RAIN', 'FOG', 'SNOW', 'STORM')) {
        $weather = $FallbackWeather.ToUpperInvariant()
    }
    $time = ([string](Get-PropertyValue -Object $StateObject -Name 'time' -Default $FallbackTime)).ToUpperInvariant()
    if ($time -notin @('DAY', 'NIGHT')) {
        $time = $FallbackTime.ToUpperInvariant()
    }
    $topic = ([string](Get-PropertyValue -Object $StateObject -Name 'topic' -Default 'NATURE')).ToUpperInvariant()
    $keyword = [string](Get-PropertyValue -Object $StateObject -Name 'keyword' -Default '')
    $query = [string](Get-PropertyValue -Object $StateObject -Name 'query' -Default '')
    if ([string]::IsNullOrWhiteSpace($query)) {
        return New-DailyWallpaperScene -Config $Config -Weather $weather -Time $time
    }

    return [PSCustomObject]@{
        Weather = $weather
        Time = $time
        Topic = $topic
        Keyword = $keyword
        Query = $query
    }
}

function Set-WeatherStateAfterDisplay {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$WeatherState,

        [Parameter(Mandatory = $true)]
        [string]$Category,

        [Parameter(Mandatory = $true)]
        [bool]$SetActiveCategory,

        [Parameter(Mandatory = $true)]
        [bool]$RecordAutomaticChange,

        [DateTimeOffset]$Now = (Get-LocalNow)
    )

    $baseState = $WeatherState
    if ($null -eq $baseState) {
        $baseState = [PSCustomObject]@{
            activeCategory = $Category
            pendingCategory = $null
            pendingCount = 0
            lastCheckAt = $Now.ToString('o')
            lastAutomaticChangeAt = $null
        }
    }

    if ($SetActiveCategory) {
        return Set-ActiveWeatherCategory -WeatherState $baseState -Category $Category -AutomaticChangeAt $Now -RecordAutomaticChange $RecordAutomaticChange
    }

    $lastAutomaticChangeAt = Get-PropertyValue -Object $baseState -Name 'lastAutomaticChangeAt'
    if ($RecordAutomaticChange) {
        $lastAutomaticChangeAt = $Now.ToString('o')
    }
    return [PSCustomObject]@{
        activeCategory = Get-PropertyValue -Object $baseState -Name 'activeCategory'
        pendingCategory = Get-PropertyValue -Object $baseState -Name 'pendingCategory'
        pendingCount = Get-PropertyValue -Object $baseState -Name 'pendingCount' -Default 0
        lastCheckAt = Get-PropertyValue -Object $baseState -Name 'lastCheckAt'
        lastAutomaticChangeAt = $lastAutomaticChangeAt
    }
}

function Invoke-PoolRebuildAndShow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config,

        [Parameter(Mandatory = $true)]
        [object]$Paths,

        [Parameter(Mandatory = $true)]
        [object]$Scene,

        [AllowEmptyCollection()]
        [object[]]$HistoryEntries,

        [Parameter(Mandatory = $true)]
        [string]$Reason,

        [Parameter(Mandatory = $true)]
        [bool]$AutomaticChange,

        [AllowNull()]
        [object]$WeatherState,

        [Parameter(Mandatory = $true)]
        [bool]$SetActiveCategory
    )

    $historyIds = Get-HistoryIds -Entries $HistoryEntries
    $pool = New-WallpaperPool -Config $Config -Scene $Scene -HistoryIds $historyIds -ProjectRoot $Paths.Root -CachePath $Paths.Cache -LogPath $Paths.Log
    $items = @((Get-PropertyValue -Object $pool -Name 'items' -Default @()))
    if ($items.Count -eq 0) {
        throw 'Pool rebuild returned no items.'
    }

    $firstItem = $items[0]
    $firstRelativePath = [string](Get-PropertyValue -Object $firstItem -Name 'file' -Default '')
    $firstPath = Resolve-ProjectPath -ProjectRoot $Paths.Root -Path $firstRelativePath
    $wallpaperEngine = Get-PropertyValue -Object $Config -Name 'wallpaperEngine'
    $monitor = Get-ConfiguredInt -Object $wallpaperEngine -Name 'monitor' -Default 0 -Minimum 0
    $engineResult = Set-WallpaperEngineImage -ImagePath $firstPath -Monitor $monitor -Config $Config -LogPath $Paths.Log
    if (-not $engineResult.Succeeded) {
        throw "Wallpaper Engine rejected the image with exit code $($engineResult.ExitCode)."
    }

    $now = Get-LocalNow
    $pool.index = 0
    $current = [PSCustomObject]@{
        wallpaperId = [string](Get-PropertyValue -Object $firstItem -Name 'id' -Default '')
        file = $firstRelativePath
        shownAt = $now.ToString('o')
        reason = $Reason
        weather = ([string](Get-PropertyValue -Object $Scene -Name 'Weather' -Default 'CLOUDY')).ToUpperInvariant()
        time = ([string](Get-PropertyValue -Object $Scene -Name 'Time' -Default 'DAY')).ToUpperInvariant()
        topic = ([string](Get-PropertyValue -Object $Scene -Name 'Topic' -Default 'NATURE')).ToUpperInvariant()
        query = [string](Get-PropertyValue -Object $Scene -Name 'Query' -Default '')
        poolIndex = 0
    }
    $historyAfterDisplay = Add-HistoryEntry -Entries $HistoryEntries -WallpaperId $current.wallpaperId -ShownAt $current.shownAt -Reason $Reason -Query $current.query
    $weatherAfterDisplay = Set-WeatherStateAfterDisplay -WeatherState $WeatherState -Category $current.weather -SetActiveCategory $SetActiveCategory -RecordAutomaticChange $AutomaticChange -Now $now

    # The new pool is committed only after Wallpaper Engine accepted the new
    # image. Each file is still written atomically to avoid partial JSON.
    Set-Pool -Path $Paths.Pool -Pool $pool
    Set-CurrentState -Path $Paths.Current -State $current
    Set-History -Path $Paths.History -Entries $historyAfterDisplay
    Set-WeatherState -Path $Paths.Weather -State $weatherAfterDisplay
    Clear-UnusedCache -CachePath $Paths.Cache -Pool $pool -Current $current -ProjectRoot $Paths.Root -LogPath $Paths.Log

    Write-DailyWallpaperLog -Config $Config -Paths $Paths -Level 'INFO' -Message "Pool created with $($items.Count) wallpapers; reason=$Reason weather=$($current.weather) topic=$($current.topic) query=[$($current.query)] selected=$($current.wallpaperId) monitor=$monitor"
    return [PSCustomObject]@{
        Changed = $true
        Current = $current
        Pool = $pool
        WeatherState = $weatherAfterDisplay
    }
}

function Get-StateShownDate {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$StateObject
    )

    $text = [string](Get-PropertyValue -Object $StateObject -Name 'shownAt' -Default '')
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }
    $value = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse($text, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeLocal, [ref]$value)) {
        return $value.ToLocalTime().Date
    }
    return $null
}

function Invoke-DailyUpdate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config,

        [Parameter(Mandatory = $true)]
        [object]$Paths
    )

    Ensure-DirectoryStructure -Paths $Paths
    $now = Get-LocalNow
    $history = Get-History -Path $Paths.History
    $historyConfig = Get-PropertyValue -Object $Config -Name 'history'
    $retentionDays = Get-ConfiguredInt -Object $historyConfig -Name 'retentionDays' -Default 60 -Minimum 1
    $pruned = Prune-History -Entries $history -RetentionDays $retentionDays -Now $now
    $history = @($pruned.Entries)
    if ($pruned.RemovedCount -gt 0) {
        Set-History -Path $Paths.History -Entries $history
        Write-DailyWallpaperLog -Config $Config -Paths $Paths -Level 'INFO' -Message "Pruned $($pruned.RemovedCount) history entries older than $retentionDays days."
    }

    $current = $null
    try {
        $current = Get-CurrentState -Path $Paths.Current
    }
    catch {
        Write-DailyWallpaperLog -Config $Config -Paths $Paths -Level 'WARN' -Message "Current state is unreadable; a fresh pool will be attempted: $($_.Exception.Message)"
    }
    $pool = $null
    try {
        $pool = Get-Pool -Path $Paths.Pool
    }
    catch {
        Write-DailyWallpaperLog -Config $Config -Paths $Paths -Level 'WARN' -Message "Pool state is unreadable; a fresh pool will be attempted: $($_.Exception.Message)"
    }
    $weatherState = $null
    try {
        $weatherState = Get-WeatherState -Path $Paths.Weather
    }
    catch {
        Write-DailyWallpaperLog -Config $Config -Paths $Paths -Level 'WARN' -Message "Weather state is unreadable; debounce state will be reinitialized: $($_.Exception.Message)"
    }

    $weatherContext = Get-EffectiveWeatherContext -Config $Config -WeatherState $weatherState -Paths $Paths -Now $now
    if ($weatherContext.IsLive) {
        $debounce = Update-WeatherDebounce -WeatherState $weatherState -FetchedCategory $weatherContext.Category -Config $Config -Now $now
        $observedWeatherState = $debounce.State
    }
    else {
        $existingActive = ([string](Get-PropertyValue -Object $weatherState -Name 'activeCategory' -Default '')).ToUpperInvariant()
        if ([string]::IsNullOrWhiteSpace($existingActive)) {
            $observedWeatherState = [PSCustomObject]@{
                activeCategory = $weatherContext.Category
                pendingCategory = $null
                pendingCount = 0
                lastCheckAt = $now.ToString('o')
                lastAutomaticChangeAt = Get-PropertyValue -Object $weatherState -Name 'lastAutomaticChangeAt'
            }
            $initialCategorySet = $true
        }
        else {
            $observedWeatherState = [PSCustomObject]@{
                activeCategory = $existingActive
                pendingCategory = Get-PropertyValue -Object $weatherState -Name 'pendingCategory'
                pendingCount = Get-PropertyValue -Object $weatherState -Name 'pendingCount' -Default 0
                lastCheckAt = $now.ToString('o')
                lastAutomaticChangeAt = Get-PropertyValue -Object $weatherState -Name 'lastAutomaticChangeAt'
            }
            $initialCategorySet = $false
        }
        $debounce = [PSCustomObject]@{
            State = $observedWeatherState
            WeatherChangeConfirmed = $false
            ConfirmedCategory = $null
            InitialCategorySet = $initialCategorySet
        }
    }
    Set-WeatherState -Path $Paths.Weather -State $observedWeatherState

    $poolUsable = $false
    try {
        $poolUsable = Test-PoolStructure -Pool $pool -ProjectRoot $Paths.Root -Config $Config
    }
    catch {
        $poolUsable = $false
        Write-DailyWallpaperLog -Config $Config -Paths $Paths -Level 'WARN' -Message "Pool validation failed; a fresh pool will be attempted: $($_.Exception.Message)"
    }
    $poolItems = @((Get-PropertyValue -Object $pool -Name 'items' -Default @()))
    $poolIndex = Get-ConfiguredInt -Object $pool -Name 'index' -Default -1 -Minimum -1
    $poolExhausted = ($poolItems.Count -gt 0 -and $poolIndex -ge ($poolItems.Count - 1))
    $shownDate = Get-StateShownDate -StateObject $current
    $today = $now.ToLocalTime().Date
    $dateChanged = ($null -eq $shownDate -or $shownDate -ne $today)

    $reason = ''
    $categoryForScene = ([string](Get-PropertyValue -Object $observedWeatherState -Name 'activeCategory' -Default $weatherContext.Category)).ToUpperInvariant()
    if ([string]::IsNullOrWhiteSpace($categoryForScene)) {
        $categoryForScene = $weatherContext.Category
    }
    $setActiveCategory = $false

    if ($null -eq $current -or -not $poolUsable) {
        $reason = if ($null -eq $current) { 'initial' } else { 'pool-repair' }
        if ($debounce.WeatherChangeConfirmed) {
            $categoryForScene = $debounce.ConfirmedCategory
            $setActiveCategory = $true
        }
        elseif ($debounce.InitialCategorySet) {
            $categoryForScene = $weatherContext.Category
            $setActiveCategory = $true
        }
    }
    elseif ($dateChanged) {
        $reason = 'daily'
        if ($debounce.WeatherChangeConfirmed) {
            $categoryForScene = $debounce.ConfirmedCategory
            $setActiveCategory = $true
        }
    }
    elseif ($debounce.WeatherChangeConfirmed) {
        $reason = 'weather-change'
        $categoryForScene = $debounce.ConfirmedCategory
        $setActiveCategory = $true
    }
    elseif ($poolExhausted) {
        $reason = 'pool-exhausted'
    }

    if ([string]::IsNullOrWhiteSpace($reason)) {
        Write-DailyWallpaperLog -Config $Config -Paths $Paths -Level 'INFO' -Message "No update required. weather=$categoryForScene time=$($weatherContext.Time) pool=$($poolIndex + 1)/$($poolItems.Count)"
        Write-Host 'DailyWallpaper'
        Write-Host "Weather: $categoryForScene"
        Write-Host "Time: $($weatherContext.Time)"
        Write-Host "Pool: $($poolIndex + 1)/$($poolItems.Count)"
        Write-Host 'No update required.'
        return [PSCustomObject]@{
            Changed = $false
            Current = $current
            Pool = $pool
            WeatherState = $observedWeatherState
        }
    }

    $scene = New-DailyWallpaperScene -Config $Config -Weather $categoryForScene -Time $weatherContext.Time
    $result = Invoke-PoolRebuildAndShow -Config $Config -Paths $Paths -Scene $scene -HistoryEntries $history -Reason $reason -AutomaticChange $true -WeatherState $observedWeatherState -SetActiveCategory $setActiveCategory
    Write-Host 'DailyWallpaper'
    Write-Host "Weather: $($scene.Weather)"
    Write-Host "Time: $($scene.Time)"
    Write-Host "Topic: $($scene.Topic)"
    Write-Host "Query: $($scene.Query)"
    Write-Host "Current wallpaper: $($result.Current.wallpaperId)"
    $resultPoolItems = @((Get-PropertyValue -Object $result.Pool -Name 'items' -Default @()))
    Write-Host "Pool: 1/$($resultPoolItems.Count)"
    return $result
}

function Invoke-ForceRefresh {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config,

        [Parameter(Mandatory = $true)]
        [object]$Paths
    )

    Ensure-DirectoryStructure -Paths $Paths
    $now = Get-LocalNow
    $history = Get-History -Path $Paths.History
    $weatherState = $null
    try {
        $weatherState = Get-WeatherState -Path $Paths.Weather
    }
    catch {
        Write-DailyWallpaperLog -Config $Config -Paths $Paths -Level 'WARN' -Message "Weather state is unreadable during force refresh: $($_.Exception.Message)"
    }
    $weatherContext = Get-EffectiveWeatherContext -Config $Config -WeatherState $weatherState -Paths $Paths -Now $now
    $category = $weatherContext.Category
    $scene = New-DailyWallpaperScene -Config $Config -Weather $category -Time $weatherContext.Time
    $baseWeatherState = if ($weatherState) { $weatherState } else { [PSCustomObject]@{ activeCategory = $category; pendingCategory = $null; pendingCount = 0; lastCheckAt = $now.ToString('o'); lastAutomaticChangeAt = $null } }
    $result = Invoke-PoolRebuildAndShow -Config $Config -Paths $Paths -Scene $scene -HistoryEntries $history -Reason 'force-refresh' -AutomaticChange $false -WeatherState $baseWeatherState -SetActiveCategory $true
    Write-Host "Force refresh complete: $($result.Current.wallpaperId)"
    return $result
}

function Invoke-LocalSkip {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config,

        [Parameter(Mandatory = $true)]
        [object]$Paths
    )

    Ensure-DirectoryStructure -Paths $Paths
    $now = Get-LocalNow
    $history = Get-History -Path $Paths.History
    $historyConfig = Get-PropertyValue -Object $Config -Name 'history'
    $retentionDays = Get-ConfiguredInt -Object $historyConfig -Name 'retentionDays' -Default 60 -Minimum 1
    $pruned = Prune-History -Entries $history -RetentionDays $retentionDays -Now $now
    $history = @($pruned.Entries)
    if ($pruned.RemovedCount -gt 0) {
        Set-History -Path $Paths.History -Entries $history
    }

    $current = $null
    $pool = $null
    try {
        $current = Get-CurrentState -Path $Paths.Current
        $pool = Get-Pool -Path $Paths.Pool
    }
    catch {
        Write-DailyWallpaperLog -Config $Config -Paths $Paths -Level 'WARN' -Message "Skip state is incomplete; a replacement pool will be attempted: $($_.Exception.Message)"
    }

    $poolUsable = $false
    if ($null -ne $current -and $null -ne $pool) {
        try {
            $poolUsable = Test-PoolStructure -Pool $pool -ProjectRoot $Paths.Root -Config $Config
        }
        catch {
            $poolUsable = $false
        }
    }

    if (-not $poolUsable) {
        $weatherState = $null
        try {
            $weatherState = Get-WeatherState -Path $Paths.Weather
        }
        catch {
        }
        $weatherContext = Get-EffectiveWeatherContext -Config $Config -WeatherState $weatherState -Paths $Paths -Now $now
        $stateForScene = if ($null -ne $current) { $current } else { Get-PropertyValue -Object $pool -Name 'scene' }
        $scene = ConvertTo-SceneFromState -StateObject $stateForScene -Config $Config -FallbackWeather $weatherContext.Category -FallbackTime $weatherContext.Time
        if ($null -eq $weatherState) {
            $weatherState = [PSCustomObject]@{
                activeCategory = $scene.Weather
                pendingCategory = $null
                pendingCount = 0
                lastCheckAt = $now.ToString('o')
                lastAutomaticChangeAt = $null
            }
        }
        $result = Invoke-PoolRebuildAndShow -Config $Config -Paths $Paths -Scene $scene -HistoryEntries $history -Reason 'manual-skip-rebuild' -AutomaticChange $false -WeatherState $weatherState -SetActiveCategory $false
        Write-Host "Skip rebuild complete: $($result.Current.wallpaperId)"
        return $result
    }

    $currentId = [string](Get-PropertyValue -Object $current -Name 'wallpaperId' -Default '')
    $currentShownAt = [string](Get-PropertyValue -Object $current -Name 'shownAt' -Default '')
    $currentReason = [string](Get-PropertyValue -Object $current -Name 'reason' -Default 'unknown')
    if ([string]::IsNullOrWhiteSpace($currentReason)) {
        $currentReason = 'unknown'
    }
    if (-not [string]::IsNullOrWhiteSpace($currentId) -and -not [string]::IsNullOrWhiteSpace($currentShownAt)) {
        $history = Add-HistoryEntry -Entries $history -WallpaperId $currentId -ShownAt $currentShownAt -Reason $currentReason -Query ([string](Get-PropertyValue -Object $current -Name 'query' -Default ''))
        Set-History -Path $Paths.History -Entries $history
    }

    $next = Get-NextPoolItem -Pool $pool -HistoryEntries $history
    if ($null -eq $next) {
        $weatherState = $null
        try {
            $weatherState = Get-WeatherState -Path $Paths.Weather
        }
        catch {
        }
        $sceneState = Get-PropertyValue -Object $pool -Name 'scene'
        $scene = ConvertTo-SceneFromState -StateObject $sceneState -Config $Config -FallbackWeather ([string](Get-PropertyValue -Object $current -Name 'weather' -Default 'CLOUDY')) -FallbackTime ([string](Get-PropertyValue -Object $current -Name 'time' -Default 'DAY'))
        if ($null -eq $weatherState) {
            $weatherState = [PSCustomObject]@{
                activeCategory = $scene.Weather
                pendingCategory = $null
                pendingCount = 0
                lastCheckAt = $now.ToString('o')
                lastAutomaticChangeAt = $null
            }
        }
        $result = Invoke-PoolRebuildAndShow -Config $Config -Paths $Paths -Scene $scene -HistoryEntries $history -Reason 'manual-skip-rebuild' -AutomaticChange $false -WeatherState $weatherState -SetActiveCategory $false
        Write-Host "Skipping $currentId; new pool starts at $($result.Current.wallpaperId)"
        return $result
    }

    $nextItem = $next.Item
    $nextRelativePath = [string](Get-PropertyValue -Object $nextItem -Name 'file' -Default '')
    $nextPath = Resolve-ProjectPath -ProjectRoot $Paths.Root -Path $nextRelativePath
    $wallpaperEngine = Get-PropertyValue -Object $Config -Name 'wallpaperEngine'
    $monitor = Get-ConfiguredInt -Object $wallpaperEngine -Name 'monitor' -Default 0 -Minimum 0
    $engineResult = Set-WallpaperEngineImage -ImagePath $nextPath -Monitor $monitor -Config $Config -LogPath $Paths.Log
    if (-not $engineResult.Succeeded) {
        throw "Wallpaper Engine rejected skipped wallpaper with exit code $($engineResult.ExitCode)."
    }

    $sceneState = Get-PropertyValue -Object $pool -Name 'scene'
    $shownAt = (Get-LocalNow).ToString('o')
    $newCurrent = [PSCustomObject]@{
        wallpaperId = [string](Get-PropertyValue -Object $nextItem -Name 'id' -Default '')
        file = $nextRelativePath
        shownAt = $shownAt
        reason = 'manual-skip'
        weather = ([string](Get-PropertyValue -Object $sceneState -Name 'weather' -Default 'CLOUDY')).ToUpperInvariant()
        time = ([string](Get-PropertyValue -Object $sceneState -Name 'time' -Default 'DAY')).ToUpperInvariant()
        topic = ([string](Get-PropertyValue -Object $sceneState -Name 'topic' -Default 'NATURE')).ToUpperInvariant()
        query = [string](Get-PropertyValue -Object $sceneState -Name 'query' -Default '')
        poolIndex = $next.Index
    }
    $pool.index = $next.Index
    $history = Add-HistoryEntry -Entries $history -WallpaperId $newCurrent.wallpaperId -ShownAt $shownAt -Reason 'manual-skip' -Query $newCurrent.query
    Set-Pool -Path $Paths.Pool -Pool $pool
    Set-CurrentState -Path $Paths.Current -State $newCurrent
    Set-History -Path $Paths.History -Entries $history
    Clear-UnusedCache -CachePath $Paths.Cache -Pool $pool -Current $newCurrent -ProjectRoot $Paths.Root -LogPath $Paths.Log
    $poolItemCount = @((Get-PropertyValue -Object $pool -Name 'items' -Default @())).Count
    Write-DailyWallpaperLog -Config $Config -Paths $Paths -Level 'INFO' -Message "Manual skip: old=$currentId new=$($newCurrent.wallpaperId) pool=$($next.Index + 1)/$poolItemCount monitor=$monitor"
    Write-Host "Skipping $currentId"
    Write-Host "Now showing $($newCurrent.wallpaperId)"
    Write-Host "Pool: $($next.Index + 1)/$poolItemCount"
    return [PSCustomObject]@{
        Changed = $true
        Current = $newCurrent
        Pool = $pool
    }
}
