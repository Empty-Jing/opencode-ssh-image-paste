# OpenCode SSH Image Paste 设计文档

## 1. 文档目的

本文说明 OpenCode SSH Image Paste 的问题背景、系统边界、架构、协议、关键状态机、安全策略和验证要求。目标读者是维护者、贡献者和准备评估该工具的终端用户。

## 2. 问题与目标

典型工作流为 Windows Terminal 通过普通 SSH 连接 Linux，在 Herdr pane 中运行 OpenCode TUI。普通 SSH 只传递终端字节流，Windows Terminal 能把文本剪贴板转换为字符，却不会把图片剪贴板编码后传给远端，因此图片 `Ctrl+V` 在 OpenCode 中完全没有反应。

本项目保留原有工作习惯：

- 文本剪贴板继续由 Windows Terminal 处理，`Ctrl+V` 行为不变；
- 图片剪贴板使用同一个 `Ctrl+V`；
- 图片通过常驻 SSH 通道传到 Linux，不为每次粘贴启动 PowerShell、SCP 或新 SSH；
- Linux 返回图片绝对路径，Windows 制造一次文本粘贴事件，OpenCode 将该路径转成图片附件；
- 用户在上传期间切换窗口、Tab、pane、输入按键、点击鼠标或复制新内容时，自动粘贴必须取消。

## 3. 非目标

- 不修改 SSH 协议、Windows Terminal、Herdr 或 OpenCode；
- 不同步完整的 Windows/Linux 剪贴板历史；
- 不提供文件管理、远程桌面或通用剪贴板共享；
- 不绕过 OpenSSH 主机校验、认证或操作系统权限；
- 不保证所有 Windows 应用发布的图片剪贴板格式都可读取。

## 4. 总体架构

```mermaid
flowchart LR
    User[用户按 Ctrl+V] --> Hook[Windows 低级键盘钩子]
    Hook --> Kind{剪贴板类型}
    Kind -->|文本或非目标窗口| Pass[放行原始按键]
    Kind -->|PNG / DIBV5 图片| Queue[有界工作队列]
    Queue --> Encode[内存编码 PNG]
    Encode --> SSH[常驻 OpenSSH 子进程]
    SSH --> Receiver[Linux receiver]
    Receiver --> Store[私有临时文件]
    Store --> Path[返回绝对路径]
    Path --> Guard[焦点/输入/剪贴板复核]
    Guard -->|变化| Cancel[取消自动粘贴]
    Guard -->|未变化| Paste[临时写入路径并模拟 Ctrl+V]
    Paste --> Herdr[Herdr PTY]
    Herdr --> OpenCode[OpenCode 路径附件识别]
    OpenCode --> Attachment[Image attachment]
```

项目发布一个二进制，按子命令承担两种角色：

| 模式 | 平台 | 职责 |
|---|---|---|
| `client` | Windows | 监听图片粘贴、编码 PNG、维护 SSH、保护焦点与剪贴板、触发路径粘贴 |
| `receiver` | Linux | 读取帧、校验边界、私有落盘、返回路径、定期清理 |

## 5. 模块设计

### 5.1 `main.rs`

负责轻量命令分发。Windows 默认进入 `client`，Linux 使用 `receiver [--dir PATH]`。Linux 上主动启动 client 会返回明确错误。

### 5.2 `windows.rs`

Windows 端由四个逻辑部分组成：

1. 低级键盘和鼠标钩子只做快速判断、活动计数和入队，不执行阻塞工作。
2. 单工作线程读取剪贴板、编码 PNG，并串行处理上传，避免多个请求争抢剪贴板。
3. `Transport` 维护一个 OpenSSH 子进程，通过 stdin/stdout 复用连接，并通过 watchdog 处理阻塞。
4. Win32 clipboard lock、自定义 marker、前台窗口和用户活动代次共同防止错误注入。

### 5.3 `protocol.rs`

协议使用固定长度头和原始 PNG 字节，避免 Base64 膨胀和 shell 转义。所有长度在分配内存前校验。

### 5.4 `receiver.rs`

Receiver 在同一 SSH 进程中循环处理请求。目录创建后设置为 `0700`，文件通过 `create_new` 原子创建并设置为 `0600`。启动时、每次写入前和每小时执行一次清理，只删除自身 `clipboard-*.png` 文件。

## 6. 关键流程

