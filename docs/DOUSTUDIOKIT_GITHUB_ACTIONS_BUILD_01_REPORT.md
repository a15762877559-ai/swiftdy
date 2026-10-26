# DOUSTUDIOKIT_GITHUB_ACTIONS_BUILD_01_REPORT

检查日期：2026-10-26（Asia/Shanghai）。本轮仅准备并静态检查 GitHub Actions 工作流。

## 结果与限制

两个交付文件已创建，38 项本地静态检查全部 PASS。没有执行 macOS 编译，没有提交、推送或触发 Actions。静态 PASS 不代表云端构建成功，更不代表抖音接口可用。

- 本地仓库：`D:\Projects\doustudio-runtime-acceptance`
- GitHub 仓库：<https://github.com/achusonwork-bit/doustudio-runtime-acceptance>
- 默认分支：GitHub 仓库元数据返回 `main`；分支列表为空，远端尚无提交。初始化的本地分支为 `main`，HEAD 尚未指向任何提交。
- 工作流：`.github/workflows/doustudio-macos-build.yml`
- 工作流名称：`DouStudioKit macOS Build Check`
- 运行器：`xcode-27`，GitHub 官方文档列出的标准 macOS ARM64 运行器；本轮没有调度运行器或验证实际镜像。
- 上游：<https://github.com/qinjian0420/DouStudioKit>
- 固定提交：`362dad3d082e9f63c8efd360acc653ba169d40a2`

## 本地环境、认证与仓库检查

| 检查 | 实际结果 |
| --- | --- |
| Git | `git version 2.45.1.windows.1`；`C:\Program Files\Git\cmd\git.exe` |
| GitHub CLI | PATH 及常见安装位置未找到 `gh`，不能执行 `gh auth status`；未安装 CLI、未进行登录 |
| GitHub 连接器 | 当前账号为 `changyaodong122-cell`；可读目标公开仓库；仓库权限返回 `pull=true`、`push=false`、`admin=false` |
| CLI 认证状态 | `UNAVAILABLE`；连接器的读访问不能视为本机 CLI 已登录，也不能证明后续可推送 |
| 原本地目录 | 不存在，没有已有文件或用户改动需要覆盖 |
| 克隆尝试 1 | 禁用 Git credential helper，匿名 HTTPS 克隆失败：`Recv failure: Connection was reset` |
| 克隆尝试 2 | 匿名 HTTPS、HTTP/1.1 克隆失败：`Failed to connect to github.com port 443 after 21095 ms: Couldn't connect to server` |
| 本地准备方式 | API 确认远端 `size=0` 且分支列表为 `[]` 后，执行 `git init -b main` 并设置同一 GitHub URL 为 `origin`。本地仓库可用于准备文件，但不是成功克隆；未下载或重建远端历史 |
| Actions 是否启用 | **UNVERIFIED**。连接器不支持 Actions permissions 端点；匿名 REST GET `/repos/achusonwork-bit/doustudio-runtime-acceptance/actions/permissions` 返回 HTTP 401。不能据此判断启用或禁用，下一阶段需要仓库所有者确认 |
| actionlint | 未安装，未执行；未将 YAML 解析冒充 actionlint 或 GitHub 服务端验证 |

未读取个人令牌、Cookie 或凭据文件。连接器使用已有连接进行只读查询；本地克隆明确禁用了 credential helper。未为本任务安装 `gh`，未更改全局 Git 配置。

## 工作流完整检查

