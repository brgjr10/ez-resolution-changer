param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [Alias("n")]
    [string]$scriptName,

    [Parameter(Position = 1)]
    [Alias("sib")]
    [bool]$startInBackground
)
$path = (Split-Path $MyInvocation.MyCommand.Path -Parent)
Set-Location $path
. .\Helpers.ps1 -n $scriptName
. .\Events.ps1 -n $scriptName
$settings = Get-Settings
$DebugPreference = if ($settings.debug) { "Continue" } else { "SilentlyContinue" }
# Since pre-commands in sunshine are synchronous, we'll launch this script again in another powershell process
if ($startInBackground -eq $false) {
    $scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Definition
    $arguments = "-ExecutionPolicy Bypass -Command `"& '$scriptPath\StreamMonitor.ps1' -scriptName $scriptName -sib 1`""
    Start-Process powershell.exe -ArgumentList $arguments -WindowStyle Hidden
    Start-Sleep -Seconds $settings.startDelay
    exit
}


Remove-OldLogs
Start-Logging

# OPTIONAL MUTEX HANDLING
# Create a mutex to prevent multiple instances of this script from running simultaneously.
$lock = $false
$mutex = New-Object System.Threading.Mutex($false, $scriptName, [ref]$lock)

# Exit the script if another instance is already running.
if (-not $mutex.WaitOne(0)) {
    Write-Host "Exiting: Another instance of the script is currently running."
    exit
}

if (-not $mutex) {
    ### If you don't use a mutex, you can optionally fan the hammer
    for ($i = 0; $i -lt 6; $i++) {
        Send-PipeMessage $scriptName NewSession
        Send-PipeMessage "$scriptName-OnStreamEnd" Terminate
    }
}


# END OF OPTIONAL MUTEX HANDLING


try {
    
    # Asynchronously start the script, so we can use a named pipe to terminate it.
    Start-Job -Name "$($scriptName)Job" -ScriptBlock {
        param($path, $scriptName)
        . $path\Helpers.ps1 -n $scriptName
        $settings = Get-Settings
        $wasStreaming = $false


        Register-EngineEvent -SourceIdentifier $scriptName -Forward
        while ($true) {
            try {
                $isStreaming = (IsCurrentlyStreaming)
                if ($isStreaming) {
                    # Rising edge: detect transition from not-streaming to streaming
                    if (-not $wasStreaming) {
                        $wasStreaming = $true
                        New-Event -SourceIdentifier $scriptName -MessageData "Start"
                    }
                }
                else {
                    if ($wasStreaming) {
                        # Falling edge: client disconnected
                        $wasStreaming = $false
                        New-Event -SourceIdentifier $scriptName -MessageData "GracePeriodExpired"
                    }
                }
            }
            finally {
                Start-Sleep -Seconds 1
            }
        }
    } -ArgumentList $path, $scriptName | Out-Null


    # This might look like black magic, but basically we don't have to monitor this pipe because it fires off an event.
    Create-Pipe $scriptName | Out-Null

    # Wake detection - register for WMI power management events
    $script:wakeSignalPath = Join-Path $env:TEMP "resolution_wake_signal"
    $null = Remove-Item $script:wakeSignalPath -ErrorAction SilentlyContinue

    $wakeAction = {
        $signalPath = $using:script:wakeSignalPath
        try {
            New-Item -ItemType File -Path $signalPath -Force | Out-Null
        } catch { }
    }
    try {
        Register-WmiEvent -Namespace "root\cimv2" -Query "SELECT * FROM Win32_PowerManagementEvent WHERE EventType = 4" -Action $wakeAction -SourceIdentifier "ResolutionWakeEvent" -ErrorAction SilentlyContinue
        Write-Host "Wake detection registered via WMI PowerManagementEvent"
    } catch {
        Write-Host "WMI wake detection registration failed: $_"
    }

    Write-Host "Waiting for the next event to be called... (for starting/ending stream)"
    while ($true) {
        Start-Sleep -Seconds 1
        $eventFired = Get-Event -SourceIdentifier $scriptName -ErrorAction SilentlyContinue
        if ($null -ne $eventFired) {
            $eventName = $eventFired.MessageData
            Write-Host "Processing event: $eventName"
            if ($eventName -eq "Start") {
                OnStreamStart
            }
            elseif ($eventName -eq "NewSession") {
                Write-Host "A new session of this script has been started. To avoid conflicts, this session will now terminate. This is a normal process and not an error."
                break;
            }
            elseif ($eventName -eq "GracePeriodExpired") {
                Write-Host "Stream has been suspended beyond the defined grace period. We will now treat this as if you ended the stream. If this was unintentional or if you wish to extend the grace period, please adjust the grace period timeout in the settings.json file."
                Wait-ForStreamEndJobToComplete
            }
            else {
                Write-Host "Received terminate signal. Stopping watchdog."
                Stop-Job -Name "$($scriptName)Job" -ErrorAction SilentlyContinue
                Wait-ForStreamEndJobToComplete
                break;
            }
            Remove-Event -EventIdentifier $eventFired.EventIdentifier
        }

        # Check for wake signal file
        if (Test-Path $script:wakeSignalPath) {
            Remove-Item $script:wakeSignalPath -Force -ErrorAction SilentlyContinue
            Write-Host "System wake from sleep detected via WMI event"
            Start-Sleep -Seconds 10  # Give system time to settle

            if (-not (IsCurrentlyStreaming)) {
                if ($settings.preferredResolution.enabled) {
                    Write-Host "Restoring preferred resolution: $($settings.preferredResolution.width)x$($settings.preferredResolution.height)x$($settings.preferredResolution.refresh)"
                    Set-ScreenResolution -Width $settings.preferredResolution.width -Height $settings.preferredResolution.height -Freq $settings.preferredResolution.refresh
                }
            }
        }
    }
}
finally {
    try {
        Unregister-Event -SourceIdentifier "ResolutionWakeEvent" -ErrorAction SilentlyContinue
    } catch { }
    if ($mutex) {
        $mutex.ReleaseMutex()
    }
    Stop-Logging
}
