# 纯 CLI 多 Agent 管理器架构设计 (zfork)

## 1. 目标 (Objective)
将 `zfork` 打造成一个极简、高性能的 **纯 CLI** 多 Agent 管理器。它不需要复杂的 TUI，而是提供类似 `tmux` 或 `docker` 核心容器管理的体验。目标是能够**在后台持续运行 Agent**、**实时跟踪状态**、并且随时可以 **挂载 (attach) 和分离 (detach)** 到 Agent 的输入输出流中。

## 2. 核心架构：Daemonless + PTY + UDS
为了保证极简和零第三方依赖，我们采用 **无中心守护进程 (Daemonless)** 架构，利用 **PTY (伪终端)** 欺骗 Agent 让它认为自己在真实终端中，并使用 **Unix Domain Socket (UDS)** 进行分离/挂载的通信。

### 2.1 进程与 I/O 模型
1. **启动 (Start)**: CLI 执行一次 "Double Fork" 将目标 Agent 放到后台执行。
2. **PTY 隔离**: 后台的 Wrapper 进程会分配一个伪终端 (PTY master/slave)。Agent 进程连接到 PTY slave。
3. **IPC 中继**: Wrapper 进程监听一个 Unix Socket。当有客户端连入时，它会将 PTY master 的数据桥接到 Socket。
4. **日志记录**: 所有进出 PTY 的数据同时被 tee (分流) 到一个专门的 Agent 日志文件中。

### 2.2 状态追踪 (State Management)
扩展现有的状态存储 (目前是 `agents.tsv`)，新增以下关键字段以实现状态跟踪：
- `pid`: 记录后台 Wrapper 的进程 ID。
- `socket_path`: 用于 `attach` 的 IPC 通信路径 (如 `~/.zfork/run/agent-1.sock`)。
- `log_path`: 持久化日志文件的路径。
- `run_status`: 通过探测系统 PID (`kill -0 <pid>`) 实时判断的真实状态 (Running, Stopped, Errored)。

## 3. CLI 命令规范与行为

| 命令 | 行为描述 |
| :--- | :--- |
| `zfork start <id>` | 后台启动 Agent，分配 PTY 与 Socket，更新 PID 到状态文件。 |
| `zfork stop <id>` | 读取 PID，向后台进程发送 `SIGTERM`，清理 Socket 文件，标记为停止。 |
| `zfork list` / `status` | 读取状态文件，实时探测每个 PID 是否存活，打印出精简的状态列表。 |
| `zfork status <id>` | 输出单个 Agent 的详细状态，包括 PID、运行态、Socket 路径和日志路径。 |
| `zfork attach <id>` | 将当前终端设为 Raw 模式，通过 UDS 连接到正在运行的 Agent。提供特殊的快捷键 (例如 `Ctrl+A, D`) 用于安全 Detach 退出。 |
| `zfork logs <id> [-f]` | 读取该 Agent 的本地历史输出日志，支持 `-f` 实时追踪 (类似 `tail -f`)。 |

## 4. 演进路线图 (Implementation Phases)

### 阶段一：生命周期管理 (PID & Logs)
- 修改 `types.zig` 和持久化逻辑，支持保存 `pid` 和 `log_path`。
- 实现 `start` 命令：后台生成子进程，并将 stdout/stderr 重定向到日志文件。
- 实现 `stop` 命令：根据 `pid` 优雅终止进程。
- 增强 `list` 命令：动态检查 PID 存活情况。

### 阶段二：I/O 挂载机制 (Attach & Detach)
- 引入基础的 Unix Socket 监听器，作为后台 Agent 的 I/O 桥梁。
- 实现 `attach` 命令：读取 Socket 路径并建立全双工字节流转发。
- **暂不使用 PTY**：仅转发标准的 stdin/stdout，验证挂载/分离机制的可靠性。

### 阶段三：原生终端体验 (PTY 集成)
- 在启动流程中加入 PTY 分配（调用底层 libc 或 Zig 的 `std.posix.openpty`）。
- 确保 `attach` 时，Agent 能正确处理 ANSI 颜色代码和交互式 prompt (例如 Python REPL 或 Vim 等)。

当前实现状态补充：
- 本地 Agent 已切换到 PTY + Raw Mode 路径。
- 远程 Agent 也已切换到 PTY 托管的本地 `ssh -tt` 控制会话。
- 本地和远程 Agent 在 `attach` 期间都会同步当前终端的窗口大小变化。
- `attach` 已支持 `Ctrl+A, D` 安全 detach；如需发送字面量 `Ctrl+A`，可按 `Ctrl+A, Ctrl+A`。

---
**附注 (关于远程 Agent)**:
对于远端主机 (Remote Agent)，`start` 实际上是后台启动一个持久化的 `ssh` 进程。`attach` 同样是连接到管理这个 SSH 进程的本地 UDS 桥接器。架构无需变动。