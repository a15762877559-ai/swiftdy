# DOUSTUDIOKIT_AUTHENTICATED_ACCESS_PREFLIGHT_01

2026-10-26，Asia/Shanghai。准备阶段已通过：代码、工作流、本地 10 项测试和真实 macOS 38 项离线验收通过；真实认证请求尚未触发。固定上游 `qinjian0420/DouStudioKit@362dad3d082e9f63c8efd360acc653ba169d40a2`，不修改上游。

## 基线与范围

- 仓库 `https://github.com/achusonwork-bit/doustudio-runtime-acceptance`，本地 `D:\Projects\doustudio-runtime-acceptance`。
- 开始时本地 main 为 `3eca2de163d9ab3a429e78a54b8360718e838e38`，远端为 `643d1bd74813b5d527a9b6dd867bec5a6e1983f3`；本地领先两笔已完成的报告提交 `3d77ce3`、`3eca2de`，仅报告和证据。本次普通推送会一并发布，不重写历史。
- [匿名基线 40271383018](https://github.com/achusonwork-bit/doustudio-runtime-acceptance/actions/runs/40271383018)：编译、19 项离线检查、主页解析通过；作品列表首次请求 HTTP 403 / ACCESS_RESTRICTED。不能由此推断 Cookie 一定解决问题或签名错误。
- 原匿名工作流、原构建工作流、既有离线工作流、Observation.swift 匿名认证头拒绝逻辑和历史证据均受哈希保护。既有未跟踪 RUN 报告不纳入提交。

## 固定上游可用配置

`Collect/DouyinClient.swift` 第 55–77 行的公开构造函数接收显式 cookie、transport、logger；显式字符串优先于环境和账户配置。`Networking/SessionStore.swift` 在内存维护字符串，初始 snapshot 保留调用方 cookie。`Networking/DouyinAPIClient.swift` 第 139–160 行把该值作为 Cookie 请求头，maxRetry=0 不自动重试。

`Networking/HTTPTransport.swift` 的 URLSessionTransport 使用 ephemeral 配置，httpShouldSetCookies=false、httpCookieAcceptPolicy=.never，支持 followRedirects=false。复用这些原版实现，不复制签名/认证/请求参数构造，不修改网络底层。

## 独立模式和一次请求边界

- 默认 RuntimeAcceptance 仍执行原匿名路径并显式 cookie=""。只有 `--authenticated-preflight` 进入新入口；OFFLINE_ONLY=1 时仍拒绝一切在线入口。
- 新 AuthPreflightTransport 与原 ObservingTransport 分离。只允许 HTTPS、www.douyin.com、精确 `/aweme/v1/web/aweme/post/`，匹配已授权用户标识，且 max_cursor=0、count=18 各出现一次。
- 只允许与已授权内存值一致的唯一 Cookie 头；拒绝 Authorization、Proxy-Authorization、额外头、代理和其他端点。请求计数在 await 前占用，第二次发送永久拒绝。
- 原版 client.endpoints.accountTimeline(... PageRequest(count:18,maxPages:1,cursor:0))，maxRetry=0、maxConcurrency=1、preferOriginalQuality=false；不调用 collectAccountBatched、下载器或媒体探测，不发起第二页。
- 403/401/404/重定向归类 ACCESS_RESTRICTED，429 归类 RATE_LIMITED，HTML/非 JSON 挑战响应停止。错误只输出固定类别。HTTP 200 还须具有成功平台状态和有效 aweme_list；空列表记录真实 0 但不认定认证采集 PASS。
- 仅输出 HTTP 状态、开始/次数、列表合法性、数量和 ID/描述/发布时间/封面/视频字段的完整性计数，不输出作品值、完整 URL、请求头或异常正文。成功不能证明 Cookie 是唯一必要条件；NO 表示本次请求被拒绝，不等同于凭据必然无效。

## 凭据隔离与工作流

文件 `.github/workflows/doustudio-authenticated-preflight.yml`，名称 `DouStudioKit Authenticated Access Preflight`。仅 workflow_dispatch，xcode-27，20 分钟，contents:read，官方 checkout/upload-artifact 固定 SHA，persist-credentials=false；无定时/推送触发、自动重试或缓存。

仅两个输入：公开主页 profile_url（无默认值）和 authorized_own_session（默认 false）。未授权或主页格式不合法时初始化失败，后续步骤跳过。

**DOUYIN_COOKIE 仅来自仓库 Actions Secret，并且只在 One authorized authenticated preflight 步骤 env 中注入。** 构建、离线检查、初始化、汇总和 Artifact 步骤均不接收 Secret。该步骤运行前必须先通过离线检查。

Python 启动器再次校验授权、Secret 非空、无控制字符及主页格式；缺失时 credential_present=false，COOKIE_CONFIGURATION=MISSING，AUTH_PREFLIGHT=BLOCKED，子进程不会启动，任何抖音请求之前即关闭。这里的网络门禁指目标平台请求；GitHub checkout/上传 Artifact 是工作流基础设施通信，不携带该凭据。

通过检查后只向认证子进程传递必要环境变量，Cookie 不进命令行/GITHUB_ENV/文件。Shell 不启用调试，关闭 core dump；认证子进程 stdout/stderr 丢弃，上游 logger disabled，异常不打印。结果只含 credential_present 布尔值，不包含 Cookie 长度、摘要、哈希、名称列表或其他派生标识。未读取浏览器或其他应用 Cookie，也不检查 Secret 的真实值。

Artifact 保留 3 天，11 个显式路径：input-validation.json、environment.json、source-protection.json、stage-outcomes.json、build.log、build-exit-code.txt、offline.log、offline-exit-code.txt、selftest-results.json、auth-result.json、auth-exit-code.txt。没有目录通配符、媒体、缓存或原始响应；build/offline 日志在 Secret 注入前生成。

## 离线验证

- Windows 本地 Python 10 项测试 PASS：缺失/空白凭据、未授权、控制字符、非法主页、子进程环境隔离与静默输出、非零退出、假成功退出、异常文本抑制、初始化不持久化凭据。
- 工作流 YAML、bash -n、Python 语法、唯一 Secret 引用、11 文件白名单和 92 个受保护文件哈希检查 PASS。
- 新增 AUTH-001..019 Swift fixture 覆盖上述输入/请求边界、403/429/挑战/空列表/响应变更/重定向、原版客户端单页管线、匿名头拒绝、无媒体和无代理。原 OFF-001..019 保留，总计 38 项。
- Windows 无 Swift 和 actionlint，不安装工具，不冒充本地 Swift 运行通过。已使用已有独立离线工作流在禁止网络的沙箱中运行 38 项；只用合成 fixture，不注入真实 Secret，不触发认证预检。
- 真实 macOS 离线结果见下节；认证预检始终等待用户手动触发。

## 真实 macOS 准备验收与发布

- 初版代码提交 `5cd2d4858f173ad2c9ffc6be3ba1729f70cfc647`，[离线运行 40272545784](https://github.com/achusonwork-bit/doustudio-runtime-acceptance/actions/runs/40272545784) 为 37/37 PASS，证据保留。随后收尾审查补充无有效作品 ID 的拒绝条件和 AUTH-019 回归，没有放宽检查。
- 最终受测源码 `f3d716c93b8f61331626ae85444ea62c81f3c5c2`，[离线运行 40272761482](https://github.com/achusonwork-bit/doustudio-runtime-acceptance/actions/runs/40272761482)：38/38 PASS，编译 exit=0、自检 exit=0、在线入口保护 exit=64（符合预期）。该工作流未注入真实凭据，所有请求为内存 fixture，系统隔离 OS_SANDBOX_DENY_NETWORK。
- 实际环境：xcode-27、arm64、macOS 27.0.1 (26A434)、Swift 6.4 (swiftlang-6.4.0.34.1)、Xcode 27.1 (27A9275)。
- 最终 Artifact `12628594926`，7727 bytes，11 个白名单文件，保留 3 天；SHA-256 `8bf54ec56163dd73f680b88a6afdd0dd62465be95671b0349679b008de5e0919`、ZIP CRC 和源码哈希均核验通过；没有媒体和真实凭据。云端日志/环境/逐项结果/保护检查位于本轮 evidence 的 offline-run-40272761482/。
- GitHub 已接受新认证工作流，ID `396665634`，state=active，名称和路径正确；核验时认证工作流运行次数为 0。未读取 Secret 是否配置或其值，故 COOKIE_CONFIGURATION=NOT_RUN，不猜测 READY/MISSING。
- 凭据门禁的缺失/未授权测试来自本地合成输入，不能替代真实仓库 Secret 配置结果。原版客户端单页行为由 AUTH-015 在 macOS 使用原版请求管线加内存 Transport 验证，has_more=1 也只有一次 send。
- 92 个受保护文件哈希不变，所有既有工作流与原匿名 Observer 不变；本轮只修改独立 Harness 入口/自检、新增认证相关文件、工作流、报告和证据。未跟踪 RUN 报告原样保留。此前两笔报告提交已随首次普通推送发布，未强推。
- 最终收尾提交仅更新报告/证据，受测源码不再改动；完成后停止，不触发认证预检。

### 新增 Swift fixture 结果

原 OFF-001..019 全部 PASS；新增用例如下，详细预期/实际摘要见 selftest-results.json。

| ID | 检查 | 结果 |
| --- | --- | --- |
| AUTH-001 | Explicit consent | PASS |
| AUTH-002 | Missing secret | PASS |
| AUTH-003 | Header injection | PASS |
| AUTH-004 | Profile scope | PASS |
| AUTH-005 | One request and field counts | PASS |
| AUTH-006 | No credential forwarding to foreign host | PASS |
| AUTH-007 | No second-page cursor | PASS |
| AUTH-008 | Credential header boundary | PASS |
| AUTH-009 | 403 handling | PASS |
| AUTH-010 | Rate limit | PASS |
| AUTH-011 | Challenge body | PASS |
| AUTH-012 | Empty list | PASS |
| AUTH-013 | Response shape | PASS |
| AUTH-014 | Redirect rejection | PASS |
| AUTH-015 | Original client pipeline with memory fixture | PASS |
| AUTH-016 | Anonymous guard unchanged | PASS |
| AUTH-017 | No media endpoint | PASS |
| AUTH-018 | No proxy or extra headers | PASS |
| AUTH-019 | Work item identity | PASS |

## 用户后续操作

准备验收通过后，用户自行在目标仓库 Settings → Secrets and variables → Actions → Repository secrets 配置 `DOUYIN_COOKIE`，不要通过聊天、普通工作流输入或 Git 传递它。

随后用户手动打开新工作流、选择 main、填写有权访问的公开主页、勾选 authorized_own_session，再点击 Run workflow。代理不代填主页或触发认证测试。遇访问限制停止，不绕过、不重试。

```ini
AUTH_PREFLIGHT = NOT_RUN
COOKIE_CONFIGURATION = NOT_RUN
PROFILE_RESOLUTION = NOT_RUN
WORKLIST_FETCH = NOT_RUN
AUTHENTICATED_ACCESS_ACCEPTED = UNKNOWN
PAGINATION = NOT_RUN
VIDEO_DOWNLOAD = NOT_RUN
SIGNATURE_REVERSE_ENGINEERING = NOT_STARTED
RUST_IMPLEMENTATION = NOT_STARTED
```
