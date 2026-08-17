# 故障排查

[English](troubleshooting.md) | 简体中文

## 先运行 `doctor`

在 Windows PowerShell 中运行：

```powershell
& "$env:LOCALAPPDATA\Programs\OpenCodeSSHImagePaste\opencode-ssh-image-paste.exe" doctor
```

它会检查配置文件、OpenSSH、Windows Terminal、SSH 目标、远端 Receiver 协议兼容性和后台
Client 进程。建议从第一个失败项开始处理。

## 安装停在 `Testing SSH connection`

使用与安装器相同的非交互模式测试 SSH：

```powershell
ssh.exe -o BatchMode=yes -o ConnectTimeout=10 -n -T ubuntu-workbox "printf ready"
```

命令必须输出 `ready` 并退出。否则请依次检查：

1. 先运行一次 `ssh.exe ubuntu-workbox`，接受主机密钥。
2. 配置 SSH key 或 `ssh-agent`；后台 Client 不支持密码提示。
3. 确认 `%USERPROFILE%\.ssh\config` 中存在对应别名。
4. 确认上面的非交互命令成功后再重试安装。

## 只有按 `Ctrl+C` 或第二次执行时才出现 `ready`

请从最新 Release 重新下载 `bootstrap.ps1`。v0.1.3 及之后的脚本会分离 SSH
探测命令的标准输入，并禁用伪终端：

```powershell
iwr https://github.com/Empty-Jing/opencode-ssh-image-paste/releases/latest/download/bootstrap.ps1 -OutFile bootstrap.ps1
```

如果旧 Client 仍在运行，先停止它再重新安装：

```powershell
Get-Process opencode-ssh-image-paste -ErrorAction SilentlyContinue | Stop-Process -Force
```

## GitHub API 限流或 Release 下载失败

当前安装器直接使用 `latest` Release 地址，不再调用匿名 GitHub Releases API。如果旧脚本
报告 API rate limit，请使用上面的命令重新下载 `bootstrap.ps1`。

其他下载错误请检查 PowerShell 能否访问 `github.com` 和
`release-assets.githubusercontent.com`，并确认代理没有拦截或改写 GitHub Release 下载。

## 支持管理员 Terminal 需要管理员 PowerShell

默认安装使用当前用户的普通 Startup 快捷方式，不需要提权。普通权限 Client 无法向管理员
Windows Terminal 注入输入。

如果需要支持管理员 Terminal，请从管理员 PowerShell 显式启用提权启动：

```powershell
.\bootstrap.ps1 -SshTarget ubuntu-workbox -ElevatedStartup
```

## 任务栏仍然显示 Client 窗口

当前 Windows Client 是无窗口后台进程。它会出现在任务管理器中，但不应创建任务栏窗口。
请停止旧进程并重新安装最新版：

```powershell
Get-Process opencode-ssh-image-paste -ErrorAction SilentlyContinue | Stop-Process -Force
.\bootstrap.ps1 -SshTarget ubuntu-workbox
```

## `Ctrl+V` 没有插入图片

请确认：

- 剪贴板中是纯图片，没有同时附带文本。
- 当前焦点位于 Windows Terminal。
- 上传期间没有切换 Windows Terminal 窗口、Tab 或 pane。
- 后台 Client 正在运行，并且 `doctor` 检查正常。
- Windows Terminal 与 Client 权限级别相同；默认 Client 为普通权限，管理员 Terminal
  需要显式使用 `-ElevatedStartup`。
- OpenCode 当前使用的模型支持图片输入。

纯文本剪贴板仍然由 Windows Terminal 自己处理，这是预期行为。

## HTTPS 安装前置检查失败

HTTPS 是默认模式。无交互安装必须显式传入固定内网 Host/IP；默认端口为 `47832`：

```powershell
.\bootstrap.ps1 -SshTarget ubuntu-workbox -HttpsHost 10.0.0.8 -HttpsPort 47832
```

远端用户必须能使用 `systemctl --user`，且 `loginctl show-user "$USER" -p Linger --value` 必须输出 `yes`。否则请让管理员执行 `loginctl enable-linger USER`。同时确认配置的内网 Host 指向 Receiver 且端口可达；bootstrap 不会修改防火墙。

