# Security Policy

## Supported Versions

项目尚未发布稳定版本。安全修复只应用于默认分支的最新代码。

## Reporting a Vulnerability

公开仓库后，请使用 GitHub Private Vulnerability Reporting 提交安全问题，不要在公开 Issue 中附加私钥、主机地址、剪贴板内容或远端文件。

报告应包含：

- 受影响的版本或 commit；
- Windows、Windows Terminal 和 OpenSSH 版本；
- 可复现步骤；
- 预期影响；
- 已脱敏的日志或最小复现。

## Security Boundaries

- 本工具复用用户现有的 OpenSSH 主机校验和认证。
- Windows 客户端不保存密码或私钥。
- Receiver 仅以当前 SSH 用户权限运行。
- 图片目录权限为 `0700`，文件权限为 `0600`。
- 单张图片上限为 16 MiB，receiver 会校验协议长度和 PNG 签名。
