param(
    [Parameter(Mandatory = $true)]
    [string]$BusId
)

$ErrorActionPreference = "Stop"

usbipd detach --busid $BusId
Write-Host "J-Link detached from WSL and returned to Windows."