| 要求 | 结果 | 实现或证据 |
| --- | --- | --- |
| YAML 语法 | PASS | PyYAML 6.0.3 解析，额外拒绝重复键；使用 BaseLoader 保留 `on` 键，避免 YAML 1.1 布尔转换 |
| 工作流名称 | PASS | 精确匹配任务指定名称 |
| 手动触发 | PASS | 唯一事件为 `workflow_dispatch`；没有 push、PR、schedule、workflow_call 或其他事件 |
| 运行器 | PASS | 精确为 `runs-on: xcode-27` |
| 权限 | PASS | 顶层仅 `permissions: contents: read`，无 job 覆盖 |
| 超时 | PASS | 唯一 job 设置 `timeout-minutes: 20` |
| 上游检出 | PASS | `actions/checkout` 的 repository 为 `qinjian0420/DouStudioKit`，路径为 `upstream` |
| 提交锁定 | PASS | checkout ref 与预期 SHA 均固定为完整 40 字符 SHA；未使用 main/latest |
| 禁止凭据持久化 | PASS | `persist-credentials: false`；关闭 submodules 和 LFS |
| 实际 HEAD 校验 | PASS（静态） | `git rev-parse HEAD` 与固定 SHA 比较；不一致则保存结果并失败，后续编译跳过 |
| 系统与工具链 | PASS（静态） | 依次记录 `sw_vers`、`swift --version`、`xcodebuild -version`、`uname -m` 及各命令退出码 |
| manifest 检查 | PASS（静态） | 在 upstream 内执行 `swift package dump-package`，分别保存 stdout JSON、原始 stderr 和退出码 |
| debug 构建 | PASS（静态） | 在 upstream 内执行 `swift build -c debug`，保存合并 stdout/stderr 的原始日志和退出码 |
| 失败传播 | PASS（静态） | 命令后立即记录 `$?`，最后 `exit "$status"`；无 continue-on-error、无 `|| true` |
| 未执行状态 | PASS（静态） | 初始退出码为 `NOT_RUN`；前置失败时，后续步骤跳过，不能误报构建成功 |
| 步骤定位 | PASS（静态） | `always()` 汇总 evidence、checkout、verify、environment、dump-package、build 的 outcome |
| Artifact | PASS（静态） | 官方 upload-artifact；`always()`；名称含 run_id/run_attempt；`retention-days: 3`；缺文件时报错；不包含隐藏文件 |
| 上传范围 | PASS | 只列出 12 个证据文件路径，不上传源码、`.git`、`.build`、环境变量或任意目录通配内容 |
| 外部 Actions | PASS | 仅使用下表两个必要官方 Actions，均为已通过官方仓库 tag API 核实的完整提交 SHA |
| 凭据与 Secrets | PASS | 未配置个人 token、SSH key 或任何 `secrets.*`；未读取或转储凭据/环境变量 |
| 运行时行为 | PASS | 没有 swift run/test、签名调用、抖音请求、媒体下载、部署、git add/commit/push 步骤 |
| 上游不可修改 | PASS | 无 Package.swift 编辑、平台降级或源码补丁；库只编译、不启动 |
| Shell 语法 | PASS | 6 个 run 脚本全部通过本机 Git Bash `--noprofile --norc -n`；只解析，未运行脚本 |
| actionlint | NOT_RUN | 本机未安装 |
| GitHub 服务端校验与 macOS 编译 | NOT_RUN | 未上传、未调度 |

本地验证器共 38 项断言通过。验证所需 PyYAML 6.0.3 从官方 PyPI 配置来源取得 wheel（pip 使用本机缓存），仅安装到本仓库 `.git/task-validation/pylibs`，未安装到系统 Python 或修改其他项目。验证器为 `.git/task-validation/validate.py`，不属于上传文件。可在本仓库使用 `python .git/task-validation/validate.py` 重复静态检查。

工作流文件 SHA-256：`FFC1AB9EDE27C272E9E4B21361EE112F176E7A08A1EE91F6F05A9D97B71ADE50`。

| 官方 Action | 固定版本 | 工作流中的不可变引用 |
| --- | --- | --- |
| actions/checkout | v7.0.1 | `actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1` |
| actions/upload-artifact | v7.0.2 | `actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9` |

checkout 默认使用 GitHub 为 job 自动生成的短期 `github.token`，受 `contents: read` 限制；未传入个人认证令牌，也不需要用户配置任何 GitHub Secrets。上传 Artifact 使用官方 Action 的运行时认证。工作流不转储这些值。

## 云端证据设计及失败边界

Artifact 仅包含实际存在的以下文件：

```text
expected-commit.txt
actual-commit.txt
verify.log
verify-exit-code.txt
environment.log
environment-exit-code.txt
dump-package.json
dump-package.stderr.log
dump-package-exit-code.txt
build.log
build-exit-code.txt
step-outcomes.txt
```

checkout 失败时，其原始错误保留在 GitHub Actions 自身步骤日志；Artifact 记录失败的 outcome。manifest 或 build 失败时保留对应原始输出，失败步骤保持失败。尚未执行的后续阶段标记为 skipped/NOT_RUN，不伪造退出码。`always()` 尝试在失败后上传证据，但 runner 丢失、job 被强制取消或 20 分钟超时等情况下不能保证最终上传完成，应检查 GitHub 保留的步骤日志。

固定提交的 Package.swift 已只读检查：`swift-tools-version: 6.0`，产品为 `.library`，平台为 `.macOS("27.0")`，无第三方 SPM 依赖或 build plugin 声明。没有将 library 当作 CLI，也没有执行上游业务代码。若平台或工具链不支持，下一阶段应保留错误并判定实际失败，不修改上游源文件、不降低平台要求。

## 文件变更及 Git 状态

准备结束时的状态：

