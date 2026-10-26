# DOUSTUDIOKIT_MEDIA_HOST_LIVE_PROBE_01

2026-10-26，Asia/Shanghai。项目已迁移至 `a15762877559-ai/swiftdy`，本地路径不变。**最新离线运行 40319014923 已成功：macOS Swift 编译 PASS、原有 83/83 fixture PASS、新增 12/12 策略断言 PASS、19/19 受控 HTTP 用例 PASS。** 受测提交 `106bc0681898450d34fac803015802af35233114`。Windows Python 84/84 PASS。真实列表请求、真实媒体探测和视频下载仍为 NOT_RUN，生产白名单仍为空。

下文保留准备、首次失败及迁移时点记录；最新验收证据和状态以末节为准。用户已配置新仓库 DOUYIN_COOKIE，助手只核验 Secret 名称存在，未读取内容；离线工作流完全没有注入该 Secret。

## 环境恢复与历史核验

项目在 `D:\Projects\doustudio-runtime-acceptance`。该目录原先不存在，本轮从 `achusonwork-bit/doustudio-runtime-acceptance` 新克隆；Git 2.45.1.windows.1、Git Credential Manager 2.5.0 已安装，GitHub CLI 未安装。重新 fetch 后，本地 main、origin/main 均为 `a683ce1cd80eb714c453aed79c43de2b0a8b426a`，ahead/behind=0/0，开始时工作区干净。无需 stash，没有覆盖用户工作。

用户完成 GitHub 登录后，API 验证当前账号为 `a15762877559-ai`，该账号对目标仓库的 push 权限为 false。最终提交/推送情况记录在本文末节和 `publication.json`，不将公开克隆成功视为写权限验证通过。没有读取浏览器凭据或输出认证令牌。

已逐一阅读用户指定的五份报告及对应证据，区分报告中历史准备记录与最新实测结论：

| 已有能力 | 核验结果 |
|---|---|
| 登录态作品列表 | PASS，真实认证列表证据存在 |
| 连续三页分页 | PASS，21/17/18，共 56 条唯一作品；不是全部作品采集完成 |
| SafeStreamingTransport 受控测试 | 运行 40285479553，28/28 PASS |
| 原版 Extractor → Downloader 受控集成 | 运行 40289436585，28/28 PASS，合成视频实际解码 30 帧 |
| 最新真实选中地址来源关联 | 运行 40299734675，21/21 PASS，未匹配 0 |
| 实际选中主机 | sf11-cdn-tos.douyinstatic.com：1 条；www.douyin.com：20 条 |
| 生产主机批准/真实视频下载 | 批准 0，白名单为空；下载 NOT_RUN |

最新主机观察的 published-evidence-index 中 **23 个文件的 Git blob SHA-256 全部匹配**。Windows 换行转换后的工作副本不冒充原始 Artifact 字节。上述结果是历史证据复核，没有重新请求抖音。搜索 docs、Harness、workflows 后未发现本任务旧实现，故新增此独立功能。

## 复用与变更

只修改一个既有文件：`runtime-harness/Sources/RuntimeAcceptance/RuntimeAcceptance.swift`，增加三个明确入口。`--media-host-live-probe` 位于已有 OFFLINE_ONLY 拦截之后；两个测试入口只允许合成数据或 loopback。既有匿名/认证/分页模式及其工作流不变。

新增源码和编排：

