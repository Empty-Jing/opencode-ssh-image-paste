param(
    [string]$SshTarget,
    [string]$Version = "latest",
    [switch]$SkipChecksum
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$Repository = "Empty-Jing/opencode-ssh-image-paste"
$ProgramName = "opencode-ssh-image-paste"
$InstallDir = Join-Path $env:LOCALAPPDATA "Programs\OpenCodeSSHImagePaste"
$ConfigDir = Join-Path $env:APPDATA "OpenCodeSSHImagePaste"
$ConfigPath = Join-Path $ConfigDir "config.toml"
$InstalledBinary = Join-Path $InstallDir "$ProgramName.exe"

function Write-Step([string]$Message) {
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function ConvertTo-TomlBasicString([string]$Value) {
    $escaped = $Value.Replace("\", "\\").Replace('"', '\"')
    $escaped = $escaped.Replace("`r", "\r").Replace("`n", "\n").Replace("`t", "\t")
    return '"' + $escaped + '"'
}

function Get-Release {
    $headers = @{ "User-Agent" = "opencode-ssh-image-paste-bootstrap" }
    if ($Version -eq "latest") {
        return Invoke-RestMethod -Headers $headers -Uri "https://api.github.com/repos/$Repository/releases/latest"
    }
    $tag = if ($Version.StartsWith("v")) { $Version } else { "v$Version" }
    return Invoke-RestMethod -Headers $headers -Uri "https://api.github.com/repos/$Repository/releases/tags/$tag"
}

function Get-Asset($Release, [string]$Name) {
    $asset = $Release.assets | Where-Object { $_.name -eq $Name } | Select-Object -First 1
    if (-not $asset) {
        throw "Release asset not found: $Name"
    }
    return $asset
}

function Download-Asset($Release, [string]$Name, [string]$Destination) {
    $asset = Get-Asset $Release $Name
    Invoke-WebRequest -UseBasicParsing -Uri $asset.browser_download_url -OutFile $Destination
}

function Assert-Checksum([string]$File, [string]$ChecksumsFile, [string]$AssetName) {
    if ($SkipChecksum) {
        return
    }
    $line = Get-Content $ChecksumsFile | Where-Object { $_ -match "^[0-9a-fA-F]{64}\s+\*?$([regex]::Escape($AssetName))$" } | Select-Object -First 1
    if (-not $line) {
        throw "No SHA-256 entry found for $AssetName"
    }
    $expected = ($line -split '\s+')[0].ToLowerInvariant()
    $actual = (Get-FileHash -Algorithm SHA256 -Path $File).Hash.ToLowerInvariant()
    if ($actual -ne $expected) {
        throw "SHA-256 mismatch for $AssetName"
    }
}

if (-not (Get-Command ssh.exe -ErrorAction SilentlyContinue)) {
    throw "Windows OpenSSH Client was not found. Install it in Settings > Optional Features."
}
if (-not (Get-Command scp.exe -ErrorAction SilentlyContinue)) {
    throw "scp.exe was not found. Install the Windows OpenSSH Client optional feature."
}
if (-not $SshTarget) {
    $SshTarget = Read-Host "SSH host or alias (for example ubuntu-workbox)"
}
if ([string]::IsNullOrWhiteSpace($SshTarget) -or $SshTarget.StartsWith("-")) {
    throw "A valid SSH host or alias is required."
}

$TempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("opencode-ssh-image-paste-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $TempDir | Out-Null

try {
    Write-Step "Testing SSH connection to $SshTarget"
    & ssh.exe -o BatchMode=yes -o ConnectTimeout=10 -- $SshTarget "printf ready"
    if ($LASTEXITCODE -ne 0) {
        throw "SSH connection failed. Configure a host key and non-interactive key or ssh-agent authentication first."
    }

    $remoteArchitecture = (& ssh.exe -o BatchMode=yes -- $SshTarget "uname -m").Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "Could not detect the remote architecture."
    }
    $linuxAsset = switch ($remoteArchitecture) {
        { $_ -in @("x86_64", "amd64") } { "$ProgramName-linux-x86_64"; break }
        { $_ -in @("aarch64", "arm64") } { "$ProgramName-linux-aarch64"; break }
        default { throw "Unsupported remote architecture: $remoteArchitecture" }
    }

    Write-Step "Finding release $Version"
    $release = Get-Release
    $windowsAsset = "$ProgramName-windows-x86_64.exe"
    $checksumsAsset = "SHA256SUMS"
    $windowsDownload = Join-Path $TempDir $windowsAsset
    $linuxDownload = Join-Path $TempDir $linuxAsset
    $checksumsDownload = Join-Path $TempDir $checksumsAsset

    Write-Step "Downloading $($release.tag_name) binaries"
    Download-Asset $release $windowsAsset $windowsDownload
    Download-Asset $release $linuxAsset $linuxDownload
    if (-not $SkipChecksum) {
        Download-Asset $release $checksumsAsset $checksumsDownload
        Assert-Checksum $windowsDownload $checksumsDownload $windowsAsset
        Assert-Checksum $linuxDownload $checksumsDownload $linuxAsset
    }

    Write-Step "Installing Linux receiver ($remoteArchitecture)"
    $remoteTemporary = ".local/bin/$ProgramName.download"
    & ssh.exe -o BatchMode=yes -- $SshTarget "mkdir -p ~/.local/bin"
    if ($LASTEXITCODE -ne 0) { throw "Could not create ~/.local/bin on the remote host." }
    & scp.exe -q -- $linuxDownload "${SshTarget}:$remoteTemporary"
    if ($LASTEXITCODE -ne 0) { throw "Could not upload the Linux receiver." }
    & ssh.exe -o BatchMode=yes -- $SshTarget "chmod 755 ~/$remoteTemporary && mv -f ~/$remoteTemporary ~/.local/bin/$ProgramName && ~/.local/bin/$ProgramName --version"
    if ($LASTEXITCODE -ne 0) { throw "Could not activate the Linux receiver." }

    Write-Step "Installing Windows client"
    New-Item -ItemType Directory -Force -Path $InstallDir, $ConfigDir | Out-Null
    Get-CimInstance Win32_Process -Filter "Name='$ProgramName.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -eq $InstalledBinary } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
    Copy-Item -Force $windowsDownload $InstalledBinary

    if (-not (Test-Path $ConfigPath)) {
        $target = ConvertTo-TomlBasicString $SshTarget
        @"
ssh_target = $target
ssh_program = "ssh.exe"
ssh_arguments = []
remote_command = "~/.local/bin/opencode-ssh-image-paste receiver"
terminal_window_class = "CASCADIA_HOSTING_WINDOW_CLASS"
restore_clipboard_delay_ms = 150
request_timeout_seconds = 15
"@ | Set-Content -Encoding UTF8 $ConfigPath
    } else {
        $target = ConvertTo-TomlBasicString $SshTarget
        $existingConfig = Get-Content -Raw $ConfigPath
        if ($existingConfig -match '(?m)^ssh_target\s*=') {
            $existingConfig = $existingConfig -replace '(?m)^ssh_target\s*=.*$', "ssh_target = $target"
            Set-Content -Encoding UTF8 -Path $ConfigPath -Value $existingConfig
        } else {
            throw "Existing configuration has no ssh_target: $ConfigPath"
        }
        Write-Host "Updated SSH target and kept other settings: $ConfigPath"
    }

    $startup = [Environment]::GetFolderPath("Startup")
    $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path $startup "OpenCode SSH Image Paste.lnk"))
    $shortcut.TargetPath = $InstalledBinary
    $shortcut.Arguments = "client `"$ConfigPath`""
    $shortcut.WorkingDirectory = $InstallDir
    $shortcut.WindowStyle = 7
    $shortcut.Save()

    Start-Process -FilePath $InstalledBinary -ArgumentList @("client", "`"$ConfigPath`"") -WindowStyle Minimized
    Start-Sleep -Milliseconds 500

    Write-Step "Running diagnostics"
    & $InstalledBinary doctor $ConfigPath
    if ($LASTEXITCODE -ne 0) {
        throw "Installation completed, but diagnostics found a problem."
    }

    Write-Host ""
    Write-Host "Installation complete. Copy an image, focus Windows Terminal, and press Ctrl+V." -ForegroundColor Green
    Write-Host "Config: $ConfigPath"
} finally {
    if (Test-Path $TempDir) {
        Remove-Item -Recurse -Force $TempDir
    }
}
