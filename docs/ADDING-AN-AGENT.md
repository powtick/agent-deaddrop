# 接入一个新 agent(SOP)

> 本文是把 deaddrop 接到一个新 agent 工具(Codex、Gemini CLI、Cursor…)的标准步骤。
> 全程主要碰四样:一个**适配器**(读该工具的 transcript)、一组本 agent 独立的 **manifest + hook packaging 模板**、对应 marketplace/catalog 接线、一组**测试**(fixture + 期望输出)。发布时由脚本生成带 hook + bin + adapter 的自包含 plugin,**不需要读核心 `bin/deaddrop`**。

接入的本质是回答四个问题:
1. 这个工具的对话记录**长什么样、在哪**?→ 适配器的 `sniff`/`extract`/`glob`。
2. 它的"用户提交前 hook"叫什么、payload 什么字段?→ hook 接线 + 可选 `hook_parse`。
3. 抽取对不对?→ fixture + 期望输出 + `tests/run.sh`。
4. 该平台怎样安装、缓存和升级 plugin?→ 平台 manifest + catalog source + version/cache 规则。

---

## 能力分级(不必一步到位)

| 级别 | 交付 | 效果 |
|---|---|---|
| **L0 只读** | `sniff` + `extract` | 能对该工具的历史会话**显式路径** drop;其他工具立即能 pickup 它的 drop |
| **L1 哨兵接入** | + hook 接线(该工具的提交前 hook → `hook-prompt --tool <name>`) | 会话内 `>>drop`/`>>pickup` 离线可用 |
| **L2 自动命名/探测** | + `title`(读该工具的会话标题)+ `glob`(doctor 探测) | 自动名更可读、doctor 能报告该工具 |
| **L3 一键分发** | + `packaging/plugins/<tool>/` 模板与 catalog entry | 发布时生成自包含 `plugins/<tool>/`,一次安装带上 hook + bin + adapter |

先做到 L0/L1 就有价值。

---

## Step 1 — 写适配器 `adapters/<tool>.sh`

适配器只产出**规范化中间流**:每行一个 `{"role":"user|agent","text":"…"}`。渲染、frontmatter、命名、轮次统计都由核心层做,你别碰。

### 必需两个函数

```bash
ADAPTERS="${ADAPTERS:-} <tool>"      # 注册(名字即 source_tool,允许连字符)

<tool>_sniff() {                     # $1=文件路径 → exit 0 表示"是本家格式"
  # 用文件头几十行的特征判断。宁可严格,避免误认别家格式。
  head -n 50 -- "$1" 2>/dev/null | jq -e -R '…本家特征…' >/dev/null 2>&1
}

<tool>_extract() {                   # $1=文件路径 → stdout: {"role","text"} JSONL
  jq -c -R '…' "$1"                  # 见下方"抽取规则"
}
```

> 函数名前缀 = 适配器名里非字母数字换成 `_`(`gemini-cli` → `gemini_cli_extract`)。

### 抽取规则要点(照着挖该工具的 transcript)

- **只保留对话**:user 的真实输入 + agent 的最终文本回答。
- **丢弃**:工具调用与其结果(tool_use/tool_result)、思考块(thinking/reasoning)、系统注入(`<system-reminder>`、`<command-…>`、各种 `<xxx>` 包裹的注入)、meta 行、inter-agent 通信。
- user 内容可能是 string 或 blocks 数组——数组只取文本块。
- 参照内置 `adapters/claude-code.sh` 和 DESIGN.md §6.2 的 claude-code 规则逐条对照。

### 可选三个函数

```bash
<tool>_title()      { … }   # $1=文件 → 短标题(自动命名用;如读该工具的会话标题行)。缺则退化用首条用户消息
<tool>_glob()       { printf '%s\n' "$HOME/.<tool>/…/*.jsonl"; }   # doctor 探测本机是否装该工具
<tool>_hook_parse() { … }   # stdin=hook payload → 打印三行:prompt / transcript_path / cwd(见 Step 2)
```

**加载防呆**:核心 source 后会校验必需函数俱全,缺则该适配器整体禁用并报 `adapter "<tool>" disabled, missing function(s): …`。

---

## Step 2 — hook 接线(哨兵触发,离线)

deaddrop 的离线触发靠该工具的**"用户提交前 hook"**——用户打哨兵 `>>drop`/`>>pickup` 回车,hook 拦截该输入、执行、结果只给用户、模型不可见。已核实四家都有此类 hook:

| 工具 | 事件名 | 拦截方式 |
|---|---|---|
| Claude Code | `UserPromptSubmit` | `exit 0` + `{"decision":"block","reason":…}` |
| Codex | `UserPromptSubmit` | `exit 0` + `{"decision":"block","reason":…}`(0.144.1 官方文档/源码已核实) |
| Gemini CLI | User Prompt Event | 核对其 block/enrich 语义 |
| Cursor | `beforeSubmitPrompt` | 核对其 block 语义 |

### 接线内容

把该工具的提交前 hook 指向:

```
deaddrop hook-prompt --tool <tool>
```

`hook-prompt` 会:从 stdin 读 payload → 取 `prompt`/`transcript_path`/`cwd` → 命中 `>>drop`/`>>pickup` 就执行并输出 `decision:block`(拦截),否则 `exit 0` 放行。

