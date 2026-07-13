# Agent Dead Drop — 详细设计 v2

> **Dead drops for your coding agents.**
> 在并发的 AI coding agent 会话之间,离线传递"用户输入 + agent 回复"的对话精华(或只传最后一轮结论)。
> 触发是输入框里的哨兵,逻辑全在脚本,**哨兵执行与机械抽取阶段模型无感知、零模型调用**;pickup 内容经用户粘贴并发送后是普通模型上下文。

命名:GitHub `agent-deaddrop` · CLI 二进制 `deaddrop` · 哨兵 `>>drop`(存)+ `>>pickup`(取) · 正文写法 "Dead Drop"。存下的单个情报文件称为一个 **drop**。

> 决策依据(为什么这么定、竞品调研、外部工具事实、跨平台)见 [ADR.md](ADR.md);接入新 agent 的步骤见 [docs/ADDING-AN-AGENT.md](docs/ADDING-AN-AGENT.md)。

---

## 1. 定位

### 1.1 痛点

同时开多个 agent 会话(常横跨多个 git worktree、多种工具)时,想把某会话的调研过程/结论/执行结果作为上下文交给另一个会话,目前只能手工复制粘贴或重新解释。

### 1.2 核心思路

dead drop(死信箱):情报员 A 把情报放约定位置,B 稍后来取,两人从不见面。对应实现——两个会话互不相知、不直接通信,通过文件系统约定位置(`~/.deaddrop/`)异步交接。无 daemon、无 IPC、无网络、无遥测。

transcript 已在磁盘上,所以 **drop 内容用纯脚本机械抽取:抽取阶段零模型调用、确定性、可对任意历史会话追溯执行**,不让 LLM 撰写摘要。

**离线是硬要求**:存/取都不应惊动当前 agent。实现方式是"提交前 hook + 输入哨兵"(§5)——用户打 `>>drop` 回车,hook 拦截该输入并执行,**模型这一轮不被触发**。

### 1.3 非目标(v1 不做)

完整执行轨迹转移、跨机器同步、LLM 摘要、SQLite/云端会话格式、**原生 Windows shell(cmd/PowerShell/Git Bash)的正式适配与兼容承诺**、**slash command 式接入**(必触发模型,与"离线"冲突,见 ADR-003)。Windows 的受支持路径是 **WSL2**(真 Linux,与 mac/linux 一致,见 §9、ADR-002);原生 shell 尚未适配或验证,当前不保证兼容。

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

关键点:**hook payload 直接带 `transcript_path`**,所以 drop 无需任何"当前会话定位"机制(v1 的注册表 + 进程链遍历已删除)。哨兵 drop/pickup 的执行阶段模型参与度为 0;用户粘贴并发送 drop 后按普通上下文处理。

---

## 3. 数据设计

### 3.1 drop 文件(格式契约,版本化)

