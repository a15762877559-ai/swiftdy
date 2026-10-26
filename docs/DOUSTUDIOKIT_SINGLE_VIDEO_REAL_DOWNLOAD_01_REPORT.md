# DOUSTUDIOKIT_SINGLE_VIDEO_REAL_DOWNLOAD_01

2026-10-26，Asia/Shanghai。用户首次离线运行 **40336326372** 的 Runtime/共享模块和受控下载 executable 均编译 PASS，既有 Runtime/HTTP/重定向回归 PASS；后续旧传输 28 个子进程全部退出 2、无用例结果且服务端零请求，集成与新完整视频用例未开始。**整套 OFFLINE_TESTS=FAIL，真实下载 NOT_RUN。** 已修正新增编排的工作目录与测试目录身份校验、补充固定启动诊断和失败状态展示；修正版 Windows **119/119 PASS**，修正版 macOS 仍待用户手动运行。下文保留初始准备记录，最新诊断见末节。

## 基线与原版调用审计

- 当前目录 `D:\Projects\swiftdy`，origin 为 `a15762877559-ai/swiftdy`，旧仓库只保留为 upstream remote。
- fetch 后开始时 HEAD 与 origin/main 同为 `ad5c7c55f81a290c58378d7c30a54b6b04aaeaeb`，工作区干净，ff-only 无新提交。
- DouStudioKit 固定 `qinjian0420/DouStudioKit@362dad3d082e9f63c8efd360acc653ba169d40a2`，未修改上游。本轮只读核验该 SHA 的原版 Downloader 路径规划和单元展开；原版 `.media` 单元由已选 URL 驱动，目录使用 nickname，故新 Adapter 会清除命名身份字段。
- 上一阶段 40328292259 已证明本次授权列表链路可获得 www 302 → 精确下一跳有效 206，并通过公网 DNS/数字地址固定/默认 TLS。该运行只接受一字节，不构成完整视频证据。本任务不复用旧签名 URL，不追加真实探测。

实际完整路径为：原版 DouyinClient/accountTimeline（一次、18/maxPages=1/cursor=0/maxRetry=0）→ 原版 DouyinExtractor → 第一个合格普通视频的原版 www 地址 → 原 LiveProbeTask 的一次 Range 入口 GET、拒绝自动重定向 → 本次 Location 内存校验 → 原 RedirectNetworkSafety 重新检查 DNS → 原 PinnedProbeTunnel 连接一个已校验数字 IP → 空 Cookie SessionStore → **原版 Downloader.download(work:progress:) → 原 SafeStreamingTransport → 原版文件写入** → 容器/全片视频解码 → 删除临时文件。

确定性策略：按本次返回列表顺序，取首个 kind=video、恰好一个 media 下载单元、原版实际选中 URL 为精确 www 且来源匹配的作品。没有样本就停止，不换视频、不用备用 CDN、不取详情或第二页。所选列表索引可记录，真实作品 ID 不记录或哈希。

## 复用与最小适配

Runtime 的 Package.swift 新增内部 SafeDownloadSupport target，直接编译 `safe-streaming-tests` 中**同一份** SafeStreamingTransport、原容器/fixture helper 和新 Bridge；没有复制传输实现或下载器。旧受控 executable 仍编译同一批源文件。流式 SHA-256 函数抽为 StreamFileTools，原 ControlledTests.hash 委托它，原 IntegrationMedia 也使用它；算法仍为 64 KiB 分块。

SafeStreamingTransport 的修改仅增加可选、默认关闭的本次会话固定连接端口和诊断字段。数据回调预算/有界队列/取消/终态实现从 didReceive(data:) 至文件末尾与基线逐字相同，静态核验通过。旧传输在默认 nil 端口下的行为不扩大。本轮改动过的传输仍必须重新跑旧 28 个受控传输和 28 个原版集成用例，不能仅沿用历史 PASS。

新 Bridge 复制原版提取模型，在副本上将 media 地址替换为本次经审核的 Location；这是明确的 Adapter 注入点。将 id 设为固定 RUN-VIDEO-001，清空标题、签名、uniqueId 并设固定 nickname，避免真实 ID/标题进入原下载器的临时文件名；原模型和完整 URL 仍仅在内存。不是猜测或构造签名地址。

旧进度下载路径生成的无界 Range 被安全 Transport 移除，实际完整 CDN GET **不发送 Range**；不将 Range 当作流量上限。options.followRedirects 不决定安全边界，传输 delegate 始终拒绝 CDN 重定向。send() 始终拒绝缓冲回退，只有 stream() 可用，无自动重试或续传。

## 临时下载作用域与授权

