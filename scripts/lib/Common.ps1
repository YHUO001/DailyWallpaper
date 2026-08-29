Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ProjectRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptRoot
    )

    $resolvedScriptRoot = (Resolve-Path -LiteralPath $ScriptRoot).ProviderPath
    $root = (Get-Item -LiteralPath (Join-Path $resolvedScriptRoot '..\..')).FullName
    return $root
}

function Get-PropertyValue {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Object,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [AllowNull()]
        [object]$Default = $null
    )

    if ($null -eq $Object) {
        return $Default
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) {
        return $property.Value
    }

    return $Default
}

function Get-ConfiguredInt {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Object,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [int]$Default,

        [int]$Minimum = [int]::MinValue
    )

    $value = Get-PropertyValue -Object $Object -Name $Name -Default $Default
    $number = 0
    if (-not [int]::TryParse([string]$value, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
        $number = $Default
    }

    if ($number -lt $Minimum) {
        return $Default
    }

    return $number
}

function Get-ConfiguredDouble {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Object,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [double]$Default,

        [double]$Minimum = [double]::MinValue
    )

    $value = Get-PropertyValue -Object $Object -Name $Name -Default $Default
    $number = 0.0
    if (-not [double]::TryParse([string]$value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
        $number = $Default
    }

    if ($number -lt $Minimum) {
        return $Default
    }

    return $number
}

function Get-DefaultConfigForFirstRun {
    [CmdletBinding()]
    param()

    return [ordered]@{
        location = [ordered]@{
            latitude = 31.2304
            longitude = 121.4737
            timezone = 'auto'
        }
        wallpaperEngine = [ordered]@{
            executable = 'C:\Program Files (x86)\Steam\steamapps\common\wallpaper_engine\wallpaper64.exe'
            monitor = 0
        }
        image = [ordered]@{
            minimumWidth = 3840
            minimumHeight = 2160
            aspectRatio = '16x9'
            categories = '100'
            purity = '100'
            minimumFileSizeKB = 100
            aspectTolerancePercent = 2
        }
        pool = [ordered]@{
            size = 8
            candidateTarget = 72
            highQualityCandidateCount = 24
            maxSearchPages = 5
        }
        history = [ordered]@{
            retentionDays = 60
        }
        schedule = [ordered]@{
            minimumAutomaticChangeHours = 3
            weatherConfirmationChecks = 2
            requestTimeoutSeconds = 30
        }
        topics = [ordered]@{
            mode = 'MIXED'
            weights = [ordered]@{
                NATURE = 40
                CITY = 30
                ARCHITECTURE = 20
                SPACE = 10
            }
        }
        wallhaven = [ordered]@{
            baseUrl = 'https://wallhaven.cc/api/v1'
            sorting = 'random'
            apiKey = ''
        }
        logging = [ordered]@{
            enabled = $true
            maxLogSizeMB = 5
        }
    }
}

function Read-JsonSafe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    $raw = [IO.File]::ReadAllText($Path)
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "JSON file is empty: $Path"
    }

    try {
        return ConvertFrom-Json -InputObject $raw
    }
    catch {
        throw "Invalid JSON in '$Path': $($_.Exception.Message)"
    }
}

function Write-JsonAtomic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [AllowNull()]
        [object]$Data
    )

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        [void](New-Item -ItemType Directory -Force -Path $parent)
    }

    $temporaryPath = "$Path.tmp.$([Guid]::NewGuid().ToString('N'))"
    $utf8 = [System.Text.UTF8Encoding]::new($false)

    try {
        $json = ConvertTo-Json -InputObject $Data -Depth 20
        if ([string]::IsNullOrWhiteSpace($json)) {
            throw "Could not serialize JSON for '$Path'"
        }

        [IO.File]::WriteAllText($temporaryPath, $json, $utf8)
        $validationText = [IO.File]::ReadAllText($temporaryPath)
        [void](ConvertFrom-Json -InputObject $validationText)

        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $replaced = $false
            try {
                [IO.File]::Replace($temporaryPath, $Path, $null, $true)
                $replaced = $true
            }
            catch {
                $replaced = $false
            }

            if (-not $replaced) {
                [void](Move-Item -LiteralPath $temporaryPath -Destination $Path -Force)
            }
        }
        else {
            [IO.File]::Move($temporaryPath, $Path)
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-DailyWallpaperPaths {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectRoot
    )

    return [PSCustomObject]@{
        Root = $ProjectRoot
        Config = Join-Path $ProjectRoot 'config.json'
        Scripts = Join-Path $ProjectRoot 'scripts'
        State = Join-Path $ProjectRoot 'state'
        Cache = Join-Path $ProjectRoot 'cache'
        Logs = Join-Path $ProjectRoot 'logs'
        Current = Join-Path $ProjectRoot 'state\current.json'
        Pool = Join-Path $ProjectRoot 'state\pool.json'
        History = Join-Path $ProjectRoot 'state\history.json'
        Weather = Join-Path $ProjectRoot 'state\weather.json'
        Log = Join-Path $ProjectRoot 'logs\dailywallpaper.log'
    }
}

