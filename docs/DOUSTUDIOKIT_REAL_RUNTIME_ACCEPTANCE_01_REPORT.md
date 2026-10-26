# DOUSTUDIOKIT_REAL_RUNTIME_ACCEPTANCE_01

日期：2026-10-26（Asia/Shanghai）。最新用户手动运行 `40271383018`：Harness 编译和 19/19 离线检查 PASS，主页解析 PASS；首次真实作品列表请求返回 HTTP 403，归类 ACCESS_RESTRICTED，分页和下载均阻塞。仅证明本次匿名访问受限，不证明签名失败或所有访问方式均不可用。完整证据见末尾“用户再次手动运行”。

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

## 准备阶段本地验证快照

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

## 首次云端运行结果

- [运行 40267311040](https://github.com/achusonwork-bit/doustudio-runtime-acceptance/actions/runs/40267311040)，attempt=1，event=workflow_dispatch，status=completed，conclusion=failure。
- 受测提交：`41255273882cfccf028c52dad4f15ca76515dbcb`；运行创建于北京时间 2026-10-26 12:06:06，最后更新时间 12:07:14。
- Job ID：`121392414176`。输入/授权校验、上游检出和 SHA 校验、运行环境记录均成功。
- 实际环境：macOS 27.0.1（26A434）、Apple Swift 6.4（swiftlang-6.4.0.34.1）、Xcode 27.1（27A9275）、arm64，运行器 xcode-27。
- Harness 编译：PASS，`harness-build-exit-code.txt` 为 0，日志结尾 `Build complete! (24.75 sec)`。AVAssetReader 的 add/startReading/copyNextSampleBuffer 有 macOS 27 弃用警告，未阻止编译；不能据此判定实际解码结果。
- 失败步骤：`Check harness guards with offline fixtures`。原始日志为 `Offline harness checks FAIL`，进程退出码 1。此步骤只使用内存 fixture，不发送网络请求。
- 具体失败断言/异常代号未被现有自检日志输出，因此根因为 NOT_IDENTIFIED；不能把推测写成已确认原因。这是验收 Harness 自检失败，不能标成抖音服务端拒绝或上游运行不兼容。
- `Run user-authorized acceptance once` 为 skipped；因此没有真实主页解析、作品请求、分页或下载结果。`harness-exit-code.txt` 不存在是该步骤未执行的预期结果，不能用编译退出码 0 替代。
- 汇总、Artifact 上传、临时媒体清理均成功。未自动重试、修改上游或触发第二次运行。

[Artifact 12627106573](https://github.com/achusonwork-bit/doustudio-runtime-acceptance/actions/runs/40267311040/artifacts/12627106573) 名为 `doustudio-runtime-evidence-40267311040-1`，5959 字节，12 个白名单文件；SHA-256 `7fa974fe2683a3690052cfe17b5baf6a352fc0a2639a36045862fdee7a66fd52` 与发布摘要一致，ZIP CRC 通过。保留 3 天，到期北京时间 2026-10-29 12:07:03。

已核验的原始 Artifact 内容保存在 `evidence/doustudio-real-runtime-acceptance-01/run-40267311040/`，另附 run-summary.json 与 artifact-inspection.json。根目录九份准备模板保留，不用历史运行结果污染下次初始化。完整 Job 日志和 ZIP 保存在 `.git/task-validation/runtime-run-40267311040/`，不提交；发布证据没有 Cookie、令牌、签名内部值或带查询参数的完整 URL，没有视频。

```ini
HARNESS_BUILD = PASS
HARNESS_OFFLINE_SELF_TEST = FAIL
HARNESS_SELF_TEST_ROOT_CAUSE = NOT_IDENTIFIED
REAL_RUNTIME_STEP = SKIPPED
ARTIFACT_VERIFICATION = PASS
AUTOMATIC_RERUN = NO
```

## 首次运行时的验收状态（历史）

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

网络验收状态继续保持 NOT_RUN；真实云端环境和 Harness 编译结果仅来自本次 run 子目录。没有把离线 fixture 视为用户主页数据，也没有把编译通过视为运行验收通过。后续需先定位 Harness 自检失败，再由用户决定下一次手动运行；本次按失败结果停止。


## RUN_02 实测结果

任务 `DOUSTUDIOKIT_REAL_RUNTIME_ACCEPTANCE_01_RUN_02`。本轮复用已有 Harness 和真实运行工作流，没有重新开发、修补或重建工作流。

### 执行前确认

- 本地 HEAD 与远端 main 均为 `643d1bd74813b5d527a9b6dd867bec5a6e1983f3`，无未提交跟踪源码改动。唯一既有未跟踪 RUN 报告保持原样并排除提交。
- Harness 三份 Swift 源码的 Git blob SHA-256 与[19/19 离线验收 40270472151](https://github.com/achusonwork-bit/doustudio-runtime-acceptance/actions/runs/40270472151) Artifact 中的 source_hashes 完全一致；受测源码提交 `44fb339dd5aea5e5b4a8c478aa4c82d8d4c9f77b` 到本轮 HEAD 的 runtime-harness/ 与真实工作流没有差异。OFF-002 修复仍在。
- 同一 Package.swift 与 ../upstream 依赖；上游仍配置固定 `362dad3d082e9f63c8efd360acc653ba169d40a2`。三页、一条视频、maxRetry=0、显式空 cookie、拒绝携带认证头及禁止重定向的保护仍在，不调用 collectAccountBatched。
- **100 MiB 检查在原版响应完整缓冲后执行，不是网络传输量/带宽上限，无法保证一次响应最多传输 100 MiB。**
- 没有代填主页、复用旧 URL、读取认证材料或自动 dispatch；以下仅收集用户已手动触发的一次运行。

### 运行与失败证据

- [真实运行 40271049168](https://github.com/achusonwork-bit/doustudio-runtime-acceptance/actions/runs/40271049168)，attempt=1，workflow_dispatch，main，受测提交 `643d1bd74813b5d527a9b6dd867bec5a6e1983f3`。北京时间 2026-10-26 12:49:43 创建，conclusion=failure。
- Job `121403737101` 在 Initialize evidence and validate explicit input 步骤 exit=2。日志：`Input blocked: enter a canonical public profile URL without query/fragment and confirm consent.`
- Artifact failure-observations.json：phase=input，code=EXPLICIT_CONSENT_AND_CANONICAL_PROFILE_REQUIRED，classification=BLOCKED。
- 本轮失败分类：**UNKNOWN（输入校验阶段）**。原因是代码将“规范主页 URL”和“authorized_public_content=true”合并检查；现有诊断无法证明是 URL 不合法还是未勾选确认。不能据此填写 PROFILE_PARSE_ERROR、ACCESS_RESTRICTED、签名失败或其他抖音服务端类别。未改代码来追查用户输入，也未输出原始输入。
- 上游检出、macOS/Swift/Xcode 环境记录、Harness 编译、自检和真实验收全部 skipped。本轮 Artifact 环境/业务状态文件主要来自初始化模板，不能当作本轮实际环境或接口结果；历史 19/19 PASS 不替代本轮自检 NOT_RUN。
- 因未进入真实阶段：未解析主页、未请求作品、无实际页记录/作品 ID/标题/时间/封面/视频字段证据，也没有 HTTP 状态、下一页游标或真实媒体文件。作品数是“未测”，不能将模板的空值/0 当成实际空账号。没有 SERVER_EXHAUSTED 证据。
- 没有下载，因此文件哈希、媒体正文与解码均未验证，无水印 NOT_TESTED。未遇到可观测的抖音 403/429/挑战响应，不推断服务端行为。

### 每个步骤 outcome

| 步骤 | outcome |
| --- | --- |
| Set up job | success |
| Checkout acceptance harness | success |
| Initialize evidence and validate explicit input | failure |
| Checkout unchanged pinned upstream | skipped |
| Verify upstream and record runtime environment | skipped |
| Compile independent harness | skipped |
| Check harness guards with offline fixtures | skipped |
| Run user-authorized acceptance once | skipped |
| Finalize truthful stage outcomes | success |
| Upload sanitized evidence only | success |
| Remove temporary media | success |
| Post Checkout acceptance harness | success |
| Complete job | success |

编译、自检、真实运行退出码均 NOT_RUN；仅输入初始化退出码 2。对应日志与退出码文件缺失是步骤跳过的预期结果，不补造成功退出码。

### Artifact 和交付

[Artifact 12628352141](https://github.com/achusonwork-bit/doustudio-runtime-acceptance/actions/runs/40271049168/artifacts/12628352141)：`doustudio-runtime-evidence-40271049168-1`，4706 bytes，10 个 JSON 白名单文件，保留 3 天，到期北京时间 2026-10-29 12:49:49。SHA-256 `bfe2bb64770b49f296b4c58742a07f39c4173853b01e02635d2d1359fecd432c` 与 GitHub 摘要一致；ZIP CRC、文件名单和 JSON 解析通过。没有媒体、认证材料或带查询参数的完整 URL。

原始 Artifact 文件保持原样保存到 `evidence/doustudio-real-runtime-acceptance-01/run-40271049168/`，另附 run-summary.json、artifact-inspection.json、input-validation-log.txt、preflight-verification.json 和 run-02-assessment.json。完整 Job 日志与 ZIP 仅存在 .git/task-validation/runtime-run-40271049168/，不提交。

按本轮枚举要求，原始 Artifact 的 PAGINATION_CORRECTNESS / MEDIA_INTEGRITY / CURRENT_INTERFACE_COMPATIBILITY=NOT_RUN 在验收表中写为 NOT_VERIFIED；原始文件不覆盖，转换说明独立保存。其余未测业务状态保持 NOT_RUN。

本轮只提交本报告与新 RunID 证据目录；原源码、两份已有工作流、离线工作流及历史证据快照哈希全部未变，没有修改上游或其他项目。失败后不自动重试，已停止；本轮结果不能证明 DouStudioKit 的真实接口是否可用。

```ini
TASK = DOUSTUDIOKIT_REAL_RUNTIME_ACCEPTANCE_01_RUN_02
HARNESS_BUILD = NOT_RUN
HARNESS_OFFLINE_SELF_TEST = NOT_RUN
PROFILE_URL_RESOLUTION = NOT_RUN
WORKLIST_FETCH = NOT_RUN
MULTI_PAGE_FETCH = NOT_RUN
PAGINATION_CORRECTNESS = NOT_VERIFIED
WORK_ITEM_FIELDS = NOT_RUN
VIDEO_DOWNLOAD = NOT_RUN
MEDIA_INTEGRITY = NOT_VERIFIED
NO_WATERMARK = NOT_TESTED
CURRENT_INTERFACE_COMPATIBILITY = NOT_VERIFIED
UPSTREAM_SOURCE_CHANGED = NO
ROOTNETSCOPE_CHANGED = NO
VIDEOFLOW_CHANGED = NO
RUST_IMPLEMENTATION = NOT_STARTED
```


## 用户再次手动运行：40271383018

用户在前次输入失败后自行再次触发，并要求查看结果。观察到两个新记录：`40271332955`（北京时间 12:53:06）仍在输入初始化失败，真实验收 skipped；随后[40271383018](https://github.com/achusonwork-bit/doustudio-runtime-acceptance/actions/runs/40271383018)（12:53:42）通过输入校验并执行真实请求。这里详细验收后者；没有由代理 dispatch 或重试。

### 提交、环境与结果

- 受测提交仍为 `643d1bd74813b5d527a9b6dd867bec5a6e1983f3`，main，attempt=1；本地前次报告提交 3d77ce3 尚未推送，且仅修改报告与证据，不影响受测源码。
- 上游固定 `362dad3d082e9f63c8efd360acc653ba169d40a2`，检出、SHA 与源码保护校验成功。
- xcode-27 / arm64，macOS 27.0.1 (26A434)，Apple Swift 6.4 (swiftlang-6.4.0.34.1)，Xcode 27.1 (27A9275)。
- Harness 编译 exit=0；离线自检日志明确 `OFFLINE SUMMARY total=19 passed=19 failed=0`，step outcome=success；真实验收 exit=2。
- 主页解析 PASS：本地解析得到 55 字符标识，仅记录标识哈希和长度，没有展开短链或打印主页。此 PASS 不表示已验证远端账号身份/可见性。
- 真实作品列表只发生 1 次传输：HTTP 403，响应 46 bytes；正文未记录，失败 phase=worklist，code=HTTP_403，classification=BLOCKED。本轮业务失败分类为 **ACCESS_RESTRICTED**。
- **Cookie 模式为显式空值**。这是既定匿名测试；Harness 同时拒绝非空 Cookie/Authorization 请求头。403 不能证明“必须 Cookie”、签名错误、验证码、地区限制或其他具体根因，也不能证明提供 Cookie 就能通过。没有读取 Cookie 或尝试绕过限制。

### 作品、分页和下载

| 页码 | 请求游标 | 下一页游标 | has_more | 本页/累计已解析作品 | 重复 ID | 结果 |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | 0 | 未获得 | 未获得 | 0 / 0 | 0（无可比较作品） | HTTP_403，立即停止 |

pages_received=1 是 Harness 创建的**错误页记录**，不是成功收到一页作品。实际可采集作品数量未知，不能据此推断账号为空；ID、描述/标题、发布时间、封面和视频地址均无真实字段证据，WORK_ITEM_FIELDS=NOT_RUN。

没有第二页请求，无法验证服务端游标传递；MULTI_PAGE_FETCH=BLOCKED，PAGINATION_CORRECTNESS=NOT_VERIFIED，stop_reason=ERROR_OR_BLOCK，不是 SERVER_EXHAUSTED，也没有游标停滞证据。

download attempted=false，VIDEO_DOWNLOAD=BLOCKED，无媒体文件、媒体 HTTP 响应、哈希或解码结果；MEDIA_INTEGRITY=NOT_VERIFIED，NO_WATERMARK=NOT_TESTED。未上传媒体，临时媒体清理步骤成功。

当前接口兼容性在这次匿名条件下验收 FAIL；不能外推为固定上游在所有授权访问条件下都不可用。100 MiB 检查仍是响应缓冲后的检查，不是真正的传输流量上限。

### 每个步骤 outcome

| 步骤 | outcome |
| --- | --- |
| Set up job | success |
| Checkout acceptance harness | success |
| Initialize evidence and validate explicit input | success |
| Checkout unchanged pinned upstream | success |
| Verify upstream and record runtime environment | success |
| Compile independent harness | success |
| Check harness guards with offline fixtures | success |
| Run user-authorized acceptance once | failure |
| Finalize truthful stage outcomes | success |
| Upload sanitized evidence only | success |
| Remove temporary media | success |
| Post Checkout unchanged pinned upstream | success |
| Post Checkout acceptance harness | success |
| Complete job | success |

### Artifact 与保护

[Artifact 12628552481](https://github.com/achusonwork-bit/doustudio-runtime-acceptance/actions/runs/40271383018/artifacts/12628552481)，6670 bytes，13 个白名单文件，保留 3 天，到期北京时间 2026-10-29 12:54:29。SHA-256 `07e477bd247c159931357f9844ddc5a5436590b711bbe96e35c0f3097f3bbe28` 与发布摘要一致，ZIP CRC/名单/JSON 核验通过，无媒体或敏感认证材料。

原始 Artifact 保存在 `evidence/doustudio-real-runtime-acceptance-01/run-40271383018/`；另附从 Job 日志提取的 19 项离线结果、逐步骤 run-summary、Artifact 核验和本轮业务分类。原始 MEDIA_INTEGRITY=NOT_RUN 保留不改，报告按约定枚举表示为 NOT_VERIFIED。

本次仅更新报告并新增该 RunID 证据，源码和全部工作流未改，先前历史证据快照哈希一致。上游、RootNetScope、VideoFlow 未改，Rust 未开始。已在首次 403 后停止，没有重试或请求认证材料。

```ini
TASK = DOUSTUDIOKIT_REAL_RUNTIME_ACCEPTANCE_01_RUN_02
HARNESS_BUILD = PASS
HARNESS_OFFLINE_SELF_TEST = PASS
CURRENT_INTERFACE_COMPATIBILITY = FAIL
MEDIA_INTEGRITY = NOT_VERIFIED
MULTI_PAGE_FETCH = BLOCKED
NO_WATERMARK = NOT_TESTED
PAGINATION_CORRECTNESS = NOT_VERIFIED
PROFILE_URL_RESOLUTION = PASS
ROOTNETSCOPE_CHANGED = NO
RUST_IMPLEMENTATION = NOT_STARTED
UPSTREAM_SOURCE_CHANGED = NO
VIDEO_DOWNLOAD = BLOCKED
VIDEOFLOW_CHANGED = NO
WORK_ITEM_FIELDS = NOT_RUN
WORKLIST_FETCH = BLOCKED
```