只允许入口 www.douyin.com 和本次临时目标 v5-dy-ov-experiment.zjcdn.com。Location 必须是原始响应中的绝对 HTTPS、精确主机、标准端口、无 userinfo/fragment/控制字符。之后重新执行所有 DNS 结果公网检查并固定一个数字地址；通道只接受该 authority、只外连一次，不尝试其他 IP。URL 保留原 TLS 主机名，使用系统默认服务器证书验证，不接受自签证书或主机不匹配。网络校验和连接固定机制复用上一轮源文件，未修改。

媒体会话与授权列表分离，使用空 Cookie SessionStore 和全新 ephemeral URLSession，禁用 cookie/credential/cache 存储，不转发 Cookie、Authorization、Referer 或原请求头。临时集合只传给本次 Transport 实例，不写生产配置；approved-hosts 始终为空。

真实工作流必须同时确认 `authorized_own_session` 和 **`authorized_single_video_download`**；二者默认 false。第二项明确确认有权完整下载一条视频，并接受 100 MiB 应用预算及临时目标范围。只有全部旧/新离线门禁和源码 seal 通过才读取在线步骤中的 DOUYIN_COOKIE。之前的探测授权不会代替本次完整下载授权。助手本轮没有 dispatch 任何工作流。

## 字节、完整性和清理

MAX_MEDIA_BYTES=104857600。声明长度超限在响应头阶段拒绝；未知长度按既有流式接受量计数，超限取消；接受量和实际写盘量必须各 ≤100 MiB。delegate_received_bytes 独立记录，系统或 URLSession 可能超收，不宣称严格网络接收硬上限。原通道自有队列上限 2 MiB，不把该上限描述为整个系统内存上限。

200 必须通过原传输类型/编码检查；206 必须声明长度且 Content-Range 精确覆盖整个资源 `bytes 0-(N-1)/N`，单字节和部分片段拒绝。原允许的 video/mp4、video/quicktime、application/octet-stream 最终都须通过实际容器和解码；通用二进制类型不能单独证明视频。声明长度必须与接受量及文件量一致；未知长度需正常 HTTP 终态、完整 MP4/QuickTime 顶层 box 和全片视频解码共同提供完成证据。

文件必须是所属 UUID 目录下单一非符号链接普通文件、非空、≤100 MiB、大小=接受字节，两次流式 SHA-256 一致。复用 IntegrationMedia.verifyBoxes 检查 ftyp/moov/mdat 与顶层长度完整。新媒体检查记录时长、自然宽高、帧率和四字符编码，仅接受一个视频轨道及有界合理元数据，不记录标题等可识别元数据。

使用 AVAssetReader 实际输出像素缓冲并逐帧遍历全片视频轨道，检查 reader 完整结束、有效图像、时间戳和开头/中间/结尾时间覆盖。记录解码帧数、首尾时间、三段覆盖及 corruption_assessment，**不会把抽样或未完成的解码记为 FULL_DECODE=PASS**。全片检查有 180 秒/250000 帧上限；达到预算、取消或失败均不通过。媒体时长上限 2 小时、宽高≤8192、帧率 0<f≤240；不支持的输入失败关闭。音频轨道未解码，不声称全音视频轨道验收。

所有像素缓冲只在内存，不写截图。没有可靠水印画面证据，NO_WATERMARK 恒为 NOT_VERIFIED，不根据 URL、MIME、库说明或文件名认定无水印。

每次下载在 Runner 临时父目录下创建全新 video-UUID 目录，原版部分文件也只在其中。Bridge 在成功、失败、取消和解码错误后取消并等待实际传输终态，再移除该所属目录。外层 Python 在子进程退出/超时后再次核验并删除专属 `doustudio-single-video-media-UUID` 父目录；路径必须为 runner.temp 的直接子目录且非符号链接，不能删除任意路径。超时结果缺失时请求计数标为 null，不伪造零请求、取消完成或下载成功。硬性进程中止无法提供的 delegate 终态不冒充验证通过。

## 离线测试与当前状态

Windows 执行：`python -B -m unittest discover -s runtime-harness -p test_*.py -v`，**116/116 PASS，本任务新增 17 项**。新增验证独立下载授权、缺 Cookie/控制字符拒绝、必须通过两层前置门禁、子进程隔离、零退出无结果拒绝、超时不重试/未知计数、所属目录清理及拒绝无关目录、清理幂等、敏感值拒绝、禁止生产批准、请求次数、以及完整/部分 Range 和未知长度 chunked fixture 的真实 Windows loopback 响应。Windows fixture 检查不替代 Swift 或真实媒体解码。

