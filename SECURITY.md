# Security Policy

## Supported Versions

项目仍处于 pre-1.0 阶段。安全修复只应用于默认分支的最新代码和维护者明确列出的受支持 Release。

## Reporting a Vulnerability

如果仓库 Security 页面提供 Private Vulnerability Reporting，请优先通过该入口提交。若入口尚未启用，请只创建不含漏洞细节的公开 Issue，请求维护者提供私密联系方式。任何情况下都不要在公开 Issue 中附加私钥、主机地址、剪贴板内容、漏洞细节或远端文件。

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
- Receiver 对图片目录持有跨进程独占锁，避免并发连接覆盖同一槽位。
- 编码后单张图片上限为 16 MiB；Windows client 在标准剪贴板解码器返回后限制图片边长、像素数和原始 RGBA 大小，因此这些限制不是解码峰值内存的硬上限；receiver 会在分配前校验协议长度并检查 PNG 签名。
- 默认安装创建当前用户的普通 Startup 快捷方式，避免由普通用户可写程序或配置驱动高完整性进程。普通权限 Client 不能向管理员 Windows Terminal 注入输入；确有需要时可从管理员 PowerShell 显式传入 `-ElevatedStartup` 创建 `RunLevel=Highest` 登录任务，并接受该模式信任当前用户可写安装目录和配置的风险。
