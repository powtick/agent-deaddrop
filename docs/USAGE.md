<!-- 本文件必须与 USAGE.en.md 保持语义一致，规则见 ../CLAUDE.md。 -->

# 使用示例

[English](USAGE.en.md) | 简体中文

下面把一段认证问题排查对话的最后两轮，从一个 agent 会话交接到另一个会话。示例回显来自当前 `deaddrop` CLI；Claude Code 与 Codex 可能使用不同的 UI 容器展示 hook 结果。

## 开始前

- 为准备使用的每个 agent 安装 plugin，然后启动新会话。
- 在 Codex 中，新增或变化的 plugin hook 可能需要 review。打开 `/hooks`，检查 Agent Dead Drop 命令并选择 trust；完成确认前，触发指令不会运行。
- 使用会持久化到本地的会话；没有 `transcript_path` 的 Codex 临时会话无法创建 drop。
- 两个会话应位于同一台机器和文件系统。drop 是本地文件，不是网络消息。

## 1. 在会话 A 保存上下文

假设会话 A 已经找到登录请求返回 `401` 的原因，并提出了修复方案。在该 agent 的普通输入框中输入这条触发指令：

```text
>>drop claude-to-codex 2
```

提交前 hook 会在模型看到指令前将其拦截。本示例中保留的每一轮都只有一条 agent 消息，因此 `deaddrop` 会返回下面的结果文本，交给 agent 宿主显示：

```text
dropped as: claude-to-codex  (2)
  2 user / 2 agent turns
```

`claude-to-codex` 是 drop 名字。`2` 表示保留最后两轮用户/agent 对话；省略时保留完整可见对话，使用 `0` 时只保留最后一条 agent 回答。agent 消息的实际数量取决于 transcript；例如 Codex 的 commentary 与 final answer 可能分别计为一条 agent 消息。

[![Claude Code 拦截触发指令并成功创建 drop](assets/claude-code-drop.png)](assets/claude-code-drop.png)

*Claude Code 创建包含最近两轮对话的 drop。触发指令被 `UserPromptSubmit` 拦截，结果只向用户显示，不会调用模型。*

## 2. 在会话 B 列出 drop

在同一项目中打开另一个受支持的 agent 会话，然后输入：

```text
>>pickup
```

下面假设它是最新的 drop，并且由 Claude Code 创建。`deaddrop` 会返回按时间倒序排列的列表，交给 agent 宿主显示：

```text
Available drops. Say which to load, or "pickup <number>":
#    agent         turns  name
1    claude-code   2      claude-to-codex
```

序号是 drop 在当前时间倒序列表中的位置，因此已有 drop 会改变这个数字。`agent` 列表示创建该 drop 的工具；由 Codex 创建的 drop 会显示为 `codex`。

## 3. 取回 drop

按名字或列表中的序号选择：

```text
>>pickup claude-to-codex
# 或
>>pickup 1
```

agent CLI 执行主机上存在受支持的剪贴板工具时，`deaddrop` 会返回：

```text
picked up "claude-to-codex" — paste it into your prompt, add notes, then send.
```

如果没有可用的剪贴板工具，`deaddrop` 会返回一条警告，随后附上完整 drop。较长 hook 结果的具体呈现方式由 agent 宿主决定；请手动复制返回的内容。

通过 SSH 或其他远程方式运行的 CLI 不能直接写入客户端 PC 的剪贴板，即使远端的剪贴板命令执行成功也是如此。此时可强制把完整 drop 放进 hook 回显：

```text
>>pickup claude-to-codex -p
```

`-p` 会覆盖默认剪贴板路径。请从本地终端或客户端 UI 复制返回内容；很长的 hook 回显可能被 agent 宿主折叠或截断。

[![Codex 列出本地 drop，并取回由 Claude Code 创建的 drop](assets/codex-pickup.png)](assets/codex-pickup.png)

*Codex 使用默认剪贴板路径取回由 Claude Code 创建的 drop。列表来自当前本地存储，因此已有条目和序号会因环境而异。*

## 4. 粘贴、补充任务并发送

pickup 指令本身不会向模型发送任何内容。把复制到剪贴板或从回显中手动选取的 Markdown 粘贴到会话 B 的输入框，在末尾补上一条明确指令，再发送组合后的 prompt。例如：

```text
<在这里粘贴复制的 drop>

继续处理这份交接内容。复现 401，验证已有修复方案，
然后在不改变公共 API 的前提下更新回归测试。
```

只有最后这次发送会成为普通模型输入并消耗上下文 token。`>>drop` 与 `>>pickup` 触发指令本身始终留在对话 transcript 之外。

## 5. 检查本地文件（可选）

drop 保存在 `~/.deaddrop` 下对应的项目目录中：

```bash
ls -l ~/.deaddrop/drops/my-project/claude-to-codex.md
```

把 `my-project` 替换为创建 drop 时所在目录的 basename。文件由带版本的 frontmatter 以及后续的 `## User`、`## Agent` 章节组成。它可能包含敏感对话原文和本地路径，分享或同步前应先检查。

## 常用变化

| 目标 | 触发指令 |
| --- | --- |
| 自动命名并保存完整的可见对话 | `>>drop` |
| 把完整的可见对话保存为 `parser-debug` | `>>drop parser-debug` |
| 只保存最后一条 agent 回答 | `>>drop release-handoff 0` |
| 在远程会话的 hook 回显中显示 drop | `>>pickup release-handoff -p` |
| 显示下一页 drop | `>>pickup -n 2` |
| 显示全部 drop | `>>pickup -a` |

完整用法见 README 中的[触发指令速查](../README.md#触发指令速查)与[故障排查](../README.md#故障排查)。
