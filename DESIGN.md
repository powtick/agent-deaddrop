# Agent Dead Drop — 详细设计 v2

> **Dead drops for your coding agents.**
> 在并发的 AI coding agent 会话之间,离线传递"用户输入 + agent 回复"的对话精华(或只传最后一轮结论)。
> 触发是输入框里的哨兵,逻辑全在脚本,**模型全程无感知、零 token**。

命名:GitHub `agent-deaddrop` · CLI 二进制 `deaddrop` · 哨兵 `>>drop`(存)+ `>>pickup`(取) · 正文写法 "Dead Drop"。存下的单个情报文件称为一个 **drop**。

> 决策依据(为什么这么定、竞品调研、外部工具事实、跨平台)见 [ADR.md](ADR.md);接入新 agent 的步骤见 [docs/ADDING-AN-AGENT.md](docs/ADDING-AN-AGENT.md)。

---

## 1. 定位

### 1.1 痛点

同时开多个 agent 会话(常横跨多个 git worktree、多种工具)时,想把某会话的调研过程/结论/执行结果作为上下文交给另一个会话,目前只能手工复制粘贴或重新解释。

### 1.2 核心思路

dead drop(死信箱):情报员 A 把情报放约定位置,B 稍后来取,两人从不见面。对应实现——两个会话互不相知、不直接通信,通过文件系统约定位置(`~/.deaddrop/`)异步交接。无 daemon、无 IPC、无网络、无遥测。

transcript 已在磁盘上,所以 **drop 内容用纯脚本机械抽取:零 token、确定性、可对任意历史会话追溯执行**,不让 LLM 撰写摘要。

**离线是硬要求**:存/取都不应惊动当前 agent。实现方式是"提交前 hook + 输入哨兵"(§5)——用户打 `>>drop` 回车,hook 拦截该输入并执行,**模型这一轮不被触发**。

### 1.3 非目标(v1 不做)

完整执行轨迹转移、跨机器同步、LLM 摘要、SQLite/云端会话格式、**原生 Windows shell(cmd/PowerShell/Git Bash)**、**slash command 式接入**(必触发模型,与"离线"冲突,见 ADR-003)。Windows 仅经 **WSL2** 支持(真 Linux,与 mac/linux 一致,见 §9、ADR-002)。

---

## 2. 总体架构

```
┌─ 任意 agent 会话(CC / Codex / Gemini / Cursor …)────────────┐
│  用户在输入框打哨兵:  >>drop [名字] [轮数]  /  >>pickup [名字|序号]  │
│  提交前 hook(UserPromptSubmit 式)拿到 stdin JSON payload        │
└───────────────────────────┬──────────────────────────────────┘
                            ▼  command: deaddrop hook-prompt --tool <name>
        ┌──────────────────────────────────────────────────────┐
        │              bin/deaddrop(唯一核心脚本)              │
        │   hook-prompt(哨兵分发)                             │
        │     ├─ drop / pickup / list / rm / doctor            │
        │     └─ adapters/<tool>.sh(+ ~/.deaddrop/adapters.d/*)│
        └──────────────────────┬───────────────────────────────┘
                               ▼  拦截该输入:{"decision":"block","reason":…}
                        模型永不可见,结果只给用户
                               ▼
        ~/.deaddrop/
        ├── drops/<project>/<name>.md   # drop 文件
        └── adapters.d/*.sh             # 用户扩展适配器
```

关键点:**hook payload 直接带 `transcript_path`**,所以 drop 无需任何"当前会话定位"机制(v1 的注册表 + 进程链遍历已删除)。模型参与度:**全程 0**。

---

## 3. 数据设计

### 3.1 drop 文件(格式契约,版本化)

路径 `~/.deaddrop/drops/<project>/<name>.md`(数据独立于代码/扩展目录);`project` = 执行 drop 时 cwd 的 basename;`name` 用户指定或缺省自动生成(§4);禁止 `/` 与空串;重名时旧文件转存 `.bak`。目录 `0700`、文件 `0600`(内容为对话原文,含敏感信息)。根目录可用环境变量 `DEADDROP_DIR` 覆盖。