YAML、workflow_dispatch、双授权、最小权限、固定上游/官方 Actions SHA、先测试后 Secret、Shell bash -n、50 个明确 Artifact 文件和保护范围检查 PASS。未安装 Swift/actionlint，macOS 新编译及新原生用例 NOT_RUN。

准备的原生离线门禁必须依次通过：

1. 原 Runtime 基线 83、老策略 12、老 HTTP 19、重定向策略 41、链路 25、固定通道 3。
2. 同一修改后 Transport 的原受控 ST 28 和原 Client→Extractor→Downloader 集成 INT 28。
3. 新选择策略 5 项、新原版 Downloader 全视频 fixture 16 项：完整 200、完整 206、未知长度成功、部分/单字节 206 拒绝、CDN 302 拒绝、HTML/JSON、损坏帧、损坏容器、空体、断开、声明预算超限、未知长度超限、原无界 Range 被移除后的完整 200，以及 SafeStreamingTransport 通过固定通道的默认 TLS 失败用例。

合成小视频复用原 AVAssetWriter（64×64、30 帧 H.264）。通过用例必须实际解码 30 帧、三段覆盖、全片 reader 完成、哈希一致、终态唯一、服务器一次请求且无认证/Range、无残留媒体/.part。损坏 mdat 构造也复用原 integration_server helper。旧超限/取消/超时/二次请求用例继续提供必要边界，不删除或降低断言。

离线测试服务和子进程只允许 loopback；生产 DNS 和 CDN 不在 fixture 范围。TLS fixture 用错误服务验证系统信任不可绕过，不冒充真实 CDN 的 TLS 成功。所有 fixture、媒体和旧受控工作空间在临时目录并清理，不进入 Artifact。

## 工作流与交付

