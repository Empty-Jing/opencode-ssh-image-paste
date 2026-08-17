$ErrorActionPreference = "Stop"
$temporaryBase = if ([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { [IO.Path]::GetTempPath() } else { $env:RUNNER_TEMP }
$testRoot = Join-Path $temporaryBase ("bootstrap-tests-" + [guid]::NewGuid().ToString("N"))
$previousLocalAppData = $env:LOCALAPPDATA
$previousAppData = $env:APPDATA

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function New-OwnedAction([int]$Slot) {
    $slotText = $Slot.ToString("00")
    return '{"command":{"action":"sendInput","input":"image-' + $slotText +
        '.png"},"id":"User.OpenCodeSSHImagePaste.AtomicPaste.Slot' + $slotText + '"}'
}

try {
    $env:LOCALAPPDATA = Join-Path $testRoot "LocalAppData"
    $env:APPDATA = Join-Path $testRoot "AppData"
    New-Item -ItemType Directory -Force -Path $env:LOCALAPPDATA, $env:APPDATA | Out-Null

    . (Join-Path $PSScriptRoot "..\bootstrap.ps1") -InternalTestMode

    Assert-True (-not $UseElevatedStartup) "Default installation did not select normal startup."
    Assert-True $UseHttpsTransport "Default installation did not select HTTPS transport."
    Assert-True ($HttpsPort -eq 47832) "Default HTTPS port was not 47832."
    $legacyMode = & {
        . (Join-Path $PSScriptRoot "..\bootstrap.ps1") -InternalTestMode -LegacySshTransport
        return -not $UseHttpsTransport
    }
    Assert-True $legacyMode "-LegacySshTransport did not explicitly select SSH transport."
    $explicitElevated = & {
        . (Join-Path $PSScriptRoot "..\bootstrap.ps1") -InternalTestMode -ElevatedStartup
        return $UseElevatedStartup
    }
    Assert-True $explicitElevated "-ElevatedStartup did not select elevated startup."
    $conflictingStartupRejected = $false
    try {
        & (Join-Path $PSScriptRoot "..\bootstrap.ps1") -InternalTestMode -ElevatedStartup -NonElevatedStartup
    } catch {
        $conflictingStartupRejected = $_.Exception.Message -match "cannot be used together"
    }
    Assert-True $conflictingStartupRejected "Conflicting startup mode switches were not rejected."

    # PowerShell coerces $null passed to a [string] parameter into "". Fresh
    # installation must treat both representations as an absent config.
    $freshConfig = Get-UpdatedConfigText `
        -ExistingConfig $null `
        -Target "test-workbox" `
        -RemotePasteDirectory "/home/test/.cache/opencode-ssh-image-paste"
    Assert-True ($freshConfig -match '(?m)^transport = "ssh"\r?$') "Fresh legacy install did not select explicit SSH transport."
    Assert-True ($freshConfig -match '(?m)^ssh_target = "test-workbox"\r?$') "Fresh install did not create ssh_target."
    Assert-True ($freshConfig -match '(?m)^terminal_paste_directory = "/home/test/.cache/opencode-ssh-image-paste"\r?$') "Fresh install did not create terminal_paste_directory."

    $httpsConfig = Get-UpdatedConfigText `
        -ExistingConfig $freshConfig `
        -Target "test-workbox" `
        -RemotePasteDirectory "/home/test/.cache/opencode-ssh-image-paste" `
        -UseHttps $true `
        -HttpsEndpoint "https://10.0.0.8:47832" `
        -HttpsToken ("ab" * 32) `
        -HttpsCertificatePath "C:\fixture\receiver-cert.pem"
    Assert-True ($httpsConfig -match '(?m)^transport = "https"\r?$') "HTTPS migration did not select HTTPS transport."
    Assert-True ($httpsConfig -match '(?m)^https_endpoint = "https://10.0.0.8:47832"\r?$') "HTTPS migration omitted its endpoint."
    Assert-True ($httpsConfig -match '(?m)^https_token = "[0-9a-f]{64}"\r?$') "HTTPS migration omitted its generated token."
    Assert-True ($httpsConfig -match '(?m)^https_certificate_path = "C:\\\\fixture\\\\receiver-cert.pem"\r?$') "HTTPS migration omitted its dedicated certificate."
    Assert-True ([regex]::Matches($httpsConfig, '(?m)^transport\s*=').Count -eq 1) "Repeated migration duplicated transport settings."
    Assert-True ((Get-HttpsEndpoint "2001:db8::8" 47832) -ceq "https://[2001:db8::8]:47832") "IPv6 HTTPS endpoint did not use brackets."

    $serviceText = Get-SystemdUserServiceText
    Assert-True ($serviceText -match 'ExecStart=%h/.local/bin/opencode-ssh-image-paste receiver --https-config %h/.config/opencode-ssh-image-paste/receiver.toml') "systemd user service does not use the HTTPS receiver config."
    Assert-True ($serviceText -match '(?m)^Restart=on-failure\r?$') "systemd user service does not restart failed receivers."
    foreach ($hardening in @('UMask=0077', 'NoNewPrivileges=true', 'PrivateTmp=true', 'ProtectSystem=strict', 'ReadWritePaths=%h/.cache/opencode-ssh-image-paste')) {
        Assert-True ($serviceText -match "(?m)^$([regex]::Escape($hardening))\r?$") "systemd service omitted hardening: $hardening"
    }
    Assert-True ($serviceText -notmatch '(?i)token|bearer') "systemd service leaks HTTPS credentials."

    $stopCommand = Get-SystemdStopCommand $false
    $disableCommand = Get-SystemdStopCommand $true
    Assert-True ($stopCommand -match 'LoadState') "systemd stop does not distinguish a missing unit from an operation failure."
    Assert-True ($disableCommand -match 'disable --now') "systemd fallback/uninstall command does not disable and stop the service."
    Assert-True ($disableCommand -match 'is-active --quiet') "systemd fallback/uninstall command does not verify the service is inactive."
    Assert-True ($disableCommand -notmatch '\|\| true') "systemd fallback/uninstall command unconditionally swallows failures."

    $bootstrapText = [IO.File]::ReadAllText((Join-Path $PSScriptRoot "..\bootstrap.ps1"))
    Assert-True ($bootstrapText -match 'cp -a ~\/\$ReceiverConfigDirectory ~\/\$remoteHttpsRollback/config; touch ~\/\$remoteHttpsRollback/config-existed') "Remote config snapshot marks success before copy completion."
    Assert-True ($bootstrapText -match 'if \(\$UseHttpsTransport -and \$remoteHttpsStateCaptured\)') "HTTPS rollback is not gated by a verified service-state snapshot."
    Assert-True ($bootstrapText -match 'else \{\s*\$restoreRemote = "set -eu; \$restoreBinary"') "Legacy SSH rollback still requires a systemd service-state snapshot."
    Assert-True ($bootstrapText -match 'Add-Type -AssemblyName System\.Net\.Http') "Windows PowerShell HTTPS probe does not load System.Net.Http."
    Assert-True ($bootstrapText -match 'PinnedCertificateHttpHandler\]::Create\(\$expectedCertificate\.RawData\)') "HTTPS probe does not create its runspace-independent certificate handler."
    Assert-True ($bootstrapText -match 'ServerCertificateCustomValidationCallback = delegate') "Certificate validation still depends on a PowerShell ScriptBlock callback."
    Assert-True ($bootstrapText -match 'difference \|= certificate\.RawData\[index\] \^ expected\[index\]') "Pinned certificate handler does not compare the complete certificate bytes."
    Assert-True ($bootstrapText -match 'SecurityProtocol = \$previousSecurityProtocol -bor \[Net\.SecurityProtocolType\]::Tls12') "Windows PowerShell HTTPS probe does not enable TLS 1.2."
    Assert-True ($bootstrapText -match 'handler\.UseProxy = false;') "Direct LAN HTTPS probe still inherits the Windows proxy."
    Assert-True ($bootstrapText -match 'SecurityProtocol = \$previousSecurityProtocol\s*\r?\n') "HTTPS probe does not restore the process-wide TLS setting."
    Assert-True ($bootstrapText -match 'elseif \(\$currentCertificate -ceq \$existingCertificateText\)') "Certificate rollback does not accept an already-restored original file."
    Assert-True ($bootstrapText -match '\[array\]::Reverse\(\$terminalItems\)') "Terminal rollback does not restore modifications in reverse order."
    $localRemoval = $bootstrapText.IndexOf('Write-Step "Removing Windows client"', [StringComparison]::Ordinal)
    $remoteRemoval = $bootstrapText.IndexOf('Write-Step "Removing Linux receiver from $target"', [StringComparison]::Ordinal)
    Assert-True ($localRemoval -ge 0 -and $remoteRemoval -gt $localRemoval) "Uninstall deletes the remote receiver before local removal succeeds."
    $httpsProbe = $bootstrapText.IndexOf('Test-HttpsReceiver $httpsEndpoint $httpsToken $downloadedCertificate', [StringComparison]::Ordinal)
    $terminalCommit = $bootstrapText.IndexOf('Write-Step "Configuring 10 atomic Windows Terminal paste actions"', [StringComparison]::Ordinal)
    Assert-True ($httpsProbe -ge 0 -and $terminalCommit -gt $httpsProbe) "Terminal actions are committed before the HTTPS receiver passes its live probe."

    $wrapperText = [IO.File]::ReadAllText((Join-Path $PSScriptRoot "..\install-windows.ps1"))
    foreach ($forwarded in @('HttpsHost', 'HttpsPort', 'LegacySshTransport')) {
        Assert-True ($wrapperText -match "-$forwarded") "install-windows.ps1 does not forward -$forwarded."
    }

    # Login startup must go through the GUI-subsystem Windows Script Host. A
    # shortcut that directly targets the console client briefly opens a window
    # before client mode can call FreeConsole.
    $launcherText = Get-ClientLauncherText
    Assert-True ($launcherText -match '(?m)^shell\.Run .+, 0, False\r?$') "Client launcher does not request a hidden, asynchronous process."
    Assert-True ($launcherText -match [regex]::Escape($InstalledBinary)) "Client launcher does not target the installed binary."
    Assert-True ($launcherText -match [regex]::Escape($ConfigPath)) "Client launcher does not pass the installed configuration."

    $startupFixture = Join-Path $testRoot "OpenCode SSH Image Paste.lnk"
    Set-StartupShortcut $startupFixture
    $startupShortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($startupFixture)
    Assert-True ($startupShortcut.TargetPath -ieq $WindowsScriptHost) "Startup shortcut directly launches a console executable."
    Assert-True ($startupShortcut.Arguments -match [regex]::Escape($LauncherPath)) "Startup shortcut does not invoke the hidden client launcher."

    # An administrator installer must broker normal startup through Explorer;
    # directly starting wscript would leak the elevated token into the client.
    $originalTestIsAdministrator = ${function:Test-IsAdministrator}
    $script:normalStart = $null
    function Test-IsAdministrator { return $true }
    function Start-Process {
        param($FilePath, $ArgumentList)
        $script:normalStart = [pscustomobject]@{ FilePath = $FilePath; ArgumentList = $ArgumentList }
    }
    try {
        Start-NormalInstalledClient $startupFixture
    } finally {
        Remove-Item -Force "Function:\Start-Process"
        Set-Item "Function:\Test-IsAdministrator" $originalTestIsAdministrator
    }
    Assert-True ($script:normalStart.FilePath -ieq (Join-Path $env:SystemRoot "explorer.exe")) "Elevated installer did not broker normal startup through Explorer."
    Assert-True (($script:normalStart.ArgumentList -join " ") -match [regex]::Escape($startupFixture)) "Explorer startup did not target the installed Startup shortcut."

    # Elevated startup must remain per-user and launch the same hidden VBS
    # entrypoint at the highest run level. Mock ScheduledTasks cmdlets so the
    # fixture never creates or modifies a machine task.
    $script:registeredTask = $null
    function New-ScheduledTaskAction {
        param($Execute, $Argument, $WorkingDirectory)
        return [pscustomobject]@{ Execute = $Execute; Argument = $Argument; WorkingDirectory = $WorkingDirectory }
    }
    function New-ScheduledTaskTrigger {
        param([switch]$AtLogOn, $User)
        return [pscustomobject]@{ AtLogOn = $AtLogOn; User = $User }
    }
    function New-ScheduledTaskPrincipal {
        param($UserId, $LogonType, $RunLevel)
        return [pscustomobject]@{ UserId = $UserId; LogonType = $LogonType; RunLevel = $RunLevel }
    }
    function New-ScheduledTaskSettingsSet {
        param([switch]$AllowStartIfOnBatteries, [switch]$DontStopIfGoingOnBatteries, $ExecutionTimeLimit)
        return [pscustomobject]@{ ExecutionTimeLimit = $ExecutionTimeLimit }
    }
    function Register-ScheduledTask {
        param($TaskName, $Action, $Trigger, $Principal, $Settings, $Description, [switch]$Force)
        $script:registeredTask = [pscustomobject]@{
            TaskName = $TaskName
            Action = $Action
            Trigger = $Trigger
            Principal = $Principal
            Settings = $Settings
        }
    }
    try {
        Register-ElevatedStartupTask
        Assert-True ($script:registeredTask.TaskName -eq $StartupTaskName) "Elevated startup registered the wrong task name."
        Assert-True ($script:registeredTask.Action.Execute -ieq $WindowsScriptHost) "Elevated startup does not use Windows Script Host."
        Assert-True ($script:registeredTask.Action.Argument -match [regex]::Escape($LauncherPath)) "Elevated startup does not invoke the hidden launcher."
        Assert-True ($script:registeredTask.Trigger.User -eq [Security.Principal.WindowsIdentity]::GetCurrent().Name) "Elevated startup is not scoped to the current user."
        Assert-True ($script:registeredTask.Principal.RunLevel -eq "Highest") "Elevated startup does not request the highest run level."
    } finally {
        foreach ($mock in @(
            "New-ScheduledTaskAction",
            "New-ScheduledTaskTrigger",
            "New-ScheduledTaskPrincipal",
            "New-ScheduledTaskSettingsSet",
            "Register-ScheduledTask"
        )) {
            Remove-Item -Force "Function:\$mock"
        }
    }

    # WScript.Shell.Run is asynchronous. Client startup can legitimately take
    # longer than the old fixed 500 ms delay, especially immediately after an
    # upgrade when application-control software scans the replacement binary.
    $script:startupProbeCalls = 0
    $startedAfterDelay = Wait-InstalledClientRunning -TimeoutMilliseconds 1000 -Probe {
        $script:startupProbeCalls++
        return $script:startupProbeCalls -ge 7
    }
    Assert-True $startedAfterDelay "Client startup polling rejected a delayed successful launch."
    Assert-True ($script:startupProbeCalls -eq 7) "Client startup polling did not stop after detecting the process."

    $script:shutdownProbeCalls = 0
    $stoppedAfterDelay = Wait-InstalledClientStopped -TimeoutMilliseconds 1000 -Probe {
        $script:shutdownProbeCalls++
        return $script:shutdownProbeCalls -lt 7
    }
    Assert-True $stoppedAfterDelay "Client shutdown polling rejected a delayed successful exit."
    Assert-True ($script:shutdownProbeCalls -eq 7) "Client shutdown polling did not stop after detecting process exit."

    # Regression: deleting adjacent objects from immutable ranges must not use
    # offsets made stale by an earlier deletion.
    # Cleanup must remain compatible with the 50 actions installed by v0.1.8.
    $owned = @(0..49 | ForEach-Object { New-OwnedAction $_ })
    $onlyOwned = "{`r`n  `"actions`": [`r`n" + ($owned -join ",`r`n") + "`r`n  ]`r`n}"
    $cleaned = Remove-OurTerminalAction $onlyOwned
    Assert-ValidWindowsTerminalJsonc $cleaned "only-owned fixture"
    Assert-True ($cleaned -notmatch "OpenCodeSSHImagePaste") "Cleanup left an owned action behind."

    # Marker-based cleanup must remain compatible with bootstrap's original
    # layout and preserve unrelated JSONC comments and trailing commas.
    $marked = @"
{
  // keep this comment
  "actions": [
    $TerminalActionBegin
$(($owned | ForEach-Object { "    $_," }) -join "`r`n")
    $TerminalActionEnd
    {"command":"copy","id":"User.KeepAfterMarker"},
  ],
}
"@
    $cleanedMarked = Remove-OurTerminalAction $marked
    Assert-ValidWindowsTerminalJsonc $cleanedMarked "marked fixture"
    Assert-True ($cleanedMarked -match "keep this comment") "Cleanup removed a user comment."
    Assert-True ($cleanedMarked -match "User.KeepAfterMarker") "Cleanup removed an unrelated action."
    Assert-True ($cleanedMarked -notmatch "OpenCodeSSHImagePaste") "Marker cleanup left an owned action behind."

    # Simulate Windows Terminal dropping markers and serializing project-owned
    # objects between user objects, with comments and a trailing comma.
    $rewritten = @"
{
  "actions": [
    {"command":"copy","id":"User.KeepBefore"},
$(($owned | ForEach-Object { "    $_," }) -join "`r`n")
    {"command":"paste","id":"User.KeepAfter"},
  ],
  // another user setting
  "profiles": {"defaults": {},},
}
"@
    $cleanedRewritten = Remove-OurTerminalAction $rewritten
    Assert-ValidWindowsTerminalJsonc $cleanedRewritten "rewritten fixture"
    Assert-True ($cleanedRewritten -match "User.KeepBefore") "Cleanup removed the preceding user action."
    Assert-True ($cleanedRewritten -match "User.KeepAfter") "Cleanup removed the following user action."
    Assert-True ($cleanedRewritten -match "another user setting") "Cleanup discarded JSONC comments."
    Assert-True ($cleanedRewritten -notmatch "OpenCodeSSHImagePaste") "Rewritten cleanup left an owned action behind."

    # Exercise real file installation twice, then uninstall. This covers marker
    # idempotency, atomic replacement, comments/trailing commas and user content.
    $terminalDir = Join-Path $env:LOCALAPPDATA "Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState"
    $terminalSettings = Join-Path $terminalDir "settings.json"
    New-Item -ItemType Directory -Force -Path $terminalDir | Out-Null

    # A valid compact actions array can place its first element directly after
    # `[`. The inserted // END marker must terminate before that element or the
    # line comment swallows it and leaves invalid JSONC.
    $emptyActionsSettings = '{"actions":[]}'
    [IO.File]::WriteAllText($terminalSettings, $emptyActionsSettings, (New-Object Text.UTF8Encoding($false)))
    $emptyActionsUpdates = @(Get-WindowsTerminalActionUpdates "/home/test/.cache/opencode-ssh-image-paste")
    Assert-True ($emptyActionsUpdates.Count -eq 1) "Empty actions fixture did not produce one update."
    Assert-ValidWindowsTerminalJsonc $emptyActionsUpdates[0].Text "empty actions fixture"
    Assert-True ($emptyActionsUpdates[0].Text -notmatch ',\s*// OpenCodeSSHImagePaste Action END\s*\]') "Empty actions update left a trailing comma before the array closed."

    # v0.1.8 added a comma after every generated action. With an otherwise empty
    # actions array, some Terminal versions rejected the comma before `]`. A
    # rerun must remove that old block and repair the file automatically.
    $v018BrokenSettings = $emptyActionsUpdates[0].Text -replace "(`r?`n        $([regex]::Escape($TerminalActionEnd)))", ",`$1"
    [IO.File]::WriteAllText($terminalSettings, $v018BrokenSettings, (New-Object Text.UTF8Encoding($false)))
    $repairedActionsUpdates = @(Get-WindowsTerminalActionUpdates "/home/test/.cache/opencode-ssh-image-paste")
    Assert-True ($repairedActionsUpdates.Count -eq 1) "v0.1.8 repair fixture did not produce one update."
    Assert-ValidWindowsTerminalJsonc $repairedActionsUpdates[0].Text "v0.1.8 repair fixture"
    Assert-True ($repairedActionsUpdates[0].Text -notmatch ',\s*// OpenCodeSSHImagePaste Action END\s*\]') "Rerun did not repair the v0.1.8 trailing comma."

    $compactSettings = '{"actions":[{"command":"copy","id":"User.KeepInline"}]}'
    [IO.File]::WriteAllText($terminalSettings, $compactSettings, (New-Object Text.UTF8Encoding($false)))
    $compactUpdates = @(Get-WindowsTerminalActionUpdates "/home/test/.cache/opencode-ssh-image-paste")
    Assert-True ($compactUpdates.Count -eq 1) "Compact actions fixture did not produce one update."
    Assert-ValidWindowsTerminalJsonc $compactUpdates[0].Text "compact actions fixture"
    Assert-True ($compactUpdates[0].Text -match "User.KeepInline") "Compact actions update removed the user's inline action."

    # Composite commands can contain nested actions arrays. Project actions
    # belong only in the root settings actions array.
    $nestedActionsSettings = '{"keybindings":[{"command":{"action":"multipleActions","actions":[{"action":"copy"}]}}],"actions":[]}'
    [IO.File]::WriteAllText($terminalSettings, $nestedActionsSettings, (New-Object Text.UTF8Encoding($false)))
    $nestedActionsUpdates = @(Get-WindowsTerminalActionUpdates "/home/test/.cache/opencode-ssh-image-paste")
    $nestedActionsResult = ConvertFrom-Json (ConvertTo-StrictJson $nestedActionsUpdates[0].Text)
    $nestedOwned = @($nestedActionsResult.keybindings[0].command.actions | Where-Object { $_.id -like "User.OpenCodeSSHImagePaste*" })
    $rootOwned = @($nestedActionsResult.actions | Where-Object { $_.id -like "User.OpenCodeSSHImagePaste*" })
    Assert-True ($nestedOwned.Count -eq 0) "Project actions were inserted into a nested actions array."
    Assert-True ($rootOwned.Count -eq 10) "Project actions were not inserted into the root actions array."

    $escapedActionsSettings = '{"\u0061ctions":[{"command":"copy","id":"User.EscapedRoot"}]}'
    [IO.File]::WriteAllText($terminalSettings, $escapedActionsSettings, (New-Object Text.UTF8Encoding($false)))
    $escapedActionsUpdates = @(Get-WindowsTerminalActionUpdates "/home/test/.cache/opencode-ssh-image-paste")
    $escapedActionsResult = ConvertFrom-Json (ConvertTo-StrictJson $escapedActionsUpdates[0].Text)
    Assert-True (@($escapedActionsResult.PSObject.Properties).Count -eq 1) "Escaped root actions key produced a duplicate property."
    Assert-True (@($escapedActionsResult.actions | Where-Object { $_.id -like "User.OpenCodeSSHImagePaste*" }).Count -eq 10) "Escaped root actions key did not receive project actions."
    Assert-True (@($escapedActionsResult.actions | Where-Object { $_.id -eq "User.EscapedRoot" }).Count -eq 1) "Escaped root actions update removed the user action."

    $initialSettings = @"
{
  // user comment survives install and uninstall
  "actions": [
    {"command":"copy","keys":"ctrl+shift+c","id":"User.KeepThisAction"},
  ],
}
"@
    [IO.File]::WriteAllText($terminalSettings, $initialSettings, (New-Object Text.UTF8Encoding($false)))

    Install-WindowsTerminalAction "/home/test/.cache/opencode-ssh-image-paste"
    $firstInstall = [IO.File]::ReadAllText($terminalSettings)
    Assert-ValidWindowsTerminalJsonc $firstInstall "first install"
    Assert-True ([regex]::Matches($firstInstall, 'User\.OpenCodeSSHImagePaste\.AtomicPaste\.Slot\d{2}').Count -eq 10) "First install did not create exactly 10 actions."
    Assert-True ($firstInstall -notmatch 'OpenCode SSH Image Paste \d{2}') "Internal actions should not add command-palette names."

    Install-WindowsTerminalAction "/home/test/.cache/opencode-ssh-image-paste"
    $secondInstall = [IO.File]::ReadAllText($terminalSettings)
    Assert-ValidWindowsTerminalJsonc $secondInstall "second install"
    Assert-True ([regex]::Matches($secondInstall, 'User\.OpenCodeSSHImagePaste\.AtomicPaste\.Slot\d{2}').Count -eq 10) "Repeated install duplicated slot actions."

    Uninstall-WindowsTerminalAction
    $afterUninstall = [IO.File]::ReadAllText($terminalSettings)
    Assert-ValidWindowsTerminalJsonc $afterUninstall "uninstall"
    Assert-True ($afterUninstall -notmatch "OpenCodeSSHImagePaste") "Uninstall left an owned action behind."
    Assert-True ($afterUninstall -match "User.KeepThisAction") "Uninstall removed a user action."
    Assert-True ($afterUninstall -match "user comment survives") "Uninstall removed a user comment."

    # Windows Terminal accepts an array of key chords as well as a single
    # string. Modifier order is semantic, so a reordered array entry must
    # still block installation instead of silently stealing the shortcut.
    $arrayConflict = @"
{
  "actions": [
    {"command":"copy","keys":["shift+alt+ctrl+f13"],"id":"User.ArrayConflict"}
  ]
}
"@
    [IO.File]::WriteAllText($terminalSettings, $arrayConflict, (New-Object Text.UTF8Encoding($false)))
    $conflictRejected = $false
    try {
        $null = @(Get-WindowsTerminalActionUpdates "/home/test/.cache/opencode-ssh-image-paste")
    } catch {
        $conflictRejected = $true
    }
    Assert-True $conflictRejected "An array key binding with reordered modifiers was not detected as a conflict."
    Assert-True ([IO.File]::ReadAllText($terminalSettings) -ceq $arrayConflict) "Conflict detection changed Windows Terminal settings."

    # Restore the normal fixture for the concurrent-write test below.
    [IO.File]::WriteAllText($terminalSettings, $afterUninstall, (New-Object Text.UTF8Encoding($false)))

    # A settings rewrite after planning must abort instead of clobbering the
    # concurrent user edit.
    $updates = @(Get-WindowsTerminalActionUpdates "/home/test/.cache/opencode-ssh-image-paste")
    $concurrentSettings = [IO.File]::ReadAllText($terminalSettings) + "`r`n// concurrent edit`r`n"
    [IO.File]::WriteAllText($terminalSettings, $concurrentSettings, (New-Object Text.UTF8Encoding($false)))
    $concurrencyRejected = $false
    try { Apply-WindowsTerminalUpdate $updates[0] } catch { $concurrencyRejected = $true }
    Assert-True $concurrencyRejected "Atomic settings update did not reject a concurrent edit."
    Assert-True ([IO.File]::ReadAllText($terminalSettings) -ceq $concurrentSettings) "Concurrent settings content was overwritten."
    Assert-True (-not (Test-Path -LiteralPath "$terminalSettings.opencode-ssh-image-paste.backup")) "Rejected concurrent update created a stale stable backup."

    # If a post-replace failure cannot restore the destination, both the
    # same-directory rollback and the stable project backup must remain. Never
    # delete the user's last recoverable copy merely because the write failed.
    $atomicDir = Join-Path $testRoot "atomic-rollback"
    $atomicSettings = Join-Path $atomicDir "settings.json"
    New-Item -ItemType Directory -Force -Path $atomicDir | Out-Null
    $atomicOriginal = "{`r`n  `"actions`": []`r`n}`r`n"
    $atomicUpdated = "{`r`n  `"actions`": [{`"command`":`"copy`"}]`r`n}`r`n"
    [IO.File]::WriteAllText($atomicSettings, $atomicOriginal, (New-Object Text.UTF8Encoding($false)))
    $atomicUpdate = [pscustomobject]@{
        Path = $atomicSettings
        Text = $atomicUpdated
        Original = $atomicOriginal
        BackupCreated = $false
    }
    $atomicFailureObserved = $false
    $script:BootstrapTestFaults["AtomicWriteAfterReplace"] = $true
    $script:BootstrapTestFaults["AtomicWriteBeforeRestore"] = $true
    try {
        Apply-WindowsTerminalUpdate $atomicUpdate
    } catch {
        $atomicFailureObserved = $true
    } finally {
        $script:BootstrapTestFaults.Clear()
    }
    Assert-True $atomicFailureObserved "Fault injection did not fail the atomic write."
    $retainedRollbacks = @(Get-ChildItem -Force -LiteralPath $atomicDir -File | Where-Object { $_.Name -like ".settings.json.*.rollback" })
    Assert-True ($retainedRollbacks.Count -eq 1) "Atomic write failure did not retain exactly one rollback file."
    Assert-True ([IO.File]::ReadAllText($retainedRollbacks[0].FullName) -ceq $atomicOriginal) "Retained atomic rollback did not contain the original settings."
    $stableBackup = "$atomicSettings.opencode-ssh-image-paste.backup"
    Assert-True (Test-Path -LiteralPath $stableBackup) "Atomic write failure removed the stable settings backup."
    Assert-True ([IO.File]::ReadAllText($stableBackup) -ceq $atomicOriginal) "Stable settings backup did not contain the original settings."

    # The stable recovery copy must describe the current operation, not the
    # first install from months earlier.
    $currentBeforeUpgrade = "{`r`n  `"actions`": [{`"id`":`"User.Current`"}]`r`n}`r`n"
    [IO.File]::WriteAllText($atomicSettings, $currentBeforeUpgrade, (New-Object Text.UTF8Encoding($false)))
    $upgradeUpdate = [pscustomobject]@{
        Path = $atomicSettings
        Text = $atomicUpdated
        Original = $currentBeforeUpgrade
        BackupCreated = $false
    }
    Apply-WindowsTerminalUpdate $upgradeUpdate
    Assert-True ([IO.File]::ReadAllText($stableBackup) -ceq $currentBeforeUpgrade) "Stable settings backup was not refreshed before an upgrade."

    # Uninstall preflight must not stop a working client when Terminal settings
    # cannot be parsed. A later write failure, after the stop, must restart the
    # exact client that was running before the attempt.
    New-Item -ItemType Directory -Force -Path $InstallDir, $ConfigDir | Out-Null
    [IO.File]::WriteAllText($InstalledBinary, "fixture", (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText($ConfigPath, 'ssh_target = "fixture"', (New-Object Text.UTF8Encoding($false)))
    $script:uninstallStopCalls = 0
    $script:uninstallStartCalls = 0
    function Test-InstalledClientRunning { return $true }
    function Stop-InstalledClient { $script:uninstallStopCalls++; return $true }
    function Start-InstalledClient { $script:uninstallStartCalls++ }

    [IO.File]::WriteAllText($terminalSettings, "{ invalid", (New-Object Text.UTF8Encoding($false)))
    $invalidSettingsRejected = $false
    try { Invoke-Uninstall } catch { $invalidSettingsRejected = $true }
    Assert-True $invalidSettingsRejected "Uninstall accepted invalid Terminal settings."
    Assert-True ($script:uninstallStopCalls -eq 0) "Uninstall stopped the client before Terminal settings preflight completed."

    [IO.File]::WriteAllText($terminalSettings, $firstInstall, (New-Object Text.UTF8Encoding($false)))
    $script:BootstrapTestFaults["AtomicWriteBeforeReplace"] = $true
    $uninstallWriteRejected = $false
    try {
        Invoke-Uninstall
    } catch {
        $uninstallWriteRejected = $true
    } finally {
        $script:BootstrapTestFaults.Clear()
    }
    Assert-True $uninstallWriteRejected "Fault injection did not fail the Terminal uninstall write."
    Assert-True ($script:uninstallStopCalls -eq 1) "Uninstall did not stop the previously running client exactly once."
    Assert-True ($script:uninstallStartCalls -eq 1) "Failed uninstall did not restart the previously running client exactly once."
    Assert-True (Test-Path -LiteralPath $InstalledBinary) "Failed uninstall removed the installed client."
    Assert-True (Test-Path -LiteralPath $ConfigPath) "Failed uninstall removed the client configuration."

    # If the Terminal write committed and its own restoration failed, restarting
    # would combine the old client with an incompletely restored environment.
    [IO.File]::WriteAllText($terminalSettings, $firstInstall, (New-Object Text.UTF8Encoding($false)))
    $script:BootstrapTestFaults["AtomicWriteAfterReplace"] = $true
    $script:BootstrapTestFaults["AtomicWriteBeforeRestore"] = $true
    try { Invoke-Uninstall } catch { }
    $script:BootstrapTestFaults.Clear()
    Assert-True ($script:uninstallStopCalls -eq 2) "Second failed uninstall did not stop the running client."
    Assert-True ($script:uninstallStartCalls -eq 1) "Uninstall restarted the client after an incomplete Terminal rollback."

    # A previous client is safe to restart only when every dependency was
    # restored. This pure truth table guards against accidentally weakening the
    # rollback gate when new rollback components are added later.
    Assert-True (Test-CanRestartPreviousClient $true $true $true $true) "A complete rollback did not permit restarting the previous client."
    Assert-True (-not (Test-CanRestartPreviousClient $false $true $true $true)) "A client that was not running should not be started."
    Assert-True (-not (Test-CanRestartPreviousClient $true $false $true $true)) "An incomplete rollback permitted a client restart."
    Assert-True (-not (Test-CanRestartPreviousClient $true $true $false $true)) "A missing restored binary permitted a client restart."
    Assert-True (-not (Test-CanRestartPreviousClient $true $true $true $false)) "A missing restored configuration permitted a client restart."

    # The Terminal actions are generated from the candidate receiver's default
    # directory. Preserving a custom receiver --dir would make upload responses
    # disagree with terminal_paste_directory, so automatic installation must
    # reject that configuration before changing either side.
    $customRemoteCommand = @"
ssh_target = "test-workbox"
remote_command = "~/.local/bin/opencode-ssh-image-paste receiver --dir /custom/images"
"@
    $customRemoteCommandRejected = $false
    try {
        $null = Get-UpdatedConfigText $customRemoteCommand "test-workbox" "/home/test/.cache/opencode-ssh-image-paste"
    } catch {
        $customRemoteCommandRejected = $_.Exception.Message -match "does not support a custom remote_command"
    }
    Assert-True $customRemoteCommandRejected "Automatic installation accepted a custom remote receiver directory."
    $quotedCustomRemoteCommand = @"
ssh_target = "test-workbox"
"remote_command" = "~/.local/bin/opencode-ssh-image-paste receiver --dir /quoted/custom"
"@
    $quotedCustomRemoteCommandRejected = $false
    try {
        $null = Get-UpdatedConfigText $quotedCustomRemoteCommand "test-workbox" "/home/test/.cache/opencode-ssh-image-paste"
    } catch {
        $quotedCustomRemoteCommandRejected = $_.Exception.Message -match "does not support a custom remote_command"
    }
    Assert-True $quotedCustomRemoteCommandRejected "Automatic installation missed a quoted custom remote_command key."
    $defaultRemoteCommand = @"
ssh_target = "test-workbox"
remote_command = "~/.local/bin/opencode-ssh-image-paste receiver"
"@
    $null = Get-UpdatedConfigText $defaultRemoteCommand "test-workbox" "/home/test/.cache/opencode-ssh-image-paste"

    # A minimal but valid serde-defaulted TOML config must receive both fields
    # that the terminal-action client now requires.
    $minimal = "# keep`r`nssh_target = `"old`"`r`n"
    $migrated = Get-UpdatedConfigText $minimal "test-workbox" "/home/test/.cache/opencode-ssh-image-paste"
    Assert-True ($migrated -match '(?m)^ssh_target = "test-workbox"\r?$') "Minimal config did not update ssh_target."
    Assert-True ($migrated -match '(?m)^remote_probe_command = "~/.local/bin/opencode-ssh-image-paste receiver --capabilities"\r?$') "Minimal config did not add the capability probe."
    Assert-True ($migrated -match '(?m)^terminal_paste_directory = "/home/test/.cache/opencode-ssh-image-paste"\r?$') "Minimal config did not add terminal_paste_directory."
    Assert-True ($migrated -match "# keep") "Minimal config migration discarded comments."

    Write-Host "Bootstrap fixture tests passed."
} finally {
    $env:LOCALAPPDATA = $previousLocalAppData
    $env:APPDATA = $previousAppData
    Remove-Item -Recurse -Force -LiteralPath $testRoot -ErrorAction SilentlyContinue
}