**写入一律原子替换**:先写同目录 `mktemp` 临时文件,再 `mv` 覆盖——读方永远看到完整文件。无锁;同名并发为 last-writer-wins,前一版已转 `.bak`。

```markdown
---
drop_version: 1
name: claude-code-hbm-resear-full-20260713-030551
source_tool: claude-code
scope: full                       # full | 0 | 1 | 2 …(见 §4 drop 的 turns)
project: wiki
cwd: /Users/town/projects/wiki
session_id: 1b1cef34-...          # 能取到则填
session_file: /Users/.../1b1cef34....jsonl
created: 2026-07-13T03:05:51+08:00
turns_user: 4
turns_agent: 6
---

## User
...

## Agent
...
```

- `scope`:`full`(整段 Q&A)或 `0`/`1`/`2`…(drop 的 turns:0=仅最后一轮 agent 回答,N=最后 N 轮 q+a)。
- `session_file` 是兜底指针:pickup 方需要对话里没有的细节(工具原始输出)时,可去原始 transcript 检索。
- `drop_version` 保证两端版本漂移时可判兼容。
- **pickup 端天然全工具通用**(读 markdown 而已)——任何能读文件的 agent 都能消费 drop。

---

## 4. 核心脚本 `bin/deaddrop`

单文件 POSIX bash(兼容 macOS bash 3.2,可被 zsh 调用),依赖仅 `jq ≥ 1.6` + coreutils。

| 子命令 | 行为 |
|---|---|
| `drop <transcript路径> [name] [turns]` | 适配器 sniff 认领 → extract 抽取;`turns`(纯数字):不填=整段;`0`=仅最后一轮 agent 回答;`N`=最后 N 轮 q+a(一轮=一个 user turn + 其后的 agent turn)。name 缺省 `<adapter>-<标题前10字>-<scope>-<时间戳>`(scope=full 或 turns 数字;标题取适配器 `title`,如 claude-code 读 summary 行,退化用首条用户消息);写 drop 文件;stdout 回显两行:`dropped as: <name> (<scope>)` + 轮次统计。**path 必填**(hook 自动传;手动用给显式路径) |
| `pickup [name\|序号] [--copy] [--all]` | 无参数 → 列**纯按时间倒序、全局编号**的表格(列:`# / agent / turns / name`;默认上限 `DEADDROP_LIST_LIMIT`(20),超出显示"… and N more",`--all` 列全部);`pickup <序号>` 按表格位置选,`pickup <name>` 按名字选(`drops/<当前project>/<name>.md` → 全局 `drops/*/<name>.md`);默认 cat 到 stdout,**`--copy` 送系统剪贴板**供粘贴进输入框;未命中列表 exit 1 |
| `hook-prompt --tool <name>` | **集成入口**(§5):从 stdin 读 hook payload,识别哨兵 `>>drop`/`>>pickup` 则执行并输出 `decision:block`(拦截,模型不可见,结果只给用户);非哨兵 exit 0 无输出(输入照常进模型) |
| `list` | 列出全部 drop:project/name、大小、created、source_tool |
| `rm <name\|project/name>` | 删除;多命中要求 `project/name` 消歧 |
| `doctor` | 自检:jq、剪贴板工具、各适配器加载与 hook 挂载提示、按 `glob` 探测检测到的工具 |

出错一律非零退出 + stderr(**报错文本一律英文**,见 CLAUDE.md 代码风格)。**报错文本会被注入模型上下文,必须写成能指导下一步的话**(如 `no adapter recognizes this transcript format: …`)。

---

## 5. 集成模型:提交前哨兵 hook(唯一接入)

### 5.1 机制

每个 agent 装一个"用户提交前"hook(Claude Code 的 `UserPromptSubmit`、Codex 同名、Gemini User Prompt Event、Cursor `beforeSubmitPrompt`),命令为 `deaddrop hook-prompt --tool <name>`。

