param(
    [Parameter(Mandatory = $true)]
    [string]$BusId
)

$ErrorActionPreference = "Stop"

Write-Host "Binding J-Link USB device on BUSID $BusId..."
usbipd bind --busid $BusId

Write-Host "Attaching J-Link to the default WSL distribution..."
usbipd attach --wsl --busid $BusId

Write-Host "Done. In WSL, run: lsusb"