### 6.1 文本粘贴

```mermaid
sequenceDiagram
    participant U as User
    participant H as Keyboard Hook
    participant WT as Windows Terminal
    participant OC as OpenCode

    U->>H: Ctrl+V
    H->>H: 检测到文本或不支持的图片格式
    H-->>WT: CallNextHookEx
    WT->>OC: 原始 Ctrl+V；最终行为由 Terminal 决定
```

该流程不经过 SSH bridge worker，确保工具未运行或异常时，原有文本粘贴仍然可用。

### 6.2 图片粘贴

```mermaid
sequenceDiagram
    participant U as User
    participant H as Windows Hook
    participant W as Worker
    participant S as OpenSSH
    participant R as Receiver
    participant WT as Windows Terminal
    participant OC as OpenCode

    U->>H: Ctrl+V
    H->>H: Windows Terminal + 图片 + 无文本
    H->>W: PasteRequest(HWND, sequence, activity)
    H-->>U: 吞掉本次 V down/up
    W->>W: 读取 RGBA 并编码 PNG
    W->>S: OCB1 request frame
    S->>R: SSH stdin
    R->>R: 校验并写入 0600 文件
    R-->>W: OCR1 response + absolute path
    W->>W: 复核 HWND、activity、clipboard sequence
    W->>WT: 临时路径剪贴板 + marker + Ctrl+V
    WT->>OC: bracketed text paste
    OC->>OC: 将路径转换为图片附件
    W->>W: marker 仍存在时恢复 PNG 剪贴板
```

## 7. Client 状态机

```mermaid
stateDiagram-v2
    [*] --> Idle
    Idle --> PassThrough: 文本/非目标窗口
    PassThrough --> Idle
    Idle --> Queued: 图片 Ctrl+V
    Queued --> Encoding
    Encoding --> Uploading
    Uploading --> Reconnecting: SSH 失败且可重试
    Reconnecting --> Uploading
    Uploading --> Guarding: 收到远端路径
    Guarding --> Cancelled: 焦点/输入/剪贴板变化
    Guarding --> Pasting: 校验通过
    Pasting --> Restoring
    Restoring --> Idle
    Cancelled --> Idle
    Uploading --> Failed: 超时或重试失败
    Failed --> Idle
```

## 8. 二进制协议

### 8.1 请求帧

```text
4 bytes  magic       "OCB1"
8 bytes  request_id  big-endian u64
4 bytes  png_length  big-endian u32
N bytes  png_data
```

### 8.2 响应帧

```text
4 bytes  magic          "OCR1"
8 bytes  request_id     big-endian u64
1 byte   status         0=success, 1=error
4 bytes  message_length big-endian u32
N bytes  UTF-8 path or error
```

协议上限：图片 16 MiB，响应消息 64 KiB。当前协议没有协商过程；任何破坏兼容性的修改都必须升级 magic/version 并保留清晰错误。

## 9. 剪贴板与焦点安全

### 9.1 条件拦截

只有以下条件全部成立时才吞掉 `Ctrl+V`：

- 前台窗口 class 为配置的 Windows Terminal class；
- 剪贴板没有 `CF_UNICODETEXT`；
- 剪贴板提供注册格式 PNG 或 `CF_DIBV5`；
- 有界队列能够接受请求。

混合文本与图片的剪贴板优先保留文本语义。

### 9.2 防误粘贴

请求记录触发时的顶层 HWND、clipboard sequence 和用户活动代次。实现监控到的非拦截 key-down 和指定鼠标点击/滚轮事件会推进活动代次，因此即使 Windows Terminal 内部切换 Tab 或 Herdr pane、顶层 HWND 没变，最终检查仍会取消粘贴。没有输入事件的程序化切换不在该保证范围内。

### 9.3 原子剪贴板替换

路径写入在持有 Win32 clipboard lock 时再次核对 sequence。临时剪贴板同时写入路径和包含进程 ID、请求计数的 marker；恢复时只有 marker 内容仍与本次请求完全一致才会清空并写回 PNG。正常复制操作会替换 marker，因此恢复逻辑不会覆盖新内容；保留全部私有格式的特殊剪贴板管理器仍属于待验证边界。

## 10. SSH 生命周期