1. 用户在输入框打哨兵:`>>drop [名字] [轮数]` 或 `>>pickup [名字|序号]`(`>>` 后可带空格),回车。
2. hook 从 **stdin** 拿 JSON payload,含 `user_prompt`(原文)+ `transcript_path` + `cwd`(字段名非标时由适配器可选 `hook_parse` 映射)。
3. `hook-prompt` 判断:
   - **命中哨兵** → `cd $cwd` → 跑 `drop <transcript_path> …` 或 `pickup … --copy` → 输出 `{"decision":"block","reason":<命令结果>}` → 该输入被**拦截、从 transcript 抹除、模型永不可见**;`reason` **只显示给用户**。
   - **未命中** → `exit 0` 且无输出 → 输入照常进模型(不影响正常使用)。

### 5.2 输出通道(2026-07 核实,务必用对)

| 方式 | 拦截? | 结果去向 |
|---|---|---|
| **exit 0 + `{"decision":"block","reason":…}`** | ✓ | **仅用户**(正解) |
| `systemMessage` 字段 | — | 仅用户 |
| `additionalContext` 字段 | — | **进模型**(不用) |
| exit 2 + stderr | ✓ | stderr **喂给模型**(不用) |

drop 的名字/pickup 的确认走 `reason`;pickup 大内容走**剪贴板**(`--copy`),`reason` 只回一行"已复制,粘贴进输入框加说明再发"。

### 5.3 为什么不用 slash command

slash command 本质是发给模型的 prompt,用户手输也必触发模型响应;`disable-model-invocation` 只挡 Claude 自触发。Claude Code 无"预填输入框不发送"的 composer API。故离线只能靠提交前 hook(详见 ADR-003)。

### 5.4 已知边界

- **pickup 内容进不了输入框**(无 composer API):`--copy` 送剪贴板 + 用户 `Cmd+V` 是最接近的等价。
- subagent 里触发哨兵:hook 的 payload 给的是当前(主)会话 transcript,存主会话——视为合理行为。

---

## 6. 适配器层

### 6.1 契约:每个 agent 一个文件

**适配器只产出规范化中间流**(每行 `{"role":"user|agent","text":"…"}`);渲染、frontmatter、统计、命名由核心层统一做。

```bash
# adapters/claude-code.sh
ADAPTERS="${ADAPTERS:-} claude-code"
claude_code_sniff()   { ... }   # 必需 $1=文件 → exit 0/1:是否本家格式
claude_code_extract() { ... }   # 必需 $1=文件 → stdout: {"role","text"} JSONL
claude_code_title()   { ... }   # 可选 $1=文件 → 短标题(自动命名用)
claude_code_glob()    { ... }   # 可选 → 会话文件 glob(doctor 探测本机)
# 可选 <tool>_hook_parse():stdin=payload → 三行 prompt/transcript/cwd(字段名非标时映射)
```

- **必需仅 `sniff`+`extract`**;`title`/`glob`/`hook_parse` 可选,缺则退化(标题用首条用户消息、doctor 不探测该工具、payload 用标准字段名)。
- **加载防呆**:source 后校验必需函数俱全,缺则该适配器整体禁用 + 明白报错(点名缺哪个),而非运行时 `command not found`。
- **仲裁顺序写死**:先 source `adapters/`(内置)再 `adapters.d/`(用户),`sniff` 首个认领者胜,用户以**同名文件**覆盖内置。
- **免 fork 扩展点**:核心启动额外 source `~/.deaddrop/adapters.d/*.sh`,私有/实验适配器丢入即生效。

分发点:`drop`/`hook-prompt` 依次 sniff 首个认领者抽取;`doctor` 用各 `glob` 探测本机装了哪些工具;`hook-prompt` 用适配器 `hook_parse` 解析 payload,缺则用标准字段。

### 6.2 内置适配器抽取规则(已在本机真实 transcript 上验证)

**claude-code**(`~/.claude/projects/<proj>/<uuid>.jsonl`):

- user:`type=="user"`;content 为 string 直接用,为数组仅取 `text` 块。**丢弃**:`isMeta==true`、tool_result 数组、以 `<command-`/`<local-command`/`<system-reminder` 开头、`Caveat: The messages below` 开头。
- agent:`type=="assistant"`,仅取 content 中 `text` 块(排除 thinking/tool_use)。
- title:取 `type=="summary"` 的 `summary` 行(Claude 会话标题),最后一条。
- 实测:14.6 MB transcript → 33 KB 对话(压缩 99.8%)。