证书 SAN 只覆盖安装时配置的 Host/IP。除非使用新 Host 重新运行 bootstrap，否则不要把 `https://10.0.0.8:47832` 换成其他别名，也不要关闭 TLS 校验。`/v1/capabilities` 返回 `401` 表示两端 Token 不一致，应重新运行安装事务，不要通过命令行复制 Token。

HTTPS 与 stdio Receiver 不能占用同一图片目录。显式回退时，运行 `.\bootstrap.ps1 -SshTarget ubuntu-workbox -LegacySshTransport`；bootstrap 会写入 `transport = "ssh"`，停止并禁用 systemd 用户服务，并验证其不再 active。HTTPS 失败会直接报错，绝不会静默改走 SSH。

## Receiver 兼容性检查失败

直接检查远端二进制：

```powershell
ssh.exe -n -T ubuntu-workbox "~/.local/bin/opencode-ssh-image-paste --version"
ssh.exe -n -T ubuntu-workbox "~/.local/bin/opencode-ssh-image-paste receiver --capabilities"
```

如果文件不存在或架构错误，请重新运行 `bootstrap.ps1`。安装器会识别 `x86_64` 和
`aarch64` Linux，并自动替换 Receiver。

## 卸载

删除 Windows Client、登录启动项、配置、远端 Receiver 和远端图片缓存：

```powershell
.\bootstrap.ps1 -Uninstall
```

脚本会从现有配置读取 SSH 目标。需要时可以显式指定：

```powershell
.\bootstrap.ps1 -Uninstall -SshTarget ubuntu-workbox
```

保留本地配置以便之后重新安装：

```powershell
.\bootstrap.ps1 -Uninstall -KeepConfig
```

如果远端主机不可达，本地卸载仍会完成，并提示远端 Receiver 仍有残留。

## 测量图片粘贴延迟

后台 Client 会为每一次被拦截的图片粘贴写入一条耗时记录：

```text
%APPDATA%\OpenCodeSSHImagePaste\timing.log
```

测试时可以在 PowerShell 中实时查看：

```powershell
Get-Content "$env:APPDATA\OpenCodeSSHImagePaste\timing.log" -Wait -Tail 20
```

每行会记录 `transport=https|ssh`；HTTPS 的状态为 `transport_state=agent_new|agent_reused`，SSH 的状态为 `transport_state=connection_new|connection_reused|connection_reconnected`；此外还包括 `queue_ms`、`clipboard_read_ms`、`png_encode_ms`、
`ssh_spawn_ms`、`upload_receiver_ms`、`modifier_wait_ms`、
`input_guard_ms`、`terminal_paste_ms` 和 `bridge_total_ms`。`output=terminal_action` 表示
远端路径通过对应的 Windows Terminal 槽位 Action 原子发送，没有替换系统剪贴板。同时还会记录图片尺寸、
RGBA/PNG 字节数和尝试次数。HTTPS 状态只表示长期 Agent 是否已经用过，客户端无法观测连接池是否复用了底层 Socket；SSH 状态表示常驻子进程连接。

`ssh_spawn_ms` 只表示本地 `ssh.exe` 进程的创建时间。对于 `cold` 或
`reconnected` 请求，由于当前协议没有上传前的 ready 消息，SSH 握手和 Receiver
启动耗时会包含在 `upload_receiver_ms` 中。`opencode_handoff_ms` 和
`opencode_handoff_unix_ms` 表示模拟粘贴已经发送到 Windows Terminal 的时间点。
OpenCode 没有提供处理完成回调，因此日志会明确记录
`opencode_completion=unobservable`；需要把 handoff 时间与屏幕上附件出现的时间对照。

成功和失败的请求都会写入日志。日志约 1 MiB 后轮转为 `timing.log.1`，且不会记录
剪贴板图片内容、远端路径或 SSH 主机名。

## 提交问题

在 [GitHub Issue](https://github.com/Empty-Jing/opencode-ssh-image-paste/issues)
中尽量提供：

- Windows 和 Windows Terminal 版本。
- `ssh.exe -V` 输出。
- 远端 Linux 发行版和 `uname -m` 输出。
- 完整 `doctor` 输出；必要时可隐藏主机名或用户名。
- Windows Terminal 是否以管理员身份运行。