路径 `~/.deaddrop/drops/<project>/<name>.md`(数据独立于代码/扩展目录);`project` = 执行 drop 时 cwd 的 basename;`name` 用户指定或缺省自动生成(§4),禁止 `/`、空串、纯数字与 `-` 前缀(避免与 pickup 选项冲突);重名时旧文件转存 `.bak`。目录 `0700`、文件 `0600`(内容为对话原文,含敏感信息)。根目录可用环境变量 `DEADDROP_DIR` 覆盖。

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
| `drop <transcript路径> [name] [turns]` | 适配器 sniff 认领 → extract 抽取;`turns`(纯数字):不填=整段;`0`=仅最后一轮 agent 回答;`N`=最后 N 轮 q+a(一轮=一个 user turn + 其后的 agent turn)。name 缺省 `<adapter>-<标题前10字>-<scope>-<时间戳>`(scope=full 或 turns 数字;标题取适配器 `title`,如 claude-code 读 summary 行,退化用首条用户消息;标题 slug 保留 UTF-8/CJK,ASCII 标点一律折叠为 `-`——名字要落成文件名,`:` `*` `?` 等会破坏 NTFS/WSL 挂载、scp `host:path` 解析与 Finder,标题全为标点时退化为无 slug 命名);写 drop 文件;stdout 回显两行:`dropped as: <name> (<scope>)` + 轮次统计。**path 必填**(hook 自动传;手动用给显式路径) |
| `pickup [name\|序号] [-c\|--copy] [-p\|--print] [-a\|--all] [-n N\|--page N]` | 无参数 → 列**纯按时间倒序、全局编号**的表格(列:`# / agent / turns / name`;每页默认 `DEADDROP_LIST_LIMIT`(20)条,超出时显示页码/总数/下一页提示,`-n N` 翻页,`-a` 列全部);`pickup <序号>` 按表格的全局位置选,`pickup <name>` 按名字选(`drops/<当前project>/<name>.md` → 全局 `drops/*/<name>.md`);默认 cat 到 stdout,`-c`/`--copy` 送到 **CLI/hook 执行主机**的剪贴板,缺工具则打印;显式 `-p`/`--print` 强制 stdout 并始终覆盖 copy,供 SSH/远程 CLI 通过 hook `reason` 回显完整 drop;长选项保留作兼容别名;未命中列表 exit 1 |
| `hook-prompt --tool <name>` | **集成入口**(§5):从 stdin 读 hook payload,识别哨兵 `>>drop`/`>>pickup` 则执行并输出 `decision:block`(拦截,模型不可见,结果只给用户);非哨兵 exit 0 无输出(输入照常进模型) |
| `list` | 列出全部 drop:project/name、大小、created、source_tool |
| `rm <name\|project/name>` | 删除;多命中要求 `project/name` 消歧 |
| `doctor` | 自检:jq、剪贴板工具、各适配器加载与 hook 挂载提示、按 `glob` 探测检测到的工具 |

出错一律非零退出 + stderr(**报错文本一律英文**,见 CLAUDE.md 代码风格)。**报错文本会被注入模型上下文,必须写成能指导下一步的话**(如 `no adapter recognizes this transcript format: …`)。

---

## 5. 集成模型:提交前哨兵 hook(唯一接入)

### 5.1 机制

每个 agent 装一个"用户提交前"hook(Claude Code 的 `UserPromptSubmit`、Codex 同名、Gemini User Prompt Event、Cursor `beforeSubmitPrompt`),命令为 `deaddrop hook-prompt --tool <name>`。

1. 用户在输入框打哨兵:`>>drop [名字] [轮数]` 或 `>>pickup [名字|序号] [-p]`(`>>` 后可带空格),回车。
2. hook 从 **stdin** 拿 JSON payload,含 prompt 原文 + `transcript_path` + `cwd`:Claude Code 用 `user_prompt`,Codex 用 `prompt`;字段名非标时由适配器可选 `hook_parse` 映射。
3. `hook-prompt` 判断:
   - **命中哨兵** → `cd $cwd` → 跑 `drop <transcript_path> …` 或默认 `pickup … --copy` → 输出 `{"decision":"block","reason":<命令结果>}` → 该输入被**拦截、从 transcript 抹除、模型永不可见**;`reason` **只显示给用户**。若 pickup 参数含 `-p`/`--print`,强制打印优先于 hook 内部追加的 copy 选项,完整 drop 进入 `reason`。
   - **未命中** → `exit 0` 且无输出 → 输入照常进模型(不影响正常使用)。

Codex 0.144.1 的 `UserPromptSubmit` 在记录本轮 user message 和模型 sampling **之前**运行;block 后两步都跳过,所以哨兵不进 rollout、也不触发模型。该事件不支持 matcher(配置了也忽略),筛选必须留在 `hook-prompt`;hooks 当前默认开启,`features.codex_hooks` 只是已弃用别名。非 managed hook 首次安装或定义变更后,用户需在 Codex `/hooks` 中 review/trust。

### 5.2 输出通道(2026-07 核实,务必用对)

| 方式 | 拦截? | 结果去向 |
|---|---|---|
| **exit 0 + `{"decision":"block","reason":…}`** | ✓ | **仅用户**(正解) |
| `systemMessage` 字段 | — | 仅用户 |
| `additionalContext` 字段 | — | **进模型**(不用) |
| exit 2 + stderr | ✓ | 工具间语义不一致;Claude 会进模型上下文,**统一不用** |

