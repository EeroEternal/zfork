# zfork
zfork - Zig Agent Fork（毫毛分身）是一个极简、轻量、高性能的 AI Agent CLI 管理器。

当前版本：`v0.1.1`

## 特性

- 同时管理多个独立 Agent
- 支持本地 Agent 和远程 Agent
- 支持通过 `zconnector` 桥接不同 LLM 做 CLI 命令补全
- 纯命令行，零第三方依赖
- 面向 Windows、Linux、macOS、Android Termux

## 构建

```bash
zig build
```

运行：

```bash
zig build run -- --help
```

## 命令

```bash
zfork new -n "代码助手" -m gpt-4o -p "你是一个专业的 shell 命令补全助手"
zfork new -n "服务器运维" -m claude-3.7 -H user@192.168.1.100
zfork start 1
zfork list
zfork status
zfork status 1
zfork attach 1
zfork logs 1
zfork logs 1 -f
zfork stop 1
zfork complete "git sta"
zfork complete "docker run" -m gpt-4o
zfork close 1
```

## zconnector 说明

`zfork` 直接链接 `zconnector` 库来完成补全请求，不再依赖外部包装脚本或 stdin 文本协议。

默认行为：

- 通过 `OPENAI_API_KEY` 读取 API Key
- 可选通过 `OPENAI_BASE_URL` 覆盖默认 OpenAI Base URL
- 调用 `zconnector` 的 OpenAI 客户端执行一次 chat completion

当前不会读取 `ZFORK_ZCONNECTOR_CMD`。

## 状态存储

Agent 状态默认保存在：

- macOS / Linux / Termux: `~/.zfork/agents.tsv`
- Windows: `%APPDATA%\\zfork\\agents.tsv`

## 说明

- 本地 Agent 现在通过 PTY 运行，`attach` 时在 TTY 上会切换到 raw mode，以支持更真实的终端交互
- 远程 Agent 现在也通过 PTY 托管本地 `ssh -tt <host>` 会话，`attach` 时同样走原生终端字节流
- 本地和远程 PTY 会话现在都会在 `attach` 期间同步终端窗口大小变化
- `attach` 时可以用 `Ctrl+A` 然后 `D` 安全 detach；如果要把字面量 `Ctrl+A` 发给前台程序，可以按 `Ctrl+A` 两次
- `status <id>` 会输出单个 Agent 的详细信息，包括 pid、socket 路径和 log 路径
- `logs -f` 会持续跟随日志，直到 Agent 退出且没有新的输出
- `complete` 会优先使用命令行传入的 `-m` 和 `-p`
- 如果 `complete` 未指定模型，则默认使用最近一个处于 `open` 状态的 Agent
