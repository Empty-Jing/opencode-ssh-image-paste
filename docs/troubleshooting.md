# Troubleshooting

English | [简体中文](troubleshooting.zh-CN.md)

## Start with `doctor`

Run the installed diagnostic command from Windows PowerShell:

```powershell
& "$env:LOCALAPPDATA\Programs\OpenCodeSSHImagePaste\opencode-ssh-image-paste.exe" doctor
```

It checks the configuration file, OpenSSH client, Windows Terminal, SSH target,
remote receiver compatibility, and background client process. Fix the first reported
failure before investigating later checks.

## Installer stops at `Testing SSH connection`

Test the same non-interactive SSH mode used by the installer:

```powershell
ssh.exe -o BatchMode=yes -o ConnectTimeout=10 -n -T ubuntu-workbox "printf ready"
```

The command must print `ready` and exit. If it does not:

1. Run `ssh.exe ubuntu-workbox` once to accept the host key.
2. Configure an SSH key or `ssh-agent`; password prompts are not supported by the background client.
3. Confirm the alias exists in `%USERPROFILE%\.ssh\config`.
4. Retry the non-interactive command before running the installer again.

## Installer prints `ready` only after `Ctrl+C` or on the second run

Download a fresh `bootstrap.ps1` from the latest release. v0.1.3 and later run
probe commands with detached standard input and no pseudo-terminal:

```powershell
iwr https://github.com/Empty-Jing/opencode-ssh-image-paste/releases/latest/download/bootstrap.ps1 -OutFile bootstrap.ps1
```

If the old client is still running, stop it before reinstalling:

```powershell
Get-Process opencode-ssh-image-paste -ErrorAction SilentlyContinue | Stop-Process -Force
```

## GitHub API rate limit or release download failure

Current installers download assets directly from the `latest` release URL and
do not call the anonymous GitHub Releases API. If an older script reports an API
rate limit, download `bootstrap.ps1` again using the command above.

For other download errors, verify that PowerShell can reach both `github.com`
and `release-assets.githubusercontent.com`, then retry without a proxy that rewrites or
blocks GitHub release downloads.

## Elevated Terminal support requires an administrator PowerShell

The default installation uses a normal per-user Startup shortcut and does not
require elevation. A normal client cannot inject input into an administrator
Windows Terminal.

If administrator Terminal support is required, run an administrator PowerShell
and explicitly enable elevated startup:

```powershell
.\bootstrap.ps1 -SshTarget ubuntu-workbox -ElevatedStartup
```

## A client window remains visible in the taskbar

The current Windows client is a windowless background process. It appears in
Task Manager, but should not create a taskbar window. Stop older processes and
reinstall the latest release:

```powershell
Get-Process opencode-ssh-image-paste -ErrorAction SilentlyContinue | Stop-Process -Force
.\bootstrap.ps1 -SshTarget ubuntu-workbox
```

## `Ctrl+V` does not attach an image

Check these conditions:

- The clipboard contains an image without accompanying text.
- The focused application is Windows Terminal.
- The same Windows Terminal window and pane remained focused during upload.
- The background client is running and `doctor` reports it as healthy.
- Windows Terminal and the client run at the same privilege level. The default
  client is not elevated; administrator Terminal support requires
  `-ElevatedStartup`.
- The selected OpenCode model supports image input.

Text-only clipboard content intentionally remains handled by Windows Terminal.

## HTTPS installation prerequisites fail

HTTPS is the default. For a non-interactive install, pass the fixed LAN host/IP explicitly; port `47832` is the default:

```powershell
.\bootstrap.ps1 -SshTarget ubuntu-workbox -HttpsHost 10.0.0.8 -HttpsPort 47832
```

The remote user must have a working `systemctl --user` session and `loginctl show-user "$USER" -p Linger --value` must print `yes`. Ask an administrator to run `loginctl enable-linger USER` if needed. Confirm the configured LAN host resolves to the receiver and the port is reachable. Bootstrap never changes firewall rules.

