# DOUSTUDIOKIT_GITHUB_ACTIONS_BUILD_01_FIX_01

日期：2026-10-26（Asia/Shanghai）。最终结论：上下文错误已修复，GitHub 服务端接受工作流，真实 macOS ARM64 云端构建成功，Artifact 已下载并核验。此结论仅覆盖固定版本 Swift library 的构建，不证明抖音接口可用。

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

## 发布记录

以上检查通过后，仅暂存以下两项并普通提交/推送默认分支 main：

```text
.github/workflows/doustudio-macos-build.yml
docs/DOUSTUDIOKIT_GITHUB_ACTIONS_BUILD_01_FIX_REPORT.md
```

提交信息：`fix(ci): resolve runner temp context validation`。修复提交及实际受测 SHA：`7a3328c1d7c00677ffd4c60c0ae253ef40103c9e`。推送前核对远端仍为指定基线，普通推送成功，随后 HEAD 与 origin/main 一致。云端运行结束后仅补充本报告；工作流内容未再次修改。

## 服务端与实际云端验证

- GitHub 工作流 ID：`396583252`；API 返回 state=active，名称为 `DouStudioKit macOS Build Check`；远端工作流文件 SHA-256 与本地一致。
- [Actions 工作流页面](https://github.com/achusonwork-bit/doustudio-runtime-acceptance/actions/workflows/doustudio-macos-build.yml)显示 Run workflow。在已登录 Chrome 中选择 main 并手动触发；API 确认 event=`workflow_dispatch`。
- [运行 40264063807](https://github.com/achusonwork-bit/doustudio-runtime-acceptance/actions/runs/40264063807)，attempt=1，status=completed，conclusion=success；受测 SHA 为上述修复提交。原 `Unrecognized named-value: 'runner'` 校验错误不再出现。
- 运行时间：2026-10-26 11:26:08 至 11:26:50（Asia/Shanghai），共 42 秒。build job ID `121382468729`，11:26:14 至 11:26:49，共 35 秒。
- 请求运行器 `xcode-27`，实际镜像 `xcode-27-arm64`，镜像版本 `20261023.0307.1`。运行器启动及全部执行步骤成功。
- 实际检出上游 SHA：`362dad3d082e9f63c8efd360acc653ba169d40a2`，与固定值一致，校验退出码 0。

| 实际环境或命令 | 结果 |
| --- | --- |
| macOS | 27.0.1，Build 26A434 |
| Swift | Apple Swift 6.4，swiftlang-6.4.0.34.1；swift-driver 1.168.6 |
| Xcode | 27.1，Build 27A9275 |
| uname -m | arm64 |
| 环境记录退出码 | 0；四个环境命令均为 0 |
| swift package dump-package | 退出码 0；stderr 为空；产品为 library，平台 macOS 27.0，toolsVersion 6.0.0，dependencies 为空 |
| swift build -c debug | 退出码 0；原始日志结尾为 `Build complete! (14.20 sec)` |

未启动 library 作为命令行程序，未修改 Package.swift、平台要求或上游 Swift 源码。

## Artifact 与原始证据

- [Artifact 12625073020](https://github.com/achusonwork-bit/doustudio-runtime-acceptance/actions/runs/40264063807/artifacts/12625073020)：`doustudio-macos-build-evidence-40264063807-1`。
- ZIP 大小 2592 字节；SHA-256：`9f89250243edc6b1b4b676ca6b3378180dd176efd0674d0699f1c2045a4ab099`，与发布摘要一致；ZIP CRC 校验通过。
- 保留 3 天；API 到期时间为 2026-10-29 03:26:46 UTC，即北京时间 11:26:46。
- 已解压核验恰好 12 个白名单文件：expected-commit.txt、actual-commit.txt、verify.log、verify-exit-code.txt、environment.log、environment-exit-code.txt、dump-package.json、dump-package.stderr.log、dump-package-exit-code.txt、build.log、build-exit-code.txt、step-outcomes.txt。
- 四个阶段退出码均为 0，六个已记录步骤 outcome 均为 success；未上传环境变量全集、凭据或其他项目文件。

本地证据保存在 `D:\Projects\doustudio-runtime-acceptance\.git\task-validation\fix01-run-40264063807\`：`run-summary.json`、`jobs.json`、`artifacts.json`、原始 `job-121382468729.log`、`artifact.zip`、解压后的 `artifact\` 和逐文件哈希验证结果 `artifact-verification.json`。这些证据保存在 Git 元数据目录内，不暂存、不推送。云端日志中的认证值由 GitHub 掩码，本任务未读取个人令牌或使用用户配置的 GitHub Secrets。

## 最终 Git 变更范围

本次仅变更 `.github/workflows/doustudio-macos-build.yml` 与本报告。构建后的报告补充仅修改本报告。已有未跟踪 RUN 报告仍保留，最终核验 SHA-256 与基线一致，未纳入提交。没有改动其他本地项目或代理配置；没有强制推送或重写历史。

## 最终验收状态

```ini
WORKFLOW_CONTEXT_ERROR = FIXED
LOCAL_VALIDATION = PASS
GITHUB_SERVER_VALIDATION = PASS
WORKFLOW_DISPATCH = AVAILABLE
MACOS_RUNNER_START = PASS
PACKAGE_MANIFEST = PASS
SWIFT_BUILD = PASS
ARTIFACT = PASS

DOUYIN_API_TEST = NOT_RUN
VIDEO_DOWNLOAD = NOT_RUN
RUST_IMPLEMENTATION = NOT_STARTED

ROOTNETSCOPE_CHANGED = NO
VIDEOFLOW_CHANGED = NO
UPSTREAM_SOURCE_CHANGED = NO
FORCE_PUSH = NO
```

## 规则核验来源

[GitHub Context availability 官方表](https://docs.github.com/en/actions/reference/workflows-and-actions/contexts#context-availability)区分了 job env、step env、step if 与 step with 的上下文可用范围。本轮按该表修复工作流，并以上述真实 GitHub 运行和 Artifact 验证服务端接受及编译结果。
