# DOUSTUDIOKIT_REAL_DOWNLOAD_INTEGRATION_01

本轮只验证受控本地服务器上的集成路径。真实下载门禁不变，未读取真实 DOUYIN_COOKIE，未发起抖音作品列表或媒体请求。

- 仓库：`D:\Projects\doustudio-runtime-acceptance`
- 初始 main：`6ea41a4c3e66ce3430fbf23cdb44f2902a30fc1d`
- 固定上游：`362dad3d082e9f63c8efd360acc653ba169d40a2`
- 既有传输基线：https://github.com/achusonwork-bit/doustudio-runtime-acceptance/actions/runs/40285479553
- 新工作流：`.github/workflows/doustudio-download-integration.yml`，名称 `DouStudioKit Download Integration Tests`。

## 复用与调用链

共用 `runtime-harness/safe-streaming-tests/Package.swift` 和同一个 SafeStreamingTransport 源文件；没有复制或修改传输实现。源文件 SHA-256：`2456887e7982c92bef429760900f46f37d2663835becf3daa2128b2131202ab1`。

新增文件均位于该包内：

- `Sources/SafeStreamingTests/IntegrationPolicy.swift`：主页授权、索引、视频类型、单下载单元、精确主机策略；仅连接 loopback 的列表 fixture adapter。
- `Sources/SafeStreamingTests/DownloadIntegration.swift`：单请求列表到下载、校验与清理的集成 Harness。
- `Sources/SafeStreamingTests/IntegrationMedia.swift`：AVAssetWriter 生成 MP4；文件、哈希、MP4 box、视频轨道与 AVAssetReader 实际解码验证。
- `integration_server.py`、`run_integration_tests.py`：本地服务器与真实 Swift 进程编排，不模拟 Swift 验收结果。
- `validate_integration.py`：Windows 上的语法、白名单、范围和保护检查。

原有 ControlledTests.main 只新增两个受控入口：`--integration-fixture` 和 `--integration-case`。入口不接受主页、媒体 URL、Cookie 或生产主机参数，只接受固定用例 ID、临时目录和本地端口；没有打开真实下载的开关。

实际链路：原版 `DouyinClient.init` → 原版 `endpoints.accountTimeline(secUid:tab:page:)`，`count=18/maxPages=1/cursor=0/maxRetry=0` → `IntegrationListTransport` 验证原版生成的端点和参数，并将网络请求严格替换为本地合成列表 → 原版 `DouyinExtractor.work(from:collectionTime:)` → `IntegrationPolicy.select` → 空 Cookie 的独立 `SessionStore` → 原版 `Downloader.download(work:progress:)` → 原有 `SafeStreamingTransport` → 原版 `.part` 写盘和移动 → `IntegrationMedia.validate` → 独立工作区清理。

原版源码依据：`Collect/DouyinClient.swift:57` 构造和注入；`Networking/DouyinAPI.swift:288` accountTimeline；`Parsing/DouyinExtractor.swift:74` work 与 video 分类；`Download/Downloader.swift:168` 注入；`Download/StreamingDownloader.swift:23` progress 下载入口及流式 transfer。未调用高层 downloadLink/downloadWork/collectAccountBatched/QualityProbe，避免额外详情、探测或分页请求。原版签名流程只用于本地合成请求的组装，未逆向或改写签名逻辑，签名参数不转发给本地服务器、不写日志。

## 凭据与主机边界

模拟凭据只使用源码内固定的非认证 fixture 字符串；原版 Client 显式传入该字符串，避免上游从环境读取 DOUYIN_COOKIE。只有列表 fixture 端点收到模拟 Cookie。媒体 Downloader 使用新的空 Cookie Session。Evidence 只记录 `credential_present` 等布尔状态，不记录凭据长度、摘要、认证头或完整请求/媒体 URL。

生产媒体主机白名单为空，`HOST_ALLOWLIST_AUDIT=BLOCKED`。本轮没有可独立核验的实际媒体主机证据，不能根据域名后缀或服务商名称推断可信。精确 HTTPS 白名单逻辑用不联网的固定 `fixture.invalid` 进行正反例测试；通过不表示任何真实 CDN 主机获得批准。成功网络测试仅允许 `http://127.0.0.1:<本轮端口>/media/<固定用例ID>`，这是独立受控 fixture 范围，不能退回生产路径。

新工作流仅 workflow_dispatch、xcode-27、contents:read、20 分钟、checkout 不持久化凭据、官方 Actions SHA 固定、Artifact 保留 3 天。没有 inputs、Secrets 引用、自动重试或自动触发。测试进程在只允许 localhost 的 macOS sandbox 内运行，子进程环境只传必要目录和固定测试参数。

## 完整性与字节预算

合成有效视频由 AVAssetWriter 编码为 64×64、30 帧 H.264 MP4。下载后必须满足：原版 downloaded 单文件结果；独立目录中的非符号链接普通文件；非空且不超过 104857600 bytes；写盘量等于接受量；两次 SHA-256 一致；ftyp/moov/mdat 顶层 box 长度有效；AVFoundation 读取视频轨道并实际输出图像帧；reader 完整结束。测试有效样本还要求解码 30 帧。ftyp 标记或 HTTP 200 不构成完整性 PASS。

