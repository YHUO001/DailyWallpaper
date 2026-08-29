Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-WallpaperEngineExecutable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config
    )

    $wallpaperEngine = Get-PropertyValue -Object $Config -Name 'wallpaperEngine'
    $configuredPath = [string](Get-PropertyValue -Object $wallpaperEngine -Name 'executable' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($configuredPath)) {
        if (-not (Test-Path -LiteralPath $configuredPath -PathType Leaf)) {
            throw "Wallpaper Engine executable was not found at '$configuredPath'. Edit wallpaperEngine.executable in config.json."
        }
        return (Resolve-Path -LiteralPath $configuredPath).ProviderPath
    }

    $commonPaths = @(
        'C:\Program Files (x86)\Steam\steamapps\common\wallpaper_engine\wallpaper64.exe',
        'C:\Program Files (x86)\Steam\steamapps\common\wallpaper_engine\wallpaper32.exe',
        'C:\Program Files\Steam\steamapps\common\wallpaper_engine\wallpaper64.exe',
        'C:\Program Files\Steam\steamapps\common\wallpaper_engine\wallpaper32.exe'
    )
    foreach ($path in $commonPaths) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            return (Resolve-Path -LiteralPath $path).ProviderPath
        }
    }

    throw 'Wallpaper Engine executable was not found. Set wallpaperEngine.executable in config.json.'
}

function ConvertTo-ProcessArgument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    if ($Value.Contains('"')) {
        throw 'Wallpaper Engine paths cannot contain double quote characters.'
    }
    return '"' + $Value + '"'
}

function Set-WallpaperEngineImage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ImagePath,

        [Parameter(Mandatory = $true)]
        [int]$Monitor,

        [Parameter(Mandatory = $true)]
        [object]$Config,

        [AllowNull()]
        [string]$LogPath
    )

    if ($Monitor -lt 0) {
        throw 'Wallpaper Engine monitor index must be zero or greater.'
    }
    if (-not (Test-Path -LiteralPath $ImagePath -PathType Leaf)) {
        throw "Wallpaper image does not exist: $ImagePath"
    }

    $executable = Get-WallpaperEngineExecutable -Config $Config
    $arguments = '-control openWallpaper -file ' + (ConvertTo-ProcessArgument -Value $ImagePath) + ' -monitor ' + [string]$Monitor
    $displayCommand = (ConvertTo-ProcessArgument -Value $executable) + ' ' + $arguments
    $process = $null

    try {
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $executable
        $startInfo.Arguments = $arguments
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $startInfo
        if (-not $process.Start()) {
            throw 'Wallpaper Engine process could not be started.'
        }

        $process.WaitForExit()
        $standardOutput = $process.StandardOutput.ReadToEnd()
        $standardError = $process.StandardError.ReadToEnd()
        $exitCode = $process.ExitCode
        $succeeded = ($exitCode -eq 0)
        $level = if ($succeeded) { 'INFO' } else { 'ERROR' }
        $message = "Wallpaper Engine command exitCode=$exitCode monitor=$Monitor command=$displayCommand"
        if (-not [string]::IsNullOrWhiteSpace($standardError)) {
            $message += " stderr=$($standardError.Trim())"
        }
        $logging = Get-PropertyValue -Object $Config -Name 'logging'
        $loggingEnabled = [bool](Get-PropertyValue -Object $logging -Name 'enabled' -Default $true)
        $maxLogSizeMB = Get-ConfiguredDouble -Object $logging -Name 'maxLogSizeMB' -Default 5 -Minimum 1
        Write-Log -Path $LogPath -Level $level -Message $message -Enabled $loggingEnabled -MaxLogSizeMB $maxLogSizeMB

        return [PSCustomObject]@{
            Succeeded = $succeeded
            ExitCode = $exitCode
            StandardOutput = $standardOutput
            StandardError = $standardError
            Command = $displayCommand
        }
    }
    finally {
        if ($null -ne $process) {
            $process.Dispose()
        }
    }
}