- `runtime-harness/Sources/RuntimeAcceptance/MediaHostLiveProbe.swift`：原版选择复用、单字节 URLSession delegate、在线一次列表编排、脱敏证据。
- `runtime-harness/Sources/RuntimeAcceptance/LiveProbeSelfTest.swift`：12 个纯策略断言、受控网络 fixture 入口。
- `runtime-harness/live_probe_tests.py`：19 个独立 Swift 进程、受控 HTTP 服务器、服务端次数/头部核验。
- `runtime-harness/live_probe.py`：授权、构建/测试门禁、最小子进程环境、证据检查和哈希清单。
- `runtime-harness/test_live_probe.py`：22 项本机 Python 边界及 loopback 服务器检查。
- `runtime-harness/validate_live_probe.py`：YAML/Shell/Python 静态检查、既有文件保护和历史证据哈希核验。
- `.github/workflows/doustudio-media-host-live-probe.yml`：真实探测手动入口。
- `.github/workflows/doustudio-media-host-live-probe-offline.yml`：无输入、无 Secret 的独立手动离线入口。

另外新增本文与 `evidence/doustudio-media-host-live-probe-01/`。完整文件清单见证据索引；只暂存显式任务路径。

原版 `DouyinClient`、`accountTimeline`、`AuthPreflightInput`、`AuthPreflightTransport` 负责授权和一次列表，count=18/maxPages=1/cursor=0/maxRetry=0，不调用详情、QualityProbe 或下载器。复用 `SelectedHostEvidence.collect/associate` 的结构预算和精确来源关联，再调用原版 `DouyinExtractor`；只选择 kind=video、恰好一个 media 单元、与原版选中地址逐字符串相等且符合精确主机策略的作品。按列表顺序每个主机取第一个符合条件的地址；无符合条件地址则阻塞，不自行构造、不改选备用 CDN，也不复用历史地址或签名。

SafeStreamingTransport 的既有 100 MiB 下载/MP4 前缀契约不适合一字节响应，本轮完全不修改它。新增 delegate 仅用于受控探测，不实现第二套作品提取器、下载器或生产媒体传输。沿用既有 ephemeral 会话、禁止跳转、无凭据、真实终态回调和脱敏输出机制。

## 请求与停止边界

探测范围独立于生产批准白名单，只允许 HTTPS 的两个精确主机：`sf11-cdn-tos.douyinstatic.com`、`www.douyin.com`。拒绝其他主机、后缀伪装、userinfo、非 443 端口、fragment、不规范主机和非 HTTPS。每个主机最多一个任务，总共最多两个；没有符合条件作品的主机不补充请求。

媒体 URL 仅保留在进程内存中。媒体请求从空 URLRequest 重建，固定 GET、`Range: bytes=0-0`、`Accept: video/*`、`Accept-Encoding: identity`；不从原版客户端复制任何头部。独立 ephemeral URLSession 禁用 Cookie storage、自动 Cookie、credential storage、cache 和代理字典；HTTP 认证挑战取消，TLS 使用默认系统信任校验。DOUYIN_COOKIE 只传给列表客户端，不进入媒体请求。没有读取其他 Cookie、要求用户重新提供 Cookie、输出凭据长度/摘要或保存凭据。

