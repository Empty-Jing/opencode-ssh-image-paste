# Contributing

感谢你参与 OpenCode SSH Image Paste。

## 开发环境

- Rust 1.89 或更高版本，edition 2024
- Windows 客户端：Windows 10/11、Windows Terminal、OpenSSH Client
- Receiver：Linux、OpenSSH Server

## 本地检查

提交变更前执行：

```bash
cargo fmt --check
cargo clippy --all-targets -- -D warnings
cargo test
cargo check --tests --target x86_64-pc-windows-msvc
pwsh -NoProfile -File ./tests/bootstrap.Tests.ps1
```

在 Linux 上生成 Windows Release 二进制：

```bash
cargo install cargo-xwin --locked
cargo xwin build --release --target x86_64-pc-windows-msvc
```

## 变更原则

- 文本剪贴板必须继续由 Windows Terminal 原样处理。
- 键盘钩子回调不得执行网络、编码或阻塞 I/O。
- Client 不得清空、替换或恢复 Windows 剪贴板；兼容性读取必须优先使用标准 PNG/DIB/Bitmap 格式。
- 只允许精确的图片 `Ctrl+V` 进入桥接，带额外修饰键的组合必须放行。
- 焦点、用户输入或剪贴板发生变化后，不得自动注入远端路径。
- 协议变更必须更新 `docs/design.md` 并补充往返测试。
- Windows Terminal 设置修改必须保留用户 JSONC 内容，使用原子写入，并为安装、重复安装和卸载提供回归测试。
- 不得在日志、示例或测试中提交密码、私钥、真实主机地址或用户目录。

## Pull Request

请说明问题、方案、验证命令和剩余风险。涉及 Windows 输入、剪贴板或 SSH 生命周期的修改，应附真实 Windows 环境验证结果。
