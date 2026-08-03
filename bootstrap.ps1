param(
    [string]$SshTarget,
    [string]$Version = "latest",
    [string]$WindowsBinaryPath,
    [string]$LinuxBinaryPath,
    [switch]$SkipChecksum,
    [switch]$NonElevatedStartup,
    [switch]$Uninstall,
    [switch]$KeepConfig,
    [Parameter(DontShow = $true)]
    [switch]$InternalTestMode
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$Repository = "Empty-Jing/opencode-ssh-image-paste"
$ProgramName = "opencode-ssh-image-paste"
$InstallDir = Join-Path $env:LOCALAPPDATA "Programs\OpenCodeSSHImagePaste"
$ConfigDir = Join-Path $env:APPDATA "OpenCodeSSHImagePaste"
$ConfigPath = Join-Path $ConfigDir "config.toml"
$InstalledBinary = Join-Path $InstallDir "$ProgramName.exe"
$LauncherPath = Join-Path $InstallDir "start-client.vbs"
$WindowsScriptHost = Join-Path $env:SystemRoot "System32\wscript.exe"
$StartupTaskName = if ($InternalTestMode) {
    "OpenCode SSH Image Paste (Elevated Bootstrap Test)"
} else {
    "OpenCode SSH Image Paste (Elevated)"
}
$UseElevatedStartup = -not $NonElevatedStartup
$TerminalActionId = "User.OpenCodeSSHImagePaste.AtomicPaste"
$ImageSlotCount = 50
$TerminalActionBegin = "// OpenCodeSSHImagePaste Action BEGIN"
$TerminalActionEnd = "// OpenCodeSSHImagePaste Action END"
$ExpectedCapabilities = "protocol=2;image_slots=50;response=slot-path-v1"
$SshOptions = @(
    "-n", "-T",
    "-o", "BatchMode=yes",
    "-o", "ConnectTimeout=10",
    "-o", "ServerAliveInterval=5",
    "-o", "ServerAliveCountMax=2"
)
$ScpOptions = @(
    "-q",
    "-o", "BatchMode=yes",
    "-o", "ConnectTimeout=10",
    "-o", "ServerAliveInterval=5",
    "-o", "ServerAliveCountMax=2"
)
$script:BootstrapTestFaults = @{}

function Write-Step([string]$Message) {
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Invoke-BootstrapTestFault([string]$Name) {
    if (-not $InternalTestMode -or -not $script:BootstrapTestFaults.ContainsKey($Name)) {
        return
    }
    if ($script:BootstrapTestFaults[$Name]) {
        throw "Injected bootstrap test fault: $Name"
    }
}

function ConvertTo-TomlBasicString([string]$Value) {
    $escaped = $Value.Replace("\", "\\").Replace('"', '\"')
    $escaped = $escaped.Replace("`r", "\r").Replace("`n", "\n").Replace("`t", "\t")
    return '"' + $escaped + '"'
}

function Get-ConfiguredSshTarget {
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        return $null
    }

    $config = Get-Content -Raw -LiteralPath $ConfigPath
    $match = [regex]::Match($config, '(?m)^\s*ssh_target\s*=\s*"([^\"]+)"')
    if (-not $match.Success) {
        return $null
    }

    return $match.Groups[1].Value.Replace('\\', '\')
}

function Stop-InstalledClient {
    Get-CimInstance Win32_Process -Filter "Name='$ProgramName.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -and $_.ExecutablePath -ieq $InstalledBinary } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

function Test-InstalledClientRunning {
    return [bool](Get-CimInstance Win32_Process -Filter "Name='$ProgramName.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -and $_.ExecutablePath -ieq $InstalledBinary } |
        Select-Object -First 1)
}

function Wait-InstalledClientRunning(
    [int]$TimeoutMilliseconds = 5000,
    [scriptblock]$Probe = { Test-InstalledClientRunning }
) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        if (& $Probe) {
            return $true
        }
        Start-Sleep -Milliseconds 100
    } while ($timer.ElapsedMilliseconds -lt $TimeoutMilliseconds)
    return [bool](& $Probe)
}

function Start-InstalledClient {
    if (Test-Path -LiteralPath $LauncherPath) {
        Start-Process -FilePath $WindowsScriptHost -ArgumentList @("//B", "//NoLogo", "`"$LauncherPath`"")
        return
    }

    # Existing installations before the hidden launcher was introduced still
    # need to be restartable if an upgrade rolls back before creating it.
    Start-Process -FilePath $InstalledBinary -ArgumentList @("client", "`"$ConfigPath`"") -WindowStyle Hidden
}

function Get-ClientLauncherText {
    $command = '"' + $InstalledBinary + '" client "' + $ConfigPath + '"'
    $commandLiteral = '"' + $command.Replace('"', '""') + '"'
    return @"
Option Explicit
Dim shell
Set shell = CreateObject("WScript.Shell")
shell.Run $commandLiteral, 0, False
"@
}

function Set-StartupShortcut([string]$Path) {
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($Path)
    $shortcut.TargetPath = $WindowsScriptHost
    $shortcut.Arguments = "//B //NoLogo `"$LauncherPath`""
    $shortcut.WorkingDirectory = $InstallDir
    $shortcut.WindowStyle = 7
    $shortcut.Save()
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-StartupTask {
    return Get-ScheduledTask -TaskName $StartupTaskName -ErrorAction SilentlyContinue
}

function Register-ElevatedStartupTask {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $action = New-ScheduledTaskAction `
        -Execute $WindowsScriptHost `
        -Argument "//B //NoLogo `"$LauncherPath`"" `
        -WorkingDirectory $InstallDir
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $currentUser
    $principal = New-ScheduledTaskPrincipal `
        -UserId $currentUser `
        -LogonType Interactive `
        -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask `
        -TaskName $StartupTaskName `
        -Action $action `
        -Trigger $trigger `
        -Principal $principal `
        -Settings $settings `
        -Description "Run OpenCode SSH Image Paste for elevated Windows Terminal sessions." `
        -Force | Out-Null
}

function Remove-ElevatedStartupTask {
    if (Get-StartupTask) {
        Unregister-ScheduledTask -TaskName $StartupTaskName -Confirm:$false
    }
}

function Start-ElevatedStartupTask {
    Start-ScheduledTask -TaskName $StartupTaskName
}

function Test-CanRestartPreviousClient(
    [bool]$WasRunning,
    [bool]$RollbackComplete,
    [bool]$BinaryExists,
    [bool]$ConfigurationExists
) {
    return $WasRunning -and $RollbackComplete -and $BinaryExists -and $ConfigurationExists
}

function Get-WindowsTerminalSettingsPaths {
    $paths = @()
    $packages = Join-Path $env:LOCALAPPDATA "Packages"
    if (Test-Path -LiteralPath $packages) {
        $paths += Get-ChildItem -LiteralPath $packages -Directory -Filter "Microsoft.WindowsTerminal*" -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName "LocalState\settings.json" } |
            Where-Object { Test-Path -LiteralPath $_ }
    }

    $unpackaged = Join-Path $env:LOCALAPPDATA "Microsoft\Windows Terminal\settings.json"
    if (Test-Path -LiteralPath $unpackaged) {
        $paths += $unpackaged
    }
    return @($paths | Select-Object -Unique)
}

function Remove-OurTerminalAction([string]$Text) {
    $begin = [regex]::Escape($TerminalActionBegin)
    $end = [regex]::Escape($TerminalActionEnd)
    $withoutBlock = [regex]::Replace(
        $Text,
        "(?ms)^[ \t]*$begin\r?\n.*?^[ \t]*$end\r?\n?",
        ""
    )

    # Windows Terminal may rewrite a combined action into separate, multiline
    # entries under actions and keybindings, and it may drop our marker comments.
    # Scan balanced JSONC objects so upgrades can still remove only project-owned
    # entries without rebuilding the user's settings file or discarding comments.
    $code = Remove-JsoncComments $withoutBlock
    $stack = New-Object 'System.Collections.Generic.Stack[int]'
    $ranges = New-Object System.Collections.ArrayList
    $ownedIdPattern = '"id"\s*:\s*"' + [regex]::Escape($TerminalActionId) + '(?:\.Slot\d{2})?"'
    $inString = $false
    $escaped = $false
    for ($i = 0; $i -lt $code.Length; $i++) {
        $current = $code[$i]
        if ($inString) {
            if ($escaped) {
                $escaped = $false
            } elseif ($current -eq "\") {
                $escaped = $true
            } elseif ($current -eq '"') {
                $inString = $false
            }
            continue
        }
        if ($current -eq '"') {
            $inString = $true
            continue
        }
        if ($current -eq "{") {
            $stack.Push($i)
            continue
        }
        if ($current -ne "}" -or $stack.Count -eq 0) {
            continue
        }

        $start = $stack.Pop()
        $object = $code.Substring($start, $i - $start + 1)
        if ([regex]::IsMatch($object, $ownedIdPattern)) {
            [void]$ranges.Add([pscustomobject]@{ Start = $start; End = $i })
        }
    }

    $innermost = @($ranges | Where-Object {
        $candidate = $_
        -not ($ranges | Where-Object {
            $_.Start -gt $candidate.Start -and $_.End -lt $candidate.End
        })
    } | Sort-Object Start -Descending)

    # Mark all removals against one immutable coordinate space and materialize
    # the result only once. Mutating the string for every range makes later
    # offsets stale; two adjacent owned objects at the end of an array used to
    # remove the closing bracket on the second deletion.
    $remove = New-Object bool[] $withoutBlock.Length
    foreach ($range in $innermost) {
        $start = $range.Start
        $end = $range.End
        for ($i = $start; $i -le $end; $i++) { $remove[$i] = $true }

        $next = $end + 1
        while ($next -lt $code.Length -and [char]::IsWhiteSpace($code[$next])) { $next++ }
        if ($next -lt $code.Length -and $code[$next] -eq ",") {
            $remove[$next] = $true
        } else {
            $previous = $start - 1
            while ($previous -ge 0 -and [char]::IsWhiteSpace($code[$previous])) { $previous-- }
            if ($previous -ge 0 -and $code[$previous] -eq ",") {
                $remove[$previous] = $true
            }
        }
    }

    $result = New-Object Text.StringBuilder
    for ($i = 0; $i -lt $withoutBlock.Length; $i++) {
        if (-not $remove[$i]) {
            [void]$result.Append($withoutBlock[$i])
        }
    }
    return $result.ToString()
}

function Remove-JsoncComments([string]$Text) {
    $chars = $Text.ToCharArray()
    $result = New-Object char[] $chars.Length
    $inString = $false
    $escaped = $false
    $lineComment = $false
    $blockComment = $false

    for ($i = 0; $i -lt $chars.Length; $i++) {
        $current = $chars[$i]
        $next = if ($i + 1 -lt $chars.Length) { $chars[$i + 1] } else { [char]0 }

        if ($lineComment) {
            if ($current -eq "`r" -or $current -eq "`n") {
                $lineComment = $false
                $result[$i] = $current
            } else {
                $result[$i] = " "
            }
            continue
        }
        if ($blockComment) {
            if ($current -eq "*" -and $next -eq "/") {
                $result[$i] = " "
                $result[$i + 1] = " "
                $i++
                $blockComment = $false
            } elseif ($current -eq "`r" -or $current -eq "`n") {
                $result[$i] = $current
            } else {
                $result[$i] = " "
            }
            continue
        }
        if ($inString) {
            $result[$i] = $current
            if ($escaped) {
                $escaped = $false
            } elseif ($current -eq "\") {
                $escaped = $true
            } elseif ($current -eq '"') {
                $inString = $false
            }
            continue
        }
        if ($current -eq '"') {
            $inString = $true
            $result[$i] = $current
            continue
        }
        if ($current -eq "/" -and $next -eq "/") {
            $result[$i] = " "
            $result[$i + 1] = " "
            $i++
            $lineComment = $true
            continue
        }
        if ($current -eq "/" -and $next -eq "*") {
            $result[$i] = " "
            $result[$i + 1] = " "
            $i++
            $blockComment = $true
            continue
        }
        $result[$i] = $current
    }
    return -join $result
}

function ConvertTo-StrictJson([string]$Text) {
    $code = Remove-JsoncComments $Text
    $chars = $code.ToCharArray()
    $inString = $false
    $escaped = $false

    for ($i = 0; $i -lt $chars.Length; $i++) {
        $current = $chars[$i]
        if ($inString) {
            if ($escaped) {
                $escaped = $false
            } elseif ($current -eq "\") {
                $escaped = $true
            } elseif ($current -eq '"') {
                $inString = $false
            }
            continue
        }
        if ($current -eq '"') {
            $inString = $true
            continue
        }
        if ($current -ne ",") {
            continue
        }

        $next = $i + 1
        while ($next -lt $chars.Length -and [char]::IsWhiteSpace($chars[$next])) { $next++ }
        if ($next -lt $chars.Length -and ($chars[$next] -eq "]" -or $chars[$next] -eq "}")) {
            $chars[$i] = " "
        }
    }
    return -join $chars
}

function Assert-ValidWindowsTerminalJsonc([string]$Text, [string]$Source) {
    try {
        $parsed = ConvertFrom-Json -InputObject (ConvertTo-StrictJson $Text) -ErrorAction Stop
    } catch {
        throw "Invalid Windows Terminal JSONC in ${Source}: $_"
    }
    if ($null -eq $parsed -or $parsed -isnot [pscustomobject]) {
        throw "Windows Terminal JSONC in $Source must contain a root object."
    }
}

function Set-TextFileAtomically(
    [string]$Path,
    [bool]$ExpectedExists,
    [AllowNull()][string]$ExpectedText,
    [string]$NewText,
    [switch]$ValidateJsonc
) {
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }
    if ($ValidateJsonc) {
        Assert-ValidWindowsTerminalJsonc $NewText $Path
    }

    $actualExists = Test-Path -LiteralPath $Path
    if ($actualExists -ne $ExpectedExists) {
        throw "$Path changed while the installer was preparing its update. Rerun bootstrap.ps1."
    }
    if ($ExpectedExists) {
        $actual = [IO.File]::ReadAllText($Path)
        if ($actual -cne $ExpectedText) {
            throw "$Path changed while the installer was preparing its update. Rerun bootstrap.ps1."
        }
    }

    $suffix = [guid]::NewGuid().ToString("N")
    $temporary = Join-Path $directory ("." + [IO.Path]::GetFileName($Path) + ".$suffix.tmp")
    $rollback = Join-Path $directory ("." + [IO.Path]::GetFileName($Path) + ".$suffix.rollback")
    $utf8 = New-Object Text.UTF8Encoding($false)
    $replaced = $false
    $retainRollback = $false
    try {
        [IO.File]::WriteAllText($temporary, $NewText, $utf8)
        if ($ValidateJsonc) {
            Assert-ValidWindowsTerminalJsonc ([IO.File]::ReadAllText($temporary)) $temporary
        }

        # Close the read before File.Replace, but compare again immediately to
        # detect Windows Terminal or its Settings UI rewriting the file.
        $actualExists = Test-Path -LiteralPath $Path
        if ($actualExists -ne $ExpectedExists) {
            throw "$Path changed while the installer was writing its update. Rerun bootstrap.ps1."
        }
        if ($ExpectedExists -and ([IO.File]::ReadAllText($Path) -cne $ExpectedText)) {
            throw "$Path changed while the installer was writing its update. Rerun bootstrap.ps1."
        }
        Invoke-BootstrapTestFault "AtomicWriteBeforeReplace"

        if ($ExpectedExists) {
            # ReplaceFile can commit and still surface an exceptional return.
            # Treat the operation as potentially committed before invoking it.
            $replaced = $true
            [IO.File]::Replace($temporary, $Path, $rollback, $true)
        } else {
            [IO.File]::Move($temporary, $Path)
            $replaced = $true
        }
        Invoke-BootstrapTestFault "AtomicWriteAfterReplace"

        if ($ValidateJsonc) {
            Assert-ValidWindowsTerminalJsonc ([IO.File]::ReadAllText($Path)) $Path
        }
    } catch {
        $failure = $_
        if ($replaced) {
            try {
                Invoke-BootstrapTestFault "AtomicWriteBeforeRestore"
                if ($ExpectedExists -and (Test-Path -LiteralPath $rollback)) {
                    $failed = "$rollback.failed"
                    [IO.File]::Replace($rollback, $Path, $failed, $true)
                    Remove-Item -Force -LiteralPath $failed -ErrorAction SilentlyContinue
                } elseif (-not $ExpectedExists -and (Test-Path -LiteralPath $Path)) {
                    Remove-Item -Force -LiteralPath $Path
                }
            } catch {
                $retainRollback = $ExpectedExists -and (Test-Path -LiteralPath $rollback)
                if ($retainRollback) {
                    Write-Warning "Could not restore $Path after an atomic write failure: $_ Original content was retained at $rollback"
                } else {
                    Write-Warning "Could not restore $Path after an atomic write failure: $_"
                }
            }
        }
        throw $failure
    } finally {
        Remove-Item -Force -LiteralPath $temporary -ErrorAction SilentlyContinue
        if (-not $retainRollback) {
            Remove-Item -Force -LiteralPath $rollback -ErrorAction SilentlyContinue
        }
    }
}

function Get-TerminalActionBinding([int]$Slot) {
    if ($Slot -lt 0 -or $Slot -ge $ImageSlotCount) {
        throw "Image slot $Slot is out of range."
    }
    if ($Slot -eq 48) { return "ctrl+alt+shift+f11" }
    if ($Slot -eq 49) { return "ctrl+alt+shift+f12" }

    $functionKey = 13 + ($Slot % 12)
    $prefix = switch ([Math]::Floor($Slot / 12)) {
        0 { "ctrl+alt+shift"; break }
        1 { "ctrl+alt"; break }
        2 { "ctrl+shift"; break }
        3 { "alt+shift"; break }
        default { throw "Image slot $Slot has no terminal shortcut." }
    }
    return "$prefix+f$functionKey"
}

function Get-JsonKeysValues($Node) {
    if ($null -eq $Node -or $Node -is [string]) {
        return
    }
    if ($Node -is [pscustomobject]) {
        foreach ($property in $Node.PSObject.Properties) {
            if ($property.Name -ieq "keys") {
                if ($property.Value -is [string]) {
                    Write-Output $property.Value
                } elseif ($property.Value -is [Collections.IEnumerable]) {
                    foreach ($value in $property.Value) {
                        if ($value -is [string]) { Write-Output $value }
                    }
                }
            } else {
                Get-JsonKeysValues $property.Value
            }
        }
        return
    }
    if ($Node -is [Collections.IEnumerable]) {
        foreach ($value in $Node) {
            Get-JsonKeysValues $value
        }
    }
}

function ConvertTo-NormalizedTerminalBinding([string]$Binding) {
    $parts = @($Binding.ToLowerInvariant().Split("+") | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $modifierOrder = @("ctrl", "alt", "shift", "win")
    $keys = @($parts | Where-Object { $_ -notin $modifierOrder })
    if ($keys.Count -ne 1) {
        return ($parts -join "+")
    }
    $normalized = @($modifierOrder | Where-Object { $_ -in $parts }) + $keys[0]
    return $normalized -join "+"
}

function Get-WindowsTerminalActionUpdates([string]$RemotePasteDirectory) {
    $settingsPaths = @(Get-WindowsTerminalSettingsPaths)
    if ($settingsPaths.Count -eq 0) {
        throw "Windows Terminal settings.json was not found. Open Windows Terminal once, then rerun bootstrap.ps1."
    }

    $escape = [char]27
    $actions = for ($slot = 0; $slot -lt $ImageSlotCount; $slot++) {
        $slotText = $slot.ToString("00")
        $remotePastePath = "$RemotePasteDirectory/image-$slotText.png"
        $payload = "${escape}[200~${remotePastePath}${escape}[201~"
        [ordered]@{
            command = [ordered]@{
                action = "sendInput"
                input = $payload
            }
            keys = (Get-TerminalActionBinding $slot)
            name = $null
            id = "$TerminalActionId.Slot$slotText"
        } | ConvertTo-Json -Depth 4 -Compress
    }
    $actionLines = ($actions | ForEach-Object { "        $_" }) -join ",`r`n"

    $updates = @()
    foreach ($settingsPath in $settingsPaths) {
        $original = [IO.File]::ReadAllText($settingsPath)
        Assert-ValidWindowsTerminalJsonc $original $settingsPath
        $text = Remove-OurTerminalAction $original
        Assert-ValidWindowsTerminalJsonc $text $settingsPath
        $code = Remove-JsoncComments $text
        $parsed = ConvertFrom-Json -InputObject (ConvertTo-StrictJson $text) -ErrorAction Stop
        $assignedBindings = @(Get-JsonKeysValues $parsed | ForEach-Object { ConvertTo-NormalizedTerminalBinding $_ })
        for ($slot = 0; $slot -lt $ImageSlotCount; $slot++) {
            $keys = Get-TerminalActionBinding $slot
            if ($assignedBindings -contains (ConvertTo-NormalizedTerminalBinding $keys)) {
                throw "$keys is already assigned in $settingsPath. Remove that binding or choose another internal shortcut."
            }
        }

        $match = [regex]::Match(
            $code,
            '"actions"\s*:\s*\[',
            [Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
        if ($match.Success) {
            $openBracket = $match.Index + $match.Value.LastIndexOf("[")
            $nextToken = $openBracket + 1
            while ($nextToken -lt $code.Length -and [char]::IsWhiteSpace($code[$nextToken])) { $nextToken++ }
            $actionSuffix = if ($nextToken -lt $code.Length -and $code[$nextToken] -ne "]") { "," } else { "" }
            # End the marker line before the user's original first element.
            # Compact settings may place that element immediately after `[`. A
            # comma is needed only when that original element exists.
            $block = "`r`n        $TerminalActionBegin`r`n$actionLines$actionSuffix`r`n        $TerminalActionEnd`r`n"
            $updated = $text.Insert($openBracket + 1, $block)
        } else {
            $rootEnd = $code.LastIndexOf("}")
            if ($rootEnd -lt 0) {
                throw "Could not find the root object in $settingsPath"
            }
            $beforeRootEnd = $code.Substring(0, $rootEnd).TrimEnd()
            $separator = if ($beforeRootEnd.EndsWith("{") -or $beforeRootEnd.EndsWith(",")) { "" } else { "," }
            $block = "`r`n        $TerminalActionBegin`r`n$actionLines`r`n        $TerminalActionEnd`r`n"
            $property = "$separator`r`n    `"actions`": [$block`r`n    ]`r`n"
            $updated = $text.Insert($rootEnd, $property)
        }
        Assert-ValidWindowsTerminalJsonc $updated $settingsPath
        $updates += [pscustomobject]@{
            Path = $settingsPath
            Text = $updated
            Original = $original
            BackupCreated = $false
        }
    }
    return $updates
}

function Apply-WindowsTerminalUpdate($Update) {
    $utf8 = New-Object Text.UTF8Encoding($false)
    $backup = "$($Update.Path).opencode-ssh-image-paste.backup"
    if (-not (Test-Path -LiteralPath $backup)) {
        [IO.File]::WriteAllText($backup, $Update.Original, $utf8)
        $Update.BackupCreated = $true
    }
    try {
        Set-TextFileAtomically $Update.Path $true $Update.Original $Update.Text -ValidateJsonc
    } catch {
        # The atomic writer retains its rollback when restoration is uncertain.
        # Keep this stable backup as well: it may be the user's only easy recovery
        # path if an external writer or filesystem error blocks the rollback.
        throw
    }
    Write-Host "Configured Windows Terminal action: $($Update.Path)"
}

function Restore-WindowsTerminalUpdate($Update) {
    if (-not (Test-Path -LiteralPath $Update.Path)) {
        Write-Warning "Could not restore missing Windows Terminal settings: $($Update.Path)"
        return $false
    }
    $current = [IO.File]::ReadAllText($Update.Path)
    if ($current -ceq $Update.Original) {
        if ($Update.BackupCreated) {
            Remove-Item -Force -LiteralPath "$($Update.Path).opencode-ssh-image-paste.backup" -ErrorAction SilentlyContinue
        }
        return $true
    }
    if ($current -cne $Update.Text) {
        Write-Warning "Windows Terminal settings changed after installation; not overwriting concurrent changes in $($Update.Path)."
        return $false
    }
    Set-TextFileAtomically $Update.Path $true $current $Update.Original -ValidateJsonc
    if ($Update.BackupCreated) {
        Remove-Item -Force -LiteralPath "$($Update.Path).opencode-ssh-image-paste.backup" -ErrorAction SilentlyContinue
    }
    return $true
}

function Install-WindowsTerminalAction([string]$RemotePasteDirectory) {
    $updates = @(Get-WindowsTerminalActionUpdates $RemotePasteDirectory)
    $applied = New-Object System.Collections.ArrayList
    try {
        foreach ($update in $updates) {
            [void]$applied.Add($update)
            Apply-WindowsTerminalUpdate $update
        }
    } catch {
        $failure = $_
        $items = @($applied.ToArray())
        [array]::Reverse($items)
        foreach ($update in $items) {
            Restore-WindowsTerminalUpdate $update
        }
        throw $failure
    }
}

function Get-WindowsTerminalUninstallUpdates {
    $updates = @()
    foreach ($settingsPath in @(Get-WindowsTerminalSettingsPaths)) {
        $original = [IO.File]::ReadAllText($settingsPath)
        Assert-ValidWindowsTerminalJsonc $original $settingsPath
        $updated = Remove-OurTerminalAction $original
        Assert-ValidWindowsTerminalJsonc $updated $settingsPath
        if ($updated -cne $original) {
            $updates += [pscustomobject]@{
                Path = $settingsPath
                Text = $updated
                Original = $original
                BackupCreated = $false
            }
        }
    }
    return $updates
}

function Uninstall-WindowsTerminalAction([AllowNull()][object[]]$PlannedUpdates) {
    $updates = if ($PSBoundParameters.ContainsKey("PlannedUpdates")) {
        @($PlannedUpdates)
    } else {
        @(Get-WindowsTerminalUninstallUpdates)
    }
    $applied = New-Object System.Collections.ArrayList
    try {
        foreach ($update in $updates) {
            Set-TextFileAtomically $update.Path $true $update.Original $update.Text -ValidateJsonc
            [void]$applied.Add($update)
            Write-Host "Removed Windows Terminal action: $($update.Path)"
        }
    } catch {
        $failure = $_
        $items = @($applied.ToArray())
        [array]::Reverse($items)
        foreach ($update in $items) {
            Set-TextFileAtomically $update.Path $true $update.Text $update.Original -ValidateJsonc
        }
        throw $failure
    }
    foreach ($settingsPath in @(Get-WindowsTerminalSettingsPaths)) {
        $backup = "$settingsPath.opencode-ssh-image-paste.backup"
        Remove-Item -Force -LiteralPath $backup -ErrorAction SilentlyContinue
    }
}

function Invoke-Uninstall {
    $target = $SshTarget
    if (-not $target) {
        $target = Get-ConfiguredSshTarget
    }

    # Parse every Terminal settings file before stopping a working client. A
    # malformed settings file must leave the currently installed client alone.
    Write-Step "Checking Windows Terminal paste action"
    $terminalUpdates = @(Get-WindowsTerminalUninstallUpdates)
    $startupTaskExists = [bool](Get-StartupTask)
    $startupTaskXml = if ($startupTaskExists) {
        Export-ScheduledTask -TaskName $StartupTaskName
    } else {
        $null
    }
    if ($startupTaskExists -and -not (Test-IsAdministrator)) {
        throw "Uninstall must run in an administrator PowerShell because the elevated startup task exists."
    }
    $clientWasRunning = Test-InstalledClientRunning
    $clientStopped = $false
    $startupTaskRemoved = $false

    try {
        Write-Step "Stopping Windows client"
        Stop-InstalledClient
        $clientStopped = $true

        Write-Step "Removing Windows Terminal paste action"
        Uninstall-WindowsTerminalAction -PlannedUpdates $terminalUpdates

        $startup = [Environment]::GetFolderPath("Startup")
        $shortcutPath = Join-Path $startup "OpenCode SSH Image Paste.lnk"
        if (Test-Path -LiteralPath $shortcutPath) {
            Remove-Item -Force -LiteralPath $shortcutPath
        }
        Remove-ElevatedStartupTask
        $startupTaskRemoved = $startupTaskExists

        if ($target) {
            if (Get-Command ssh.exe -ErrorAction SilentlyContinue) {
                Write-Step "Removing Linux receiver from $target"
                & ssh.exe @SshOptions -- $target "rm -f ~/.local/bin/$ProgramName; rm -rf ~/.cache/$ProgramName"
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "Could not remove the remote receiver. Local uninstall will continue."
                }
            } else {
                Write-Warning "Windows OpenSSH Client was not found. The remote receiver was not removed."
            }
        } else {
            Write-Warning "No SSH target was provided or found in the configuration. The remote receiver was not removed."
        }

        Write-Step "Removing Windows client"
        if (Test-Path -LiteralPath $InstallDir) {
            Remove-Item -Recurse -Force -LiteralPath $InstallDir
        }

        if ($KeepConfig) {
            if (Test-Path -LiteralPath $ConfigPath) {
                Write-Host "Kept configuration: $ConfigPath"
            }
        } elseif (Test-Path -LiteralPath $ConfigDir) {
            Remove-Item -Recurse -Force -LiteralPath $ConfigDir
        }
    } catch {
        $failure = $_
        $terminalRollbackComplete = $true
        $startupRollbackComplete = $true
        if ($startupTaskRemoved) {
            try {
                Register-ScheduledTask `
                    -TaskName $StartupTaskName `
                    -Xml $startupTaskXml `
                    -Force | Out-Null
            } catch {
                $startupRollbackComplete = $false
                Write-Warning "Uninstall failed and the elevated startup task could not be restored: $_"
            }
        }
        foreach ($update in $terminalUpdates) {
            try {
                if (-not (Test-Path -LiteralPath $update.Path) -or
                    [IO.File]::ReadAllText($update.Path) -cne $update.Original) {
                    $terminalRollbackComplete = $false
                    break
                }
            } catch {
                $terminalRollbackComplete = $false
                break
            }
        }
        if ($clientStopped -and $clientWasRunning -and $terminalRollbackComplete -and $startupRollbackComplete -and
            (Test-Path -LiteralPath $InstalledBinary) -and
            (Test-Path -LiteralPath $ConfigPath)) {
            try {
                if ($startupTaskExists) {
                    Start-ElevatedStartupTask
                } else {
                    Start-InstalledClient
                }
            } catch {
                Write-Warning "Uninstall failed and the previous Windows client could not be restarted: $_"
            }
        } elseif ($clientStopped -and $clientWasRunning -and -not $terminalRollbackComplete) {
            Write-Warning "Uninstall failed and Windows Terminal settings were not fully restored; the previous client remains stopped."
        }
        throw $failure
    }

    Write-Host ""
    Write-Host "Uninstall complete." -ForegroundColor Green
}

function Get-DownloadBase {
    if ($Version -eq "latest") {
        return "https://github.com/$Repository/releases/latest/download"
    }
    $tag = if ($Version.StartsWith("v")) { $Version } else { "v$Version" }
    return "https://github.com/$Repository/releases/download/$tag"
}

function Download-Asset([string]$BaseUri, [string]$Name, [string]$Destination) {
    Invoke-WebRequest -UseBasicParsing -Uri "$BaseUri/$Name" -OutFile $Destination
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

function Get-LocalBinaryInformation([string]$Path) {
    $versionOutput = ((& $Path --version 2>&1) -join "`n").Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($versionOutput)) {
        throw "Windows binary validation failed: $Path --version"
    }
    $capabilities = ((& $Path receiver --capabilities 2>&1) -join "`n").Trim()
    if ($LASTEXITCODE -ne 0 -or $capabilities -cne $ExpectedCapabilities) {
        throw "Windows binary has incompatible capabilities. Expected '$ExpectedCapabilities', got '$capabilities'."
    }
    return [pscustomobject]@{ Version = $versionOutput; Capabilities = $capabilities }
}

function Test-SafeRemoteDirectory([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not $Path.StartsWith("/") -or $Path.EndsWith("/")) {
        return $false
    }
    foreach ($character in $Path.ToCharArray()) {
        if ([char]::IsControl($character)) {
            return $false
        }
    }
    return $true
}

function Assert-CompatibleExistingRemoteCommand([AllowNull()][string]$ExistingConfig) {
    if ($null -eq $ExistingConfig) {
        return
    }

    $assignments = [regex]::Matches(
        $ExistingConfig,
        "(?m)^\s*(?:remote_command|`"remote_command`"|'remote_command')\s*=\s*(?<value>[^\r\n]*)$"
    )
    if ($assignments.Count -eq 0) {
        return
    }

    $expected = "~/.local/bin/$ProgramName receiver"
    $expectedDoubleQuoted = '"' + $expected + '"'
    $expectedSingleQuoted = "'" + $expected + "'"
    foreach ($assignment in $assignments) {
        $value = $assignment.Groups["value"].Value.Trim()
        $comment = $value.IndexOf("#", [StringComparison]::Ordinal)
        if ($comment -ge 0) {
            $value = $value.Substring(0, $comment).TrimEnd()
        }
        if ($value -cne $expectedDoubleQuoted -and $value -cne $expectedSingleQuoted) {
            throw "Automatic installation does not support a custom remote_command. Expected remote_command = $expectedDoubleQuoted. Remove custom receiver arguments such as --dir, or install and configure both sides manually."
        }
    }
}

function Get-UpdatedConfigText(
    [AllowNull()][string]$ExistingConfig,
    [string]$Target,
    [string]$RemotePasteDirectory
) {
    Assert-CompatibleExistingRemoteCommand $ExistingConfig
    $targetSetting = "ssh_target = $(ConvertTo-TomlBasicString $Target)"
    $probeSetting = 'remote_probe_command = "~/.local/bin/opencode-ssh-image-paste receiver --capabilities"'
    $pasteDirectorySetting = "terminal_paste_directory = $(ConvertTo-TomlBasicString $RemotePasteDirectory)"

    # PowerShell coerces $null passed to a [string] parameter into "".
    if ([string]::IsNullOrEmpty($ExistingConfig)) {
        return @"
$targetSetting
ssh_program = "ssh.exe"
ssh_arguments = []
remote_command = "~/.local/bin/opencode-ssh-image-paste receiver"
$probeSetting
$pasteDirectorySetting
terminal_window_class = "CASCADIA_HOSTING_WINDOW_CLASS"
request_timeout_seconds = 15
"@
    }

    $updated = $ExistingConfig
    if ($updated -notmatch '(?m)^\s*ssh_target\s*=') {
        throw "Existing configuration has no ssh_target: $ConfigPath"
    }
    $updated = $updated -replace '(?m)^\s*ssh_target\s*=.*$', $targetSetting

    if ($updated -match '(?m)^\s*remote_probe_command\s*=') {
        $updated = $updated -replace '(?m)^\s*remote_probe_command\s*=.*$', $probeSetting
    } else {
        $updated = $updated.TrimEnd([char[]]@([char]13, [char]10)) + "`r`n$probeSetting`r`n"
    }

    if ($updated -match '(?m)^\s*terminal_paste_directory\s*=') {
        $updated = $updated -replace '(?m)^\s*terminal_paste_directory\s*=.*$', $pasteDirectorySetting
    } elseif ($updated -match '(?m)^\s*terminal_paste_path\s*=') {
        $updated = $updated -replace '(?m)^\s*terminal_paste_path\s*=.*$', $pasteDirectorySetting
    } else {
        $updated = $updated.TrimEnd([char[]]@([char]13, [char]10)) + "`r`n$pasteDirectorySetting`r`n"
    }
    return $updated
}

if ($InternalTestMode) {
    return
}

$bootstrapMutex = $null
$bootstrapMutexAcquired = $false
try {
    $bootstrapMutex = [Threading.Mutex]::new($false, "Local\OpenCodeSSHImagePaste.Bootstrap")
    try {
        $bootstrapMutexAcquired = $bootstrapMutex.WaitOne(0)
    } catch [Threading.AbandonedMutexException] {
        # The previous owner exited without releasing the mutex. WaitOne grants
        # ownership together with the exception, so this invocation can recover.
        $bootstrapMutexAcquired = $true
    }
    if (-not $bootstrapMutexAcquired) {
        throw "Another bootstrap.ps1 install or uninstall is already running. Wait for it to finish, then rerun this command."
    }

    if ($Uninstall) {
        Invoke-Uninstall
        return
    }

if ($KeepConfig) {
    throw "-KeepConfig can only be used together with -Uninstall."
}
if ($UseElevatedStartup -and -not (Test-IsAdministrator)) {
    throw "The default installation creates a highest-privilege login task and requires an administrator PowerShell. Reopen PowerShell as administrator, or explicitly use -NonElevatedStartup for a normal Windows Terminal."
}
if (-not $UseElevatedStartup -and (Get-StartupTask) -and -not (Test-IsAdministrator)) {
    throw "The elevated startup task already exists. Run this mode switch in an administrator PowerShell so the task can be removed."
}
if ([bool]$WindowsBinaryPath -ne [bool]$LinuxBinaryPath) {
    throw "-WindowsBinaryPath and -LinuxBinaryPath must be provided together."
}

if (-not (Get-Command ssh.exe -ErrorAction SilentlyContinue)) {
    throw "Windows OpenSSH Client was not found. Install it in Settings > Optional Features."
}
if (-not (Get-Command scp.exe -ErrorAction SilentlyContinue)) {
    throw "scp.exe was not found. Install the Windows OpenSSH Client optional feature."
}
if (-not (Test-Path -LiteralPath $WindowsScriptHost)) {
    throw "Windows Script Host was not found: $WindowsScriptHost"
}
if (-not $SshTarget) {
    $SshTarget = Read-Host "SSH host or alias (for example ubuntu-workbox)"
}
if ([string]::IsNullOrWhiteSpace($SshTarget) -or $SshTarget.StartsWith("-")) {
    throw "A valid SSH host or alias is required."
}

$TempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("opencode-ssh-image-paste-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $TempDir | Out-Null

$operationId = [guid]::NewGuid().ToString("N")
$remoteTemporary = ".local/bin/$ProgramName.download.$operationId"
$remoteRollback = ".local/bin/$ProgramName.rollback.$operationId"
$remoteActivated = $false
$remoteHadExisting = $false
$localActivated = $false
$localCandidate = $null
$localRollback = Join-Path $InstallDir ".$ProgramName.$operationId.rollback.exe"
$retainLocalRollback = $false
$configCommitted = $false
$shortcutCommitted = $false
$launcherCommitted = $false
$startupTaskCommitted = $false
$commitStarted = $false
$appliedTerminalUpdates = New-Object System.Collections.ArrayList

try {
    Write-Step "Testing SSH connection to $SshTarget"
    & ssh.exe @SshOptions -- $SshTarget "echo ready"
    if ($LASTEXITCODE -ne 0) {
        throw "SSH connection failed. Configure a host key and non-interactive key or ssh-agent authentication first."
    }

    $remoteArchitecture = ((& ssh.exe @SshOptions -- $SshTarget "uname -m") -join "`n").Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($remoteArchitecture)) {
        throw "Could not detect the remote architecture."
    }
    $linuxAsset = switch ($remoteArchitecture) {
        { $_ -in @("x86_64", "amd64") } { "$ProgramName-linux-x86_64"; break }
        { $_ -in @("aarch64", "arm64") } { "$ProgramName-linux-aarch64"; break }
        default { throw "Unsupported remote architecture: $remoteArchitecture" }
    }

    if ($WindowsBinaryPath) {
        $windowsDownload = (Resolve-Path -LiteralPath $WindowsBinaryPath).Path
        $linuxDownload = (Resolve-Path -LiteralPath $LinuxBinaryPath).Path
        Write-Step "Using locally built Windows and Linux binaries"
    } else {
        $downloadBase = Get-DownloadBase
        $windowsAsset = "$ProgramName-windows-x86_64.exe"
        $checksumsAsset = "SHA256SUMS"
        $windowsDownload = Join-Path $TempDir $windowsAsset
        $linuxDownload = Join-Path $TempDir $linuxAsset
        $checksumsDownload = Join-Path $TempDir $checksumsAsset

        Write-Step "Downloading $Version release binaries"
        Download-Asset $downloadBase $windowsAsset $windowsDownload
        Download-Asset $downloadBase $linuxAsset $linuxDownload
        if (-not $SkipChecksum) {
            Download-Asset $downloadBase $checksumsAsset $checksumsDownload
            Assert-Checksum $windowsDownload $checksumsDownload $windowsAsset
            Assert-Checksum $linuxDownload $checksumsDownload $linuxAsset
        }
    }

    Write-Step "Validating Windows client"
    $windowsInformation = Get-LocalBinaryInformation $windowsDownload

    Write-Step "Staging and validating Linux receiver ($remoteArchitecture)"
    & ssh.exe @SshOptions -- $SshTarget "mkdir -p ~/.local/bin"
    if ($LASTEXITCODE -ne 0) { throw "Could not create ~/.local/bin on the remote host." }
    & scp.exe @ScpOptions -- $linuxDownload "${SshTarget}:$remoteTemporary"
    if ($LASTEXITCODE -ne 0) { throw "Could not upload the Linux receiver." }

    $remoteVersion = ((& ssh.exe @SshOptions -- $SshTarget "chmod 755 ~/$remoteTemporary && ~/$remoteTemporary --version") -join "`n").Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($remoteVersion)) {
        throw "Linux receiver candidate failed its version check; the installed receiver was not changed."
    }
    if ($remoteVersion -cne $windowsInformation.Version) {
        throw "Windows and Linux binary versions differ: '$($windowsInformation.Version)' vs '$remoteVersion'."
    }

    $remoteCapabilities = ((& ssh.exe @SshOptions -- $SshTarget "~/$remoteTemporary receiver --capabilities") -join "`n").Trim()
    if ($LASTEXITCODE -ne 0 -or $remoteCapabilities -cne $ExpectedCapabilities) {
        throw "Linux receiver has incompatible capabilities. Expected '$ExpectedCapabilities', got '$remoteCapabilities'."
    }

    $remotePasteDirectory = ((& ssh.exe @SshOptions -- $SshTarget "~/$remoteTemporary receiver --print-directory") -join "`n").Trim()
    if ($LASTEXITCODE -ne 0 -or -not (Test-SafeRemoteDirectory $remotePasteDirectory)) {
        throw "Could not determine a safe absolute receiver image directory."
    }

    Write-Step "Checking Windows Terminal paste actions"
    $terminalUpdates = @(Get-WindowsTerminalActionUpdates $remotePasteDirectory)

    $configExisted = Test-Path -LiteralPath $ConfigPath
    $existingConfig = if ($configExisted) { [IO.File]::ReadAllText($ConfigPath) } else { $null }
    $updatedConfig = Get-UpdatedConfigText `
        -ExistingConfig $existingConfig `
        -Target $SshTarget `
        -RemotePasteDirectory $remotePasteDirectory
    $launcherExisted = Test-Path -LiteralPath $LauncherPath
    $existingLauncher = if ($launcherExisted) { [IO.File]::ReadAllText($LauncherPath) } else { $null }
    $updatedLauncher = Get-ClientLauncherText

    # Creating a temporary shortcut verifies COM availability without touching
    # the user's Startup folder during preflight.
    $wscriptShell = New-Object -ComObject WScript.Shell
    $shortcutProbe = Join-Path $TempDir "startup-probe.lnk"
    $probe = $wscriptShell.CreateShortcut($shortcutProbe)
    $probe.TargetPath = $windowsDownload
    $probe.Save()
    Remove-Item -Force -LiteralPath $shortcutProbe

    $oldClientWasRunning = Test-InstalledClientRunning
    $binaryExisted = Test-Path -LiteralPath $InstalledBinary
    $previousBinaryHash = if ($binaryExisted) {
        (Get-FileHash -LiteralPath $InstalledBinary -Algorithm SHA256).Hash
    } else {
        $null
    }
    $startup = [Environment]::GetFolderPath("Startup")
    $shortcutPath = Join-Path $startup "OpenCode SSH Image Paste.lnk"
    $shortcutExisted = Test-Path -LiteralPath $shortcutPath
    $shortcutBackup = Join-Path $TempDir "startup-shortcut.lnk"
    if ($shortcutExisted) {
        Copy-Item -LiteralPath $shortcutPath -Destination $shortcutBackup
    }
    $existingStartupTask = Get-StartupTask
    $startupTaskExisted = [bool]$existingStartupTask
    $existingStartupTaskXml = if ($startupTaskExisted) {
        Export-ScheduledTask -TaskName $StartupTaskName
    } else {
        $null
    }

    $remoteState = ((& ssh.exe @SshOptions -- $SshTarget "if [ -e ~/.local/bin/$ProgramName ]; then printf yes; else printf no; fi") -join "`n").Trim()
    if ($LASTEXITCODE -ne 0 -or $remoteState -notin @("yes", "no")) {
        throw "Could not inspect the currently installed remote receiver."
    }
    $remoteHadExisting = $remoteState -eq "yes"

    # Commit only after every network, binary, Terminal and configuration
    # preflight has succeeded. This is the only window in which the old client
    # is stopped.
    $commitStarted = $true
    Stop-InstalledClient
    Start-Sleep -Milliseconds 250

    Write-Step "Configuring 50 atomic Windows Terminal paste actions"
    foreach ($update in $terminalUpdates) {
        [void]$appliedTerminalUpdates.Add($update)
        Apply-WindowsTerminalUpdate $update
    }

    Write-Step "Activating Linux receiver ($remoteArchitecture)"
    $activateRemote = "rm -f ~/$remoteRollback; " +
        "if [ -e ~/.local/bin/$ProgramName ]; then mv -f ~/.local/bin/$ProgramName ~/$remoteRollback; fi; " +
        "if ! mv -f ~/$remoteTemporary ~/.local/bin/$ProgramName; then " +
        "if [ -e ~/$remoteRollback ]; then mv -f ~/$remoteRollback ~/.local/bin/$ProgramName; fi; exit 1; fi"
    # Treat activation as potentially committed before invoking SSH. A broken
    # connection can hide a successful remote command, so rollback must still
    # be attempted when the local ssh.exe reports failure.
    $remoteActivated = $true
    & ssh.exe @SshOptions -- $SshTarget $activateRemote
    if ($LASTEXITCODE -ne 0) { throw "Could not atomically activate the Linux receiver." }

    $activatedCapabilities = ((& ssh.exe @SshOptions -- $SshTarget "~/.local/bin/$ProgramName receiver --capabilities") -join "`n").Trim()
    if ($LASTEXITCODE -ne 0 -or $activatedCapabilities -cne $ExpectedCapabilities) {
        throw "The activated Linux receiver failed its capability check."
    }

    Write-Step "Installing Windows client"
    New-Item -ItemType Directory -Force -Path $InstallDir, $ConfigDir | Out-Null
    $localCandidate = Join-Path $InstallDir ".$ProgramName.$operationId.new.exe"
    Copy-Item -Force -LiteralPath $windowsDownload -Destination $localCandidate
    $installedCandidateInformation = Get-LocalBinaryInformation $localCandidate
    if ($installedCandidateInformation.Version -cne $windowsInformation.Version) {
        throw "The staged Windows client changed after validation."
    }
    # File.Replace/Move may have committed even if an exceptional return path
    # prevents PowerShell from observing success. Enable rollback first.
    $localActivated = $true
    if ($binaryExisted) {
        [IO.File]::Replace($localCandidate, $InstalledBinary, $localRollback, $true)
    } else {
        [IO.File]::Move($localCandidate, $InstalledBinary)
    }

    # An atomic replace can commit before surfacing an error. Mark the config as
    # potentially committed first so the outer rollback always inspects it.
    $configCommitted = $true
    Set-TextFileAtomically `
        -Path $ConfigPath `
        -ExpectedExists $configExisted `
        -ExpectedText $existingConfig `
        -NewText $updatedConfig
    if ($configExisted) {
        Write-Host "Updated SSH target and kept other settings: $ConfigPath"
    }

    $launcherCommitted = $true
    Set-TextFileAtomically `
        -Path $LauncherPath `
        -ExpectedExists $launcherExisted `
        -ExpectedText $existingLauncher `
        -NewText $updatedLauncher

    $startupTaskCommitted = $true
    if ($UseElevatedStartup) {
        Register-ElevatedStartupTask
    } else {
        Remove-ElevatedStartupTask
    }

    # Save can partially replace an existing .lnk before surfacing an error.
    $shortcutCommitted = $true
    if ($UseElevatedStartup) {
        Remove-Item -Force -LiteralPath $shortcutPath -ErrorAction SilentlyContinue
    } else {
        Set-StartupShortcut $shortcutPath
    }

    if ($UseElevatedStartup) {
        Start-ElevatedStartupTask
    } else {
        Start-InstalledClient
    }
    if (-not (Wait-InstalledClientRunning)) {
        throw "The installed Windows client exited before diagnostics. Check antivirus or application-control events, then rerun bootstrap.ps1."
    }

    Write-Step "Running diagnostics"
    & $InstalledBinary doctor $ConfigPath
    if ($LASTEXITCODE -ne 0) {
        throw "Installation completed, but diagnostics found a problem."
    }

    Write-Host ""
    Write-Host "Installation complete. Copy an image, focus Windows Terminal, and press Ctrl+V." -ForegroundColor Green
    Write-Host "Config: $ConfigPath"
    Remove-Item -Force -LiteralPath $localRollback -ErrorAction SilentlyContinue
    & ssh.exe @SshOptions -- $SshTarget "rm -f ~/$remoteRollback" | Out-Null
} catch {
    $failure = $_
    if ($commitStarted) {
        $rollbackComplete = $true
        Stop-InstalledClient

        if ($shortcutCommitted) {
            try {
                if ($shortcutExisted) {
                    if (-not (Test-Path -LiteralPath $shortcutBackup)) {
                        throw "Startup shortcut rollback is missing: $shortcutBackup"
                    }
                    Copy-Item -Force -LiteralPath $shortcutBackup -Destination $shortcutPath
                } else {
                    Remove-Item -Force -LiteralPath $shortcutPath -ErrorAction SilentlyContinue
                }
            } catch {
                $rollbackComplete = $false
                Write-Warning "Could not restore the Startup shortcut: $_"
            }
        }

        if ($startupTaskCommitted) {
            try {
                if ($startupTaskExisted) {
                    Register-ScheduledTask `
                        -TaskName $StartupTaskName `
                        -Xml $existingStartupTaskXml `
                        -Force | Out-Null
                } else {
                    Remove-ElevatedStartupTask
                }
            } catch {
                $rollbackComplete = $false
                Write-Warning "Could not restore the startup task: $_"
            }
        }

        if ($launcherCommitted) {
            try {
                if (Test-Path -LiteralPath $LauncherPath) {
                    $currentLauncher = [IO.File]::ReadAllText($LauncherPath)
                    if ($currentLauncher -ceq $updatedLauncher) {
                        if ($launcherExisted) {
                            Set-TextFileAtomically $LauncherPath $true $currentLauncher $existingLauncher
                        } else {
                            Remove-Item -Force -LiteralPath $LauncherPath
                        }
                    } elseif ($launcherExisted -and $currentLauncher -ceq $existingLauncher) {
                        # The atomic update failed before replacing the original.
                    } else {
                        $rollbackComplete = $false
                        Write-Warning "Client launcher changed after installation; not overwriting concurrent changes in $LauncherPath."
                    }
                } elseif ($launcherExisted) {
                    Set-TextFileAtomically `
                        -Path $LauncherPath `
                        -ExpectedExists $false `
                        -ExpectedText $null `
                        -NewText $existingLauncher
                }
            } catch {
                $rollbackComplete = $false
                Write-Warning "Could not restore the client launcher: $_"
            }
        }

        if ($configCommitted) {
            try {
                if (Test-Path -LiteralPath $ConfigPath) {
                    $currentConfig = [IO.File]::ReadAllText($ConfigPath)
                    if ($currentConfig -ceq $updatedConfig) {
                        if ($configExisted) {
                            Set-TextFileAtomically $ConfigPath $true $currentConfig $existingConfig
                        } else {
                            Remove-Item -Force -LiteralPath $ConfigPath
                        }
                    } elseif ($configExisted -and $currentConfig -ceq $existingConfig) {
                        # The atomic update failed before replacing the original.
                    } else {
                        $rollbackComplete = $false
                        Write-Warning "Configuration changed after installation; not overwriting concurrent changes in $ConfigPath."
                    }
                } elseif ($configExisted) {
                    Set-TextFileAtomically `
                        -Path $ConfigPath `
                        -ExpectedExists $false `
                        -ExpectedText $null `
                        -NewText $existingConfig
                }
            } catch {
                $rollbackComplete = $false
                Write-Warning "Could not restore configuration: $_"
            }
        }

        if ($localActivated) {
            try {
                if ($binaryExisted -and (Test-Path -LiteralPath $localRollback)) {
                    if (Test-Path -LiteralPath $InstalledBinary) {
                        $failedBinary = "$localRollback.failed"
                        [IO.File]::Replace($localRollback, $InstalledBinary, $failedBinary, $true)
                        Remove-Item -Force -LiteralPath $failedBinary -ErrorAction SilentlyContinue
                    } else {
                        [IO.File]::Move($localRollback, $InstalledBinary)
                    }
                } elseif (-not $binaryExisted) {
                    Remove-Item -Force -LiteralPath $InstalledBinary -ErrorAction SilentlyContinue
                }

                if ($binaryExisted) {
                    if (-not (Test-Path -LiteralPath $InstalledBinary)) {
                        throw "The previous Windows client is missing after rollback."
                    }
                    $restoredBinaryHash = (Get-FileHash -LiteralPath $InstalledBinary -Algorithm SHA256).Hash
                    if ($restoredBinaryHash -cne $previousBinaryHash) {
                        throw "The Windows client does not match the pre-installation binary after rollback."
                    }
                } elseif (Test-Path -LiteralPath $InstalledBinary) {
                    throw "The newly installed Windows client could not be removed during rollback."
                }
            } catch {
                $rollbackComplete = $false
                $retainLocalRollback = $true
                Write-Warning "Could not restore the previous Windows client: $_"
            }
        }

        $terminalItems = @($appliedTerminalUpdates.ToArray())
        [array]::Reverse($terminalItems)
        foreach ($update in $terminalItems) {
            try {
                if (-not (Restore-WindowsTerminalUpdate $update)) {
                    $rollbackComplete = $false
                }
            } catch {
                $rollbackComplete = $false
                Write-Warning $_
            }
        }

        if ($remoteActivated) {
            $restoreRemote = if ($remoteHadExisting) {
                "if [ -e ~/$remoteRollback ]; then mv -f ~/$remoteRollback ~/.local/bin/$ProgramName; else exit 1; fi"
            } else {
                "rm -f ~/.local/bin/$ProgramName"
            }
            try {
                & ssh.exe @SshOptions -- $SshTarget $restoreRemote | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    throw "ssh.exe exited with code $LASTEXITCODE"
                }
            } catch {
                $rollbackComplete = $false
                if ($remoteHadExisting) {
                    Write-Warning "Could not restore the previous Linux receiver: $_ Inspect retained rollback path: ~/$remoteRollback"
                } else {
                    Write-Warning "Could not remove the newly activated Linux receiver: $_"
                }
            }
        }

        $installedBinaryExists = Test-Path -LiteralPath $InstalledBinary
        $configurationExists = Test-Path -LiteralPath $ConfigPath
        if (Test-CanRestartPreviousClient $oldClientWasRunning $rollbackComplete $installedBinaryExists $configurationExists) {
            try {
                if ($startupTaskExisted) {
                    Start-ElevatedStartupTask
                } else {
                    Start-InstalledClient
                }
            } catch {
                Write-Warning "Could not restart the previous Windows client: $_"
            }
        } elseif ($oldClientWasRunning) {
            Write-Warning "The previous Windows client remains stopped because installation rollback was incomplete. Resolve the rollback warnings before restarting it."
            if (Test-Path -LiteralPath $localRollback) {
                Write-Warning "Retained Windows client rollback: $localRollback"
            }
            if ($remoteActivated -and $remoteHadExisting) {
                Write-Warning "Remote receiver rollback candidate: ~/$remoteRollback"
            }
            foreach ($update in $terminalItems) {
                $terminalBackup = "$($update.Path).opencode-ssh-image-paste.backup"
                if (Test-Path -LiteralPath $terminalBackup) {
                    Write-Warning "Windows Terminal settings backup: $terminalBackup"
                }
            }
        }
    }
    throw $failure
} finally {
    if ($remoteTemporary) {
        try {
            & ssh.exe @SshOptions -- $SshTarget "rm -f ~/$remoteTemporary" 2>$null | Out-Null
        } catch {
            Write-Warning "Could not remove staged remote receiver ~/${remoteTemporary}: $_"
        }
    }
    if ($localCandidate) {
        Remove-Item -Force -LiteralPath $localCandidate -ErrorAction SilentlyContinue
    }
    if (-not $retainLocalRollback) {
        Remove-Item -Force -LiteralPath $localRollback -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $TempDir) {
        Remove-Item -Recurse -Force -LiteralPath $TempDir -ErrorAction SilentlyContinue
    }
}
} finally {
    if ($bootstrapMutexAcquired) {
        try {
            $bootstrapMutex.ReleaseMutex()
        } catch {
            Write-Warning "Could not release the bootstrap process lock: $_"
        }
    }
    if ($null -ne $bootstrapMutex) {
        try {
            $bootstrapMutex.Dispose()
        } catch {
            Write-Warning "Could not dispose the bootstrap process lock: $_"
        }
    }
}
