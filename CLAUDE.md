# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

`AGENTS.md` 软链到本文件,两者是同一份手册,只维护 `CLAUDE.md`。

## 项目

Agent Dead Drop(CLI 二进制 `deaddrop`):在并发的 AI coding agent 会话之间,**离线**传递对话精华(或只传最后一轮结论)。纯脚本机械抽取 transcript,零 token、确定性、无 daemon、无网络。

接入方式是**提交前哨兵 hook**:用户在输入框打 `>>drop` / `>>pickup`,hook 拦截该输入并执行,**模型全程无感知**(不是 slash command——那必触发模型)。

**`DESIGN.md` 是权威设计文档**,动手前先读相关章节。决策与外部事实见 `ADR.md`;接入新 agent 见 `docs/ADDING-AN-AGENT.md`。

## 技术栈

- 核心 `bin/deaddrop`:单文件 POSIX bash,兼容 macOS bash 3.2,可被 zsh 调用
- 平台:macOS、Linux 一等;Windows 仅经 WSL2(原生 cmd/PowerShell/Git Bash 不支持,见 ADR-002)
- 运行时依赖:`jq ≥ 1.6` + coreutils;pickup `--copy` 另需剪贴板工具
- 无 build 步骤;无 npm 发包,仅 git clone + install 脚本安装

## 常用命令

```bash
tests/run.sh          # 全部测试(唯一闸门):抽取 diff + drop/turns + pickup/分页 + hook-prompt 哨兵 + 防呆
shellcheck bin/deaddrop adapters/*.sh
shfmt -d bin/deaddrop adapters/*.sh    # -d 只报差异;-w 就地格式化
bin/deaddrop doctor   # 自检:jq、剪贴板、适配器、工具探测

# 单跑一个适配器抽取:
bin/deaddrop _extract claude-code tests/fixtures/claude-code/sample.jsonl
# 模拟哨兵 hook(测集成入口):
echo '{"user_prompt":">>drop","transcript_path":"<path>","cwd":"<dir>"}' | bin/deaddrop hook-prompt --tool claude-code
```

## 工作流

**动手前**:读 `DESIGN.md` 相关章节 → 读将改的模块及其现有测试 → 需求与设计有出入就停下确认。改了设计覆盖的行为(drop 文件格式、适配器契约、哨兵/hook 机制、抽取规则)同步更新 `DESIGN.md`,保持文档与代码互相印证。

**提交前**:`tests/run.sh` 全绿才算完成——以闸门绿为准,不以"我觉得写好了"为准。测试随功能走:改抽取必带 fixture + 期望输出;改 drop/pickup/hook-prompt 必覆盖对应断言。

接入新 agent 见 `docs/ADDING-AN-AGENT.md`;测试自动遍历 `adapters/`,无需改核心。

## 硬约束

- 单文件 bash + 只依赖 jq;不引入其他运行时依赖
- 出错一律非零退出 + stderr;**报错文本会被注入模型上下文,必须写成能指导下一步操作的英文**(如 `run 'deaddrop doctor' to verify …`),报错集中经 `die()`
- 数据目录 `0700`、drop 文件 `0600`(内容为对话原文,含敏感信息)
- 共享文件写入一律 mktemp + mv 原子替换,无锁
- 适配器只产出规范化中间流(每行 `{"role":"user|agent","text":"…"}` JSONL),不产出最终 markdown——渲染、frontmatter、轮次、命名由核心层统一做
- 适配器必需函数仅 `sniff`+`extract`;`title`/`glob`/`hook_parse` 可选
- drop 文件 frontmatter 带 `drop_version`;改格式契约必须升版本
- **hook 输出通道**:拦截 + 结果只给用户 = `exit 0` + `{"decision":"block","reason":…}`;**绝不用** `additionalContext` 或 exit-2 stderr(都进模型)
- 数据布局:`~/.deaddrop/` 下 `drops/<project>/`(数据)、`adapters.d/`(用户扩展)分开

## 代码风格

- 脚本开头 `set -uo pipefail`(**不用 `set -e`**:适配器/命令非零返回是正常控制流)
- 函数前缀:核心用 `cmd_`/`_`,适配器用 `<工具名>_`(如 `claude_code_extract`)
- 文档(`.md`)用中文;**代码注释、报错文本、脚本所有 stderr/stdout 输出一律英文**,标识符用英文
- 注释只写"为什么"与约束,不写"这行在做什么"
- `shellcheck` 与 `shfmt` 提交前必须干净(CI 门禁)