损坏 mdat 用例保留容器结构和轨道信息，破坏压缩帧数据，必须解码失败。HTML、JSON、假 ftyp、截断容器、空文件分别被拒绝。Downloader 返回成功但媒体验证失败时，Harness 仍判定失败，并删除完整和不完整文件。

沿用 delegate_received_bytes、accepted_bytes、written_bytes、cancel_requested、cancel_completed。历史实测 delegate 可接收 101 MiB，而应用接受/写盘受 100 MiB 限制。本轮继续 `STRICT_NETWORK_RECEIVE_LIMIT=NOT_PROVEN`，不修改历史超收说明。所有下载异常路径显式请求取消并等待真实完成回调；清理仅限本轮创建的独立 UUID 目录。AVFoundation 校验错误同样清理，无自动重试。

## 用例清单

| ID | 验证内容 |
|---|---|
| INT-001 | 原版 Client、Extractor、Downloader、Transport 完整链路与 30 帧解码 |
| INT-002 / 003 | 负数索引 / 等于实际列表长度的越界索引 |
| INT-004 / 005 | Extractor 提取图集 / 实况多媒体并拒绝 |
| INT-006 | 明确标注的损坏模型 fixture：视频出现两个下载单元则拒绝 |
| INT-007 | 空列表不能选择作品 |
| INT-008 / 009 | 未审核媒体主机 / URL userinfo 拒绝 |
| INT-010 / 011 | HTML / 伪装成视频的 JSON |
| INT-012 / 013 | 假 ftyp / 截断 MP4 |
| INT-014 | 容器和轨道存在但压缩帧损坏，解码必须失败 |
| INT-015 | 101 MiB chunked 超限、取消与 .part 清理 |
| INT-016 / 017 / 018 | 空响应 / 中断 / 超时 |
| INT-019 | 调用方取消与完成回调、残留清理 |
| INT-020 | 第一次完整下载后第二次媒体请求拒绝 |
| INT-021 | 不规范主页在列表请求前拒绝 |
| INT-022 | 精确 HTTPS 主机策略、后缀欺骗和生产空白名单 |
| INT-023 / 024 | 列表 403 / 429 立即停止，不触发媒体 |
| INT-025 | 第二次列表请求拒绝 |
| INT-026 | 媒体 302 重定向拒绝，不到达目标 |
| INT-027 / 028 | 无授权 / 无模拟登录态，在任何请求前停止 |

所有网络用例都核对服务器实际列表/媒体请求数、媒体端无凭据和 Range、无缓冲回退、完成回调、取消后不再接受数据、清理结果。每例独立 Swift 进程保存真实退出码。Artifact 仅白名单中的 10 个诊断文件，不含媒体、原始 API JSON、Cookie 或完整媒体 URL。服务器发送量是 payload 成功写出计数，不是网络包级接收证明。

## 验收记录

本地 Python、YAML、Shell 语法和保护检查通过，详见 `evidence/doustudio-real-download-integration-01/local-validation.json`。Windows 没有 Swift/actionlint，未安装或虚构运行结果。247 个既有文件中，仅受控测试 main 新增入口；原 Transport、Package.swift、全部既有工作流、原匿名/认证/分页 Harness、历史证据及未跟踪 RUN 报告不变。

真实 macOS 编译、集成结果、运行 URL、Artifact 哈希将在实际运行后填写。

```ini
TASK = DOUSTUDIOKIT_REAL_DOWNLOAD_INTEGRATION_01
ORIGINAL_EXTRACTOR_INTEGRATION = NOT_RUN
ORIGINAL_DOWNLOADER_INTEGRATION = NOT_RUN
SAFE_STREAMING_INTEGRATION = NOT_RUN
HOST_ALLOWLIST_AUDIT = BLOCKED
MEDIA_DECODE_FIXTURE = NOT_RUN
APPLICATION_BYTE_BUDGET = NOT_RUN
STRICT_NETWORK_RECEIVE_LIMIT = NOT_PROVEN
INTEGRATION_TESTS = NOT_RUN
REAL_DOUYIN_DOWNLOAD = NOT_RUN
REAL_MEDIA_INTEGRITY = NOT_VERIFIED
NO_WATERMARK = NOT_TESTED
RUST_IMPLEMENTATION = NOT_STARTED
UPSTREAM_SOURCE_CHANGED = NO
ROOTNETSCOPE_CHANGED = NO
VIDEOFLOW_CHANGED = NO
```

## 仍然阻塞真实下载的条件

1. 用户未授权改变严格网络接收限制的保证范围，当前 URLSession 方案不能保证网络接收绝对不超过 100 MiB。
2. 实际媒体主机尚未独立审核，生产白名单为空。
3. 本轮没有授权真实 Cookie、真实作品列表或媒体请求；旧单视频工作流继续固定失败关闭。

本轮完成后停止。即使所有受控集成用例通过，也不代表真实媒体完整性或无水印通过。