```mermaid
flowchart TD
    Start[首次图片请求] --> Spawn[启动 ssh -T]
    Spawn --> Auth{非交互认证成功?}
    Auth -->|否| Retry[短暂等待后重试一次]
    Auth -->|是| Send[写请求帧]
    Send --> Watchdog[请求 watchdog]
    Watchdog --> Response{期限内收到响应?}
    Response -->|是| Reuse[保留连接供后续请求复用]
    Response -->|否| Kill[通过 Win32 尽力终止 ssh 进程]
    Kill --> Retry
    Retry --> Spawn
```

客户端强制启用 `BatchMode=yes`，要求使用 SSH key 或 `ssh-agent`。Windows client 使用 `CREATE_NO_WINDOW` 启动 OpenSSH 子进程，避免无窗口 client 首次粘贴时由 `ssh.exe` 创建控制台并抢走前台焦点。连接、写入或响应失败时，当前请求最多重连并重传一次；第二次失败后结束当前请求，下一次图片粘贴再建立新连接。OpenSSH 负责加密、主机密钥校验和身份认证；本工具不实现自有加密或凭据存储。

## 11. 威胁模型

| 风险 | 控制措施 |
|---|---|
| 恶意或损坏的长度字段 | 分配前校验 16 MiB/64 KiB 上限 |
| 非图片 payload | Receiver 校验 PNG 签名 |
| 路径覆盖或符号链接攻击 | 私有目录、随机文件名、`create_new` |
| 临时图片泄露 | `0700` 目录、`0600` 文件、每小时清理超过 24 小时的匹配文件 |
| 上传后切换目标导致误注入 | HWND、活动代次、剪贴板 sequence 三重检查 |
| 覆盖用户新剪贴板 | 请求级 marker 完全匹配时才恢复 |
| SSH 半连接或 receiver 卡死 | OpenSSH keepalive、连接超时、请求 watchdog |
| shell 注入 | 图片走二进制 stdin，不进入 shell 参数；远端命令来自本地配置 |

## 12. 已知限制

- Windows client 当前只支持 Windows Terminal 的窗口 class，可通过配置覆盖，但其他终端未验证。
- 图片检测与读取支持注册格式 PNG 和 `CF_DIBV5`；只发布传统 `CF_DIB`/`CF_BITMAP` 的应用不会触发桥接。
- 同时包含文本与图片格式时优先文本，避免破坏原文本 `Ctrl+V`。
- Windows client 通过 Windows GUI subsystem 以无窗口后台进程运行，不显示控制台或任务栏窗口，当前没有托盘菜单和图形化状态页；进程仍会正常显示在 Windows 任务管理器中。
- 自动粘贴依赖目标 Terminal 与 client 处于相同完整性级别；提权 Terminal 可能拒绝输入注入。
- Linux receiver 已自动化测试；真实 Windows 输入、剪贴板和 Windows Terminal 行为仍需在发布前执行手工兼容性矩阵。
- Watchdog 通过 Win32 `TerminateProcess` 尽力中止超时 SSH；操作系统拒绝进程访问时无法形成严格超时保证。
- 临时文件按小时扫描，通常在产生后 24～25 小时删除；只按 `clipboard-*.png` 命名范围清理。

## 13. 验证策略

### 13.1 自动验证

```bash
cargo fmt --check
cargo clippy --all-targets -- -D warnings
cargo test --locked
cargo check --tests --target x86_64-pc-windows-msvc
cargo xwin build --release --target x86_64-pc-windows-msvc
```

### 13.2 Windows 手工矩阵

至少覆盖：

- 纯文本 `Ctrl+V`；
- `Win+Shift+S` 截图后图片 `Ctrl+V`；
- 连续粘贴多张图；
- 上传期间键盘切 Tab、Herdr pane；
- 上传期间鼠标点击其他 pane；
- 上传期间复制新文本；
- SSH 首次连接、断线、receiver 退出和请求超时；
- 超过 16 MiB 图片；
- 普通与提权 Windows Terminal；
- OpenCode 使用支持图片输入和不支持图片输入的模型。

## 14. 后续演进

1. 增加 Windows 托盘状态和非阻塞通知。
2. 增加真实 Windows 集成测试和 Windows Terminal 版本矩阵。
3. 评估 `CF_DIB`/`CF_BITMAP` 转换支持。
4. 为协议增加显式能力协商和版本错误。
5. 评估向 Herdr 上游贡献 Windows clipboard image bridge，减少独立工具维护面。
