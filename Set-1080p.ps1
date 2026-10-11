Add-Type -Path "F:\Sunshine\ResolutionAutomation\internals\DisplaySettings.cs"

$width = 1920
$height = 1080
$frequency = 60

# Scaling mapping: 0 = 100%, 1 = 125%, 2 = 150%, 3 = 175%, 4 = 200%
$dpiIndex = 0 # Resets scaling back to 100%

$devMode = New-Object DisplaySettings+DEVMODE
$devMode.dmSize = [System.Runtime.InteropServices.Marshal]::SizeOf($devMode)
$modeNum = 0

while ([DisplaySettings]::EnumDisplaySettings([NullString]::Value, $modeNum, [ref]$devMode)) {
    $frequencyDiff = [Math]::Abs($devMode.dmDisplayFrequency - $frequency)
    if ($devMode.dmPelsWidth -eq $width -and $devMode.dmPelsHeight -eq $height -and $frequencyDiff -le 2) {
        $result = [DisplaySettings]::ChangeDisplaySettings([ref]$devMode, 0)
        if ($result -eq 0) {
            Write-Host "Resolution set to $width x $height x $frequency"
            
            # --- START OF SCALING RESET LOGIC ---
            $sourceScale = @"
            using System;
            using System.Runtime.InteropServices;
            public class User32Dpi {
                [DllImport("user32.dll", SetLastError = true)]
                public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, IntPtr pvParam, uint fWinIni);
            }
"@
            Add-Type -TypeDefinition $sourceScale -ErrorAction SilentlyContinue
            
            # 0x009F is SPI_SETLOGICALDPIOVERRIDE, 1 forces the profile update
            $scaleResult = [User32Dpi]::SystemParametersInfo(0x009F, $dpiIndex, [IntPtr]::Zero, 1)
            
            if ($scaleResult) {
                Write-Host "Scaling successfully reset to 100%"
            } else {
                Write-Host "Scaling API reset call failed."
            }
            # --- END OF SCALING RESET LOGIC ---
            
        } else {
            Write-Host "Failed. Error code: $result"
        }
        break
    }
    $modeNum++
}
