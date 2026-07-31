param(
    [Parameter(Mandatory = $true)]
    [string]$SshTarget,
    [string]$BinaryPath = ".\opencode-ssh-image-paste.exe",
    [string]$RemoteCommand = "~/.local/bin/opencode-ssh-image-paste receiver"
)

$ErrorActionPreference = "Stop"
$installDir = Join-Path $env:LOCALAPPDATA "Programs\OpenCodeSSHImagePaste"
$configDir = Join-Path $env:APPDATA "OpenCodeSSHImagePaste"
$configPath = Join-Path $configDir "config.toml"
$installedBinary = Join-Path $installDir "opencode-ssh-image-paste.exe"

if (-not (Test-Path $BinaryPath)) {
    throw "Binary not found: $BinaryPath"
}

function ConvertTo-TomlBasicString([string]$Value) {
    $escaped = $Value.Replace("\", "\\").Replace('"', '\"')
    $escaped = $escaped.Replace("`r", "\r").Replace("`n", "\n").Replace("`t", "\t")
    return '"' + $escaped + '"'
}

New-Item -ItemType Directory -Force -Path $installDir, $configDir | Out-Null
Copy-Item -Force $BinaryPath $installedBinary

if (-not (Test-Path $configPath)) {
    $sshTargetToml = ConvertTo-TomlBasicString $SshTarget
    $remoteCommandToml = ConvertTo-TomlBasicString $RemoteCommand
    @"
ssh_target = $sshTargetToml
ssh_program = "ssh.exe"
ssh_arguments = []
remote_command = $remoteCommandToml
remote_probe_command = "~/.local/bin/opencode-ssh-image-paste --version"
terminal_window_class = "CASCADIA_HOSTING_WINDOW_CLASS"
restore_clipboard_delay_ms = 150
request_timeout_seconds = 15
"@ | Set-Content -Encoding UTF8 $configPath
}

$startup = [Environment]::GetFolderPath("Startup")
$shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut(
    (Join-Path $startup "OpenCode SSH Image Paste.lnk")
)
$shortcut.TargetPath = $installedBinary
$shortcut.Arguments = "client `"$configPath`""
$shortcut.WorkingDirectory = $installDir
$shortcut.WindowStyle = 7
$shortcut.Save()

Start-Process -FilePath $installedBinary -ArgumentList @("client", "`"$configPath`"") -WindowStyle Hidden
Write-Host "Installed Windows client: $installedBinary"
Write-Host "Config: $configPath"
Write-Host "The bridge now starts automatically after Windows login."