drop 的名字/pickup 的确认走 `reason`;有剪贴板工具时,pickup 大内容默认走 **执行主机剪贴板**(`-c`/`--copy`),`reason` 只回一行"已复制,粘贴进输入框加说明再发";缺工具或显式 `-p` 时,完整 drop 通过 `reason` 显示给用户。`-p` 是 sticky override,不受内部 copy 选项参数顺序影响。

### 5.3 为什么不用 slash command

slash command 本质是发给模型的 prompt,用户手输也必触发模型响应;`disable-model-invocation` 只挡 Claude 自触发。Claude Code 无"预填输入框不发送"的 composer API。故离线只能靠提交前 hook(详见 ADR-003)。

### 5.4 已知边界

- **pickup 内容进不了输入框**(无 composer API):`-c`/`--copy` 送剪贴板 + 用户 `Cmd+V` 是最接近的等价。
- **远程剪贴板不透传**:通过 SSH/远程环境运行时,剪贴板工具只操作 CLI/hook 执行主机,不能直接写客户端 PC。用户用 `>>pickup NAME -p` 把完整 drop 放进仅用户可见的 hook 回显,再从本地终端/UI 复制;超长回显可能被宿主折叠或截断。
- Codex 的 `transcript_path` 类型是 `string|null`;无持久化 transcript 的临时会话不能 drop,错误需引导用户改用持久化本地会话或显式路径。
- subagent 里触发哨兵时按该工具 payload 指向的当前 transcript 存储;Codex payload 还可能带 `agent_id`/`agent_type`。

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

**codex**(`~/.codex/sessions/Y/M/D/rollout-<ts>-<uuid>.jsonl`;doctor 探测固定用 `~/.codex`,不读 `CODEX_HOME`——实际抽取的 transcript 路径由 hook payload 直接传入,不依赖该 glob):

- 只读 `type=="event_msg"` 的语义事件;user 取 `payload.type=="user_message"` 的 `message`,agent 取 `payload.type=="agent_message"` 的非空 `message`。
- agent 的 `phase=="commentary"`、`phase=="final_answer"` 与缺失/null phase 都保留:前两者都是用户可见文本,缺失/null 是旧 provider 的兼容路径;显式未知 phase 不猜测。
- **丢弃**全部 `response_item`(同一消息会重复,且混有 AGENTS/environment/developer 注入)、reasoning、tool call/result、系统/开发者上下文与 inter-agent 事件。
- `session_id` 取首条 `session_meta.payload.session_id`,旧格式回退 `session_meta.payload.id`;rollout 是内部格式,官方不承诺稳定,必须靠 fixture 锁定兼容行为。

### 6.3 接入新 agent

= canonical `adapters/<tool>.sh` + `packaging/plugins/<tool>/` 下本平台独立的 manifest/hook 模板 + marketplace catalog entry + fixture/期望输出。`scripts/package-plugins.sh` 在临时目录物化自包含的 `plugins/<tool>/`,注入根 `VERSION`,并复制真实 `bin/deaddrop` 与本工具 adapter。完整 SOP 见 [docs/ADDING-AN-AGENT.md](docs/ADDING-AN-AGENT.md);测试自动遍历 `adapters/`,贡献者无需读核心代码。

---

## 7. 分发与安装

裸 CLI 安装脚本仍在规划中,当前只支持从源码 checkout 直接运行 `bin/deaddrop`(手动 drop 需显式 transcript 路径);不发 npm 包(见 ADR)。面向用户的集成走下述已发布 agent plugin。

agent plugin 采用**源码与发布树分离**:

- `main` 只维护一个 `VERSION`、canonical `bin/deaddrop`、`adapters/*.sh` 以及 `packaging/` 下按 agent 隔离的 manifest/hook/catalog 模板;不提交重复的 bin/adapter payload。
- `scripts/package-plugins.sh <out>` 将模板复制到生成树,把 `VERSION` 注入每个 manifest,再把 canonical bin 与本平台 adapter 复制为真文件。生成包必须无 symlink、可离开源码仓库独立运行。
- tag 发布 workflow 把生成树写到独立的 `marketplace` orphan 分支:首个 commit 与 `main` 无共同历史,以后只做非 force 的线性追加。该分支根含 `.claude-plugin/marketplace.json`、`.agents/plugins/marketplace.json`、`VERSION` 与 `plugins/<tool>/`;不含测试、脚本或 canonical 开发树。

