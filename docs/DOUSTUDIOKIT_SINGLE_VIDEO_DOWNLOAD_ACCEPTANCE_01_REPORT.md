# DOUSTUDIOKIT_SINGLE_VIDEO_DOWNLOAD_ACCEPTANCE_01

2026-10-26，Asia/Shanghai。**下载前置检查 BLOCKED，尚未执行真实媒体 GET。** 这是安全门禁未满足，不是已经证实“视频下载失败”。固定版本具有实际下载实现，但现有路径不能保证本任务要求的 100 MiB 接收硬限制、及时取消、禁止重定向和失败清理。按停止规则，不读取 Cookie、不采集主页、不尝试下载。

## 基线及范围

- 本地 `D:\Projects\doustudio-runtime-acceptance`；仓库 [achusonwork-bit/doustudio-runtime-acceptance](https://github.com/achusonwork-bit/doustudio-runtime-acceptance)。开始时本地/远端 main 都为 `cad5049a343a719ab63c8a2ecdf096c856b7994f`。
- 固定上游 `362dad3d082e9f63c8efd360acc653ba169d40a2`，本地只读源码副本 HEAD 核对一致。
- [分页基线 40279553152](https://github.com/achusonwork-bit/doustudio-runtime-acceptance/actions/runs/40279553152) 已通过三页、56 条唯一作品验收。PAGINATION=PASS 仅引用该历史结果，本轮没有分页。
- 既有全部源码、五个工作流及历史证据不变；本轮只新增独立审计门禁、工作流、测试、报告及证据。196 个原文件哈希不变，其中含原有未跟踪 RUN 报告，该报告不暂存。未修改其他项目、Git 全局配置、系统代理或 v2rayN。

## 源码调用链

下列位置均来自固定 SHA 的本地源码，文件哈希及 Git blob 一致性另存于证据；不是根据名称推测。

| 层次 | 源码位置及实际行为 |
| --- | --- |
| 列表 | `Networking/DouyinAPI.swift:288`，`DouyinEndpoints.accountTimeline` 调用原 `PaginatedCollector.collect`，返回 `AccountTimeline.works` 原始 JSONNode |
| 字段映射 | `Parsing/DouyinExtractor.swift:71`，`work(from:collectionTime:...)`；`classifyVideo` 第 164–168 行从 `selectBitrate` 选 URL，写入 `work.downloads=[.media(url:...)]`；第 184–216 行从 bit_rate 的 play_addr 或 video.play_addr 的 url_list 取值 |
| 下载单元 | `Download/Downloader.swift:185`，`download(work:)`；第 237 行 `plannedUnits(for:)` 遍历所有下载目标，`.media` 一项对应一个 DownloadUnit。它本身不是“一条文件上限”，图片/实况可扩为多文件 |
| 缓冲入口 | `Downloader.download(work:) → downloadUnit`（第 262 行）→ `HTTPTransport.send`（第 309 行）→ `URLSessionTransport.send`（`Networking/HTTPTransport.swift:89`）→ `session.data(for:)`（第 114 行）。响应体完整 Data 返回之后才进入下载器状态检查/写文件 |
| 流式入口 | `Download/StreamingDownloader.swift:23`，`Downloader.download(work:progress:progressInterval:)` → 第 103 行 `downloadUnitStreaming` → 第 187 行 `transfer` → `StreamingHTTPTransport.stream`。仅 progress 重载走该分支；若传输不符合流式协议，第 155–163 行回落为整段缓冲 |
| 流式生产端 | `Networking/StreamingTransport.swift:84`，`URLSessionTransport.stream` 创建独立 ephemeral URLSession；私有 `StreamDelegate.start` 第 160–161 行调用 `session.dataTask(with:)` 和 `task.resume()`，第 234–239 行在 didReceive data 回调中 yield Data |
| 高层重载 | `Collect/DouyinClient.swift:201` 的 downloadWork(id:) 会先请求详情；第 227 行 download(work:progress:) 在 preferOriginalQuality=true 时也可能请求详情及质量探测。未来受控入口应避开额外详情/探测，直接用首次列表提取的一项视频和原 Downloader 的 progress 重载 |
| 现有 Harness | `RuntimeAcceptance.swift:107–114` 取候选作品，调用 `client.downloader.download(work:)`，所以仍是缓冲入口。ObservingTransport 只符合 HTTPTransport，并不实现 StreamingHTTPTransport |

## HTTP、类型、落盘和失败行为

- 缓冲下载器第 314–318 行在完整响应后接受任意 2xx；非 2xx 的上游异常会嵌入正文前 200 字符，不能原样输出。第 333 行 atomic 写 `.part`，第 340–351 行 sniff 或回落 URL 扩展名后 move 到最终目录。没有把 HTML/JSON、空文件、不能解码的 MP4 全部作为失败拒绝；sniff 未命中也可使用提示扩展名，不能把 `.downloaded` 当作媒体验证。
- 流式 `transfer` 第 196–200 行检查 2xx，第 206–214 行创建或打开 `.part`，第 228–235 行先写 chunk 再累计 received。第 267–273 行对声明了 total 的短传输报错，并检查取消；第 286–289 行 Content-Type 只用于扩展名映射，不是严格媒体类型门禁。
- 流式入口第 21–22、229–230 行明确保留部分文件供续传；defer 仅关闭 FileHandle。异常没有保证删除 `.part`。缓冲路径在发送失败时通常还未写入，但已有续传文件、写入/移动失败也没有统一失败清理保证。
- `DownloadLayout.tempDirectory`（Downloader.swift:97）为 root/temp，最终目录在同一 root 下。未来必须将 root 显式设为 runner.temp 下独立目录，退出时清理这个目录；本轮没有创建媒体目录或部分文件，清理记为 NOT_NEEDED_NO_TRANSFER，不能记成“下载中断清理已验证”。
- `Networking/SessionStore.swift:236–243` 的 downloadHeaders 会在 Cookie 非空时加入 Cookie，并设置 `Range: bytes=0-`。该 Range 没有上界。不能直接向不经验证的媒体主机传递登录态；未来媒体边界需明确不转发凭据及禁止重定向。

## 100 MiB 门禁审计

1. **旧限制在收完以后。** ObservingTransport.send 第 155 行先 await base.send；第 175 行才比较 `response.body.count <= 100 * 1024 * 1024`。它限制交给下载器的已缓冲结果，不能限制实际接收量。
2. **原流式实现没有字节预算。** `StreamDelegate.didReceive(data:)` 只 yield，没有接收计数、阈值或超限 cancel。流只在消费端检查/停止，无法保证生产端同步停止，不能用进度回调里的文件大小替代接收硬上限。
3. **取消控制不可从原公开返回值取得。** `StreamingHTTPTransport.stream`（第 66–75 行）只返回 head 和 AsyncThrowingStream；原 delegate 私有，任务仅是 start 内局部变量，未设置把流终止连接到 dataTask.cancel 的 onTermination/取消处理。不能从现有 wrapper 保证在超限后及时停止底层接收。
4. **流式禁止重定向参数未生效。** StreamDelegate.followRedirects 是 let，第 143 行固定 true；start 接收同名参数却未存储，重定向回调第 266 行使用属性。设置 options.followRedirects=false 不能据此保证流式不跟随重定向。此结论针对流式实现；普通 HTTPTransport 的 RedirectDelegate 正常保存 follow 参数。
5. **失败清理不满足。** 原实现有意保留 `.part`，并非本任务所需的失败删除行为。

因此 DOWNLOAD_IMPLEMENTATION_AUDIT=PASS 表示审计完成，**不表示原下载器通过安全验收**。DOWNLOAD_PREFLIGHT=BLOCKED、RECEIVE_BYTE_LIMIT=NOT_ENFORCED。没有通过 Range、Content-Length、进度回调或“收完后检查”绕过门禁。

## 最小后续方案（尚未实施/验证）

接口层面存在不改上游的扩展点：`Downloader.init(transport:session:layout:...)`（第 168 行）接受 HTTPTransport，progress 重载会识别 StreamingHTTPTransport。因此不能宣称“不修改上游就永远做不到”。但现有原传输不满足条件，仅套一层原 stream 的消费检查不足以形成接收硬限制。

最小候选方案是测试仓库提供独立的、直接持有 URLSessionDataTask 的 StreamingHTTPTransport，仍让原版 Downloader 完成写文件；在生产端实现字节预算、头部拒绝、超限取消、取消回执、超时与禁止重定向，限制一次媒体请求，避免无界队列和缓冲回退，并用临时目录级 finally 清理。对未知/虚假 Content-Length、chunked、突发大块、取消后排队回调、重定向和中断做真实 macOS 本地可控服务测试。

必须区分底层已到达的网络字节、交付给消费者的字节及写盘字节：delegate 回调收到 Data 时，这个块已到达；cancel 也不是内核缓冲立即清零的证明。只有实际测量并符合本任务接收限制口径后才可标 ENFORCED；若只能证明不写入超过 100 MiB，仍应 BLOCKED，不声称网络接收有硬上限。本轮不新建未经验证的替代传输后直接放行。

之后才能增加“一次第一页列表 → 校验索引 0 <= index < 实际数量 → kind=video 且恰好一个 .media → 一次原版 progress 下载 → 文件 SHA-256 两次一致 → 容器/轨道 → AVFoundation 或现有工具解码一帧”的路径。索引校验/解码/下载测试均不得用模拟结果冒充真实媒体验收。

## 独立工作流与离线检查

已新增 `.github/workflows/doustudio-single-video-download.yml`，名称符合任务要求，manual-only、xcode-27、20 分钟、contents:read、两个 checkout persist-credentials=false、固定上游与官方 Actions SHA，不改现有工作流。

**当前是审计失败关闭工作流，不是已开放下载的工作流。** 手动输入公开主页、0 起始作品索引及登录态授权；只检查格式，实际作品列表范围记 NOT_VERIFIED，不发请求。没有 Cookie 普通输入，没有 Secrets 注入步骤：在安全门禁通过前完全不读取登录态，不是改从其他渠道获取 Cookie；未来若开放仍只能使用仓库 DOUYIN_COOKIE。

工作流检查固定上游及 9 个文件哈希，运行 11 项 Python 门禁测试（macOS sandbox 禁网络），然后固定退出 78 / RECEIVE_HARD_LIMIT_NOT_VERIFIED；不调用旧在线 Harness。没有可由输入、环境或元数据打开的 bypass。失败后 always 上传 8 个白名单诊断文件，保留 3 天，无媒体/凭据/原始响应。工作流不编译或运行下载 Swift 路径；该路径在门禁前已阻塞，HARNESS_BUILD=NOT_RUN。

本地 11/11 门禁单元测试通过：授权/URL/索引格式、实际索引范围不伪造、环境不能解锁、两次调用均阻塞、无网络/子进程/媒体文件、凭据不读取、输入不落盘、元数据不能解锁、无网络依赖。这些测试只证明失败关闭，不是下载器回归通过。

| 要求的真实下载离线回归 | 本轮状态 | 原因 |
| --- | --- | --- |
| HTTP 非成功、HTML/JSON、空文件 | NOT_RUN | 未实现可放行的受限媒体传输 |
| 下载中断、超时、网络异常 | NOT_RUN | 不用 Python 模型替代 Swift 网络行为 |
| 超过 100 MiB 时取消 | NOT_VERIFIED | 核心接收取消机制不满足门禁 |
| 部分文件删除 | NOT_VERIFIED | 原实现保留续传文件；本轮未生成媒体 |
| 第二次下载拒绝 | BLOCKED_BEFORE_FIRST | 门禁拒绝第一次和后续所有调用，不等同“一次成功后拒绝第二次”的回归 |
| Artifact 白名单 | PASS | 静态检查 8 个显式诊断路径，没有目录通配/媒体/凭据 |

Windows 无 Swift/actionlint，未安装新工具；YAML、bash -n、Python 语法、9 文件源码哈希、保护检查通过。本轮 OFFLINE_SELF_TEST=NOT_RUN 专指完整下载回归，不能用 11 项门禁测试代替。

## 结果与停止

新真实下载运行链接、HTTP 状态、文件大小、媒体哈希均为 NOT_RUN；媒体工具未执行，MEDIA_DECODE=NOT_VERIFIED；NO_WATERMARK=NOT_TESTED。没有真实媒体 GET，也没有为了准备发出 HEAD、详情探测或作品列表请求。源码审计和本地证据位于 `evidence/doustudio-single-video-download-acceptance-01/`。

```ini
DOWNLOAD_IMPLEMENTATION_AUDIT = PASS
DOWNLOAD_PREFLIGHT = BLOCKED
RECEIVE_BYTE_LIMIT = NOT_ENFORCED
HARNESS_BUILD = NOT_RUN
OFFLINE_SELF_TEST = NOT_RUN
VIDEO_DOWNLOAD = BLOCKED
FILE_INTEGRITY = NOT_VERIFIED
MEDIA_DECODE = NOT_VERIFIED
NO_WATERMARK = NOT_TESTED
PAGINATION = PASS
RUST_IMPLEMENTATION = NOT_STARTED
UPSTREAM_SOURCE_CHANGED = NO
ROOTNETSCOPE_CHANGED = NO
VIDEOFLOW_CHANGED = NO
```

按任务停止规则，在接收硬限制没有实际验证的情况下停止真实下载。发布审计工作流后不自动运行；即使手动运行当前版本，也只会输出 BLOCKED，不会下载视频。
