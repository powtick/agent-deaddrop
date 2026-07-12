# 接入一个新 agent(SOP)

> 本文是把 deaddrop 接到一个新 agent 工具(Codex、Gemini CLI、Cursor…)的标准步骤。
> 全程只碰三样:一个**适配器**(读该工具的 transcript)、一段 **hook 接线**(哨兵触发)、一组**测试**(fixture + 期望输出)。**不需要读核心 `bin/deaddrop`**。

接入的本质是回答三个问题:
1. 这个工具的对话记录**长什么样、在哪**?→ 适配器的 `sniff`/`extract`/`glob`。
2. 它的"用户提交前 hook"叫什么、payload 什么字段?→ hook 接线 + 可选 `hook_parse`。
3. 抽取对不对?→ fixture + 期望输出 + `tests/run.sh`。

---

## 能力分级(不必一步到位)

| 级别 | 交付 | 效果 |
|---|---|---|
| **L0 只读** | `sniff` + `extract` | 能对该工具的历史会话**显式路径** drop;其他工具立即能 pickup 它的 drop |
| **L1 哨兵接入** | + hook 接线(该工具的提交前 hook → `hook-prompt --tool <name>`) | 会话内 `>>drop`/`>>pickup` 离线可用 |
| **L2 自动命名/探测** | + `title`(读该工具的会话标题)+ `glob`(doctor 探测) | 自动名更可读、doctor 能报告该工具 |
| **L3 一键分发** | + 该工具的插件打包 | `/plugin install` 之类一键装 |

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
| Codex | `UserPromptSubmit` | 同上(核对其文档) |
| Gemini CLI | User Prompt Event | 核对其 block/enrich 语义 |
| Cursor | `beforeSubmitPrompt` | 核对其 block 语义 |

### 接线内容

把该工具的提交前 hook 指向:

```
deaddrop hook-prompt --tool <tool>
```

`hook-prompt` 会:从 stdin 读 payload → 取 `prompt`/`transcript_path`/`cwd` → 命中 `>>drop`/`>>pickup` 就执行并输出 `decision:block`(拦截),否则 `exit 0` 放行。

### payload 字段映射(`hook_parse`)

`hook-prompt` 默认按 Claude 式字段读:`.user_prompt` / `.transcript_path` / `.cwd`。若该工具字段名不同,写 `<tool>_hook_parse`,从 stdin 读原始 payload,**按顺序打印三行**:

```bash
<tool>_hook_parse() {
  jq -r '.promptText // empty,  .transcriptFile // empty,  .workingDir // empty'
  # 依次输出:prompt / transcript_path / cwd
}
```

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
```

`run.sh` **自动遍历** `tests/fixtures/*/`,对每个 fixture 跑 `deaddrop _extract <tool> <fixture>` 并 diff 对应 expected。你新加的 `<tool>` 会被自动纳入,无需改测试脚本。全绿即抽取正确。

想单测哨兵入口:

```bash
echo '{"user_prompt":">>drop","transcript_path":"tests/fixtures/<tool>/sample.jsonl","cwd":"/tmp"}' \
  | bin/deaddrop hook-prompt --tool <tool>
# 应输出 {"decision":"block","reason":"dropped as: …"}
```

---

## 交付清单(PR)

- [ ] `adapters/<tool>.sh`:`sniff` + `extract`(+ 可选 `title`/`glob`/`hook_parse`)
- [ ] `tests/fixtures/<tool>/sample.jsonl` + `tests/expected/<tool>/sample.jsonl`
- [ ] `tests/run.sh` 全绿
- [ ] hook 接线说明:该工具提交前 hook 的事件名、配置位置、payload 字段(若非标准)、block 语义是否"仅用户"
- [ ] 若发现该工具的 hook/输出语义与本 SOP 有出入,在 PR 描述里注明,并考虑补一条 ADR

> 参考实现:`adapters/claude-code.sh` + `tests/fixtures/claude-code/` + `hooks/hooks.json`。