- 真实入口：[DouStudioKit Single Video Real Download](https://github.com/a15762877559-ai/swiftdy/actions/workflows/doustudio-single-video-real-download.yml)。一次列表、一次入口、最多一次完整 CDN GET；默认不运行，必须双授权。
- 先运行：[DouStudioKit Single Video Real Download Offline Tests](https://github.com/a15762877559-ai/swiftdy/actions/workflows/doustudio-single-video-real-download-offline.yml)。无输入/Secret，不会请求真实作品或下载真实视频。

两个工作流均仅手动触发，xcode-27、30 分钟、contents:read、SHA 固定、checkout 不持久化凭据、诊断保留三天。完整下载和全片检查需要额外时间，因此新任务超时独立设为 30 分钟；旧工作流不改。

必需交付 JSON：download-summary、request-counts、download-budget、redirect-security、media-integrity、decode-results、cleanup-results、redaction-results、evidence-index；另保留 typed transfer 和旧/新回归诊断。敏感值检查作用于结构化字符串和整数，避免把高精度取消耗时误判成作品 ID。线上 stdout/stderr 丢弃；编译日志中的合成 URL 字面量脱敏。没有媒体、图片、音频、原始响应、路径、Cookie、签名、完整 Location 或作品真实 ID。历史兼容 probe-summary 是探测门禁占位，**本任务真实状态以 download-summary 为准**。

当前新运行链接及 Artifact 哈希为 NOT_RUN；登记工作流不等于编译或验收成功。发布状态另见 publication.json。本轮普通提交推送后停止，等待用户先运行独立离线工作流，再单独决定是否真实完整下载。

```ini
TASK = DOUSTUDIOKIT_SINGLE_VIDEO_REAL_DOWNLOAD_01
SWIFT_BUILD = NOT_RUN
OFFLINE_TESTS = NOT_RUN
REAL_WORKLIST = NOT_RUN
REDIRECT_RESOLUTION = NOT_RUN
REAL_VIDEO_DOWNLOAD = NOT_RUN
APPLICATION_BYTE_BUDGET = NOT_RUN
MEDIA_FILE_INTEGRITY = NOT_RUN
MEDIA_DECODE = NOT_RUN
FULL_DECODE = NOT_RUN
TEMP_FILE_CLEANUP = NOT_RUN
NO_WATERMARK = NOT_VERIFIED
PRODUCTION_ALLOWLIST = EMPTY
RUST_IMPLEMENTATION = NOT_STARTED
AUTO_TRIGGERED = NO
```

新增代码包括 Runtime 的 SingleVideoRealDownload/SingleDownloadSelfTest、共享 StreamFileTools/SingleVideoDownloadBridge、四个 single_download Python 脚本、两个新工作流及本任务报告/证据。既有跟踪文件只修改 Package.swift、RuntimeAcceptance.swift、SafeStreamingTransport.swift、ControlledTests.swift、IntegrationMedia.swift；不改上游、RedirectNetworkSafety、PinnedProbeTunnel、旧工作流、历史证据、VideoFlow、RootNetScope、系统代理、v2rayN 或 Git 全局设置。


## 发布核验

准备代码和初始证据已正常提交并推送：`ff4aed62a5d848599b5cbf41e73a749d50badcbb`。GitHub 已登记独立离线工作流 ID 397124262 和真实单视频工作流 ID 397124264，state=active，核验时各自运行数为 0。没有触发 Actions。后续收尾提交只更新本节、publication.json、注册元数据及证据索引，不变更待验证源码。

本任务仍停在阶段 A：Windows 116/116 PASS；新 Swift/macOS 构建与完整下载原生验收 NOT_RUN；真实列表、入口解析和完整 CDN 下载均 NOT_RUN。请先手动运行无 Secret 的 Offline Tests；全部通过后，另行手动选择真实工作流并完成双授权。此前单字节探测许可不作为本次完整下载许可。


## 首次 macOS 离线运行 40336326372 与启动诊断修正

[实际运行](https://github.com/a15762877559-ai/swiftdy/actions/runs/40336326372)，attempt=1，受测提交 `7e5e4b566c7e1db98328279ff60a7dd936a3b05c`，job=121618789595，最终 failure。Runtime/共享下载模块编译退出码 0，旧 SafeStreamingTests executable 编译退出码 0；原基线 83、老策略 12、老 HTTP 19、重定向策略 41、链路 25、通道 3 均 PASS。失败步骤是原传输/集成及新完整视频套件。

controlled-results 中 28 项全部 NO_SWIFT_RESULT、子进程退出码 2、服务端请求 0；这表示旧 CLI 在生成用例结果前已经失败，不是 28 个已运行下载场景都证明传输失败。集成 28、新选择策略 5、新完整视频 16 项均尚未开始。没有真实作品列表、入口或 CDN 下载。

原 CLI 的退出码 2 可能来自输入环境、workspace 预检或证据写入，但旧 Artifact 没有固定子类诊断，不能从当前证据单独认定哪一分支。本次源码修正：

- 新编排的隔离工作空间显式放到 runner.temp，沿用此前已验证套件的命名空间，不再默认落到 macOS /var 与 /private/var 可能出现别名的系统临时目录。
- 旧测试 CLI 的创建/删除边界统一比较解析符号链接后的规范父目录 path，避免 URL 对象的目录标志/别名差异导致身份误判；仍要求唯一新 UUID、不存在旧目录、真实父目录精确相同，不改网络范围或预算断言。
- 三种退出 2 分支增加固定无数据类别；编排只从旧日志提取这三个白名单字符串，不保存原始 stderr、路径、URL 或任意错误描述。
- 旧套件失败时也保存其清理结果，再拒绝门禁；不因失败提前丢失清理证据。
- 修正 summary 展示：执行后退出码非零的离线步骤标记 FAIL，不继续保留种子 NOT_RUN；SWIFT_BUILD 只有 Runtime 与受控 executable 两次编译均通过才为 PASS。

这些是工作目录/诊断/状态层修正，不降低任何下载断言。是否解决本次 macOS 启动故障仍需修正版实测；未宣称原因已完全复现或修复已通过 macOS。

Windows 修正版 **119/119 PASS**，本任务累计新增 20 项。新增回归验证 runner.temp 所属工作空间、失败套件保留清理和仅固定类别、成功编译但离线失败的正确状态。静态检查继续通过；SafeStreamingTransport 的数据/预算/取消/终态代码没有此次改动，真实入口与所有工作流不变。

Artifact ID 12655834700，ZIP SHA-256 `0b1ab0ad683b68c568fa63c770620990db62f73f94e15d8b9142d58b6281f718` 与 GitHub digest 一致；CRC、50 文件白名单及清单内 49 个文件哈希通过，源码 seal 与受测 Git blobs 一致。原始诊断位于 `evidence/doustudio-single-video-real-download-01/run-40336326372/`，另附 jobs/Artifact 元数据和验证记录；原始 download-summary 的 OFFLINE_TESTS=NOT_RUN 作为当次展示缺陷原样保留，不改写历史文件。根目录最新汇总则标记该次整套离线失败。

修正代码普通推送后，请用户在独立 Offline Tests 页面点击 **Run workflow/main** 测试新提交，不要 Re-run jobs 旧 SHA。修正版原生测试仍 NOT_RUN，当前不应运行真实下载流程。助手没有自动重跑、触发真实工作流或读取 Douyin Secret。