206 要求规范 `Content-Range: bytes 0-0/N`、正整数总长、video/*、无非 identity 编码；声明 Content-Length 时必须为 1。只接受一个恰好一字节的回调，不保留字节内容，随后立即取消。大于预算的回调直接拒绝；取消后来的回调只累加 delegate_received_bytes，不再接受。迟到数据若使 delegate 总数超过一字节，结果明确归类 BODY_BUDGET_EXCEEDED。

200 忽略 Range、HTML/JSON、错误范围、403、429、认证挑战、其他状态、空体和网络错误都停止。301/302/307/308 及其他 3xx 从不跟随，只存状态和经过既有主机规范检查的目标主机；无法安全规范化只存拒绝布尔值。目标路径、签名、完整 Location 不落盘。相对目标只在内存解析，不访问。异常停止整个运行，不再探测第二个主机；重定向属于已完成的诊断观察，可以继续另一个已选主机，仍不访问重定向目标。

取消后等待 `didCompleteWithError`，记录发起、终态回调及取消完成状态；cancel_completed 表示发起取消后已经收到任务终态，不代表内核缓冲瞬间清零。每次请求超时 15 秒，resource 超时 20 秒；没有应用重试、续传或缓冲回退。服务端计数用例会检查真实到达请求数。媒体文件、.part、响应正文、完整媒体 URL、真实 ID、标题和签名均不保存。既有列表传输沿用原响应缓冲语义，不宣称列表响应有一字节预算。

**应用接受量最多一字节，不保证 delegate/URLSession/操作系统实际接收量绝对不超过一字节。** 一字节配合视频类型响应头仅能识别“视频类型的 Range 响应”，不能验证完整视频、可播放性或无水印。不会因 206 或主机探测成功而批准生产主机。

## 离线验证状态

Windows 实际执行：`python -B -m unittest discover -s runtime-harness -p test_*.py -v`，**80/80 PASS**；其中本任务 22 项。新增检查包括无授权/缺凭据/控制字符时不启动、失败或过期离线结果阻止在线入口、最小子进程环境、日志丢弃、超时不重试、零退出无有效证据拒绝、取消未完成拒绝、超量/重复请求证据拒绝、生产白名单禁止自动批准、URL/签名/凭据/真实格式 ID 脱敏拒绝。两个 Windows loopback 检查验证 Python 受控服务器的 206 和 308 fixture，**不能替代 Swift 的网络行为测试**。

YAML 结构、manual-only、xcode-27、contents:read、固定完整 Actions SHA/上游 SHA、Secret 单点隔离、25 文件 Artifact 白名单、Python 语法及 bash -n 通过。actionlint 未安装，NOT_RUN。没有安装 Swift 或将 Windows 检查冒充 Swift 编译。

准备的 Swift 离线验证：原有 83 项 fixture；新增 12 个原版选择/精确主机/拒绝备用地址策略断言；19 个独立进程网络用例。用例包括 206 正确范围、200 忽略范围、四种重定向、相对/不安全跳转、HTML、JSON、403、429、401 挑战、错误范围、编码、空体、断开、超量回调及第二次请求拒绝。每例核对实际服务端次数、无认证头、Range 唯一、应用量≤1、取消后的终态，并检查没有媒体或 .part。策略用例运行于 deny network 沙箱；网络用例仅放行 literal 127.0.0.1。以上新增 Swift 用例本轮全部 **NOT_RUN**。

构建和全部离线结果、ID 完整性及源码指纹通过后，真实入口才读取既有 Secret。两个工作流均仅 workflow_dispatch，20 分钟，checkout 不持久化凭据，固定上游 `362dad3d082e9f63c8efd360acc653ba169d40a2`，诊断保留三天。Secret 只在真实工作流最后的在线步骤注入；编译/测试没有 Secret。在线子进程 stdout/stderr 丢弃。Artifact 只包含显式 JSON、状态和无凭据编译/测试日志；先脱敏、校验，再上传并生成 SHA-256 清单。当前本地要求的主机/响应/跳转 JSON 保留空数组，表示本次无观察，绝不把历史主机信息填成新探测结果。

## 保护和下一步

基线 392 个跟踪文件中只修改入口文件且仅新增分支。上游未检出或修改；既有 SafeStreamingTransport、10 个旧工作流、历史报告和证据全部不变。RootNetScope、VideoFlow、系统代理、v2rayN 和 Git 全局配置没有修改。没有 reset --hard、强推、删除旧证据或触发任何 Actions。

发布后先由用户手动运行 [DouStudioKit Media Host Live Probe Offline Tests](https://github.com/a15762877559-ai/swiftdy/actions/workflows/doustudio-media-host-live-probe-offline.yml)。它没有输入或 Secret，不能访问抖音。若编译/用例失败，根据其脱敏诊断修复并重新验证，不将准备状态升级为通过。

取得真实 macOS 编译和离线 PASS 后，另由用户决定是否手动运行 [DouStudioKit Media Host Live Probe](https://github.com/a15762877559-ai/swiftdy/actions/workflows/doustudio-media-host-live-probe.yml)，输入有权访问的规范公开主页并明确勾选授权；原仓库的 DOUYIN_COOKIE Secret 不会迁移；新仓库当前未配置该 Secret，未来真实运行前须由用户在新仓库 Actions Secrets 设置中添加，不要在聊天或代码中提供。该工作流会再次验证当前源码的编译和离线结果，再进行一次列表及最多两次受控探测。助手本轮不触发这两个工作流，不运行真实网络测试或下载。

```ini
PREPARATION = READY_FOR_MACOS_VALIDATION
WINDOWS_STATIC = PASS
WINDOWS_PYTHON_TESTS = 80/80 PASS
MACOS_SWIFT_BUILD = PASS_TESTED_106BC06
SWIFT_OFFLINE_TESTS = PASS
REPAIRED_RUNNER_MACOS = PASS
REAL_WORKLIST_REQUEST = NOT_RUN
REAL_MEDIA_PROBE = NOT_RUN
REAL_VIDEO_DOWNLOAD = NOT_RUN
STRICT_NETWORK_RECEIVE_LIMIT = NOT_PROVEN
PRODUCTION_ALLOWLIST = EMPTY
APPROVED_HOSTS = 0
NO_WATERMARK = NOT_TESTED
RUST_IMPLEMENTATION = NOT_STARTED
AUTO_TRIGGERED = NO
```

## 首次向原仓库发布的历史记录

准备代码、报告和初始证据已普通提交：`9a3a7e48f3dbd354c88050f9dbedf45bdbb37988`。随后仅补充本文、发布状态和对应证据哈希，不改变受测 Python 或待验证 Swift 源码。两次普通推送（第二次仅临时使用 HTTP/1.1）均返回 `Recv failure: Connection was reset`，未发布。

推送后重新使用 GitHub API 核验：远端 main 仍为 `a683ce1cd80eb714c453aed79c43de2b0a8b426a`；当前账号仍为 `a15762877559-ai`，push 权限仍为 false。故即使连接恢复，也需要先切换到有写权限的账号或由所有者授权。没有创建 fork、绕过权限或强推。工作流链接是预定发布入口，推送成功前不能视为 GitHub 已登记。

下一步先处理该账号的仓库写权限与 GitHub HTTPS 连通性，然后在项目目录执行普通 `git push origin main`。成功发布后才能按上一节先手动执行独立离线工作流。两项待处理状态分别为 `PUSH=NOT_COMPLETED`、`MACOS_VALIDATION=NOT_RUN`；不会将本机准备完成写成整项探测验收完成。


## 迁移发布时状态（历史）

用户提供新空仓库 `https://github.com/a15762877559-ai/swiftdy`，当前认证账号 `a15762877559-ai` 对它具有写权限。先核对远端无任何 refs，再将原 origin 改名为 upstream，新增 origin 指向用户仓库；没有覆盖远端已有工作、创建 fork 或强推。main 正常推送并设置跟踪 origin/main，全部既有历史及准备提交均保留。

Git HTTPS 连接中断的原因已定位为 Windows 系统代理与 Git 默认路由不同。本轮仅在 Git 命令中通过 `-c http.proxy=http://127.0.0.1:7890` 沿用已有 Windows 代理；没有修改系统代理、v2rayN 或 Git 全局/本地代理配置。采用该路由后普通 push 成功。

发布后 GitHub API 与本地 origin/main 均核对为 `492ff0d8115c8897b6f10a0c9d86762895e5eeb7`，ahead/behind=0/0、工作区干净。后续当前收尾提交只更新本文、publication.json 和 evidence-index.json，再普通推送，不修改 Swift/Python/workflow 源码。最终同步状态另由命令核验。

- 独立离线工作流 ID：396987395，state=active。
- 真实探测工作流 ID：396987397，state=active。
- 新仓库 Actions 运行总数：0；助手没有 dispatch、重试或执行真实列表/媒体请求。
- 新仓库 DOUYIN_COOKIE：未配置。旧仓库 Secret 无法自动迁移，也未读取其内容。
- macOS Swift 编译及新增 Swift 离线测试仍为 NOT_RUN；工作流登记不是编译或验收通过。

下一步由用户先打开上文更新后的独立离线工作流，选择 Run workflow/main。该流程无输入、无 Secret，只运行本机合成策略和 loopback HTTP 用例。收集编译/离线证据并通过后，再单独配置新仓库 Secret、决定是否手动授权真实探测。当前不执行任何真实探测、完整下载或主机批准。


## 用户首次手动离线运行 40317689736 与启动器修正

[实际运行](https://github.com/a15762877559-ai/swiftdy/actions/runs/40317689736)，attempt=1，受测提交 `4396f848028fa932a97d56cfcf08621c28808521`。job=121554319401，最终 failure，失败步骤是受控 Swift HTTP 测试；编译、原有 fixture、收尾检查和诊断上传均 success。环境 macOS 27.0.1 (26A434)、Swift 6.4、Xcode 27.1、arm64，上游固定 SHA 核验通过。

- build-exit-code=0，macOS 编译 PASS。
- baseline-exit-code=0，原有通用/认证 38、主机 20、优先证据 25，共 83/83 PASS。
- policy-tests.json 的 12 个原版地址选择与精确主机策略断言全部 true。
- offline-exit-code=1，未生成 offline-tests.json 或第一例已发布观察。不能把 95 个已通过断言等同整套 HTTP 测试通过，也不能认定任何一个真实媒体探测成功。
- 工作流无 Secret 注入、真实请求为 0；新仓库缺少 DOUYIN_COOKIE 与本次离线失败无关。

Artifact ID 12647213914，ZIP SHA-256 `490d6650317b9f8bc764b0540c39da2a0e29812edba12ad202307b9a3b6c83ad` 与 GitHub digest 一致；ZIP CRC、23 文件白名单及清单中 22 个文件哈希全部通过。原 Artifact 字节保存在 `evidence/doustudio-media-host-live-probe-01/run-40317689736/`，另附 jobs、GitHub 元数据和核验结果，不覆盖原运行证据。

启动器诊断缺陷：旧版本丢弃 Swift stderr，结果文件不存在时只输出固定笼统失败，故现有 Artifact 不足以单独证明该子进程失败的具体系统原因。源码比较发现新启动器没有复用已验收集成测试的完整 loopback 沙箱配置，缺少 network-bind 许可，且离线子进程未传 HOME。本次改为既有受控集成工作流相同的 localhost-only inbound/outbound/bind 规则，并只为离线子进程补充 HOME；fixture 的实际目的地址仍为 literal 127.0.0.1，没有放开外网。是否解决 macOS 失败仍需实测，不能提前标记根因已证实修复。

同时补充固定安全诊断：即使结果文件缺失，也在 offline-tests.json 记录用例 ID、子进程退出码、服务端实际请求次数和失败类别。stderr 只在内存中分类，不能原样写盘；超时/无法启动同样记录失败并停止，不重试。新增四项 Windows 回归核对 loopback 沙箱范围、原始 stderr 不落盘、缺失观察证据可归档、超时不重试。本机全套 Python **84/84 PASS**，其中本任务 26 项；静态检查通过。仅改 `live_probe_tests.py`、`test_live_probe.py` 及本任务报告和证据，Swift、SafeStreamingTransport、真实入口与全部工作流未改。

下一步：修正代码推送后，请用户重新打开独立离线工作流，选择 Run workflow/main，启动新提交的运行；不要使用 Re-run jobs 重跑旧 SHA。当前没有自动 dispatch 或 retry，没有真实列表、媒体请求、完整下载或生产主机批准。修正后的 macOS 运行仍为 NOT_RUN。


## 最新真实 macOS 离线验收：40319014923 PASS

[成功运行](https://github.com/a15762877559-ai/swiftdy/actions/runs/40319014923)，attempt=1，受测提交 `106bc0681898450d34fac803015802af35233114`，job=121558853881。用户已启动该运行；随后用户要求 run 时，助手发现同一提交的离线运行正在进行，因此复用并监测，没有重复 dispatch，也没有重试旧运行。

macOS 27.0.1 (26A434)、Swift 6.4、Xcode 27.1、arm64；固定上游 SHA 与干净状态核验通过。build/baseline/offline 退出码全部 0，所有 GitHub job 步骤 success。测试如下：

- 原有通用/认证 38、主机 20、优先证据 25，共 83/83 PASS。
- 原版选中地址、精确主机、非 HTTPS/userinfo/端口/后缀伪装拒绝及不改选备用地址，12/12 策略断言 PASS。
- 19/19 独立 Swift/URLSession 网络进程 PASS，逐例退出码均为 0。
- 206 正确范围实际收到并接受 1 字节，发起取消并收到任务终态；第二次调用被拒绝，服务端仍只有一次请求。
- 200 忽略 Range、HTML/JSON、403/429、错误范围、编码响应、认证挑战均拒绝；应用接受 0 字节并完成取消。
- 301/302/307/308 和相对/不安全目标均不跟随；服务端验证没有跳转目标请求。只保存合规目标主机或拒绝布尔值。
- 超量 chunked 用例：delegate_received_bytes=65536，accepted_bytes=0，BODY_BUDGET_EXCEEDED，cancel_requested=true、cancel_completed=true。严格网络接收一字节上限依旧 NOT_PROVEN，不能因应用量为 0 而改写。
- 空体及断开连接正确判定失败，任务已经自然终止，cancel=false/false 是正常结果，不伪造取消完成。
- 所有网络用例服务端实际请求数符合一次限制，Range=bytes=0-0，没有 Cookie/Authorization/其他受检认证头；没有重试、续传、媒体或 .part 文件。

Artifact ID 12647952399，ZIP SHA-256 `78f41b73bd3183355d8a3b9b44ea822d61f84341703f7ce7a67a185026578532` 与 GitHub digest 一致。ZIP CRC、25 文件精确白名单和 runner 清单内 24 个文件哈希全部通过。另从受测提交的 Git blobs 重算 macOS 源码指纹，与 offline-source.json 完全匹配；未使用 Windows 换行字节冒充 macOS 源码。原 Artifact 字节归档在 `evidence/doustudio-media-host-live-probe-01/run-40319014923/`，另附 jobs、GitHub 元数据和核验结果；首次失败的 run-40317689736 完整保留。原始编译日志中的 ANSI 和尾部空格不为通过 diff --check 而篡改。

修正后的 loopback 启动配置已获得实测成功，完整受控离线验收通过。本次只新增报告/证据，不改受测 Swift/Python/workflow 源码。没有依据此结果批准主机，也没有进行真实媒体请求或下载。

用户声明并由 API 名称列表确认：新仓库现在存在 DOUYIN_COOKIE。只记录是否存在，不读取 Secret 内容、长度、摘要或其他派生标识。离线工作流没有引用 Secret，不能把这次离线 PASS 当作真实 Cookie 有效、真实媒体可响应或下载通过。

当前任务的准备、Windows 验证、macOS 编译和完整离线验证均已完成。后续真实探测须用户另行手动打开 [DouStudioKit Media Host Live Probe](https://github.com/a15762877559-ai/swiftdy/actions/workflows/doustudio-media-host-live-probe.yml)，输入本人有权访问的规范主页并明确勾选授权；一次列表、最多两个精确主机各一次 Range GET，不跟随重定向、不下载完整视频。助手在本轮归档后停止，不自动运行该流程。
