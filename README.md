# zfork
zfork - Zig Agent Fork（毫毛分身）是一个极简、轻量、高性能的 AI Agent CLI 管理器。

当前版本：`v0.1.0`

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
zfork list
zfork attach 1
zfork complete "git sta"
zfork complete "docker run" -m gpt-4o
zfork close 1
```

## zconnector 桥接说明

`zfork` 不硬编码 `zconnector` 的具体参数协议，因为不同安装方式或包装脚本可能不同。

默认行为：

- 直接执行 `zconnector`
- 通过标准输入写入一段纯文本请求：

```text
model=<模型名>
system=<系统提示词>
input=<补全请求>
```

你也可以通过环境变量覆盖桥接命令：

```bash
export ZFORK_ZCONNECTOR_CMD=/path/to/your-zconnector-wrapper
```

你的包装命令需要：

- 从 stdin 读取请求
- 输出最终补全结果到 stdout
- 非 0 退出码表示失败

## 状态存储

Agent 状态默认保存在：

- macOS / Linux / Termux: `~/.zfork/agents.tsv`
- Windows: `%APPDATA%\\zfork\\agents.tsv`

## 说明

- `attach` 本地 Agent 时会打开当前系统默认 shell
- `attach` 远程 Agent 时会执行 `ssh <host>`
- `complete` 会优先使用命令行传入的 `-m` 和 `-p`
- 如果 `complete` 未指定模型，则默认使用最近一个处于 `open` 状态的 Agent
