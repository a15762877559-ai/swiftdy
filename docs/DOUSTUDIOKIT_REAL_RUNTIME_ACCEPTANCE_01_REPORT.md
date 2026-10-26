# DOUSTUDIOKIT_REAL_RUNTIME_ACCEPTANCE_01

日期：2026-10-26（Asia/Shanghai）。当前阶段：独立 Harness 与工作流准备。用户已在本轮提供公开主页链接，未将其设为工作流默认值或写入仓库；仍等待用户在 Actions 页面手动输入并触发。尚未执行抖音网络请求、视频下载或新 Harness 的云端编译。历史构建通过不能替代本轮运行验收。

## 仓库和基线

- 测试仓库：https://github.com/achusonwork-bit/doustudio-runtime-acceptance
- 本地：`D:\Projects\doustudio-runtime-acceptance`，默认分支 `main`。
- 本轮开始时本地与远端 HEAD：`d1b6e336f028d224a54c77076cb133c09bb244c5`。
- 上游：`qinjian0420/DouStudioKit`，固定 `362dad3d082e9f63c8efd360acc653ba169d40a2`，本地只读检出并核对。
- [已通过的原版构建 40264063807](https://github.com/achusonwork-bit/doustudio-runtime-acceptance/actions/runs/40264063807)。该历史运行只验证 library 构建。
- 原有未跟踪 `docs/DOUSTUDIOKIT_GITHUB_ACTIONS_BUILD_01_RUN_REPORT.md` 保留且不提交。
- `.github/workflows/doustudio-macos-build.yml` 未修改，SHA-256 仍为 `2451d682512c8b94f5bcd9ae48f9273405387dc4c7b4841b5c66e8712fab9b94`。

## 固定源码的公开入口

源码证据、文件哈希和行号链接见 `evidence/doustudio-real-runtime-acceptance-01/entrypoint-analysis.json`。

| 能力 | 实际公开入口及数据流 |
| --- | --- |
| 产品 | Package.swift 仅发布 `DouStudioKit` library，没有可启动的 CLI；本仓库新增独立 executable package |
| 主页解析 | `LinkParser().parse(input)` → `DouyinLink.target` → `.user(secUid:modalWorkID:)`。从标准主页路径提取 sec_user_id；不展开短链，不请求主页 HTML |
| 客户端 | `DouyinClient(configuration:cookie:transport:logger:)`；显式传入空 cookie，防止继承 DOUYIN_COOKIE；maxRetry=0，logger disabled |
| 作品列表 | `client.endpoints.accountTimeline(secUid:tab:.post,page:PageRequest(count:18,maxPages:3,cursor:0))` → `AccountTimeline.works: [JSONNode]`，响应数据键为 aweme_list |
| 原版分页 | `PaginatedCollector.collect` 把服务端 max_cursor 赋给下一次请求游标，按 has_more 结束；原版 accountTimeline 返回时丢弃分页元数据 |
| 逐页观察 | 通过公开 HTTPTransport 接口包装原版 URLSessionTransport，仅记录允许字段并施加验收边界；不重建请求参数、不复制签名或采集器实现 |
| 字段解析 | 原版 `DouyinExtractor.work(from:collectionTime:)`；id、desc、createTimestamp/createTime、staticCover/dynamicCover、downloads 中的 `.media(url:)` |
| 下载 | 原版 `client.downloader.download(work:)`，返回 downloaded、skipped 或 partial；原版缓冲响应，写入临时 .part 后移动到 DownloadLayout 目录 |

发现的源码限制必须与真实测试结果分开：

1. `collectAccountBatched` 在 DouyinClient.swift 第 440–450 行附近按数量推断 hasMore，并返回 `startCursor + pages`，不是服务端游标。本 Harness 不调用该接口，保留原版源码不变。
2. 原版 `accountTimeline` 不直接暴露每页分页信息，所以由 Transport 观察真实响应，核验下一次实际请求是否使用上次返回的游标。不会自行推算。
3. 原版 Downloader 接受 2xx 响应，文件类型探测失败仍可用推测扩展名保存；不含完整视频解码验证。Harness 的响应、哈希与解码检查是额外验收保护，不能描述成原版已具备这些错误处理能力。
4. 匿名请求可能受到登录、验证码、风控或限流限制；源码注释不是实测结论。仅在用户手动触发后请求，遇限制立即停止。只调用原版请求管线，不逆向或修改签名，不获取身份凭据，不自动重试。

## Harness 设计

文件：`runtime-harness/Package.swift`、`runtime-harness/Sources/RuntimeAcceptance/*.swift`。

独立 SPM executable 通过 `../upstream` 依赖原版 library。工作流把上游检出到该位置并核验完整 SHA；平台要求保持 macOS 27.0。

- 输入只接受 `https://www.douyin.com/user/ID`，不含 query、fragment、用户名密码或其他主机；没有默认主页，不复用历史聊天中的链接。
- 手动输入确认 `authorized_public_content=true` 后才允许执行。原始输入从 GitHub event 文件读取，不拼接到 Shell；校验后加入 GitHub mask。
- 最多三页，每页请求 18 条；逐页记录请求游标、响应游标、作品数、累计数、去重数、重复数、has_more、游标有效性/停滞和错误代号。拒绝游标停滞、循环、分页字段缺失、空页却声称仍有下一页。
- 只有至少两页成功，才可能将 MULTI_PAGE_FETCH 和 PAGINATION_CORRECTNESS 标记 PASS。第一页即耗尽则 MULTI_PAGE_FETCH=BLOCKED、PAGINATION_CORRECTNESS=NOT_VERIFIED，并记录 SERVER_EXHAUSTED；不表示服务端故障。
- 字段证据保留字符串作品 ID，其余只记录描述是否存在/长度、时间和 URL 的有效性。图集不要求视频 URL，不下载图集。
- 最多选择一条单媒体视频，要求原始响应明确 `status.is_private=0`，未删除/禁止，媒体为 HTTPS 的 douyinvod.com 或 douyin.com 及其子域名。元数据不足或主机不在允许范围时记 BLOCKED。
- 下载经原版 Downloader 执行，额外限制为 HTTP 200、禁止重定向，拒绝 HTML/JSON、空内容、长度不符及非 MP4 头。100 MiB 大小检查发生在原版响应缓冲之后，**不是传输过程中的带宽上限**。
- 核对写入文件大小、SHA-256 与收到的响应一致，再使用 AVFoundation AVAssetReader 将完整视频轨道解码为 BGRA 帧，要求正常读到结尾且帧数大于 0。
- 无水印没有独立证据，一次下载/解码成功也仅能填 NOT_CONFIRMED。未运行时为 NOT_TESTED。
- 视频仅位于 runner.temp 下的专属媒体目录，Artifact 不包含媒体文件；最后执行路径校验后的清理。强制中止时由临时 runner 生命周期清理。
- 不打印上游错误原文、响应正文、签名、Cookie、令牌或完整媒体 URL；错误只记录固定代号及 HTTP/平台数值状态。

## 工作流

新文件：`.github/workflows/doustudio-runtime-acceptance.yml`。

名称 `DouStudioKit Real Runtime Acceptance`；唯一触发方式 workflow_dispatch，运行器 xcode-27，contents: read，超时 20 分钟。两个 checkout 均 persist-credentials: false。仅使用官方 checkout/upload-artifact 的完整固定 SHA，与已通过构建工作流一致。没有 push、pull_request、schedule 或部署触发器，没有 GitHub Secrets。

执行顺序：初始化脱敏证据并验证输入 → 检出/校验固定上游 → 记录环境 → 编译独立 Harness → 离线内存 fixture 检查 → 单次真实验收 → 汇总步骤 outcome → 上传明确白名单证据（保留 3 天）→ 清理临时媒体。编译或离线检查失败时不会进入网络测试。

Artifact 名称为 `doustudio-runtime-evidence-<run_id>-<attempt>`。九份 JSON 覆盖用户要求的八份及额外 profile-resolution.json，并上传 stage-outcomes.json、Harness 构建日志和退出码。没有目录通配符，没有原始响应或媒体上传。

## 本地验证

执行 `python runtime-harness/validate_local.py`：106 项 PASS。使用既有 Python/PyYAML 和 Git Bash；未安装工具。

| 检查 | 结果 |
| --- | --- |
| YAML 结构、重复键、触发器、最小权限、固定 Actions/SHA、超时、Artifact 白名单 | PASS |
| 工作流表达式上下文及先前步骤输出引用 | PASS（针对本文件的静态检查，不能替代 GitHub 服务端验证） |
| 全部 run 脚本 bash -n | PASS |
| Python AST 和所有证据 JSON | PASS |
| 初始化脚本隔离执行：合法输入、无授权、带 query、换行注入、错误主机 | PASS；均未发送网络请求 |
| 原构建工作流 SHA-256 | 未变 |
| actionlint | 未安装，NOT_RUN |
| Swift 编译/类型检查 | NOT_RUN；Windows 环境无 Swift 编译器，不以文本检查冒充编译 |
| Swift 离线 fixtures | 已准备，NOT_RUN；将在手动工作流中先于网络测试执行 |
| 本轮 macOS 云端运行/接口测试 | NOT_RUN |

验证 JSON 保存在 `.git/task-validation/runtime-local-validation.json`，上游只读检出位于 `.git/task-validation/runtime-upstream`，不纳入提交。

## 发布和等待点

初次发布提交 `a41a614c725583415e2c5a1a7ed8c317c6b9b19e` 已普通推送至 main，共 17 个新增文件，仅包含新工作流、Harness、本报告及准备阶段证据；原 RUN 报告排除。后续准备收尾补充本节，并为 AVFoundation 引入兼容 Swift 6 并发标注的 preconcurrency import，媒体对象仍限于 MainActor；没有运行网络测试。

GitHub 服务端核验：PASS。工作流 ID `396629067`，API 返回正确名称与 state=active，创建时间 2026-10-26 12:01:30（Asia/Shanghai）。远端工作流 SHA-256 与本地一致：`ca5a9b86fa4de9a006173b1e1b49fad43846c788fc0b5f943a9cc2539c7ec8fc`。

已通过 Chrome 核验 [工作流页面](https://github.com/achusonwork-bit/doustudio-runtime-acceptance/actions/workflows/doustudio-runtime-acceptance.yml)：存在 Run workflow，展开后分支为 main，并显示主页输入框、未勾选的确认框和最终 Run workflow 按钮。当前为 0 workflow runs，没有提交表单或发起 dispatch。服务端接受工作流不表示 Harness 编译或网络验收通过。

只读 REST 元数据保存在 `.git/task-validation/runtime-server-workflow.json`；未改变系统、v2rayN 或 Git 全局代理配置。

准备就绪后，由用户进入 [Actions](https://github.com/achusonwork-bit/doustudio-runtime-acceptance/actions)，选择 `DouStudioKit Real Runtime Acceptance` → Run workflow → main，手动输入要测试的公开主页并勾选授权确认，再运行。用户触发后才能读取真实日志/Artifact 并更新验收。此前聊天中的 URL 不作为本轮默认输入。

## 当前验收状态

```ini
BUILD_BASELINE = PASS
PROFILE_URL_RESOLUTION = NOT_RUN
WORKLIST_FETCH = NOT_RUN
MULTI_PAGE_FETCH = NOT_RUN
PAGINATION_CORRECTNESS = NOT_RUN
WORK_ITEM_FIELDS = NOT_RUN
VIDEO_DOWNLOAD = NOT_RUN
MEDIA_INTEGRITY = NOT_RUN
NO_WATERMARK = NOT_TESTED
CURRENT_INTERFACE_COMPATIBILITY = NOT_RUN
RUST_IMPLEMENTATION = NOT_STARTED
UPSTREAM_SOURCE_CHANGED = NO
VIDEOFLOW_CHANGED = NO
ROOTNETSCOPE_CHANGED = NO
```

`evidence/doustudio-real-runtime-acceptance-01/` 当前均明确标为准备阶段/未执行；没有伪造真实主页、作品数、下载哈希或云端环境。
