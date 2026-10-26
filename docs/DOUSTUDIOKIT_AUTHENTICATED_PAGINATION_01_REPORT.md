# DOUSTUDIOKIT_AUTHENTICATED_PAGINATION_01

2026-10-26，Asia/Shanghai。最新真实运行 40279553152 的认证分页验收 PASS：macOS 编译通过、62/62 Swift 自检通过；三次请求均 HTTP 200，分别返回 21、17、18 条作品，共 56 条且无重复。第二、三页游标链匹配，无停滞或循环。达到三页上限停止，服务端仍 has_more=true；不表示已采集全部作品。未下载视频、未验证媒体或无水印、未开始 Rust。以下准备记录保留为历史，最新详情见末尾。

## 准备阶段记录（历史）

准备期间 Windows Python 27/27 通过；当时 macOS/Swift/网络尚未执行。下列 NOT_RUN 描述均属于准备时点。

## 基线与保护

- 本地：`D:\Projects\doustudio-runtime-acceptance`。
- 仓库：[achusonwork-bit/doustudio-runtime-acceptance](https://github.com/achusonwork-bit/doustudio-runtime-acceptance)，分支 main。
- 开始时本地 HEAD 与远端 main 同为 `ba92c9d870cccb875cae33ffa2d050466d1a70ba`。
- [认证预检基线 40274532110](https://github.com/achusonwork-bit/doustudio-runtime-acceptance/actions/runs/40274532110)：单次 HTTP 200、21 条作品；只作为历史基线，不能证明新分页模式成功。
- 上游固定 `362dad3d082e9f63c8efd360acc653ba169d40a2`，本地只读检视副本 HEAD 匹配、tracked 工作区干净。
- 对全部原跟踪文件及既有未跟踪 RUN 报告建立 163 文件哈希快照。只有 `RuntimeAcceptance.swift` 增加两个显式模式分支；其他 162 文件哈希相同。原四个工作流、匿名 Observer、单请求认证实现和历史证据未修改。
- `docs/DOUSTUDIOKIT_GITHUB_ACTIONS_BUILD_01_RUN_REPORT.md` 是原有未跟踪文件，不纳入暂存/提交。RootNetScope、VideoFlow、zhuabao 和其他项目未修改；未修改 Git 全局配置、系统代理或 v2rayN。

## 原版调用路径及证据

固定源码 `Sources/DouStudioKit/Networking/DouyinAPI.swift`：

1. `DouyinEndpoints.accountTimeline`（第 288 行）调用 `collector.collect`，参数为 `itemsKey=aweme_list`、`cursorKey=max_cursor`，默认 `hasMoreKey=has_more`。
2. `PaginatedCollector.collect`（第 151 行起）从 `PageRequest.cursor` 开始，以实际响应生成 RawPage；遇到空数组、has_more=false 或 maxPages 上限停止，下一轮设置 `cursor=raw.cursor`。
3. 原版 JSONNode.int64 对缺失值回落到 0；循环未检查停滞/循环。因此 Harness 在响应返回给原版 collector 前检查这些错误，保留错误、阻止后续请求，不修改原始响应或填补游标。
4. `DouyinAPIClient` 保留原签名、会话、节流及请求构造管线；maxRetry=0。没有复制参数生成逻辑、调用 collectAccountBatched 或研究/改写签名。

新 `AuthenticatedPagination.collect` 只调用一次 `endpoints.accountTimeline(... PageRequest(count:18,maxPages:3,cursor:0))`。循环始终在原版 collector 内部；Harness 不手工发出第二页，也不计算游标。

## 独立边界与状态判定

- 新 `PaginationTransport` 单独包裹原版 URLSessionTransport；原 AuthPreflightTransport 的 request_count==0 限制原样保留，匿名入口仍显式空 Cookie。
- 只放行 GET、无 body、HTTPS www.douyin.com 的精确作品列表路径，count=18、已授权用户标识、预期游标各只有一个参数。Cookie 必须等于该次授权内存值；拒绝额外认证头、代理、额外头和其他主机/端点。
- 每次 send 在 await 前占用一次额度，最多三次；拒绝并发、第四次或已停止后的发送。followRedirects=false、timeout=30、maxRetry=0。HTTP 403/429、重定向、挑战及结构错误立即停止。
- 观察前一页真实返回的 max_cursor；下一次请求必须逐值匹配。证据只保存 uses_previous_response_cursor 布尔关联、返回游标有效性、停滞/循环标记，不保存游标本身。
- has_more 只接受明确的 0/1 或布尔状态；has_more=true 要求有效正整数游标，拒绝缺失、停滞、循环及空页仍声明有更多。has_more=false 时不要求可继续使用的游标，正常 SERVER_EXHAUSTED。
- 每页记录真实请求是否开始、HTTP 状态、页序、has_more、返回游标有效性、作品数、累计原始数量和唯一数量、重复 ID 出现次数。作品 ID 仅内存比较，不输出；同页及跨页重复都计数。重复项导致 PAGINATION_ERROR / DUPLICATE_WORK_IDS 并停止，不去重后掩盖问题。
- 至少两页非空且合法、实际游标链正确、原管线成功结束、没有完整性错误才给 PAGINATION_CORRECTNESS=PASS。三页上限正常停止时记录 PAGE_LIMIT_REACHED，不声称收齐账号全部作品。
- 第一页正常耗尽时记录 SERVER_EXHAUSTED，MULTI_PAGE_FETCH=NOT_VERIFIED；这是采用任务文字中的明确特殊规则，虽然上方枚举未列出 NOT_VERIFIED。空作品数组也不能证明认证列表采集成功。
- 每页与汇总错误均为固定类别/原因。JSON 解码/上游错误正文不输出，也不把所有失败归因于签名。原版返回作品集合只用于核对总数，不落盘。
- 无视频播放地址探测、下载器调用、媒体写入或媒体上传。URLSession 响应依旧由原实现缓冲；本任务没有声称存在硬网络字节上限。

## 工作流及凭据隔离

文件 `.github/workflows/doustudio-authenticated-pagination.yml`，名称 `DouStudioKit Authenticated Pagination Acceptance`。

- 仅 workflow_dispatch；xcode-27、20 分钟、contents:read，两个 checkout 均 persist-credentials=false，上游固定完整 SHA。
- 官方 Actions 与已验证基线相同：checkout `3d3c42e5aac5ba805825da76410c181273ba90b1`、upload-artifact `cf430e030ddbb5b0abf93d22962f4752f3646cd9`。
- profile_url 必填且无默认值；authorized_own_session 默认 false，必须用户明确确认。未授权/无效主页时初始化阻塞。
- 只有认证分页步骤引用仓库 Actions Secret DOUYIN_COOKIE。之前的构建和离线步骤没有凭据。
- 新 Python 启动器复用原安全输入解析助手，只导入函数，不调用原单请求执行器。必须验证两份离线结果的固定 ID 集合、全部 PASS、无在线/媒体标记，以及构建/离线退出码 0，然后才允许认证子进程。
- Cookie 缺失、控制字符、授权缺失、主页无效均在平台请求前关闭。只记录 credential_present 布尔值，不记录 Cookie 内容、长度、哈希或任何派生标识。
- 子进程最小环境、凭据仅环境传递，不进入 argv/GITHUB_ENV/文件；stdout/stderr 丢弃，上游日志关闭，Shell 关闭调试和 core dump。真实请求异常只保存固定分类。子进程超时 240 秒、不重试。
- Artifact 保留 3 天，显式 13 文件白名单：input-validation.json、environment.json、source-protection.json、stage-outcomes.json、build.log、build-exit-code.txt、offline.log、offline-exit-code.txt、selftest-results.json、pagination-result.json、pagination-exit-code.txt、pagination-selftest-results.json、final-acceptance.json。无通配目录、媒体、缓存、原始响应或事件输入。

## 离线检查结果与限制

- `python -B -m unittest discover -s runtime-harness -p test_auth*.py -v`：27/27 PASS；新 17 项验证缺失凭据/授权、控制字符、主页、缺失/失败/重复 ID 的离线结果、编译失败门禁、子进程隔离、退出码、异常抑制、不重试、耗尽不误判、多于三请求结果拒绝、初始化不持久化输入、上游保护失败如实标记。
- `validate_auth_pagination.py`：YAML、触发器、官方版本/上游 SHA、最小权限、步骤上下文、唯一 Secret 注入点、离线先行、bash -n、13 文件白名单、源代码调用边界、24 fixture 定义及保护哈希 PASS。
- 原 `validate_auth_preflight.py` 也通过，原单请求限制与 11 文件白名单没有放宽。
- 本机 Swift 不可用；actionlint 未安装，未擅自安装。以上 PASS 不是 Swift 编译或 fixture 运行证明。
- 新 `--pagination-self-test` 先执行原 38 项，再执行下列 24 项。原 `--self-test` 行为不变。云端在 sandbox-exec deny network* 中执行，任一失败都会让工作流停止在认证步骤之前。`OFFLINE_ONLY=1` 拒绝认证分页入口。

| 用例 | 覆盖 | 本轮 Swift 执行 |
| --- | --- | --- |
| PAG-001 | 原版两页链及服务端耗尽 | NOT_RUN |
| PAG-002 | 原版三页链、第四请求拒绝 | NOT_RUN |
| PAG-003 | 第一页耗尽不误报多页成功 | NOT_RUN |
| PAG-004 | 空首页不误报采集成功 | NOT_RUN |
| PAG-005–008 | 缺失/零游标、停滞、循环 | NOT_RUN |
| PAG-009–010 | 跨页和页内重复次数、累计唯一数 | NOT_RUN |
| PAG-011–015 | 403、第二页 429、HTML、结构变化、缺失 has_more | NOT_RUN |
| PAG-016–019 | 空页有更多、重定向、无效作品 ID、平台错误 | NOT_RUN |
| PAG-020 | 错误下一页游标在发送前阻断 | NOT_RUN |
| PAG-021–022 | 媒体端点/外部主机/无 Cookie/代理拒绝 | NOT_RUN |
| PAG-023 | 结果无原始游标、作品 ID、Cookie、URL | NOT_RUN |
| PAG-024 | 网络异常停止且不重试 | NOT_RUN |

## 交付和手动运行

新增工作流、两个 Swift 文件、分页 Python 启动器/测试/静态检查、此报告和 `evidence/doustudio-authenticated-pagination-01/`；原 RuntimeAcceptance.swift 仅增加两个分支。没有修改既有工作流。

打开 [分页工作流](https://github.com/achusonwork-bit/doustudio-runtime-acceptance/actions/workflows/doustudio-authenticated-pagination.yml)，选择 Run workflow / main，手动输入有权访问的公开主页并勾选 authorized_own_session。Secret 继续使用仓库 DOUYIN_COOKIE，不要输入到主页框或聊天中。

手动运行将先编译、执行全部 62 项 Swift fixture，再最多发出三次列表请求。任一离线失败就不会进入认证阶段。此次准备没有触发任何工作流。

新分页真实运行 URL、受测 SHA、逐页结果、游标关联与 Artifact 哈希均为 NOT_RUN，等待手动运行后补齐；本地源码哈希和保护结果见 evidence，不用历史 run 充当此次分页证据。

```ini
HARNESS_BUILD = NOT_RUN
OFFLINE_SELF_TEST = NOT_RUN
AUTHENTICATED_PROFILE_ACCESS = NOT_RUN
FIRST_PAGE_FETCH = NOT_RUN
MULTI_PAGE_FETCH = NOT_RUN
PAGINATION_CURSOR_CHAIN = NOT_VERIFIED
PAGINATION_CORRECTNESS = NOT_VERIFIED
VIDEO_DOWNLOAD = NOT_RUN
MEDIA_INTEGRITY = NOT_RUN
NO_WATERMARK = NOT_TESTED
RUST_IMPLEMENTATION = NOT_STARTED
UPSTREAM_SOURCE_CHANGED = NO
ROOTNETSCOPE_CHANGED = NO
VIDEOFLOW_CHANGED = NO
```

这里 OFFLINE_SELF_TEST 专指当前源码的 macOS Swift 自检，Windows Python 离线检查单独记录为 27/27 PASS。

## 发布核验

- 准备代码及初始证据已普通提交并推送：`e64fd8d3e7719f4eb3305fbb7daf8b6ec2da6428`。
- GitHub 只读 API 返回新工作流 ID `396701158`、名称/路径匹配、state=active；发布核验时 total_count=0。元数据见 `github-publication.json`。
- 这证明 GitHub 已登记工作流，不代表 macOS 编译、Swift fixture、运行时表达式或真实分页已经通过。新分页运行 URL 和 Artifact 哈希仍为 NOT_RUN。
- 最后一次提交仅补充本节和发布元数据，不改变待验证的 Harness/工作流源码。未触发认证或离线云端工作流；不自动重试。


## 真实运行 40279553152：认证分页 PASS

- [GitHub Actions 运行](https://github.com/achusonwork-bit/doustudio-runtime-acceptance/actions/runs/40279553152)，2026-10-26 14:23:38（Asia/Shanghai）创建，workflow_dispatch，attempt=1，job=121429588978，结论 success。由用户手动触发；本轮只读取/归档结果，没有再次触发或自动重试。
- 受测提交 `c05127d88fa184e1c5966096022cd6a45284f0d1`；源码与准备提交 e64fd8d 相同，后续 c05127d 只补充报告和发布信息。
- 实际上游 HEAD `362dad3d082e9f63c8efd360acc653ba169d40a2`；运行结束 tracked_source_clean=true。
- xcode-27，arm64，macOS 27.0.1 (26A434)，Swift 6.4 (swiftlang-6.4.0.34.1)，Xcode 27.1 (27A9275)。
- 构建退出码 0；离线退出码 0，原 OFF/AUTH 38 项及 PAG-001..024 全部 PASS，总计 62/62；真实分页退出码 0。
- 离线诊断文件逐例包含固定 ID、函数、预期、实际安全摘要及 PASS；两份结果均 onlineEntryCalled=false、mediaDownloaded=false。真实请求独立记录在 pagination-result.json，不把 fixture 算作平台请求。
- `credential_present=true`；只记录存在性，不读取或保存 Secret 内容、长度、摘要或其他派生值。

### 逐页结果及游标证据

| 页码 | HTTP | 作品数 | 累计/唯一数 | 重复次数 | 使用前页返回游标 | has_more | 返回游标有效 | 停滞/循环 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 200 | 21 | 21 / 21 | 0 | 不适用（初始页） | true | true | false / false |
| 2 | 200 | 17 | 38 / 38 | 0 | true | true | true | false / false |
| 3 | 200 | 18 | 56 / 56 | 0 | true | true | true | false / false |

实际 request_count=3、pipeline_completed=true，全部 valid_page=true。uses_previous_response_cursor 来自检查层对实际签名请求与前一页原始响应游标的内存比较，第二、三页均匹配；未自行生成游标，也没有把原始游标、作品 ID 或完整请求 URL 写入证据。

停止原因为 PAGE_LIMIT_REACHED。第三页仍 has_more=true，未发起第四次请求；这是三页样本的分页能力通过，不能据此宣称账号全部作品已经获取或长期稳定。每次请求 count=18，实际响应 21/17/18 原样计数，不截断或凑数。无失败类别；下载、媒体完整性和无水印仍未验证。

### 步骤 outcome

| 步骤 | outcome |
| --- | --- |
| Set up job | success |
| Checkout harness | success |
| Validate explicit authorization and initialize evidence | success |
| Checkout pinned upstream | success |
| Verify upstream and environment | success |
| Build harness without credentials | success |
| Offline fixtures without credentials or network | success |
| At most three authorized worklist pages | success |
| Record outcomes and upstream protection | success |
| Upload sanitized evidence | success |
| Post Checkout pinned upstream | success |
| Post Checkout harness | success |
| Complete job | success |

### Artifact 和交付保护

[Artifact 12632016389](https://github.com/achusonwork-bit/doustudio-runtime-acceptance/actions/runs/40279553152/artifacts/12632016389)，10808 bytes，13 个白名单文件，保留 3 天，到期时间 2026-10-29T06:25:09Z。

下载 ZIP 的 SHA-256 为 `de54c543517c6d5b255002bb3d301bb1a4026d52fd19a11c77ff2e83f58c5065`，与 GitHub 发布摘要一致；ZIP CRC 和文件白名单通过。原始脱敏文件逐字节保存于 `evidence/doustudio-authenticated-pagination-01/run-40279553152/`，另存步骤摘要、Artifact 核验、验收判断及保护结果。原始 ZIP 存在本地 .git/task-validation 下，不作为媒体或运行产物提交。

Artifact 无媒体、Cookie、认证头、原始平台响应或带查询参数的完整请求/视频 URL；构建和自检日志在 Secret 注入之前生成。7 个准备源码哈希及 163 条基线保护记录核对一致（包括此前允许的 main 分支入口修改和原有未跟踪 RUN 报告）。本次仅更新主报告和新增该 RunID 证据，不修改 Harness、工作流、上游或历史证据；RootNetScope、VideoFlow、zhuabao、系统代理及 v2rayN 未改动。普通提交、推送，不强推。

```ini
HARNESS_BUILD = PASS
OFFLINE_SELF_TEST = PASS
AUTHENTICATED_PROFILE_ACCESS = PASS
FIRST_PAGE_FETCH = PASS
MULTI_PAGE_FETCH = PASS
PAGINATION_CURSOR_CHAIN = PASS
PAGINATION_CORRECTNESS = PASS
VIDEO_DOWNLOAD = NOT_RUN
MEDIA_INTEGRITY = NOT_RUN
NO_WATERMARK = NOT_TESTED
RUST_IMPLEMENTATION = NOT_STARTED
UPSTREAM_SOURCE_CHANGED = NO
ROOTNETSCOPE_CHANGED = NO
VIDEOFLOW_CHANGED = NO
```

验收完成后停止；不自动开始视频下载、额外分页或 Rust 移植。