```text
## No commits yet on main
?? .github/workflows/doustudio-macos-build.yml
?? docs/DOUSTUDIOKIT_GITHUB_ACTIONS_BUILD_01_REPORT.md
```

只新增上述两个可提交文件。未暂存；没有提交 SHA、没有提交或推送。`.git` 内另外保存初始化元数据、origin 配置和本地验证工具，均不应上传。

没有读取、复制或修改 `D:\Projects\zhuabao` 的内容、Git 状态或历史证据；没有修改 RootNetScope、VideoFlow、DouStudioKit 上游源码或任何其他本地项目。

## 后续上传与手动触发说明（本轮均未执行）

先由用户确认进入 `DOUSTUDIOKIT_GITHUB_ACTIONS_BUILD_01_RUN`。下一阶段需恢复本机 GitHub 网络连接，使用对目标仓库有写权限的认证方式，并确认仓库 Settings → Actions → General 已启用 Actions 且允许所用官方 Actions。当前连接器账号没有 push 权限，不能凭本报告直接认定上传可行。

以下是待用户确认后使用的上传命令，明确暂存仅两个文件，不使用 `git add .`。执行前再次检查远端是否仍为空；若已有提交，应先读取并整合远端历史，不强推。

```powershell
Set-Location 'D:\Projects\doustudio-runtime-acceptance'
git status --short --branch --untracked-files=all
git ls-remote origin
# 确认远端状态和写权限后，再执行：
git add -- .github/workflows/doustudio-macos-build.yml docs/DOUSTUDIOKIT_GITHUB_ACTIONS_BUILD_01_REPORT.md
git diff --cached --check
git diff --cached --stat
git commit -m "ci: prepare pinned DouStudioKit macOS build check"
git push -u origin main
```

工作流进入默认分支后，可在目标仓库 Actions → DouStudioKit macOS Build Check → Run workflow，选择 `main` 并手动运行。若下一阶段已安装并登录具有相应权限的 `gh`，等效命令为：

```powershell
gh workflow run doustudio-macos-build.yml --repo achusonwork-bit/doustudio-runtime-acceptance --ref main
```

提交或推送本身不会触发此工作流。只有下一阶段读取真实云端步骤日志和 Artifact 后，才能给出编译 PASS/FAIL；无论编译结果如何，都不代表抖音 API 或媒体下载已验证。

## 最终状态

`LOCAL_REPOSITORY = READY` 仅表示本地空仓库和交付文件已准备好，不表示网络克隆成功或具备远端写权限。

```ini
TASK = DOUSTUDIOKIT_GITHUB_ACTIONS_BUILD_01
TARGET_REPOSITORY = achusonwork-bit/doustudio-runtime-acceptance
LOCAL_REPOSITORY = READY
GITHUB_AUTH = UNAVAILABLE
WORKFLOW_CREATED = YES
WORKFLOW_VALIDATION = PASS
UPSTREAM_COMMIT_PINNED = YES
MACOS_RUNNER = xcode-27
CLOUD_BUILD = NOT_RUN
DOUYIN_API_TEST = NOT_RUN
VIDEO_DOWNLOAD = NOT_RUN
ROOTNETSCOPE_CHANGED = NO
VIDEOFLOW_CHANGED = NO
UPSTREAM_SOURCE_CHANGED = NO
GIT_COMMIT = NO
GIT_PUSH = NO
```

补充：`ACTIONS_ENABLED = UNVERIFIED`；`ACTIONLINT = NOT_RUN`；`CLONE = FAILED_NETWORK`；连接器只读访问可用，`GITHUB_AUTH` 指所要求的本机 CLI 认证。

## 核验来源

- [GitHub 标准 runner 官方说明](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
- [目标仓库元数据](https://api.github.com/repos/achusonwork-bit/doustudio-runtime-acceptance)
- [目标仓库分支列表](https://api.github.com/repos/achusonwork-bit/doustudio-runtime-acceptance/branches)
- [固定提交的 Package.swift](https://github.com/qinjian0420/DouStudioKit/blob/362dad3d082e9f63c8efd360acc653ba169d40a2/Package.swift)
- [checkout v7.0.1 官方 tag](https://api.github.com/repos/actions/checkout/git/ref/tags/v7.0.1)
- [upload-artifact v7.0.2 官方 tag](https://api.github.com/repos/actions/upload-artifact/git/ref/tags/v7.0.2)
- [checkout 固定版本输入定义](https://github.com/actions/checkout/blob/3d3c42e5aac5ba805825da76410c181273ba90b1/action.yml)
- [upload-artifact 固定版本输入定义](https://github.com/actions/upload-artifact/blob/cf430e030ddbb5b0abf93d22962f4752f3646cd9/action.yml)