### 6.3 接入新 agent

= `adapters/<tool>.sh` + hook 接线 + fixture + 期望输出。完整 SOP 见 [docs/ADDING-AN-AGENT.md](docs/ADDING-AN-AGENT.md);测试自动遍历 `adapters/`,贡献者无需读核心代码。

---

## 7. 分发与安装

git clone 仓库,install 脚本把 `bin/` + `adapters/` 复制进 `~/.deaddrop/`,并为检测到的 agent 挂 hook(`deaddrop hook-prompt --tool <name>`)。更新 = 先更新代码库,再重跑 install 覆盖。不发 npm 包(见 ADR)。插件 `bin/` 会自动加入 agent 的 Bash 工具 PATH,故插件启用时 `deaddrop` 可直接作裸命令调用。

Claude Code 插件(L3):`.claude-plugin/plugin.json` + `.claude-plugin/marketplace.json` + `hooks/hooks.json`(`UserPromptSubmit` → `hook-prompt --tool claude-code`)。安装:`/plugin marketplace add <repo>` → `/plugin install agent-deaddrop`。

---

## 8. 测试与 CI

- `tests/fixtures/<tool>/sample.jsonl`:脱敏样例,含全部脏数据形态(tool_result、thinking、`<system-reminder`、isMeta、summary);
- `tests/expected/<tool>/sample.jsonl`:期望的规范化流(抽取输出);
- `tests/run.sh`:纯 bash 断言——抽取输出 diff 期望;drop full/turns(0/1/2)/重名转 `.bak`/自动命名;pickup 名字/序号/表格/分页/`--copy`;**hook-prompt 哨兵命中拦截+执行、非哨兵放行**;适配器防呆;自动遍历 `adapters/`;
- CI:GitHub Actions,macos-latest + ubuntu-latest(bash 3.2 兼容靠 macOS runner);shellcheck + shfmt 门禁。

---

## 9. 隐私、安全与跨平台

本地纯文件,无网络、无遥测。drop 内容为对话原文:`0600/0700` 权限;README 明示"若把 `~/.deaddrop` 纳入 git/同步盘,注意其中含对话内容"。hook 只读 stdin JSON,只写自己的数据目录。

**跨平台**:macOS、Linux 一等支持;Windows 仅经 **WSL2**(真 Linux,与 mac/linux 完全一致)。原生 Windows shell 不支持(理由见 ADR-002)。目标环境统一 POSIX,故 `$HOME`、`chmod`、剪贴板(clip.exe on WSL2)等差异很小。

---

## 10. 里程碑

- **M0 骨架**(已完成):`bin/deaddrop` 全子命令、claude-code 适配器、fixtures + 测试绿。
- **M1 Claude 端闭环**(进行中):插件本地安装;`${CLAUDE_PLUGIN_ROOT}` 展开、`UserPromptSubmit` hook 挂载、哨兵拦截真机验证。
- **M2 第二个 agent**:按 SOP 接入 Codex(或其他),验证 `hook_parse` 与跨工具哨兵。
- **M3 发布**:install.sh、README(英文为主+中文)、MIT License、marketplace 上架、GitHub topics。

### 待实测清单

1. ~~`${CLAUDE_PLUGIN_ROOT}` 展开、`!` 预处理~~ **已验证(2026-07)**;
2. **`UserPromptSubmit` hook 真机**:CC 是否以约定 payload 触发、`decision:block` 是否如文档拦截且 `reason` 仅给用户(文档确认,待真机);
3. Codex/Gemini/Cursor 各自 payload 字段与 hook 配置形态(接入时按 SOP 实测);
4. WSL2 端到端(唯一支持的 Windows 环境)。

---

## 11. v2 展望(不进当前范围)

按 tag 检索、名字子串过滤清单、`deaddrop gc --older-than 30d`、`deaddrop sync`(目录 git 化跨机器)、Gemini/Aider 适配器。