function Ensure-DirectoryStructure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Paths
    )

    foreach ($directory in @($Paths.State, $Paths.Cache, $Paths.Logs)) {
        [void](New-Item -ItemType Directory -Force -Path $directory)
    }

    if (-not (Test-Path -LiteralPath $Paths.History -PathType Leaf)) {
        Write-JsonAtomic -Path $Paths.History -Data @()
    }

    if (-not (Test-Path -LiteralPath $Paths.Weather -PathType Leaf)) {
        $initialWeather = [ordered]@{
            activeCategory = $null
            pendingCategory = $null
            pendingCount = 0
            lastCheckAt = $null
            lastAutomaticChangeAt = $null
        }
        Write-JsonAtomic -Path $Paths.Weather -Data $initialWeather
    }
}

function Get-Config {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Paths
    )

    if (-not (Test-Path -LiteralPath $Paths.Config -PathType Leaf)) {
        $example = Get-DefaultConfigForFirstRun
        Write-JsonAtomic -Path $Paths.Config -Data $example
        throw "config.json was missing. An example was created at '$($Paths.Config)'; edit it and run again."
    }

    $config = Read-JsonSafe -Path $Paths.Config
    if ($null -eq $config) {
        throw "Configuration is empty: $($Paths.Config)"
    }

    $location = Get-PropertyValue -Object $config -Name 'location'
    $wallpaperEngine = Get-PropertyValue -Object $config -Name 'wallpaperEngine'
    if ($null -eq $location -or $null -eq $wallpaperEngine) {
        throw "config.json must contain 'location' and 'wallpaperEngine' sections."
    }

    $latitude = Get-ConfiguredDouble -Object $location -Name 'latitude' -Default 31.2304 -Minimum -90
    $longitude = Get-ConfiguredDouble -Object $location -Name 'longitude' -Default 121.4737 -Minimum -180
    if ($latitude -gt 90 -or $longitude -gt 180) {
        throw 'Location coordinates are outside valid ranges.'
    }

    $monitor = Get-ConfiguredInt -Object $wallpaperEngine -Name 'monitor' -Default 0 -Minimum 0
    $image = Get-PropertyValue -Object $config -Name 'image'
    $pool = Get-PropertyValue -Object $config -Name 'pool'
    $history = Get-PropertyValue -Object $config -Name 'history'
    $schedule = Get-PropertyValue -Object $config -Name 'schedule'
    $wallhaven = Get-PropertyValue -Object $config -Name 'wallhaven'
    $logging = Get-PropertyValue -Object $config -Name 'logging'

    if ($null -eq $image -or $null -eq $pool -or $null -eq $history -or $null -eq $schedule -or $null -eq $wallhaven) {
        throw 'config.json is missing one or more required sections: image, pool, history, schedule, wallhaven.'
    }

    return $config
}

function Get-LocalNow {
    [CmdletBinding()]
    param()

    return [DateTimeOffset]::Now
}

function Get-RelativeProjectPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectRoot,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $rootFull = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\') + '\'
    $pathFull = [IO.Path]::GetFullPath($Path)
    if (-not $pathFull.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path '$Path' is outside project root '$ProjectRoot'."
    }

    return $pathFull.Substring($rootFull.Length).Replace('/', '\')
}

function Resolve-ProjectPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectRoot,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ([IO.Path]::IsPathRooted($Path)) {
        return [IO.Path]::GetFullPath($Path)
    }

    return [IO.Path]::GetFullPath((Join-Path $ProjectRoot $Path))
}

function Get-RandomItem {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [object[]]$Items
    )

    $collection = @($Items)
    if ($collection.Count -eq 0) {
        return $null
    }
    if ($collection.Count -eq 1) {
        return $collection[0]
    }

    $index = Get-Random -Minimum 0 -Maximum $collection.Count
    return $collection[$index]
}