**每个 agent 必须维护独立的 `packaging/plugins/<tool>/`**:放该平台标准 manifest(模板不写 version)和自己的 `hooks/hooks.json`;不要把多平台命令塞进同一个 hook 后按环境变量分流。根 `bin/`/`adapters/` 是 canonical 源,`scripts/package-plugins.sh` 会按模板目录名找到 `adapters/<tool>.sh`,注入根 `VERSION`,并在生成的 `plugins/<tool>/` 中复制真实 bin 与本工具 adapter。

在 `packaging/.agents/plugins/marketplace.json`、`packaging/.claude-plugin/marketplace.json` 或该平台规定的 catalog 模板里增加 entry,source 只指向生成树的 `./plugins/<tool>`。生成包必须无 symlink、可离开源码仓库独立运行。manifest/hook/catalog、canonical bin、本 adapter 或打包逻辑有变化时 bump**全局** `VERSION`;不要在单个 manifest 里手改版本。

### payload 字段映射(`hook_parse`)

`hook-prompt` 默认兼容 `.user_prompt // .prompt`、`.transcript_path`、`.cwd`;因此 Codex 不需要 `hook_parse`。其他字段名才写 `<tool>_hook_parse`,从 stdin 读原始 payload,**按顺序打印三行**:

```bash
<tool>_hook_parse() {
  jq -r '[.promptText // "", .transcriptFile // "", .workingDir // ""][]'
  # 依次输出:prompt / transcript_path / cwd
}
```

Codex 的输入另含 `session_id`、`turn_id`、`hook_event_name`、`model`、`permission_mode`,subagent 时可能有 `agent_id`/`agent_type`;`transcript_path` 可为 null。它的 `UserPromptSubmit` matcher 会被忽略,且 plugin hook 首次出现或内容变化后必须由用户在 `/hooks` review/trust。

### 输出通道铁律(别踩)

拦截 + 结果**只给用户** = `exit 0` + `{"decision":"block","reason":…}`(或 `systemMessage`)。
**绝不用** `additionalContext` 或 `exit 2` 的 stderr——那些会进模型上下文(见 ADR-003)。核心已处理好,你只需保证该工具的 hook 语义与"block+reason=仅用户"一致;不一致就在接入 PR 里注明差异。

---

## Step 3 — fixture + 期望输出

```
tests/fixtures/<tool>/sample.jsonl    # 脱敏样例,故意塞满该工具的全部脏数据形态
tests/expected/<tool>/sample.jsonl    # 期望的规范化流(手写,对照抽取规则)
```

- fixture 要覆盖:正常 user/agent、工具调用+结果、思考块、系统注入、meta、以及该工具特有的脏数据。
- 期望文件**手写**(从抽取规则推,不要跑一遍程序抄输出)。
- 每行 `{"role":"user|agent","text":"…"}`,顺序即对话顺序,jq 紧凑格式(`{"role":"user","text":"…"}`,无空格,UTF-8 原文)。

---

## Step 4 — 测试

```bash
tests/run.sh
scripts/package-plugins.sh .dist/marketplace
scripts/package-plugins.sh --check .dist/marketplace
```

`run.sh` **自动遍历** `tests/fixtures/*/`,对每个 fixture 跑 `deaddrop _extract <tool> <fixture>` 并 diff 对应 expected。它还临时生成发布树,检查 version/catalog/hook/真实 payload/无 symlink,并只从生成 plugin 执行集成 hook。你新加的 `<tool>` 会自动进入抽取测试;平台特有的 hook payload 与 catalog schema 仍须补针对性断言。

想单测哨兵入口:

```bash
echo '{"user_prompt":">>drop","transcript_path":"tests/fixtures/<tool>/sample.jsonl","cwd":"/tmp"}' \
  | bin/deaddrop hook-prompt --tool <tool>
# 应输出 {"decision":"block","reason":"dropped as: …"}
```

---

## 交付清单(PR)

- [ ] `adapters/<tool>.sh`:`sniff` + `extract`(+ 可选 `title`/`glob`/`hook_parse`)
- [ ] `packaging/plugins/<tool>/`:该平台标准 manifest(不写 version)+ 独立 `hooks/hooks.json`
- [ ] 平台 marketplace/catalog 模板 entry 的 source 只指向生成的 `./plugins/<tool>`
- [ ] `scripts/package-plugins.sh` 能发现模板,生成 manifest + hook + 真 `bin/deaddrop` + 仅本工具 adapter,且无 symlink
- [ ] 若当前版本已打 tag,package-impacting 变更已 bump 根 `VERSION`;没有直接编辑生成 manifest version
- [ ] `tests/fixtures/<tool>/sample.jsonl` + `tests/expected/<tool>/sample.jsonl`
- [ ] `scripts/package-plugins.sh <临时目录>` 与 `--check` 通过
- [ ] `tests/run.sh` 全绿
- [ ] hook 接线说明:该工具提交前 hook 的事件名、配置位置、payload 字段(若非标准)、block 语义是否"仅用户"
- [ ] 若发现该工具的 hook/输出语义与本 SOP 有出入,在 PR 描述里注明,并考虑补一条 ADR

发布后再用全新的临时 agent 配置目录从远程 `marketplace` ref 安装;只从安装 cache 运行 hook 与抽取,确认没有偷用仓库根文件。tag 必须等于 `v$(cat VERSION)`,并检查远程 `marketplace` 分支的 catalog、manifest version 与文件完整性。

> 参考实现:`adapters/claude-code.sh`、`adapters/codex.sh`、对应 fixtures,以及 `packaging/plugins/claude-code/` / `packaging/plugins/codex/`。
