Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-OpenMeteoWeather {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config
    )

    $location = Get-PropertyValue -Object $Config -Name 'location'
    $latitude = Get-ConfiguredDouble -Object $location -Name 'latitude' -Default 31.2304 -Minimum -90
    $longitude = Get-ConfiguredDouble -Object $location -Name 'longitude' -Default 121.4737 -Minimum -180
    $timezone = [string](Get-PropertyValue -Object $location -Name 'timezone' -Default 'auto')
    if ([string]::IsNullOrWhiteSpace($timezone)) {
        $timezone = 'auto'
    }

    $schedule = Get-PropertyValue -Object $Config -Name 'schedule'
    $timeoutSeconds = Get-ConfiguredInt -Object $schedule -Name 'requestTimeoutSeconds' -Default 30 -Minimum 1
    $query = @(
        'latitude=' + [Uri]::EscapeDataString($latitude.ToString([Globalization.CultureInfo]::InvariantCulture))
        'longitude=' + [Uri]::EscapeDataString($longitude.ToString([Globalization.CultureInfo]::InvariantCulture))
        'current=weather_code%2Ctemperature_2m%2Ccloud_cover%2Cprecipitation'
        'daily=sunrise%2Csunset'
        'forecast_days=1'
        'timezone=' + [Uri]::EscapeDataString($timezone)
    ) -join '&'
    $uri = "https://api.open-meteo.com/v1/forecast?$query"

    $response = Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec $timeoutSeconds
    if ($null -eq $response) {
        throw 'Open-Meteo returned an empty response.'
    }

    $current = Get-PropertyValue -Object $response -Name 'current'
    $daily = Get-PropertyValue -Object $response -Name 'daily'
    if ($null -eq $current -or $null -eq $daily) {
        throw 'Open-Meteo response did not contain current and daily data.'
    }

    $weatherCodeValue = Get-PropertyValue -Object $current -Name 'weather_code'
    $weatherCode = 0
    if (-not [int]::TryParse([string]$weatherCodeValue, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$weatherCode)) {
        throw 'Open-Meteo returned an invalid weather code.'
    }

    $sunrises = @((Get-PropertyValue -Object $daily -Name 'sunrise' -Default @()))
    $sunsets = @((Get-PropertyValue -Object $daily -Name 'sunset' -Default @()))
    if ($sunrises.Count -eq 0 -or $sunsets.Count -eq 0) {
        throw 'Open-Meteo response did not contain sunrise and sunset.'
    }

    return [PSCustomObject]@{
        WeatherCode = $weatherCode
        Category = ConvertTo-WeatherCategory -WeatherCode $weatherCode
        Temperature = Get-PropertyValue -Object $current -Name 'temperature_2m'
        CloudCover = Get-PropertyValue -Object $current -Name 'cloud_cover'
        Precipitation = Get-PropertyValue -Object $current -Name 'precipitation'
        CurrentTime = Get-PropertyValue -Object $current -Name 'time'
        Sunrise = $sunrises[0]
        Sunset = $sunsets[0]
        FetchedAt = (Get-LocalNow).ToString('o')
    }
}

function ConvertTo-WeatherCategory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int]$WeatherCode
    )

    switch ($WeatherCode) {
        { $_ -in @(0, 1) } { return 'CLEAR' }
        { $_ -in @(2, 3) } { return 'CLOUDY' }
        { $_ -in @(45, 48) } { return 'FOG' }
        { $_ -in @(51, 53, 55, 56, 57, 61, 63, 65, 66, 67, 80, 81, 82) } { return 'RAIN' }
        { $_ -in @(71, 73, 75, 77, 85, 86) } { return 'SNOW' }
        { $_ -in @(95, 96, 99) } { return 'STORM' }
        default { return 'CLOUDY' }
    }
}

