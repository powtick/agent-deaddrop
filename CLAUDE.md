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
- 无用户侧 build 步骤;无 npm 发包。`main` 只维护 canonical 源与 packaging 模板;agent 安装使用 `marketplace` 发布分支里已物化的自包含 plugin

## 常用命令

```bash
tests/run.sh                    # 唯一测试闸门;含临时打包、版本/tag、bare remote 发布演练
scripts/package-plugins.sh      # 生成 .dist/marketplace;可传其他输出目录
scripts/package-plugins.sh --check .dist/marketplace
scripts/check-release-tag.sh "v$(cat VERSION)"
shellcheck bin/deaddrop adapters/*.sh scripts/*.sh tests/run.sh
shfmt -d bin/deaddrop adapters/*.sh scripts/*.sh tests/run.sh
actionlint
bin/deaddrop doctor   # 自检:jq、剪贴板、适配器、工具探测

# 单跑一个适配器抽取:
bin/deaddrop _extract claude-code tests/fixtures/claude-code/sample.jsonl
# 模拟哨兵 hook(测集成入口):
echo '{"user_prompt":">>drop","transcript_path":"<path>","cwd":"<dir>"}' | bin/deaddrop hook-prompt --tool claude-code
```

## 工作流

**动手前**:读 `DESIGN.md` 相关章节 → 读将改的模块及其现有测试 → 需求与设计有出入就停下确认。改了设计覆盖的行为(drop 文件格式、适配器契约、哨兵/hook 机制、抽取规则)同步更新 `DESIGN.md`,保持文档与代码互相印证。

**提交前**:若当前 `VERSION` 已存在对应 `v<VERSION>` tag,package-impacting 变更(`bin/`、`adapters/`、`packaging/`、`scripts/package-plugins.sh`)必须显式递增根 `VERSION`;未打 tag 的发布候选允许在同一版本继续修复。不要手改 manifest version。随后跑 shellcheck、shfmt、actionlint 与 `tests/run.sh`,全绿才算完成——以闸门绿为准,不以“我觉得写好了”为准。测试随功能走:改抽取必带 fixture + 期望输出;改 drop/pickup/hook-prompt 必覆盖对应断言。`.dist/` 是生成物,不提交。

接入新 agent 见 `docs/ADDING-AN-AGENT.md`;测试自动遍历 `adapters/`,无需改核心。

## 测试与发布流水线

### CI

- `.github/workflows/ci.yml` 在 PR、`main` push 和手动触发时跑 Ubuntu + macOS;macOS 的 `/bin/bash` 覆盖 bash 3.2。
- 两端都跑 shellcheck、shfmt、actionlint 和 `tests/run.sh`。测试会在临时目录构建完整 Claude/Codex plugin,从生成包执行 hook,并用临时 bare git remote 演练 orphan 首发、幂等重跑、线性升版和降版拒绝。
- PR 或非首次 `main` push 中,若当前版本已经打 tag,package 输入变化而 `VERSION` 未按 semver 递增就失败;未打 tag 的发布候选可保持版本。纯文档、测试或 workflow 变更不要求 bump。

### 发布

`VERSION` 用单行稳定 semver `X.Y.Z`;tag 才是生产发布触发器,只提交/合并 VERSION 不会发布。流程:

```bash
# 1. 随 package-impacting 代码显式递增 VERSION;首发版本为 0.0.1
# 2. 在最新 main 上做本地预检
release_tag="v$(cat VERSION)"
scripts/check-release-tag.sh "$release_tag"
tests/run.sh

# 3. main 已在远程后创建并推 tag;首次发布要先 push main
git tag "$release_tag"
git push origin "$release_tag"
```

`.github/workflows/publish-plugins.yml` 仅响应 `v*` tag。它验证 tag=`v$(cat VERSION)`、tag commit 属于 `origin/main`,重新跑完整静态检查和测试,生成自包含树,再用同仓库 `GITHUB_TOKEN` 非 force 推到 orphan `marketplace` 分支。发布任务串行排队;同版本不同内容、旧版本回退和非 fast-forward 推送都会失败。仓库默认 token 权限保持 read,只有该 workflow 显式声明 `contents:write`;无需 PAT。当前仓库为 private,远程安装/更新者必须有 GitHub 读取权限。

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
- 每个 agent 在 `packaging/plugins/<tool>/` 维护独立 manifest + `hooks/hooks.json`;hook 不共享,不在运行时猜 agent
- 生成产物的 `plugins/<tool>/` 必须含 manifest、独立 hook、真实 `bin/deaddrop`、且只含本工具 adapter;禁止任何 symlink
- 根 `bin/`/`adapters/` 是唯一代码源;`scripts/package-plugins.sh` 机械物化副本并从根 `VERSION` 注入所有 manifest version
- `main` 不提交生成的 `plugins/`/catalog;可安装的完整树只发布到 `marketplace` 分支,用户侧不 build

## 代码风格

- 脚本开头 `set -uo pipefail`(**不用 `set -e`**:适配器/命令非零返回是正常控制流)
- 函数前缀:核心用 `cmd_`/`_`,适配器用 `<工具名>_`(如 `claude_code_extract`)
- 文档(`.md`)用中文;**代码注释、报错文本、脚本所有 stderr/stdout 输出一律英文**,标识符用英文
- 注释只写"为什么"与约束,不写"这行在做什么"
- `shellcheck` 与 `shfmt` 提交前必须干净(CI 门禁)
