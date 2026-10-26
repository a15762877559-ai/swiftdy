# DOUSTUDIOKIT_AUTHENTICATED_PAGINATION_01

2026-10-26，Asia/Shanghai。准备阶段：新增独立认证分页 Harness、工作流、24 项 Swift 分页 fixture 及 17 项 Python 启动器测试。Windows 上 27 项 Python 测试通过（新 17 项及原认证预检 10 项），静态检查通过。**本机没有 Swift；macOS 编译、62 项 Swift fixture 和真实分页均未执行，不能认定分页验收 PASS。** 不自动触发，等待用户手动运行。

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