function Get-DayNightState {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Weather,

        [DateTimeOffset]$Now = (Get-LocalNow)
    )

    $sunriseText = Get-PropertyValue -Object $Weather -Name 'Sunrise'
    $sunsetText = Get-PropertyValue -Object $Weather -Name 'Sunset'
    if ([string]::IsNullOrWhiteSpace([string]$sunriseText) -or [string]::IsNullOrWhiteSpace([string]$sunsetText)) {
        return 'DAY'
    }

    $comparisonNow = $Now.DateTime
    $currentTimeText = Get-PropertyValue -Object $Weather -Name 'CurrentTime'
    $parsedTime = [DateTimeOffset]::MinValue
    if (-not [string]::IsNullOrWhiteSpace([string]$currentTimeText) -and [DateTimeOffset]::TryParse([string]$currentTimeText, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeLocal, [ref]$parsedTime)) {
        $comparisonNow = $parsedTime.DateTime
    }

    $sunrise = [DateTimeOffset]::MinValue
    $sunset = [DateTimeOffset]::MinValue
    $styles = [Globalization.DateTimeStyles]::AssumeLocal
    if (-not [DateTimeOffset]::TryParse([string]$sunriseText, [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$sunrise)) {
        return 'DAY'
    }
    if (-not [DateTimeOffset]::TryParse([string]$sunsetText, [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$sunset)) {
        return 'DAY'
    }

    if ($comparisonNow -lt $sunrise.DateTime -or $comparisonNow -ge $sunset.DateTime) {
        return 'NIGHT'
    }

    return 'DAY'
}

function Update-WeatherDebounce {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$WeatherState,

        [Parameter(Mandatory = $true)]
        [string]$FetchedCategory,

        [Parameter(Mandatory = $true)]
        [object]$Config,

        [DateTimeOffset]$Now = (Get-LocalNow)
    )

    $category = ([string]$FetchedCategory).ToUpperInvariant()
    $validCategories = @('CLEAR', 'CLOUDY', 'RAIN', 'FOG', 'SNOW', 'STORM')
    if ($category -notin $validCategories) {
        $category = 'CLOUDY'
    }

    $active = ([string](Get-PropertyValue -Object $WeatherState -Name 'activeCategory' -Default '')).ToUpperInvariant()
    if ([string]::IsNullOrWhiteSpace($active)) {
        $newState = [PSCustomObject]@{
            activeCategory = $category
            pendingCategory = $null
            pendingCount = 0
            lastCheckAt = $Now.ToString('o')
            lastAutomaticChangeAt = Get-PropertyValue -Object $WeatherState -Name 'lastAutomaticChangeAt'
        }
        return [PSCustomObject]@{
            State = $newState
            WeatherChangeConfirmed = $false
            ConfirmedCategory = $null
            InitialCategorySet = $true
        }
    }

    $pending = [string](Get-PropertyValue -Object $WeatherState -Name 'pendingCategory' -Default '')
    $pendingCount = Get-ConfiguredInt -Object $WeatherState -Name 'pendingCount' -Default 0 -Minimum 0
    if ($category -eq $active) {
        $pending = $null
        $pendingCount = 0
    }
    elseif ($category -eq $pending) {
        $pendingCount++
    }
    else {
        $pending = $category
        $pendingCount = 1
    }

    $schedule = Get-PropertyValue -Object $Config -Name 'schedule'
    $confirmationChecks = Get-ConfiguredInt -Object $schedule -Name 'weatherConfirmationChecks' -Default 2 -Minimum 1
    $minimumHours = Get-ConfiguredDouble -Object $schedule -Name 'minimumAutomaticChangeHours' -Default 3 -Minimum 0
    $lastAutomaticChangeAt = Get-PropertyValue -Object $WeatherState -Name 'lastAutomaticChangeAt'
    $minimumSatisfied = $true
    if (-not [string]::IsNullOrWhiteSpace([string]$lastAutomaticChangeAt)) {
        $lastChange = [DateTimeOffset]::MinValue
        if ([DateTimeOffset]::TryParse([string]$lastAutomaticChangeAt, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeLocal, [ref]$lastChange)) {
            $minimumSatisfied = (($Now - $lastChange).TotalHours -ge $minimumHours)
        }
    }

    $confirmed = $false
    $confirmedCategory = $null
    if ($pendingCount -ge $confirmationChecks -and $pending -eq $category -and $minimumSatisfied) {
        # Keep the old active category in the persisted state until the new
        # pool has been downloaded and Wallpaper Engine accepts it.
        $confirmed = $true
        $confirmedCategory = $category
        $pendingCount = $confirmationChecks
    }

    $newState = [PSCustomObject]@{
        activeCategory = $active
        pendingCategory = $pending
        pendingCount = $pendingCount
        lastCheckAt = $Now.ToString('o')
        lastAutomaticChangeAt = $lastAutomaticChangeAt
    }

    return [PSCustomObject]@{
        State = $newState
        WeatherChangeConfirmed = $confirmed
        ConfirmedCategory = $confirmedCategory
        InitialCategorySet = $false
    }
}

function Set-ActiveWeatherCategory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$WeatherState,

        [Parameter(Mandatory = $true)]
        [string]$Category,

        [DateTimeOffset]$AutomaticChangeAt = (Get-LocalNow),

        [bool]$RecordAutomaticChange = $false
    )

    $lastAutomaticChangeAt = Get-PropertyValue -Object $WeatherState -Name 'lastAutomaticChangeAt'
    if ($RecordAutomaticChange) {
        $lastAutomaticChangeAt = $AutomaticChangeAt.ToString('o')
    }

    return [PSCustomObject]@{
        activeCategory = $Category.ToUpperInvariant()
        pendingCategory = $null
        pendingCount = 0
        lastCheckAt = Get-PropertyValue -Object $WeatherState -Name 'lastCheckAt'
        lastAutomaticChangeAt = $lastAutomaticChangeAt
    }
}
