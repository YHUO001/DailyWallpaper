[CmdletBinding()]
param(
    [string]$TaskPrefix = 'DailyWallpaper'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).ProviderPath
$updateScript = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot 'update.ps1')).ProviderPath
$powerShell = (Get-Command pwsh.exe -ErrorAction SilentlyContinue)
if ($null -eq $powerShell) {
    $powerShell = (Get-Command powershell.exe -ErrorAction SilentlyContinue)
}
if ($null -eq $powerShell) {
    throw 'Could not find pwsh.exe or powershell.exe.'
}

$taskAction = New-ScheduledTaskAction -Execute $powerShell.Source -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$updateScript`""
$logonTrigger = New-ScheduledTaskTrigger -AtLogOn
$hourlyTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Hours 1) -RepetitionDuration (New-TimeSpan -Days 3650)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

Register-ScheduledTask -TaskName "$TaskPrefix - Login" -Action $taskAction -Trigger $logonTrigger -Settings $settings -Description 'Initialize DailyWallpaper at user logon.' -Force | Out-Null
Register-ScheduledTask -TaskName "$TaskPrefix - Hourly" -Action $taskAction -Trigger $hourlyTrigger -Settings $settings -Description 'Check DailyWallpaper weather and date state hourly.' -Force | Out-Null

Write-Host "Installed scheduled tasks: '$TaskPrefix - Login' and '$TaskPrefix - Hourly'"
Write-Host "Project: $projectRoot"
Write-Host 'The tasks run in the current user context and do not start a background daemon.'

