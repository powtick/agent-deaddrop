<!-- 本文件必须与 README.md 保持语义一致，规则见 CLAUDE.md。 -->

# Agent Dead Drop

**给 coding agent 用的死信箱。**

[English](README.md) | 简体中文

[![CI](https://github.com/powtick/agent-deaddrop/actions/workflows/ci.yml/badge.svg)](https://github.com/powtick/agent-deaddrop/actions/workflows/ci.yml)

Agent Dead Drop 通过本地 Markdown 文件，在并发的 coding agent 会话之间传递有用的对话上下文。在一个会话中输入触发指令，再从另一个会话取走 drop；提交前 hook 会在模型看到输入之前完成操作。

保存和取回 drop 都不会调用模型，也不会消耗模型 token。只有在你把内容粘贴并发送后，接收方模型才会看到这份交接内容，并正常占用上下文 token。

> **项目状态：** 早期预览版。请使用当前版本的 Claude Code 与 Codex；最低支持版本尚未确定，全新安装环境中的端到端验收仍在进行。

## 为什么用 Agent Dead Drop？

- **运行时离线：**没有 daemon、网络请求、云服务或遥测。
- **模型无感知：**`>>drop` 与 `>>pickup` 会在进入 transcript 或触发模型回复前被拦截。
- **确定性抽取：**Bash 与 `jq` 机械过滤已有 transcript，不让 LLM 总结或改写。
- **跨 agent 交接：**内置 Claude Code 和 Codex 适配器产出同一种可读 Markdown 格式。
- **小而可审计：**一个 Bash 核心、每个工具一个适配器，用户侧没有 build 步骤。
- **默认本地：**drop 留在本地文件系统，使用严格的文件权限，并且没有内置同步。

## 工作原理

```text
会话 A：   >>drop auth-debug 2
                      │
                      │ 提交前 hook；触发指令被拦截
                      ▼
        ~/.deaddrop/drops/<project>/auth-debug.md
                      │
                      ▼
会话 B：   >>pickup auth-debug  ──► 执行主机剪贴板 ──► 粘贴、补充说明、发送
```

1. 在会话 A 中，`>>drop` 从 agent 的提交前 hook 获得 transcript 路径，并抽取用户与 agent 之间可见的对话。
2. 核心把带版本的 Markdown drop 原子写入 `~/.deaddrop/`。
3. 在会话 B 中，`>>pickup` 会列出 drop，或把指定 drop 复制到运行 agent CLI 与 hook 的主机剪贴板。远程使用时可加 `-p`，让 drop 显示在 hook 回显中，再从本地终端或客户端 UI 复制。

两条触发指令都在 agent CLI 执行主机上处理，并对模型拦截。普通输入不受影响，照常通过。

## 依赖与支持范围

| 范围 | 支持情况 |
| --- | --- |
| Agent 集成 | Claude Code 与 Codex |
| 操作系统 | macOS、Linux；Windows 的受支持环境是 WSL2 |
| 原生 Windows shell | cmd、PowerShell 和 Git Bash 尚未适配或验证 |
| 运行时 | Bash 3.2+、`jq` 1.6+ 与标准 Unix 命令行工具 |
| 默认 pickup 的剪贴板 | agent CLI 执行主机上的 `pbcopy`、`wl-copy`、`xclip`、`xsel` 或 `clip.exe` |

如果尚未安装 `jq`：

```bash
# macOS
brew install jq

# Debian / Ubuntu / WSL2
sudo apt-get install jq
```

剪贴板工具是可选依赖。没有可用工具时，pickup 会退化为直接打印 drop，而不是复制。剪贴板访问只发生在执行主机：通过 SSH 或其他远程环境运行的 agent CLI 不能直接写入客户端 PC 的剪贴板；此时请使用 `>>pickup NAME -p`。

WSL2 是 Windows 上的受支持路径，因为它提供了 Agent Dead Drop 所面向的同一套 Linux Bash、`jq`、coreutils 与 hook 执行环境。原生 cmd、PowerShell 和 Git Bash 在 hook 执行、路径处理与剪贴板行为上可能不同；项目尚未对它们完成适配或端到端测试，因此不保证兼容性。目前请使用 WSL2。

## 安装、更新与卸载

请从已发布的 `marketplace` 分支安装。`main` 分支只包含 canonical 源码和打包模板，不是可安装的 marketplace 树。下面两组示例都安装到用户级。

### Codex（用户级）

Codex 没有提供 plugin scope 参数。marketplace 与 plugin 状态保存在用户的 `CODEX_HOME` 下（通常是 `~/.codex`）。

**安装**

```bash
codex plugin marketplace add powtick/agent-deaddrop@marketplace
codex plugin add agent-deaddrop@agent-deaddrop
```

安装后启动一个新的、会持久化到本地的会话。

> **Hook review：**Codex 可能提示有新 hook 需要 review。这是预期的安全确认：Agent Dead Drop 会注册一个本地 `UserPromptSubmit` hook，以便在触发指令到达模型前将其拦截。打开 `/hooks`，检查 Agent Dead Drop 命令后选择 trust。完成 trust 前，`>>drop` 与 `>>pickup` 不会运行。Codex 通常会记住信任结果；hook 首次出现或其有效定义发生变化时，可能再次要求 review。

[![Codex 启动时提示新增或变化的 hook 需要 review](docs/assets/codex-hook-review.png)](docs/assets/codex-hook-review.png)

*Codex 启动 review。选择 **Review hooks**，检查 Agent Dead Drop 命令，然后再将其设为 trusted。*

没有持久化 transcript 的临时会话无法执行 drop。

**更新**

```bash
codex plugin marketplace upgrade agent-deaddrop
codex plugin add agent-deaddrop@agent-deaddrop
```

更新后请启动新的 Codex 会话。如果 hook 定义有变化，还需在 `/hooks` 中重新 review/trust。

**卸载**

```bash
codex plugin remove agent-deaddrop@agent-deaddrop
codex plugin marketplace remove agent-deaddrop
```

第二条命令可选，用于同时移除 marketplace 注册。

### Claude Code（用户级）

**安装**

```bash
claude plugin marketplace add --scope user powtick/agent-deaddrop@marketplace
claude plugin install --scope user agent-deaddrop@agent-deaddrop
```

安装后启动新会话，让 hook 被加载。

**更新**

```bash
claude plugin marketplace update agent-deaddrop
claude plugin update --scope user agent-deaddrop@agent-deaddrop
```

更新后启动新会话，让更新后的 hook 被加载。

**卸载**

```bash
claude plugin uninstall --scope user agent-deaddrop@agent-deaddrop
claude plugin marketplace remove --scope user agent-deaddrop
```

第二条命令可选，用于同时移除用户级 marketplace 注册。

如果仓库是 private，安装机器必须已经具备对应的 GitHub 读取权限。plugin 只会把一份内部 `deaddrop` 副本放进对应 agent 的 plugin 中，**不会**在你的 shell 中安装全局 `deaddrop` 命令。

卸载任一 plugin 都不会删除 `~/.deaddrop`。如果不再需要已保存的对话，请另行检查并删除其中的 `.md` 与 `.bak` 文件。

## 快速开始

在含有有用上下文的会话中，用一个好记的名字保存最后两轮用户/agent 对话：

```text
>>drop auth-debug 2
```

hook 不调用模型，直接确认 drop 名字、范围以及抽取出的用户/agent 消息数。

在另一个会话中列出可用的 drop：

```text
>>pickup
```

再按名字或列表中的序号取回：

```text
>>pickup auth-debug
# 或
>>pickup 1
```

默认情况下，drop 会被复制到 agent CLI 执行主机的剪贴板；没有可用剪贴板工具时则直接打印。如果 CLI 运行在远端，可强制把完整 drop 放进 hook 回显：

```text
>>pickup auth-debug -p
```

从本地终端或客户端 UI 复制返回的 Markdown，把它粘贴到输入框，补上任务或注意事项，然后发送。最终发出的 prompt 是普通模型输入，会像往常一样占用上下文 token。

完整的双会话流程（包括 hook 回显和最终粘贴的 prompt）见[使用示例](docs/USAGE.zh-CN.md)。

## 触发指令速查

| 触发指令 | 结果 |
| --- | --- |
| `>>drop` | 自动命名并保存完整的可见对话。 |
| `>>drop NAME` | 把完整的可见对话保存为 `NAME`。 |
| `>>drop NAME 0` | 只保存最后一条 agent 回答。 |
| `>>drop NAME N` | 保存最后 `N` 轮用户/agent 对话。 |
| `>>pickup` | 按时间倒序显示带编号的 drop 列表。 |
| `>>pickup NAME` | 尝试把指定名字的 drop 复制到 agent CLI 执行主机的剪贴板；剪贴板不可用时改为在 hook 中回显。 |
| `>>pickup NUMBER` | 对列表中对应序号的 drop 执行同样操作。 |
| `>>pickup NAME -p` | 不使用剪贴板，直接在 hook 回显中显示完整 drop；适合远程会话。也可用列表序号代替 `NAME`。 |
| `>>pickup -n N` | 显示 drop 列表的第 `N` 页。 |
| `>>pickup -a` | 显示全部 drop。 |

`>>` 后的空格可有可无，所以 `>> drop` 也能工作。名字必须是单个字符串，不能是纯数字、包含 `/` 或以 `-` 开头。

## Drop 中有什么

drop 是经过过滤的对话文本，不是 AI 生成的摘要，也不是完整执行轨迹。

包含：

- 对话中可见的用户消息；
- 用户可见的 agent 回复文本，包括 Codex 的 commentary 与 final answer；
- 含格式版本、来源工具、范围、项目、时间、轮次统计与源会话指针的 frontmatter。

内置适配器会排除以下已识别记录：

- reasoning/thinking 块；
- 工具调用及工具结果；
- system/developer 注入与元数据；
- agent 间事件和重复的底层记录。

这种过滤不是秘密扫描或脱敏。分享或同步 drop 前仍须人工检查。

默认路径是 `~/.deaddrop/drops/<project>/<name>.md`。可以用 `DEADDROP_DIR` 移动数据根目录。复用同一个名字时，旧 drop 会先被移动为 `<name>.md.bak`，再写入新文件。

## 高级 CLI 用法

打包后的 hook 会在内部调用 CLI。在源码 checkout 中，可以直接运行：

```bash
bin/deaddrop help
bin/deaddrop doctor
bin/deaddrop drop /path/to/transcript.jsonl handoff 1
bin/deaddrop pickup handoff -c
bin/deaddrop pickup handoff -p
bin/deaddrop list
bin/deaddrop rm handoff
```

手动执行 `drop` 时必须显式传入 transcript 路径，因为平时是提交前 hook 提供这个路径。

## 隐私与安全

- 运行时的 drop/pickup 操作只在 agent CLI 执行主机上进行，不发起网络请求。
- 在支持的平台上，数据目录使用 `0700`；drop 文件使用 `0600`，并通过同目录临时文件加原子替换写入。
- drop 含有原始对话文本，以及 `cwd`、`session_file` 等本机元数据，**没有加密**。
- 存在受支持的剪贴板工具时，默认 pickup 会把所选内容放进 agent CLI 执行主机的剪贴板；使用 `-p` 时则保留在仅用户可见的 hook 回显中。
- 复用名字会在 `.bak` 文件中保留上一版内容。

> **敏感数据提醒：**除非你明确希望其中的对话和本地路径离开当前机器，否则不要把 `~/.deaddrop` 加进 Git 或同步盘。不再需要时，请同时检查并删除 `.md` 和 `.bak` 文件。

## 已知限制

- 交接目前依赖共享的本地文件系统；跨机器同步不在当前范围内。
- Agent 的输入框 API 无法只预填而不发送，因此 pickup 会使用执行主机剪贴板或仅用户可见的 hook 回显，之后仍需用户手动粘贴。
- 远程运行的 agent CLI 不能直接写入客户端 PC 的剪贴板。请使用 `>>pickup NAME -p`；很长的 hook 回显可能被 agent 宿主折叠或截断。
- 没有持久化 `transcript_path` 的 Codex 临时会话无法执行 drop。
- 原生 cmd、PowerShell 和 Git Bash 尚未适配或验证；请使用受支持的 WSL2 环境。
- 内置集成目前只有 Claude Code 与 Codex。其他工具需要适配器和各自独立的提交前 hook packaging。

## 故障排查

| 现象 | 处理方式 |
| --- | --- |
| 触发指令到达了模型 | 确认 plugin 已启用，启动新会话，并在 Codex `/hooks` 中 review/trust。 |
| 提示 `jq not found` | 安装 `jq` 1.6 或更新版本后重试。 |
| 没有可用的 transcript 路径 | 改用会持久化到本地的会话，不要使用临时会话。 |
| pickup 提示剪贴板不可用 | Linux 安装 `wl-clipboard`、`xclip` 或 `xsel`；macOS 自带 `pbcopy`，WSL2 通常自带 `clip.exe`。 |
| 远程 pickup 提示成功，但客户端 PC 剪贴板没有变化 | 剪贴板属于 agent CLI 执行主机。改用 `>>pickup NAME -p`，再从本地终端或客户端 UI 复制回显内容。 |
| 终端提示 `deaddrop: command not found` | plugin 安装后这是预期行为；请使用触发指令，或在源码 checkout 中运行 `bin/deaddrop`。 |

要从源码 checkout 做更全面的本机诊断，运行 `bin/deaddrop doctor`。

## 开发与扩展

修改行为前先读 [DESIGN.md](DESIGN.md)。决策与外部调研见 [ADR.md](ADR.md)，[接入新 agent](docs/ADDING-AN-AGENT.md) 是适配器与 packaging 的完整指南。报告问题时，请[创建 issue](https://github.com/powtick/agent-deaddrop/issues)，并附上 agent 版本、操作系统和观察到的 hook 结果。

唯一完整测试闸门是：

```bash
tests/run.sh
```

提交 shell 或 workflow 变更前还应运行：

```bash
shellcheck bin/deaddrop adapters/*.sh scripts/*.sh tests/run.sh
shfmt -d bin/deaddrop adapters/*.sh scripts/*.sh tests/run.sh
actionlint
```

无需 fork 也能添加私有或实验适配器：把 `<tool>.sh` 放进 `~/.deaddrop/adapters.d/`。可分发的集成还需要 fixture、期望抽取输出、隔离的 plugin manifest/hook，以及指南中描述的 marketplace entry。
