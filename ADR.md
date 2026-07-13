# ADR — 决策记录与调研依据

> 本文件收录本项目的架构决策(ADR)、同类项目调研与外部关键事实。
> `DESIGN.md` 只描述本项目**自身的设计**;"为什么这么定 / 排除了什么"、竞品对比、外部工具事实归在这里。
> ADR 格式:**决定 / 理由 / 排除项**。只追加,不改写历史;被推翻的决策在原条目上标注取代关系,不删除。

---

## 一、同类项目调研(2026-07)

| 项目 | 方向 | 与本项目差异 |
|---|---|---|
| blader/baton ★51 | LLM 撰写交接文档,存 repo 内 `.baton/` | LLM 摘要烧上下文;repo 内存储在多 worktree 间不可见 |
| carryover-dev/carryover ★7 | 常驻 daemon 读 transcript,自动蒸馏状态交接 | 同哲学(读磁盘、不烧上下文),但环境式续跑,无"具名定向"语义,需 daemon |
| codeprakhar25/agent-baton ★11 | 配额耗尽前抢救性交接 | 触发场景不同,顺序接力非并发互传 |
| handoff 系插件(thepushkarp 等) | 同会话断点续传 | Claude 单生态,LLM 撰写,纵向非横向 |

**本项目独占的组合**:对话原话机械抽取 + 具名/定向/按需 + 并发多会话精确定位 + 跨工具 + 无 daemon。

---

## 二、关键事实依据(2026-07-12 核验)

- Claude Code transcript:`~/.claude/projects/<cwd转义>/<uuid>.jsonl`;Bash 工具环境无 `CLAUDE_SESSION_ID`;
- Codex rollout:`~/.codex/sessions/Y/M/D/rollout-<ts>-<uuid>.jsonl`;本机 codex-cli 0.144.1;
- Codex hooks(0.144.1,2026-07-13):v0.124.0 稳定;规范开关为默认启用的 `[features].hooks`,`codex_hooks` 已是弃用别名;`UserPromptSubmit` stdin 用 `prompt`/`transcript_path`/`cwd`,支持 exit 0 + `decision:block`;block 发生在本轮写 transcript 与模型 sampling 之前;非 managed hook 需 `/hooks` 按定义 hash 信任;
- Codex 插件市场:v0.121.0 引入,v0.143.0 起 remote plugins 默认开启,清单 `.agents/plugins/marketplace.json`;
- Claude 插件:`.claude-plugin/plugin.json`,可打包 commands/hooks/skills/MCP,marketplace 为 git 仓库 + `.claude-plugin/marketplace.json`;
- claude/codex 进程均不持有 transcript 句柄(lsof 验证);Bash 工具 shell 的直接父进程为 claude 进程(ps 验证)。

---

## 三、决策记录(ADR)

### ADR-001 命名:agent-deaddrop / deaddrop / drop+pickup

**决定**:GitHub/npm `agent-deaddrop`,CLI 二进制 `deaddrop`,slash command `/drop`(存)+`/pickup`(取),正文写法 "Dead Drop",单个情报文件称一个 **drop**。

**理由**:"dead drop"(死信箱)隐喻精确对应"异步、不见面、约定位置交接";标识符合写为 `deaddrop`,避免 `agent-dead-drop` 被误切为 "agent-dead"+"drop",同类项目(deaddrop-js、ipfs-deaddrop 等)均合写;`/drop`+`/pickup` 用初中词汇兜底易懂性;npm `agent-deaddrop` 于 2026-07-12 确认可注册。

**排除项**:"接力/交接"隐喻(baton/handoff/carryover/handover)已被同赛道多个项目占据,避开;`dead letter box` 语义等价但被死信队列(DLQ,"投递失败的消息")语境劫持,弃用。

### ADR-002 跨平台:单份 bash 核心;macOS/Linux 一等,Windows 仅经 WSL2

**决定**:核心 `bin/deaddrop` 保持**单文件 POSIX bash**,全平台同一份,不拆第二套实现。支持面:**macOS、Linux 一等**;**Windows 仅经 WSL2 支持**(WSL2 是真 Linux,bash/jq/coreutils、hook、进程链全部原生一致)。**原生 Windows shell(cmd/PowerShell/Git Bash)不支持**——CC 原生 Windows 顶多 best-effort(见下),`locate` 失败即回退显式路径,`pickup` 恒可用。

**理由**:bash 让 hook 启动最快、纯文本可审计、贡献者门槛低。真正一致的 Windows 环境是 WSL2;原生 Windows 的 hook 一致性经核验不成立(见下),不值得为它牺牲 bash 或维护第二套实现。

