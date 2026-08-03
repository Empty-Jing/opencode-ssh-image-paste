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

## Installation requires an administrator PowerShell

This is the default and is intentional. The installer creates a per-user login
task with `RunLevel=Highest` so the keyboard hook and input injection can work in
an administrator Windows Terminal. Installation and updates require one UAC
authorization, while login startup does not prompt again.

If Windows Terminal always runs without administrator privileges, explicitly
install the normal-integrity mode instead:

```powershell
.\bootstrap.ps1 -SshTarget ubuntu-workbox -NonElevatedStartup
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
  installation is elevated; `-NonElevatedStartup` is only for a normal Terminal.
- The selected OpenCode model supports image input.

Text-only clipboard content intentionally remains handled by Windows Terminal.

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

Each line reports `queue_ms`, `clipboard_read_ms`, `png_encode_ms`,
`ssh_spawn_ms`, `upload_receiver_ms`, `modifier_wait_ms`, `terminal_paste_ms`,
`input_guard_ms`, and `bridge_total_ms`. `output=terminal_action` confirms that the remote
path was dispatched through its matching Windows Terminal slot action without replacing the clipboard. The record also includes image
dimensions, raw and PNG byte counts, attempt counts, and whether the SSH connection
was `cold`, `reused`, or `reconnected`.

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
