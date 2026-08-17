$ErrorActionPreference = "Stop"
$temporaryBase = if ([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { [IO.Path]::GetTempPath() } else { $env:RUNNER_TEMP }
$testRoot = Join-Path $temporaryBase ("bootstrap-uninstall-test-" + [guid]::NewGuid().ToString("N"))
$previousLocalAppData = $env:LOCALAPPDATA
$previousAppData = $env:APPDATA
$env:LOCALAPPDATA = Join-Path $testRoot "LocalAppData"
$env:APPDATA = Join-Path $testRoot "AppData"
$installDir = Join-Path $env:LOCALAPPDATA "Programs\OpenCodeSSHImagePaste"
$configDir = Join-Path $env:APPDATA "OpenCodeSSHImagePaste"
$terminalDir = Join-Path $env:LOCALAPPDATA "Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState"
$terminalSettings = Join-Path $terminalDir "settings.json"

try {
    New-Item -ItemType Directory -Force -Path $installDir, $configDir, $terminalDir | Out-Null
    Set-Content -Path (Join-Path $installDir "opencode-ssh-image-paste.exe") -Value "test"
    Set-Content -Path (Join-Path $configDir "config.toml") -Value "test = true"
    Set-Content -Path (Join-Path $configDir "receiver-cert.pem") -Value "https certificate fixture"
    @(
        '{',
        '  "actions": [',
        '    {',
        '      "command": {"action":"sendInput","input":"latest.png"},',
        '      "id": "User.OpenCodeSSHImagePaste.AtomicPaste"',
        '    },',
        '    {"command":"copy","id":"User.KeepThisAction"}',
        '  ],',
        '  "keybindings": [',
        '    {',
        '      "keys": "ctrl+alt+shift+f24",',
        '      "id": "User.OpenCodeSSHImagePaste.AtomicPaste"',
        '    }',
        '  ]',
        '}'
    ) | Set-Content -Path $terminalSettings
    Set-Content -Path "$terminalSettings.opencode-ssh-image-paste.backup" -Value "backup"

    & (Join-Path $PSScriptRoot "..\bootstrap.ps1") -Uninstall
    if (Test-Path $installDir) { throw "Uninstall did not remove the install directory." }
    if (Test-Path $configDir) { throw "Uninstall did not remove the config directory or HTTPS certificate." }
    if ((Get-Content -Raw $terminalSettings) -match "OpenCodeSSHImagePaste") {
        throw "Uninstall did not remove the Windows Terminal action."
    }
    if ((Get-Content -Raw $terminalSettings) -notmatch "User.KeepThisAction") {
        throw "Uninstall removed an unrelated Windows Terminal action."
    }
    try {
        Get-Content -Raw $terminalSettings | ConvertFrom-Json | Out-Null
    } catch {
        throw "Uninstall left invalid Windows Terminal JSON: $_"
    }
    if (Test-Path "$terminalSettings.opencode-ssh-image-paste.backup") {
        throw "Uninstall did not remove the Windows Terminal settings backup."
    }

    New-Item -ItemType Directory -Force -Path $installDir, $configDir | Out-Null
    Set-Content -Path (Join-Path $installDir "opencode-ssh-image-paste.exe") -Value "test"
    Set-Content -Path (Join-Path $configDir "config.toml") -Value "test = true"
    Set-Content -Path (Join-Path $configDir "receiver-cert.pem") -Value "https certificate fixture"

    & (Join-Path $PSScriptRoot "..\bootstrap.ps1") -Uninstall -KeepConfig
    if (Test-Path $installDir) { throw "Uninstall did not remove the install directory." }
    if (-not (Test-Path (Join-Path $configDir "config.toml"))) {
        throw "-KeepConfig did not preserve the configuration."
    }
    if (-not (Test-Path (Join-Path $configDir "receiver-cert.pem"))) {
        throw "-KeepConfig did not preserve the dedicated HTTPS certificate."
    }
} finally {
    $env:LOCALAPPDATA = $previousLocalAppData
    $env:APPDATA = $previousAppData
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $testRoot
}