**排除项**:为原生 Windows 拆 bash + PowerShell 两套实现(等于把抽取规则/定位/每个适配器都写两遍,漂移必然,毁掉"一份脚本 + 适配器开放扩展"的气质);整体重写为 Node/Python/Go(与"纯脚本可审计"卖点冲突,引入运行时/构建;native Windows 收益仅一格,不划算)。

**为何原生 Windows 不做(2026-07 核验,见调研来源)**:
- **CC hook 在原生 Windows 默认走 cmd.exe**,非 Git Bash;需手动设 `CLAUDE_CODE_GIT_BASH_PATH` 才用 bash。
- 即便设了 Git Bash,**插件 hook 有已知 bug**:`${CLAUDE_PLUGIN_ROOT}` 解析成反斜杠 Windows 路径,Git Bash 当转义符处理 → 插件 hook 失败(anthropics/claude-code #21878 等)。我们的 Claude 集成正是插件,直接命中。
- 官方/社区推荐的跨平台 hook 写法是"用 `node`,避开 bash",与本项目 bash 核心冲突。
- **Codex 原生 Windows 默认 PowerShell 沙箱**,仅 WSL2 下才是 bash。
- 结论:原生 Windows 一致性不成立;WSL2 里两端全部原生一致。Windows 用户请在 WSL2 内运行 CC/Codex。

### ADR-003 使用接口:提交前哨兵 hook(离线),弃用 slash command

**决定**:唯一接入方式是**"用户提交前 hook" + 输入哨兵**。用户在输入框打 `>>drop [name] [turns]` / `>>pickup [name|number]`(`>>` 后可带空格)回车,hook(命令 `deaddrop hook-prompt --tool <name>`)从 stdin payload 拿 `user_prompt`/`transcript_path`/`cwd`,命中哨兵则执行并输出 `{"decision":"block","reason":<结果>}`(`exit 0`)——**该输入被拦截、从 transcript 抹除、模型永不可见,结果只给用户**;非哨兵 `exit 0` 无输出放行。**弃用 slash command**(2026-07 用户定,完全重构)。

**理由**:离线(模型无感知)是硬要求,而 slash command 做不到。且 hook 的 payload 直接给 `transcript_path`,drop 无需任何会话定位机制(见 ADR-004)。hook 是"离线 + 原生 + 跨 agent"三合一的唯一扩展面。

**输出通道(2026-07 核实,硬事实,务必用对)**:
- **exit 0 + `{"decision":"block","reason":"…"}`** → 拦截 + `reason` **只给用户**。← 正解
- `systemMessage` → 只给用户;`suppressOutput` → 藏 hook stdout。
- ~~exit 2 + stderr~~ → 也拦截,但 stderr **喂给模型**,不可用。
- `additionalContext` → 注入**模型**上下文,不可用。

**跨 agent 通用性已核实**:Claude Code(`UserPromptSubmit`)、Codex(`UserPromptSubmit`)、Gemini CLI(User Prompt Event)、Cursor(`beforeSubmitPrompt`)四家均有"提交前 hook + 可拦截";payload 字段差异由适配器可选 `hook_parse` 吸收。接入 SOP 见 docs/ADDING-AN-AGENT.md。

**Codex 实现核验(0.144.1,2026-07-13)**:`UserPromptSubmit` 的 matcher 不生效;命令 stdin 含 `prompt`/`transcript_path`/`cwd`/`session_id`/`turn_id`;`decision:block` 的 `reason` 作为用户可见 feedback,阻断后不记录 prompt、不进入模型流程。普通 stdout/`additionalContext` 会成为模型可见 developer context,不用;`suppressOutput` 当前只解析未实现。Codex 的 exit 2 + stderr 同样能阻断且当前走 feedback,但为保持跨工具安全契约仍统一禁用。

**排除项(附能力核验,记此以免重复探索)**:
- slash command / 自定义命令 **本质是 prompt 模板,必触发模型**;`disable-model-invocation` 只挡 Claude 自触发,`user-invocable:false` 只隐藏入口。
- 内置命令(`/reload-plugins`、`/clear`)那种离线动作是**客户端二进制原生代码**,`plugin.json`/frontmatter 无任何"command type / 本地执行 / 输出抑制"字段可复制它——架构边界,非配置项。
- Claude Code **无 composer 预填 API**:故 **pickup 的"内容进输入框待编辑"不可得**。pickup 输出改走**剪贴板**(`--copy`,`reason` 回一行"已复制,粘贴进输入框加说明再发"),或 `reason` 回显(小内容);用户 `Cmd+V` 是最接近的等价。
- `!` bang 模式 v2.1.186 起也自动响应(需 `respondToBashCommands:false` 才静默),不作为接入方式。

### ADR-004 删除会话定位子系统(注册表 + 进程链遍历)

**决定**:移除 v1 的 SessionStart 注册表(`~/.deaddrop/.sessions/`)、`hook-session-start`/`locate` 子命令、进程链遍历(`ps -o ppid=`)与适配器 `process_re` 函数。

**理由**:该子系统只为回答"当前会话的 transcript 是哪个"。改用提交前哨兵 hook(ADR-003)后,**payload 直接给 `transcript_path`**——这个问题不存在了。保留即死代码,且比读 payload 更脆(依赖进程树结构)。适配器必需函数因此从 4 个(sniff/extract/process_re/glob)减为 2 个(sniff/extract),`glob` 降为可选(仅 doctor 探测用)。

**代价**:裸 `deaddrop drop`(无 hook、终端手动跑)不再能自动定位,须显式传 transcript 路径。可接受——主用法是 hook,hook 自带路径。

### ADR-005 agent 集成隔离:每个 agent 独立 plugin 与 hook

**决定**:根 `bin/deaddrop` 与 `adapters/*.sh` 是 canonical 开发源;每个平台分发一个自包含 `plugins/<tool>/`,内含本平台 manifest、默认路径 `hooks/hooks.json`、真实 `bin/deaddrop` 与本工具 adapter。Claude/Codex 根 marketplace catalog 分别指向 `plugins/claude-code` / `plugins/codex`。plugin 副本由 `scripts/sync-plugin-payloads.sh` 机械物化并在测试中 `--check`;禁止共享 hook 动态分流或任何 symlink。已发布 payload/hook 有变化必须 bump 对应 manifest version;核心变化同步到所有包时全部 bump。

**理由**:两端 marketplace 安装都会把 plugin source 单独复制进版本 cache,运行时 root 分别是 `${CLAUDE_PLUGIN_ROOT}` / `${PLUGIN_ROOT}`;Codex 0.144.1 实测还会静默省略 symlink。真实 payload 才能保证 clone 后直接安装、独立复制/压缩也不失效。约 20 KB 核心重复成本小,同步闸门可消除手工漂移。各平台的 payload、hook trust、发布与升级生命周期保持独立,一个平台变更不会改另一个平台的 hook hash。

**排除项**:仓库根同时作为两家 plugin;通用 hook 内检测 root 变量决定 `--tool`;plugin 文件 symlink 回 canonical;只在 release 时生成包(会让 clone 后不能直接安装,引入用户侧 build)。

**状态(2026-07-13)**:由 ADR-006 部分取代。每 agent 独立 plugin/hook、自包含发布产物与禁 symlink 继续有效;“在 `main` 提交物化副本”和“排除 release-time generation”被取代。

### ADR-006 源码与发布分离:VERSION/tag 驱动 orphan marketplace

**决定**:`main` 只维护 canonical `bin/deaddrop`、`adapters/*.sh` 和 `packaging/` 下每个 agent 独立的 manifest/hook/catalog 模板,不提交重复 payload。根 `VERSION` 是所有 plugin manifest 的唯一版本源;`scripts/package-plugins.sh` 在 CI/测试中注入版本并生成无 symlink、含真实 bin 与本平台 adapter 的自包含包。只有严格匹配 `v<VERSION>` 且指向 `main` commit 的 tag 才触发生产发布;workflow 全量验证后,把生成树非 force 推到独立的 orphan `marketplace` 分支。首次发布无 `main` 祖先,后续发布保持线性;同版本不同内容与版本回退均拒绝。hook/adapter 仍按 agent 隔离,不共享 hook。

**理由**:`main` 维护 N 份相同 bin 会制造评审噪音和同步负担,但 marketplace 安装 cache 又必须拿到离开源码树仍可运行的真文件。构建时机械物化同时满足“源码单份”和“分发自包含”;orphan 分支把开发历史与可安装快照分开,用户仍无 build。显式 `VERSION` + 人工 tag 可审计、可重放,不会让 CI 猜测或擅自递增版本。GitHub Actions 同仓库 `GITHUB_TOKEN` 只需 workflow 级 `contents:write` 即可推分支,且该 token 触发的 push 不递归启动普通 push workflow;发布 worktree 可继承 checkout 的认证配置。

**代价**:`main` clone 不再能直接作为 marketplace,维护者本地安装须先打包,远程安装必须显式选 `marketplace` ref。任何会改变任一生成包的输入都整体 bump 全局版本,即使只改一个 agent;这是换取单一版本源和发布原子性的成本。private 仓库阶段,远程安装者还必须拥有仓库读取权限。

**排除项**:运行时共享 bin 或 symlink;一个 hook 动态探测 agent;要求用户安装时 build;继续在 `main` 提交重复 payload;每包各自手改 version;CI 自动推断/递增 version;tag 不校验便发布;force push marketplace 历史。