function Select-WeightedRandom {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [object[]]$Items,

        [Parameter(Mandatory = $true)]
        [int]$Count,

        [string]$WeightProperty = 'Weight'
    )

    $remaining = New-Object 'System.Collections.Generic.List[object]'
    foreach ($item in @($Items)) {
        if ($null -ne $item) {
            [void]$remaining.Add($item)
        }
    }

    $selected = New-Object 'System.Collections.Generic.List[object]'
    $random = [System.Random]::new()
    $wanted = [Math]::Max(0, $Count)

    while ($remaining.Count -gt 0 -and $selected.Count -lt $wanted) {
        $totalWeight = 0.0
        foreach ($candidate in $remaining) {
            $rawWeight = Get-PropertyValue -Object $candidate -Name $WeightProperty -Default 1
            $weight = 1.0
            if ([double]::TryParse([string]$rawWeight, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$weight)) {
                if ($weight -lt 1.0 -or [double]::IsNaN($weight) -or [double]::IsInfinity($weight)) {
                    $weight = 1.0
                }
            }
            else {
                $weight = 1.0
            }
            $totalWeight += $weight
        }

        if ($totalWeight -le 0) {
            $index = Get-Random -Minimum 0 -Maximum $remaining.Count
            $chosen = $remaining[$index]
        }
        else {
            $roll = $random.NextDouble() * $totalWeight
            $running = 0.0
            $chosenIndex = $remaining.Count - 1
            for ($i = 0; $i -lt $remaining.Count; $i++) {
                $rawWeight = Get-PropertyValue -Object $remaining[$i] -Name $WeightProperty -Default 1
                $weight = 1.0
                if (-not [double]::TryParse([string]$rawWeight, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$weight) -or $weight -lt 1.0 -or [double]::IsNaN($weight) -or [double]::IsInfinity($weight)) {
                    $weight = 1.0
                }
                $running += $weight
                if ($roll -lt $running) {
                    $chosenIndex = $i
                    break
                }
            }
            $chosen = $remaining[$chosenIndex]
        }

        [void]$selected.Add($chosen)
        [void]$remaining.Remove($chosen)
    }

    return $selected.ToArray()
}

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG')]
        [string]$Level = 'INFO',

        [bool]$Enabled = $true,

        [double]$MaxLogSizeMB = 5
    )

    if (-not $Enabled) {
        return
    }

    try {
        $parent = Split-Path -Parent $Path
        if (-not [string]::IsNullOrWhiteSpace($parent)) {
            [void](New-Item -ItemType Directory -Force -Path $parent)
        }

        $maxBytes = [long]([Math]::Max(1, $MaxLogSizeMB) * 1MB)
        if ((Test-Path -LiteralPath $Path -PathType Leaf) -and ((Get-Item -LiteralPath $Path).Length -ge $maxBytes)) {
            $archive = "$Path.1"
            if (Test-Path -LiteralPath $archive -PathType Leaf) {
                Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
            }
            [void](Move-Item -LiteralPath $Path -Destination $archive -Force -ErrorAction SilentlyContinue)
        }

        $timestamp = (Get-LocalNow).ToString('yyyy-MM-dd HH:mm:ss zzz')
        $line = "$timestamp [$Level] $Message$([Environment]::NewLine)"
        $utf8 = [System.Text.UTF8Encoding]::new($false)
        [IO.File]::AppendAllText($Path, $line, $utf8)
    }
    catch {
        # Logging must never turn a successful wallpaper update into a failure.
    }
}

function Enter-DailyWallpaperLock {
    [CmdletBinding()]
    param(
        [string]$Name = 'Local\DailyWallpaper.SingleWriter'
    )

    $mutex = [System.Threading.Mutex]::new($false, $Name)
    try {
        if (-not $mutex.WaitOne(0)) {
            $mutex.Dispose()
            return $null
        }

        return [PSCustomObject]@{
            Mutex = $mutex
            Acquired = $true
        }
    }
    catch {
        $mutex.Dispose()
        throw
    }
}

function Exit-DailyWallpaperLock {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Lock
    )

    if ($null -eq $Lock) {
        return
    }

    try {
        if ($Lock.Acquired) {
            $Lock.Mutex.ReleaseMutex()
        }
    }
    finally {
        $Lock.Mutex.Dispose()
    }
}