The generated certificate SAN contains exactly the configured host/IP. Do not replace `https://10.0.0.8:47832` with another alias unless you rerun bootstrap with that alias. Do not disable TLS verification. A `401` from `/v1/capabilities` means the local and receiver tokens differ; rerun bootstrap transactionally rather than copying tokens through a command line.

HTTPS and stdio receivers cannot share one image directory. For explicit fallback, rerun `bootstrap.ps1 -SshTarget ubuntu-workbox -LegacySshTransport`; bootstrap writes `transport = "ssh"`, stops and disables the systemd user service, and verifies it is inactive. HTTPS failures are reported and never silently retried through SSH.

## Receiver compatibility check fails

Verify the remote binary directly:

```powershell
ssh.exe -n -T ubuntu-workbox "~/.local/bin/opencode-ssh-image-paste --version"
ssh.exe -n -T ubuntu-workbox "~/.local/bin/opencode-ssh-image-paste receiver --capabilities"
```

If the binary is missing or has the wrong architecture, rerun `bootstrap.ps1`.
The installer detects `x86_64` and `aarch64` Linux hosts and replaces the
receiver atomically.

## Uninstall

Remove the Windows client, startup shortcut, configuration, remote receiver,
and remote image cache:

```powershell
.\bootstrap.ps1 -Uninstall
```

The SSH target is read from the existing configuration. Override it when needed:

```powershell
.\bootstrap.ps1 -Uninstall -SshTarget ubuntu-workbox
```

Keep the local configuration for a later reinstall:

```powershell
.\bootstrap.ps1 -Uninstall -KeepConfig
```

If the remote host cannot be reached, local uninstall still completes and prints
a warning about the remaining receiver.

## Measure image paste latency

The background client writes one timing record for every intercepted image paste:

```text
%APPDATA%\OpenCodeSSHImagePaste\timing.log
```

Follow it live from PowerShell while testing:

```powershell
Get-Content "$env:APPDATA\OpenCodeSSHImagePaste\timing.log" -Wait -Tail 20
```

Each line reports `transport=https|ssh`, `transport_state=agent_new|agent_reused` for HTTPS or `transport_state=connection_new|connection_reused|connection_reconnected` for SSH, `queue_ms`, `clipboard_read_ms`, `png_encode_ms`,
`ssh_spawn_ms`, `upload_receiver_ms`, `modifier_wait_ms`, `terminal_paste_ms`,
`input_guard_ms`, and `bridge_total_ms`. `output=terminal_action` confirms that the remote
path was dispatched through its matching Windows Terminal slot action without replacing the clipboard. The record also includes image
dimensions, raw and PNG byte counts, and attempt counts. HTTPS state records only whether the long-lived Agent has been used before; the client cannot observe whether its pool reused an underlying socket. SSH state describes the persistent subprocess connection.

`ssh_spawn_ms` only measures creation of the local `ssh.exe` process. For a
`cold` or `reconnected` request, SSH negotiation and receiver startup are part
of `upload_receiver_ms` because the current protocol has no pre-upload ready
message. `opencode_handoff_ms` and `opencode_handoff_unix_ms` mark when the
synthetic paste was sent to Windows Terminal. OpenCode does not provide a
completion callback, so the log records `opencode_completion=unobservable`;
compare the handoff timestamp with when the attachment appears on screen.

Successful and failed requests are both recorded. The active log rotates to
`timing.log.1` after approximately 1 MiB and never includes clipboard pixels,
remote paths, or SSH host names.

## Reporting a problem

Include the following information in a
[GitHub issue](https://github.com/Empty-Jing/opencode-ssh-image-paste/issues):

- Windows version and Windows Terminal version.
- Output from `ssh.exe -V`.
- Remote Linux distribution and `uname -m` output.
- Full `doctor` output with hostnames or usernames redacted if necessary.
- Whether the terminal is elevated.
