param(
    [string]$SshTarget,
    [string]$Version = "latest",
    [string]$WindowsBinaryPath,
    [string]$LinuxBinaryPath,
    [string]$HttpsHost,
    [int]$HttpsPort = 47832,
    [switch]$LegacySshTransport,
    [switch]$SkipChecksum,
    [switch]$ElevatedStartup,
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
if ($ElevatedStartup -and $NonElevatedStartup) {
    throw "-ElevatedStartup and -NonElevatedStartup cannot be used together."
}
$UseElevatedStartup = [bool]$ElevatedStartup
$UseHttpsTransport = -not [bool]$LegacySshTransport
if ($LegacySshTransport -and (-not [string]::IsNullOrWhiteSpace($HttpsHost) -or $HttpsPort -ne 47832)) {
    throw "-LegacySshTransport cannot be combined with -HttpsHost or a non-default -HttpsPort."
}
if ($UseHttpsTransport -and ($HttpsPort -lt 1 -or $HttpsPort -gt 65535)) {
    throw "-HttpsPort must be between 1 and 65535."
}
if ($HttpsHost -and ($HttpsHost -notmatch '^[A-Za-z0-9._:-]+$' -or @($HttpsHost.ToCharArray() | Where-Object { [char]::IsControl($_) }).Count -gt 0)) {
    throw "-HttpsHost must be a DNS name or IP address without shell metacharacters."
}
$TerminalActionId = "User.OpenCodeSSHImagePaste.AtomicPaste"
$ImageSlotCount = 10
$TerminalActionBegin = "// OpenCodeSSHImagePaste Action BEGIN"
$TerminalActionEnd = "// OpenCodeSSHImagePaste Action END"
$ExpectedCapabilities = "protocol=2;image_slots=10;response=slot-path-v1"
$ReceiverConfigDirectory = ".config/$ProgramName"
$ReceiverConfigFile = "$ReceiverConfigDirectory/receiver.toml"
$ReceiverCertificateFile = "$ReceiverConfigDirectory/receiver-cert.pem"
$ReceiverServiceFile = ".config/systemd/user/$ProgramName.service"
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

function Get-HttpsEndpoint([string]$HostName, [int]$Port) {
    $authority = if ($HostName.Contains(":")) { "[$HostName]" } else { $HostName }
    return "https://${authority}:$Port"
}

function Get-SystemdUserServiceText {
    return @"
[Unit]
Description=OpenCode SSH Image Paste HTTPS Receiver
After=network-online.target

[Service]
Type=simple
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=%h/.cache/opencode-ssh-image-paste
ExecStart=%h/.local/bin/opencode-ssh-image-paste receiver --https-config %h/.config/opencode-ssh-image-paste/receiver.toml
Restart=on-failure

[Install]
WantedBy=default.target
"@
}

function Get-SystemdStopCommand([bool]$Disable) {
    $operation = if ($Disable) { "disable --now" } else { "stop" }
    return "set -eu; " +
        "load_state=`$(systemctl --user show $ProgramName.service -p LoadState --value 2>/dev/null || true); " +
        "if [ `"`$load_state`" != `"not-found`" ]; then systemctl --user $operation $ProgramName.service; fi; " +
        "if systemctl --user is-active --quiet $ProgramName.service; then exit 1; fi"
}

function Initialize-PinnedCertificateHttpHandler {
    Add-Type -AssemblyName System.Net.Http
    if (-not ("OpenCodeSshImagePaste.Install.PinnedCertificateHttpHandler" -as [type])) {
        $validatorSource = @'
using System;
using System.Net.Http;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;

namespace OpenCodeSshImagePaste.Install
{
    public static class PinnedCertificateHttpHandler
    {
        public static HttpClientHandler Create(byte[] expectedRawData)
        {
            byte[] expected = (byte[])expectedRawData.Clone();
            HttpClientHandler handler = new HttpClientHandler();
            handler.AllowAutoRedirect = false;
            handler.UseProxy = false;
            handler.ServerCertificateCustomValidationCallback = delegate(
                HttpRequestMessage request,
                X509Certificate2 certificate,
                X509Chain chain,
                SslPolicyErrors errors)
            {
                if (certificate == null || certificate.RawData.Length != expected.Length)
                {
                    return false;
                }

                int difference = 0;
                for (int index = 0; index < expected.Length; index++)
                {
                    difference |= certificate.RawData[index] ^ expected[index];
                }
                return difference == 0;
            };
            return handler;
        }
    }
}
'@
        $validatorAssemblies = @(
            [System.Net.Http.HttpClient].Assembly.Location
            [System.Net.Security.SslPolicyErrors].Assembly.Location
            [System.Security.Cryptography.X509Certificates.X509Certificate2].Assembly.Location
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
        Add-Type `
            -TypeDefinition $validatorSource `
            -ReferencedAssemblies $validatorAssemblies
    }
}

function Test-HttpsReceiver(
    [string]$Endpoint,
    [string]$Token,
    [string]$CertificatePath
) {
    Initialize-PinnedCertificateHttpHandler
    $expectedCertificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new($CertificatePath)
    $previousSecurityProtocol = [Net.ServicePointManager]::SecurityProtocol
    $handler = $null
    $client = $null
    $request = $null
    $response = $null
    try {
        [Net.ServicePointManager]::SecurityProtocol = $previousSecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        # The certificate callback is compiled C#, not a PowerShell ScriptBlock:
        # .NET Framework performs TLS callbacks on a thread without a Runspace.
        $handler = [OpenCodeSshImagePaste.Install.PinnedCertificateHttpHandler]::Create($expectedCertificate.RawData)
        $client = [System.Net.Http.HttpClient]::new($handler)
        $client.Timeout = [TimeSpan]::FromSeconds(15)
        $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, "$Endpoint/v1/capabilities")
        $request.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new("Bearer", $Token)
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) {
            throw "HTTPS capability probe returned HTTP $([int]$response.StatusCode)."
        }
        $capabilities = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if ($capabilities.Trim() -cne $ExpectedCapabilities) {
            throw "HTTPS receiver has incompatible capabilities."
        }
    } catch {
        throw "HTTPS capability probe failed for ${Endpoint}: $($_.Exception.ToString())"
    } finally {
        if ($request) { $request.Dispose() }
        if ($response) { $response.Dispose() }
        if ($client) { $client.Dispose() }
        if ($handler) { $handler.Dispose() }
        $expectedCertificate.Dispose()
        [Net.ServicePointManager]::SecurityProtocol = $previousSecurityProtocol
    }
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

function Get-InstalledClientProcesses {
    try {
        $namedProcesses = @(Get-CimInstance Win32_Process -Filter "Name='$ProgramName.exe'" -ErrorAction Stop)
    } catch {
        throw "Could not inspect installed Windows client processes: $_"
    }
    if ($namedProcesses | Where-Object { -not $_.ExecutablePath }) {
        throw "Could not determine the executable path of a running $ProgramName process."
    }
    return @($namedProcesses | Where-Object { $_.ExecutablePath -ieq $InstalledBinary })
}

function Stop-InstalledClient([int]$TimeoutMilliseconds = 5000) {
    $processes = @(Get-InstalledClientProcesses)
    foreach ($process in $processes) {
        Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
    }
    if ($processes.Count -eq 0) {
        return $true
    }
    return Wait-InstalledClientStopped -TimeoutMilliseconds $TimeoutMilliseconds
}

function Wait-InstalledClientStopped(
    [int]$TimeoutMilliseconds = 5000,
    [scriptblock]$Probe = { Test-InstalledClientRunning }
) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        if (-not (& $Probe)) {
            return $true
        }
        Start-Sleep -Milliseconds 100
    } while ($timer.ElapsedMilliseconds -lt $TimeoutMilliseconds)
    return -not (& $Probe)
}

function Test-InstalledClientRunning {
    return @(Get-InstalledClientProcesses).Count -gt 0
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

function Start-NormalInstalledClient([string]$ShortcutPath) {
    if (-not (Test-IsAdministrator)) {
        Start-InstalledClient
        return
    }

    # Explorer brokers the shortcut through the existing normal-integrity shell
    # instead of inheriting this administrator installer's token.
    $explorer = Join-Path $env:SystemRoot "explorer.exe"
    Start-Process -FilePath $explorer -ArgumentList @("`"$ShortcutPath`"")
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

function Find-RootJsonArrayOpenBracket([string]$Code, [string]$PropertyName) {
    $objectDepth = 0
    $arrayDepth = 0
    for ($i = 0; $i -lt $Code.Length; $i++) {
        $current = $Code[$i]
        if ($current -eq '"') {
            $start = $i
            $escaped = $false
            for ($i++; $i -lt $Code.Length; $i++) {
                $current = $Code[$i]
                if ($escaped) {
                    $escaped = $false
                } elseif ($current -eq "\") {
                    $escaped = $true
                } elseif ($current -eq '"') {
                    break
                }
            }
            if ($i -ge $Code.Length) {
                return -1
            }
            if ($objectDepth -eq 1 -and $arrayDepth -eq 0) {
                $next = $i + 1
                while ($next -lt $Code.Length -and [char]::IsWhiteSpace($Code[$next])) { $next++ }
                if ($next -lt $Code.Length -and $Code[$next] -eq ":") {
                    $encodedName = $Code.Substring($start, $i - $start + 1)
                    $name = ConvertFrom-Json -InputObject $encodedName -ErrorAction Stop
                    $next++
                    while ($next -lt $Code.Length -and [char]::IsWhiteSpace($Code[$next])) { $next++ }
                    if ($name -ieq $PropertyName -and $next -lt $Code.Length -and $Code[$next] -eq "[") {
                        return $next
                    }
                }
            }
            continue
        }
        switch ($current) {
            "{" { $objectDepth++; break }
            "}" { $objectDepth--; break }
            "[" { $arrayDepth++; break }
            "]" { $arrayDepth--; break }
        }
    }
    return -1
}

function Set-TextFileAtomically(
    [string]$Path,
    [bool]$ExpectedExists,
    [AllowNull()][string]$ExpectedText,
    [string]$NewText,
    [switch]$ValidateJsonc,
    [string]$FaultPrefix = "AtomicWrite"
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
        Invoke-BootstrapTestFault "${FaultPrefix}BeforeReplace"

        if ($ExpectedExists) {
            # ReplaceFile can commit and still surface an exceptional return.
            # Treat the operation as potentially committed before invoking it.
            $replaced = $true
            [IO.File]::Replace($temporary, $Path, $rollback, $true)
        } else {
            [IO.File]::Move($temporary, $Path)
            $replaced = $true
        }
        Invoke-BootstrapTestFault "${FaultPrefix}AfterReplace"

        if ($ValidateJsonc) {
            Assert-ValidWindowsTerminalJsonc ([IO.File]::ReadAllText($Path)) $Path
        }
    } catch {
        $failure = $_
        if ($replaced) {
            try {
                Invoke-BootstrapTestFault "${FaultPrefix}BeforeRestore"
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
    $functionKey = 13 + ($Slot % 12)
    return "ctrl+alt+shift+f$functionKey"
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
        $payload = "${escape}[200~${remotePastePath}${escape}[201~ "
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

        $openBracket = Find-RootJsonArrayOpenBracket $code "actions"
        if ($openBracket -ge 0) {
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
    if (-not (Test-Path -LiteralPath $Update.Path) -or
        [IO.File]::ReadAllText($Update.Path) -cne $Update.Original) {
        throw "$($Update.Path) changed while the installer was preparing its backup. Rerun bootstrap.ps1."
    }
    $backup = "$($Update.Path).opencode-ssh-image-paste.backup"
    $backupExisted = Test-Path -LiteralPath $backup
    $existingBackup = if ($backupExisted) { [IO.File]::ReadAllText($backup) } else { $null }
    Set-TextFileAtomically `
        -Path $backup `
        -ExpectedExists $backupExisted `
        -ExpectedText $existingBackup `
        -NewText $Update.Original `
        -FaultPrefix "StableBackupWrite"
    $Update.BackupCreated = -not $backupExisted
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
    $terminalActionsRemoved = $false
    $startupTaskRemoved = $false
    $remoteCleanupComplete = $true
    $startup = [Environment]::GetFolderPath("Startup")
    $shortcutPath = Join-Path $startup "OpenCode SSH Image Paste.lnk"
    $shortcutExisted = Test-Path -LiteralPath $shortcutPath
    $shortcutBytes = if ($shortcutExisted) { [IO.File]::ReadAllBytes($shortcutPath) } else { $null }
    $shortcutRemoved = $false

    try {
        Write-Step "Stopping Windows client"
        if (-not (Stop-InstalledClient)) {
            throw "Could not stop the installed Windows client. Close it in Task Manager, then rerun uninstall."
        }
        $clientStopped = $true

        Write-Step "Removing Windows Terminal paste action"
        Uninstall-WindowsTerminalAction -PlannedUpdates $terminalUpdates
        $terminalActionsRemoved = $true

        if (Test-Path -LiteralPath $shortcutPath) {
            Remove-Item -Force -LiteralPath $shortcutPath
            $shortcutRemoved = $true
        }
        Remove-ElevatedStartupTask
        $startupTaskRemoved = $startupTaskExists

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

        # Remote deletion is deliberately last: a local failure must not leave a
        # restored old client depending on an already deleted receiver.
        if ($target) {
            if (Get-Command ssh.exe -ErrorAction SilentlyContinue) {
                Write-Step "Removing Linux receiver from $target"
                $remoteUninstall = (Get-SystemdStopCommand $true) + "; " +
                    "rm -f ~/$ReceiverServiceFile; rm -rf ~/$ReceiverConfigDirectory; " +
                    "systemctl --user daemon-reload; " +
                    "if systemctl --user is-active --quiet $ProgramName.service; then exit 1; fi; " +
                    "rm -f ~/.local/bin/$ProgramName; rm -rf ~/.cache/$ProgramName"
                & ssh.exe @SshOptions -- $target $remoteUninstall
                if ($LASTEXITCODE -ne 0) {
                    $remoteCleanupComplete = $false
                    Write-Warning "Remote receiver cleanup failed or could not be verified. Local uninstall completed, but remote files or service state may remain."
                }
            } else {
                $remoteCleanupComplete = $false
                Write-Warning "Windows OpenSSH Client was not found. Local uninstall completed, but the remote receiver was not removed."
            }
        } else {
            $remoteCleanupComplete = $false
            Write-Warning "No SSH target was provided or found in the configuration. Local uninstall completed, but the remote receiver was not removed."
        }
    } catch {
        $failure = $_
        $terminalRollbackComplete = $true
        $startupRollbackComplete = $true
        if ($terminalActionsRemoved) {
            $terminalItems = @($terminalUpdates)
            [array]::Reverse($terminalItems)
            foreach ($update in $terminalItems) {
                try {
                    if (-not (Restore-WindowsTerminalUpdate $update)) {
                        $terminalRollbackComplete = $false
                    }
                } catch {
                    $terminalRollbackComplete = $false
                    Write-Warning "Uninstall failed and Windows Terminal settings could not be restored: $_"
                }
            }
        }
        if ($shortcutRemoved) {
            try {
                if (Test-Path -LiteralPath $shortcutPath) {
                    throw "Startup shortcut was recreated concurrently: $shortcutPath"
                }
                [IO.File]::WriteAllBytes($shortcutPath, $shortcutBytes)
            } catch {
                $startupRollbackComplete = $false
                Write-Warning "Uninstall failed and the Startup shortcut could not be restored: $_"
            }
        }
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
                } elseif ($shortcutExisted) {
                    Start-NormalInstalledClient $shortcutPath
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
    if ($remoteCleanupComplete) {
        Write-Host "Uninstall complete." -ForegroundColor Green
    } else {
        Write-Warning "Local uninstall complete; remote cleanup is incomplete. Review the warning above and remove the remote receiver manually."
    }
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

function Set-TomlSetting(
    [string]$Text,
    [string]$Name,
    [string]$Value
) {
    $setting = "$Name = $Value"
    if ($Text -match "(?m)^\s*$([regex]::Escape($Name))\s*=") {
        return $Text -replace "(?m)^\s*$([regex]::Escape($Name))\s*=.*$", $setting
    }
    return $Text.TrimEnd([char[]]@([char]13, [char]10)) + "`r`n$setting`r`n"
}

function Get-UpdatedConfigText(
    [AllowNull()][string]$ExistingConfig,
    [string]$Target,
    [string]$RemotePasteDirectory,
    [bool]$UseHttps = $false,
    [string]$HttpsEndpoint,
    [string]$HttpsToken,
    [string]$HttpsCertificatePath
) {
    Assert-CompatibleExistingRemoteCommand $ExistingConfig
    $targetSetting = "ssh_target = $(ConvertTo-TomlBasicString $Target)"
    $probeSetting = 'remote_probe_command = "~/.local/bin/opencode-ssh-image-paste receiver --capabilities"'
    $pasteDirectorySetting = "terminal_paste_directory = $(ConvertTo-TomlBasicString $RemotePasteDirectory)"
    $transportSetting = if ($UseHttps) { 'transport = "https"' } else { 'transport = "ssh"' }

    # PowerShell coerces $null passed to a [string] parameter into "".
    if ([string]::IsNullOrEmpty($ExistingConfig)) {
        return @"
$transportSetting
$targetSetting
ssh_program = "ssh.exe"
ssh_arguments = []
remote_command = "~/.local/bin/opencode-ssh-image-paste receiver"
$probeSetting
$pasteDirectorySetting
terminal_window_class = "CASCADIA_HOSTING_WINDOW_CLASS"
request_timeout_seconds = 15
$(if ($UseHttps) { "https_endpoint = $(ConvertTo-TomlBasicString $HttpsEndpoint)`r`nhttps_token = $(ConvertTo-TomlBasicString $HttpsToken)`r`nhttps_certificate_path = $(ConvertTo-TomlBasicString $HttpsCertificatePath)" })
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

    $transportValue = if ($UseHttps) { '"https"' } else { '"ssh"' }
    $updated = Set-TomlSetting $updated "transport" $transportValue
    if ($updated -match '(?m)^\s*terminal_paste_directory\s*=') {
        $updated = $updated -replace '(?m)^\s*terminal_paste_directory\s*=.*$', $pasteDirectorySetting
    } elseif ($updated -match '(?m)^\s*terminal_paste_path\s*=') {
        $updated = $updated -replace '(?m)^\s*terminal_paste_path\s*=.*$', $pasteDirectorySetting
    } else {
        $updated = $updated.TrimEnd([char[]]@([char]13, [char]10)) + "`r`n$pasteDirectorySetting`r`n"
    }
    if ($UseHttps) {
        $updated = Set-TomlSetting $updated "https_endpoint" (ConvertTo-TomlBasicString $HttpsEndpoint)
        $updated = Set-TomlSetting $updated "https_token" (ConvertTo-TomlBasicString $HttpsToken)
        $updated = Set-TomlSetting $updated "https_certificate_path" (ConvertTo-TomlBasicString $HttpsCertificatePath)
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
    throw "-ElevatedStartup creates a highest-privilege login task and requires an administrator PowerShell. Reopen PowerShell as administrator, or omit -ElevatedStartup for a normal Windows Terminal."
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
if ($UseHttpsTransport -and [string]::IsNullOrWhiteSpace($HttpsHost)) {
    $HttpsHost = Read-Host "Fixed LAN host name or IP for the HTTPS receiver"
}
if ($UseHttpsTransport -and ([string]::IsNullOrWhiteSpace($HttpsHost) -or
    $HttpsHost -notmatch '^[A-Za-z0-9._:-]+$' -or
    @($HttpsHost.ToCharArray() | Where-Object { [char]::IsControl($_) }).Count -gt 0)) {
    throw "A valid fixed LAN HTTPS host name or IP address is required."
}

$TempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("opencode-ssh-image-paste-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $TempDir | Out-Null

$operationId = [guid]::NewGuid().ToString("N")
$remoteTemporary = ".local/bin/$ProgramName.download.$operationId"
$remoteRollback = ".local/bin/$ProgramName.rollback.$operationId"
$remoteHttpsRollback = ".config/$ProgramName.rollback.$operationId"
$remoteActivated = $false
$remoteHttpsStateCaptured = $false
$remoteHadExisting = $false
$localActivated = $false
$localCandidate = $null
$localRollback = Join-Path $InstallDir ".$ProgramName.$operationId.rollback.exe"
$retainLocalRollback = $false
$configCommitted = $false
$certificateCommitted = $false
$clientCertificatePath = Join-Path $ConfigDir "receiver-cert.pem"
$certificateExisted = Test-Path -LiteralPath $clientCertificatePath
$existingCertificateText = if ($certificateExisted) { [IO.File]::ReadAllText($clientCertificatePath) } else { $null }
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

    if ($UseHttpsTransport) {
        Write-Step "Checking systemd user service and linger"
        $systemdState = ((& ssh.exe @SshOptions -- $SshTarget "systemctl --user show-environment >/dev/null 2>&1 && loginctl show-user `"`$USER`" -p Linger --value") -join "`n").Trim()
        if ($LASTEXITCODE -ne 0) {
            throw "systemctl --user is unavailable for the remote user. HTTPS mode requires a systemd user manager."
        }
        if ($systemdState -cne "yes") {
            throw "Remote user linger is not enabled. Run 'loginctl enable-linger USER' as an administrator before HTTPS installation."
        }
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
    $updatedConfig = $null
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
    if (-not (Stop-InstalledClient)) {
        throw "Could not stop the previous Windows client. Close it in Task Manager, then rerun bootstrap.ps1."
    }

    if ($UseHttpsTransport) {
        Write-Step "Capturing Linux receiver service state"
        $captureRemoteState = "set -eu; rm -rf ~/$remoteHttpsRollback; mkdir -p -m 700 ~/$remoteHttpsRollback; " +
            "if [ -d ~/$ReceiverConfigDirectory ]; then cp -a ~/$ReceiverConfigDirectory ~/$remoteHttpsRollback/config; touch ~/$remoteHttpsRollback/config-existed; fi; " +
            "if [ -f ~/$ReceiverServiceFile ]; then cp -a ~/$ReceiverServiceFile ~/$remoteHttpsRollback/service; touch ~/$remoteHttpsRollback/unit-existed; fi; " +
            "active_status=0; systemctl --user is-active --quiet $ProgramName.service || active_status=`$?; " +
            "case `"`$active_status`" in 0) touch ~/$remoteHttpsRollback/was-active ;; 3|4) ;; *) exit 1 ;; esac; " +
            "enabled_status=0; enabled_state=`$(systemctl --user is-enabled $ProgramName.service 2>/dev/null) || enabled_status=`$?; " +
            "case `"`$enabled_state`" in enabled|enabled-runtime) touch ~/$remoteHttpsRollback/was-enabled ;; disabled|static|indirect|masked|not-found|generated|transient) ;; *) exit 1 ;; esac; " +
            "touch ~/$remoteHttpsRollback/state-captured; test -f ~/$remoteHttpsRollback/state-captured"
        & ssh.exe @SshOptions -- $SshTarget $captureRemoteState
        if ($LASTEXITCODE -ne 0) { throw "Could not capture the existing HTTPS receiver service state." }
        $remoteHttpsStateCaptured = $true
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

    $httpsEndpoint = $null
    $httpsToken = $null
    $downloadedCertificate = Join-Path $TempDir "receiver-cert.pem"
    if ($UseHttpsTransport) {
        Write-Step "Initializing HTTPS receiver"
        & ssh.exe @SshOptions -- $SshTarget (Get-SystemdStopCommand $false)
        if ($LASTEXITCODE -ne 0) { throw "Could not stop and verify the previous HTTPS receiver service." }
        $initializeHttps = "mkdir -p -m 700 ~/$ReceiverConfigDirectory; " +
            "~/.local/bin/$ProgramName receiver --init-https-config ~/$ReceiverConfigFile --host $HttpsHost --port $HttpsPort"
        & ssh.exe @SshOptions -- $SshTarget $initializeHttps
        if ($LASTEXITCODE -ne 0) { throw "Could not initialize the HTTPS receiver configuration." }

        $serviceText = Get-SystemdUserServiceText
        $serviceBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($serviceText))
        $installService = "set -eu; mkdir -p ~/.config/systemd/user; " +
            "printf %s $serviceBase64 | base64 -d > ~/$ReceiverServiceFile.new; chmod 600 ~/$ReceiverServiceFile.new; mv -f ~/$ReceiverServiceFile.new ~/$ReceiverServiceFile; " +
            "systemctl --user daemon-reload; systemctl --user enable --now $ProgramName.service; " +
            "systemctl --user is-enabled --quiet $ProgramName.service; systemctl --user is-active --quiet $ProgramName.service"
        & ssh.exe @SshOptions -- $SshTarget $installService
        if ($LASTEXITCODE -ne 0) { throw "Could not install or start the systemd user HTTPS receiver service." }

        $downloadedReceiverConfig = Join-Path $TempDir "receiver.toml"
        & scp.exe @ScpOptions -- "${SshTarget}:$ReceiverConfigFile" $downloadedReceiverConfig
        if ($LASTEXITCODE -ne 0) { throw "Could not download the generated HTTPS receiver configuration." }
        & scp.exe @ScpOptions -- "${SshTarget}:$ReceiverCertificateFile" $downloadedCertificate
        if ($LASTEXITCODE -ne 0) { throw "Could not download the HTTPS receiver certificate." }
        $updatedCertificateText = [IO.File]::ReadAllText($downloadedCertificate)
        $receiverConfigText = [IO.File]::ReadAllText($downloadedReceiverConfig)
        $tokenMatch = [regex]::Match($receiverConfigText, '(?m)^token\s*=\s*"([0-9a-fA-F]{64})"\s*$')
        if (-not $tokenMatch.Success) { throw "Generated HTTPS receiver token is missing or invalid." }
        $httpsToken = $tokenMatch.Groups[1].Value
        $httpsEndpoint = Get-HttpsEndpoint $HttpsHost $HttpsPort
        Test-HttpsReceiver $httpsEndpoint $httpsToken $downloadedCertificate
    } else {
        Write-Step "Selecting explicit legacy SSH receiver mode"
        $stopOptionalHttpsService = "if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then " +
            (Get-SystemdStopCommand $true) + "; fi"
        & ssh.exe @SshOptions -- $SshTarget $stopOptionalHttpsService
        if ($LASTEXITCODE -ne 0) { throw "Could not disable, stop, and verify the HTTPS receiver before selecting SSH mode." }
    }

    # Delay the Terminal write until the remote transport has passed its live
    # probe. This keeps TLS, authentication, and service-start failures entirely
    # inside the remote rollback path and avoids a Terminal rewrite race.
    Write-Step "Configuring 10 atomic Windows Terminal paste actions"
    foreach ($update in $terminalUpdates) {
        [void]$appliedTerminalUpdates.Add($update)
        Apply-WindowsTerminalUpdate $update
    }

    $updatedConfig = Get-UpdatedConfigText `
        -ExistingConfig $existingConfig `
        -Target $SshTarget `
        -RemotePasteDirectory $remotePasteDirectory `
        -UseHttps $UseHttpsTransport `
        -HttpsEndpoint $httpsEndpoint `
        -HttpsToken $httpsToken `
        -HttpsCertificatePath $clientCertificatePath

    Write-Step "Installing Windows client"
    New-Item -ItemType Directory -Force -Path $InstallDir, $ConfigDir | Out-Null
    if ($UseHttpsTransport) {
        $certificateCommitted = $true
        Set-TextFileAtomically `
            -Path $clientCertificatePath `
            -ExpectedExists $certificateExisted `
            -ExpectedText $existingCertificateText `
            -NewText $updatedCertificateText
    }
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
        Start-NormalInstalledClient $shortcutPath
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
    & ssh.exe @SshOptions -- $SshTarget "rm -f ~/$remoteRollback; rm -rf ~/$remoteHttpsRollback" | Out-Null
} catch {
    $failure = $_
    if ($commitStarted) {
        $rollbackComplete = $true
        try {
            $rollbackClientStopped = Stop-InstalledClient
        } catch {
            $retainLocalRollback = $true
            Write-Warning "Could not inspect or stop the newly started Windows client; installation rollback was not attempted: $_"
            throw $failure
        }
        if (-not $rollbackClientStopped) {
            $retainLocalRollback = $true
            Write-Warning "Could not stop the newly started Windows client; installation rollback was not attempted."
            throw $failure
        }

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

        if ($certificateCommitted) {
            try {
                if ($certificateExisted) {
                    $currentCertificate = [IO.File]::ReadAllText($clientCertificatePath)
                    if ($currentCertificate -ceq $updatedCertificateText) {
                        Set-TextFileAtomically $clientCertificatePath $true $currentCertificate $existingCertificateText
                    } elseif ($currentCertificate -ceq $existingCertificateText) {
                        # The atomic update failed before replacing the original.
                    } else {
                        throw "HTTPS certificate changed after installation; refusing to overwrite it."
                    }
                } else {
                    if (Test-Path -LiteralPath $clientCertificatePath) {
                        $currentCertificate = [IO.File]::ReadAllText($clientCertificatePath)
                        if ($currentCertificate -cne $updatedCertificateText) {
                            throw "HTTPS certificate changed after installation; refusing to remove it."
                        }
                        Remove-Item -Force -LiteralPath $clientCertificatePath
                    }
                }
            } catch {
                $rollbackComplete = $false
                Write-Warning "Could not restore the HTTPS receiver certificate: $_"
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
            $restoreBinary = if ($remoteHadExisting) {
                "test -e ~/$remoteRollback; mv -f ~/$remoteRollback ~/.local/bin/$ProgramName; "
            } else {
                "rm -f ~/.local/bin/$ProgramName; "
            }
            if ($UseHttpsTransport -and $remoteHttpsStateCaptured) {
                $restoreRemote = "set -eu; test -f ~/$remoteHttpsRollback/state-captured; " +
                    (Get-SystemdStopCommand $false) + "; " +
                    $restoreBinary +
                    "rm -rf ~/$ReceiverConfigDirectory; rm -f ~/$ReceiverServiceFile; " +
                    "if [ -f ~/$remoteHttpsRollback/config-existed ]; then cp -a ~/$remoteHttpsRollback/config ~/$ReceiverConfigDirectory; fi; " +
                    "if [ -f ~/$remoteHttpsRollback/unit-existed ]; then cp -a ~/$remoteHttpsRollback/service ~/$ReceiverServiceFile; fi; " +
                    "systemctl --user daemon-reload; " +
                    "if [ -f ~/$remoteHttpsRollback/was-enabled ]; then " +
                    "systemctl --user enable $ProgramName.service; systemctl --user is-enabled --quiet $ProgramName.service; " +
                    "else " + (Get-SystemdStopCommand $true) + "; if systemctl --user is-enabled --quiet $ProgramName.service; then exit 1; fi; fi; " +
                    "if [ -f ~/$remoteHttpsRollback/was-active ]; then " +
                    "systemctl --user start $ProgramName.service; systemctl --user is-active --quiet $ProgramName.service; " +
                    "elif systemctl --user is-active --quiet $ProgramName.service; then exit 1; fi"
            } elseif ($UseHttpsTransport) {
                $restoreRemote = $null
                $rollbackComplete = $false
                Write-Warning "The Linux receiver was activated without a verified service-state snapshot; remote rollback was blocked."
            } else {
                $restoreRemote = "set -eu; $restoreBinary"
            }
            if ($restoreRemote) {
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
        }

        $installedBinaryExists = Test-Path -LiteralPath $InstalledBinary
        $configurationExists = Test-Path -LiteralPath $ConfigPath
        if (Test-CanRestartPreviousClient $oldClientWasRunning $rollbackComplete $installedBinaryExists $configurationExists) {
            try {
                if ($startupTaskExisted) {
                    Start-ElevatedStartupTask
                } elseif ($shortcutExisted) {
                    Start-NormalInstalledClient $shortcutPath
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