发布树中每个平台仍是一个**独立、自包含 plugin root**;hook 不共享,也不在运行时猜 agent:

- `plugins/claude-code/`:`.claude-plugin/plugin.json` + `hooks/hooks.json` + `bin/deaddrop` + `adapters/claude-code.sh`;hook 用 `${CLAUDE_PLUGIN_ROOT}` 定位并固定 `--tool claude-code`。
- `plugins/codex/`:`.codex-plugin/plugin.json` + `hooks/hooks.json` + `bin/deaddrop` + `adapters/codex.sh`;hook 用 `${PLUGIN_ROOT}` 定位并固定 `--tool codex`。

用户安装拿到的始终是现成自包含 payload,**没有用户侧 build**。从远程安装时必须显式选择发布分支(`main` 不是 marketplace);当前两端均按用户级安装:

```bash
# Codex(无 scope 参数;写入用户 CODEX_HOME)
codex plugin marketplace add powtick/agent-deaddrop@marketplace
codex plugin add agent-deaddrop@agent-deaddrop

# Claude Code(显式用户级)
claude plugin marketplace add --scope user powtick/agent-deaddrop@marketplace
claude plugin install --scope user agent-deaddrop@agent-deaddrop
```

用户级更新与卸载命令:

```bash
# Codex 更新:刷新 Git marketplace 快照,再重新 add 以安装新版本
codex plugin marketplace upgrade agent-deaddrop
codex plugin add agent-deaddrop@agent-deaddrop

# Codex 卸载:先删 plugin;不再使用该源时再删 marketplace 注册
codex plugin remove agent-deaddrop@agent-deaddrop
codex plugin marketplace remove agent-deaddrop

# Claude Code 更新:刷新 marketplace 后更新用户级 plugin
claude plugin marketplace update agent-deaddrop
claude plugin update --scope user agent-deaddrop@agent-deaddrop

# Claude Code 卸载:先删用户级 plugin;不再使用该源时再删用户级 marketplace 注册
claude plugin uninstall --scope user agent-deaddrop@agent-deaddrop
claude plugin marketplace remove --scope user agent-deaddrop
```

更新后须新开会话以加载更新后的 hook。plugin/marketplace 卸载都不删除 `~/.deaddrop` 数据;不再需要时应另行检查并删除 `.md`/`.bak`。

Codex CLI 当前没有 plugin scope 选项,marketplace/plugin 状态写入用户的 `CODEX_HOME`(通常 `~/.codex`);Claude Code 用 `--scope user` 显式选择用户级。仓库为 private 时,安装机器须先具备该 GitHub 仓库的认证读取权限。Codex 对普通 plugin 的新增或有效定义发生变化的 hook 要求安全 review:用户须在新会话用 `/hooks` 检查并 trust,否则 hook 不运行;信任结果通常持久保留,但定义变化后可能重新要求 review。普通 plugin 不能静默预信任自己,文档不引导用户使用全局绕过 hook trust 的危险启动参数。plugin 安装不等于给用户终端全局安装 `deaddrop`;当前裸 CLI 只能从源码 checkout 运行。

根 `VERSION` 是所有 plugin manifest 的唯一版本源,首发为 `0.0.1`;不手改模板 manifest 版本。版本未打 tag 前可在同一发布候选上继续修复;一旦存在 `v<VERSION>` tag,canonical bin、任一 adapter、manifest/hook/catalog 模板或打包逻辑再变化就必须显式 bump 全局 `VERSION`,所以两包一起升版。真正发布由匹配的 tag 触发:改源码/模板 → 选定/递增 `VERSION` → PR CI → 合并 `main` → 创建并 push tag → 重新 build/test → 更新 `marketplace`。CI 不猜版本、不自动递增;同版本不同内容和版本回退都会被发布器拒绝。

