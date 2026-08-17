param(
    [Parameter(Mandatory = $true)]
    [string]$SshTarget,
    [Parameter(Mandatory = $true)]
    [string]$WindowsBinaryPath,
    [Parameter(Mandatory = $true)]
    [string]$LinuxBinaryPath,
    [string]$HttpsHost,
    [int]$HttpsPort = 47832,
    [switch]$LegacySshTransport,
    [switch]$ElevatedStartup,
    [switch]$NonElevatedStartup
)

$ErrorActionPreference = "Stop"
$bootstrap = Join-Path $PSScriptRoot "bootstrap.ps1"
if (-not (Test-Path -LiteralPath $bootstrap)) {
    throw "bootstrap.ps1 was not found next to install-windows.ps1."
}

& $bootstrap `
    -SshTarget $SshTarget `
    -WindowsBinaryPath $WindowsBinaryPath `
    -LinuxBinaryPath $LinuxBinaryPath `
    -HttpsHost $HttpsHost `
    -HttpsPort $HttpsPort `
    -LegacySshTransport:$LegacySshTransport `
    -ElevatedStartup:$ElevatedStartup `
    -NonElevatedStartup:$NonElevatedStartup
