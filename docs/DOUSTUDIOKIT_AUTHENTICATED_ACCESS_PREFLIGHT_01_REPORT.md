# DOUSTUDIOKIT_AUTHENTICATED_ACCESS_PREFLIGHT_01

2026-10-26，Asia/Shanghai。准备阶段：独立认证预检代码与工作流已创建，真实认证请求尚未触发。固定上游 `qinjian0420/DouStudioKit@362dad3d082e9f63c8efd360acc653ba169d40a2`，不修改上游。

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
- 新增 AUTH-001..018 Swift fixture 覆盖上述输入/请求边界、403/429/挑战/空列表/响应变更/重定向、原版客户端单页管线、匿名头拒绝、无媒体和无代理。原 OFF-001..019 保留，总计 37 项。
- Windows 无 Swift 和 actionlint，不安装工具，不冒充本地 Swift 运行通过。将使用已有独立离线工作流在禁止网络的沙箱中运行 37 项；只用合成 fixture，不注入真实 Secret，不触发认证预检。
- 真实 macOS 离线结果待补记；认证预检始终等待用户手动触发。

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