---

## 8. 测试与 CI

- `tests/fixtures/<tool>/sample.jsonl`:脱敏样例,含全部脏数据形态(tool_result、thinking、`<system-reminder`、isMeta、summary);
- `tests/expected/<tool>/sample.jsonl`:期望的规范化流(抽取输出);
- `tests/run.sh`:纯 bash 断言——临时构建两次并验证可复现;manifest 注入 `VERSION`;catalog/hook/执行位/无 symlink;payload 与 canonical 一致且每包只有本工具 adapter;抽取 diff;drop/pickup;**从各自生成包执行独立 hook**;版本/tag 门禁;在临时 bare remote 演练 orphan 首发、幂等重跑、线性升版与降版拒绝;
- `.github/workflows/ci.yml`:PR、`main` push、手动触发;macos-latest + ubuntu-latest(bash 3.2 兼容靠 macOS runner);shellcheck + shfmt + actionlint + 全量测试。已打 tag 的版本若有 package 输入变化而 `VERSION` 未按 semver 递增则失败;
- `.github/workflows/publish-plugins.yml`:仅 `v*` tag 触发;要求 tag=`v$(cat VERSION)` 且 tag commit 属于 `origin/main`;重新跑完整门禁后生成发布树,用同仓库 `GITHUB_TOKEN` 的 `contents:write` 权限非 force 推送 `marketplace`。发布并发串行排队,workflow 自己的 push 不递归触发 CI。

---

## 9. 隐私、安全与跨平台

本地纯文件,无网络、无遥测。drop 内容为对话原文:`0600/0700` 权限且不加密;README 明示"若把 `~/.deaddrop` 纳入 git/同步盘,注意其中含对话内容"。hook 从 stdin JSON 取得 transcript 路径并读取该文件,持久写入只限自己的数据目录;pickup 默认可把内容写入执行主机剪贴板,`-p` 则只通过用户可见回显返回。

**跨平台**:macOS、Linux 一等支持;Windows 的受支持路径是 **WSL2**(真 Linux,与 mac/linux 完全一致)。原生 Windows shell 尚未适配或验证,在 hook 执行、路径处理与剪贴板行为上可能不同,当前不保证兼容(技术依据见 ADR-002)。目标环境统一 POSIX,故 `$HOME`、`chmod`、剪贴板(clip.exe on WSL2)等差异很小。

---

## 10. 里程碑

- **M0 骨架**(已完成):`bin/deaddrop` 全子命令、claude-code 适配器、fixtures + 测试绿。
- **M1 Claude 端闭环**(进行中):插件本地安装;`${CLAUDE_PLUGIN_ROOT}` 展开、`UserPromptSubmit` hook 挂载、哨兵拦截真机验证。
- **M2 第二个 agent**(代码完成):Codex rollout 适配器、Claude/Codex 独立 plugin 模板、生成包阻断/metadata 测试;待真机 trust 后端到端验收。
- **M3 发布**(流水线完成):`VERSION`/tag 门禁、双平台 CI、orphan `marketplace` 发布与本地 bare remote 演练已完成;首个远程 marketplace 已发布,install.sh/MIT License/GitHub topics 仍待补;中英文 README 已补齐。

### 待实测清单

1. ~~`${CLAUDE_PLUGIN_ROOT}` 展开、`!` 预处理~~ **已验证(2026-07)**;
2. **`UserPromptSubmit` hook 真机**:CC 是否以约定 payload 触发、`decision:block` 是否如文档拦截且 `reason` 仅给用户(文档确认,待真机);
3. **Codex 真机**:安装 plugin → `/hooks` trust → 验证 `>>drop` 不进 rollout且模型零调用(官方文档与 0.144.1 源码已确认,待 UI 实测);Gemini/Cursor 仍待接入;
4. WSL2 端到端(当前受支持的 Windows 环境)。

---

## 11. v2 展望(不进当前范围)

按 tag 检索、名字子串过滤清单、`deaddrop gc --older-than 30d`、`deaddrop sync`(目录 git 化跨机器)、Gemini/Aider 适配器。
