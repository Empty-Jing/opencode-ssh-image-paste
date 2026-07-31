# Troubleshooting

English | [简体中文](troubleshooting.zh-CN.md)

## Start with `doctor`

Run the installed diagnostic command from Windows PowerShell:

```powershell
& "$env:LOCALAPPDATA\Programs\OpenCodeSSHImagePaste\opencode-ssh-image-paste.exe" doctor
```

It checks the configuration file, OpenSSH client, Windows Terminal, SSH target,
remote receiver version, and background client process. Fix the first reported
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
and `objects.githubusercontent.com`, then retry without a proxy that rewrites or
blocks GitHub release downloads.

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
- Windows Terminal and the client run at the same privilege level. A normal client cannot inject input into an elevated terminal.
- The selected OpenCode model supports image input.

Text-only clipboard content intentionally remains handled by Windows Terminal.

## Receiver version check fails

Verify the remote binary directly:

```powershell
ssh.exe -n -T ubuntu-workbox "~/.local/bin/opencode-ssh-image-paste --version"
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

## Reporting a problem

Include the following information in a
[GitHub issue](https://github.com/Empty-Jing/opencode-ssh-image-paste/issues):

- Windows version and Windows Terminal version.
- Output from `ssh.exe -V`.
- Remote Linux distribution and `uname -m` output.
- Full `doctor` output with hostnames or usernames redacted if necessary.
- Whether the terminal is elevated.
