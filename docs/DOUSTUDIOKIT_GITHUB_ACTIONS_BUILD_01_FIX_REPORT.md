# DOUSTUDIOKIT_GITHUB_ACTIONS_BUILD_01_FIX_01

日期：2026-10-26（Asia/Shanghai）。此节为修复提交时的本地验证快照；线上验证结果将在发布后补充，不能把本地通过视为云端构建通过。

## 基线与范围

- 本地仓库：`D:\Projects\doustudio-runtime-acceptance`
- GitHub：<https://github.com/achusonwork-bit/doustudio-runtime-acceptance>
- 开始时本地 HEAD 与远端 main：`45ea0d007fad34be9fd28269c62a4ac1599553f4`，已通过 `git ls-remote` 重新确认。
- 上游固定 SHA：`362dad3d082e9f63c8efd360acc653ba169d40a2`。
- 历史失败：<https://github.com/achusonwork-bit/doustudio-runtime-acceptance/actions/runs/40260046063>。
- 原工作区没有已跟踪文件修改；已有未跟踪 `docs/DOUSTUDIOKIT_GITHUB_ACTIONS_BUILD_01_RUN_REPORT.md` 被保留，不暂存、不提交。
- 原 RUN 报告 SHA-256：`9B2B91B02F765A1B63128BEBFBD3111092888836DC6ACE2DF02DD9A2328480E4`，修复后核对未变。

## 修复

错误根因是 job 级 env 不允许使用 runner 上下文。将 EVIDENCE_DIR 从 job env 移到 `id: evidence` 初始化步骤的 env，在此处使用受支持的 `runner.temp`。

初始化步骤先创建目录，然后将同一变量写入两个通道：

```bash
printf 'EVIDENCE_DIR=%s\n' "$EVIDENCE_DIR" >> "$GITHUB_ENV"
printf 'directory=%s\n' "$EVIDENCE_DIR" >> "$GITHUB_OUTPUT"
```

后续 Shell 使用 `$EVIDENCE_DIR`。Artifact 的 12 个明确文件路径统一使用 `${{ steps.evidence.outputs.directory }}`，没有假设 GITHUB_ENV 自动更新表达式 env 上下文。结果汇总和上传保留 `always()`，并增加输出非空检查：初始化未能提供目录时不对空路径操作；初始化成功而后续失败时仍汇总和上传现有证据。

以下设计均保留：唯一触发器 workflow_dispatch；xcode-27；上游完整 SHA 和实际 HEAD 校验；contents: read；20 分钟超时；persist-credentials: false；仅两个固定 SHA 的官方 Actions；3 天 Artifact 保留；原始日志和退出码；`swift package dump-package` 与 `swift build -c debug`；不修改上游源码或平台要求。

## 本地验证

执行 `python .git/task-validation/validate_fix01.py`，退出码 0：92 项检查 PASS，检查了全部 23 处工作流表达式。验证复用已有 PyYAML 6.0.3 和 Git Bash，未安装新工具。

| 检查 | 结果 |
| --- | --- |
| YAML 解析、缩进及重复键 | PASS |
| job env 不含 runner | PASS |
| runner.temp 只在初始化 step env 中出现 | PASS |
| 表达式上下文可用位置及先前步骤引用 | PASS，依据官方上下文表检查本文件实际表达式；不是通用 GitHub 服务端验证器 |
| Shell 环境变量与步骤输出的双通道 | PASS |
| Artifact 12 文件白名单和目录一致性 | PASS |
| 6 个 Shell 脚本 bash -n | PASS |
| 独立目录执行初始化脚本 | PASS，含空格路径；GITHUB_ENV 与 GITHUB_OUTPUT 相同目录；固定 SHA 文件正确；四个阶段均初始化为 NOT_RUN |
| 原有安全、命令、日志和退出码设计 | PASS |
| git diff --check | PASS |
| 原未跟踪 RUN 报告 hash | 未变 |
| actionlint | 未安装，NOT_RUN |
| macOS/Swift 编译 | NOT_RUN；本地仅执行初始化脚本，不是 runner 或编译模拟 |

本地验证工具和 JSON 结果仅位于 `.git/task-validation/`，不提交。实际改动范围为工作流与本报告；不修改其他项目、Windows 系统代理、v2rayN 配置或全局 Git 配置。

修复后工作流 SHA-256：`2451D682512C8B94F5BCD9AE48F9273405387DC4C7B4841B5C66E8712FAB9B94`。

## 发布与后续验证

只有以上检查通过后，才按要求暂存以下两项并普通提交/推送 main：

```text
.github/workflows/doustudio-macos-build.yml
docs/DOUSTUDIOKIT_GITHUB_ACTIONS_BUILD_01_FIX_REPORT.md
```

提交信息：`fix(ci): resolve runner temp context validation`。推送前重新核对远端仍是指定基线；若变化或推送被拒绝，停止，不强推。提交 SHA、推送结果、服务端结果与云端 run 证据在实际发生后记录。

若当前环境不能通过已授权渠道触发，请用户访问 [Actions 页面](https://github.com/achusonwork-bit/doustudio-runtime-acceptance/actions)，选择 `DouStudioKit macOS Build Check`，点击 `Run workflow`，选择 `main` 后运行。没有实际运行时，不生成或声称存在 macOS 版本、Swift/Xcode 版本、build exit code 或 Artifact。

## 提交前状态

```ini
WORKFLOW_CONTEXT_ERROR = FIXED
LOCAL_VALIDATION = PASS
GITHUB_SERVER_VALIDATION = NOT_RUN
WORKFLOW_DISPATCH = NOT_RUN
MACOS_RUNNER_START = NOT_RUN
PACKAGE_MANIFEST = NOT_RUN
SWIFT_BUILD = NOT_RUN
ARTIFACT = NOT_RUN

DOUYIN_API_TEST = NOT_RUN
VIDEO_DOWNLOAD = NOT_RUN
RUST_IMPLEMENTATION = NOT_STARTED

ROOTNETSCOPE_CHANGED = NO
VIDEOFLOW_CHANGED = NO
UPSTREAM_SOURCE_CHANGED = NO
FORCE_PUSH = NO
```

## 规则核验来源

[GitHub Context availability 官方表](https://docs.github.com/en/actions/reference/workflows-and-actions/contexts#context-availability)区分了 job env、step env、step if 与 step with 的上下文可用范围。本轮仅按该表修复工作流；真正的服务端接受情况仍需发布后验证。
