# DOUSTUDIOKIT_MEDIA_HOST_ALLOWLIST_AUDIT_01

用户手动运行已核验：**编译 PASS、Swift 离线检查 58/58 PASS、单次作品列表 HTTP 200/21 条；主机审计仍 BLOCKED**。观察到 5 个播放字段主机，但采集记录被上限截断，4 条选中地址未关联到来源，且独立关联证据不足。批准主机仍为 0；未发出任何真实媒体请求，未自动触发或重试，未读取 Secret 值。

## 用户手动运行结果（2026-10-26）

- [实际运行 40292928113](https://github.com/achusonwork-bit/doustudio-runtime-acceptance/actions/runs/40292928113)，受测提交 `83e1aba315f53e766b2f77f12462c7501d2aeba1`，原版上游 SHA 保持固定。
- macOS 27.0.1 / arm64 / Swift 6.4 / Xcode 27.1；build-exit-code=0，offline-exit-code=0。
- 原有通用/认证 fixture 38/38，新主机 fixture 20/20，合计 58/58 通过。
- 工作流失败在 `One authorized worklist request and string-only host observation`，audit-exit-code=2，固定类别 `INCOMPLETE_OR_NO_VIDEO_HOST_EVIDENCE`。不是编译失败、登录失败、HTTP 403 或视频大小问题。
- 认证请求只发生 1 次，HTTP 200，21 条有效作品。凭据只记录 credential_present=true。
- 诊断记录总数 1000，其中播放字段记录 864；truncated=true；21 条已选视频中仅 17 条完成字段关联，selected_source_unmatched=4。证据证明触及总记录上限；没有原始响应，不能断言是否还同时触及其他数组上限。按现有完整性门禁退出是正确行为，不能把部分采样当成完整 PASS。
- Artifact ID `12637495195`，17 个文件。ZIP SHA-256 `3a9b549159f4dcd394d013d69b91ee8576a0a5a804f7ada84905cfe129d29448` 与 GitHub digest 匹配，CRC 和 runner 文件哈希清单全部通过，未包含媒体、原始响应或完整媒体 URL。
- 原始脱敏证据保存在 `evidence/doustudio-media-host-allowlist-audit-01/run-40292928113/`，包括 jobs.json 的每步 outcome。证据校验、上传和上游保护步骤均 success。

### 已观察到的候选与审核决定

| 精确主机 | 播放字段记录数 | 与 Extractor 已选 URL 匹配记录数 | 决定 |
|---|---:|---:|---|
| sf6-cdn-tos.douyinstatic.com | 1 | 0 | 候选，未批准 |
| sf11-cdn-tos.douyinstatic.com | 1 | 1 | 候选，未批准 |
| v26-web.douyinvod.com | 287 | 0 | 候选，未批准 |
| v26-webf.douyinvod.com | 288 | 0 | 候选，未批准 |
| www.douyin.com | 287 | 16 | 候选，未批准 |

这些是记录数，不是不同视频数，也不是发出的媒体请求数。来源字段及 HOST-xxxx / WORK-xxx 关联保存于 candidate-hosts.json、host-provenance.json 和原始 run 目录；没有真实作品 ID。`sf11-cdn-tos.douyinstatic.com` 对应首条作品 `video.play_addr.url_list[1]`；不以 URL 名称推断媒体内容。

其他资源主机 `p3-pc-sign.douyinpic.com`、`p3-pc.douyinpic.com`、`p9-pc-sign.douyinpic.com` 单独排除，不进入视频候选白名单。所有 5 个播放字段主机的已观察字符串均为 HTTPS、无 userinfo、无非标准端口、无 IP/本机名称；这些语法事实不能证明 DNS 目标安全或无重定向。

限定官方开发者/云服务文档的 6 次检索未返回足够的精确主机资料（见 public-association-review.json）。这不证明主机不合法，也不能据此认定可信。尤其 www.douyin.com 出现在已选播放地址中，不等于已证明它是无重定向的直接媒体响应端点。本轮没有 HEAD/GET 探测、DNS 查询或跟随重定向。

结论：已有作品响应支持 5 个候选的字段来源，但完整来源审计仍 PARTIAL；独立服务关联和网络目标安全证据不足，HOST_SECURITY_REVIEW=BLOCKED，approved-hosts.json 保持空数组。不会仅凭后缀批准，也不会改选未被 Extractor 选中的备用 CDN 来规避门禁。

本轮只归档这次结果，不更改限额或提取代码、不重试。最小后续方案是单独改进证据收集顺序：优先记录每条作品的原版已选地址来源，再按主机聚合并保留引用，避免大量备用 URL 挤满诊断配额；离线验证后仍需用户另行手动采样。之后才对精确候选补齐独立审核依据。此方案尚未执行。

## 仓库及已有证据

- 本地：`D:\Projects\doustudio-runtime-acceptance`
- 远端：https://github.com/achusonwork-bit/doustudio-runtime-acceptance
- 初始本地 HEAD 与远端 main 一致：`ba17ce255ef99fe2c13c6125b05c09f31413ea00`。
- 固定上游：`362dad3d082e9f63c8efd360acc653ba169d40a2`，已有本地只读 checkout HEAD 一致且工作区干净。
- 已有未跟踪 `docs/DOUSTUDIOKIT_GITHUB_ACTIONS_BUILD_01_RUN_REPORT.md` 保留，不暂存。

复用以下真实证据，不重复发出作品请求：

| 编号 | 证据 | 已证明 | 未保留的信息 |
|---|---|---|---|
| EXISTING-001 | [认证预检 40274532110](https://github.com/achusonwork-bit/doustudio-runtime-acceptance/actions/runs/40274532110) 的 auth-result.json | 单请求 HTTP 200、21 条作品、21 个视频地址字段存在 | 实际视频主机及地址来源字段 |
| EXISTING-002 | [分页 40279553152](https://github.com/achusonwork-bit/doustudio-runtime-acceptance/actions/runs/40279553152) 的 pagination-result.json | 三页 21/17/18 条、累计 56 条、游标关联正确 | 实际视频主机及地址来源字段 |
| EXISTING-003 | [集成 40289436585](https://github.com/achusonwork-bit/doustudio-runtime-acceptance/actions/runs/40289436585) 的 integration-results.json | 28/28、应用字节预算、取消和清理、合成媒体解码 | 真实媒体主机；该运行全部为 loopback fixture |

结构扫描了既有 evidence 下 163 个 JSON：没有记录实际媒体 URL 字段或实际主机字段。命中 play_addr/host 等文本的其他文件是离线用例名称，不能当成生产地址。只输出结构统计，未打印任何完整媒体 URL。来源文件 SHA-256 见 host-provenance.json/evidence-index.json。

准备时没有实际主机记录；本次运行后已观察 5 个真实播放字段主机，5 个均待审核，独立关联证据充分的主机 0，批准主机 0。不是因语法不合格而拒绝这 5 个主机，而是暂缓批准。这里的批准数 0 不表示实际响应没有视频 URL。

## 固定版本的地址选择和下载路径

源码位置均相对于固定上游的 `Sources/DouStudioKit/`：

1. `Parsing/DouyinExtractor.swift:71` 的 `work(from:collectionTime:)` 在 images 非空时分类为图集或实况，否则调用 `classifyVideo`。
2. `Parsing/DouyinExtractor.swift:163` 的 `classifyVideo` 将 `selectBitrate` 返回的 URL 直接写入单个 `.media` 下载单元。封面独立取 `video.dynamic_cover.url_list[-1]`、`video.cover.url_list[-1]`，不能混作播放主机。
3. `Parsing/DouyinExtractor.swift:190` 的 `selectBitrate` 对 `video.bit_rate` 按 `(max(height,width), FPS, bit_rate, play_addr.data_size)` 升序排序并取最后一项，再取该项 `play_addr.url_list[-1]`。数组缺失/为空时取 `video.play_addr.url_list[-1]`。代码注释的 “first play_addr” 不能取代实际实现中的 `[-1]`。
4. `Parsing/DouyinExtractor.swift:240` 的 `originalQualityURL` 可构造其他播放入口，但本次没有调用它或 QualityProbe，配置 `preferOriginalQuality=false`，不进行地址升级、额外详情请求或质量探测。
5. `Download/StreamingDownloader.swift:23` 的原版 `Downloader.download(work:progress:)` 处理已选单元；其下载单元路径在 `:137` 生成 Range，并在 `:143` 默认使用 `followRedirects:true`。这不是无重定向保证；既有 SafeStreamingTransport 负责拒绝重定向和移除无界 Range。本轮没有调用下载器，也不进行 HEAD/GET 来确认某个地址是否重定向。

当前单视频工作流仍在凭据/列表/媒体请求前固定关闭，没有实际选用的生产下载 URL。已通过的集成路径使用合成数据和 localhost；不能据此批准真实 CDN。旧匿名 Observation 中的域名后缀策略也不构成精确主机审计依据，本轮保持旧功能不变，不复用该策略批准主机。

## 新增手动观察入口

工作流：`.github/workflows/doustudio-media-host-audit.yml`，名称 **DouStudioKit Media Host Allowlist Audit**。

- 只有 workflow_dispatch；xcode-27；20 分钟；contents: read；官方 checkout/upload-artifact 固定完整 SHA；两次 checkout 均 persist-credentials: false；上游 SHA 固定且检查实际 HEAD。
- 主页必须由用户手动输入，不设默认值；必须勾选 authorized_own_session。
- Cookie 仅在 observe 步骤从已有 DOUYIN_COOKIE Secret 注入。缺失、未授权、控制字符或非法主页在作品请求前拒绝；不读取浏览器/其他应用凭据，不输出或写盘 Cookie，不记录其长度、摘要。
- 原版 Client/accountTimeline + 原有 AuthPreflightInput/AuthPreflightTransport 保持不变。pageSize=18、maxPages=1、cursor=0、maxRetry=0；实际返回数量可以不同，沿用已有最多 50 条的响应验证。
- AuthPreflightTransport 只允许精确 www.douyin.com 的作品列表路径，保留一次请求计数、禁止重定向和额外认证头、403/429/挑战立即停止。新增模式不调用 Downloader、QualityProbe、任何媒体传输方法或 DNS 解析。
- 原版 Extractor 负责选 URL；新代码仅将选中字符串与原始字段值做内存比较，保存对应字段编号。相同 URL 出现在多个有效字段时可有多个关联记录，不声称唯一来源。
- 只记录小写规范主机、字段、HOST-xxxx 证据编号、运行内 WORK-xxx 序号以及安全标志，不记录真实作品 ID、ID 哈希、标题、URL 路径、查询参数、签名或原始响应。视频、封面、头像、其他音频、非视频作品资源分组明确。
- 限制最多 50 条作品、每个 URL 数组 20 条、每条最多 50 个码率项、总记录 1000 条；超出时明确 truncated 并以非零退出，不将截断证据当成完整观察。

源码：`MediaHostAudit.swift`、`MediaHostAuditSelfTest.swift`；编排 `media_host_audit.py`。原有 RuntimeAcceptance.main 仅增加两个明确入口 `--media-host-audit` 与 `--media-host-audit-self-test`；在线分支仍位于 OFFLINE_ONLY 保护之后。原匿名/认证/分页入口及全部既有工作流不变。

## 主机安全审查范围

字符串检查拒绝 HTTP、userinfo、非 443 端口、IP/纯数字地址、本机和保留名称、空标签、尾点、异常标签和 IDN 歧义。不将语法正常的主机标记为 approved：所有响应主机最多只是候选。

**域名外观无法证明 DNS 不指向私网，也无法证明媒体服务归属或不存在重定向。** 因此记录 `NOT_VERIFIED_NO_DNS_LOOKUP` 和 `UNKNOWN_NOT_REQUESTED_REDIRECTS_FORBIDDEN`。候选出现后，需要另行查证可信公开资料支持的精确主机关联、目标安全性与来源一致性；资料不足继续 BLOCKED。不得根据后缀/服务商名称、封面主机或重定向目标自动批准。

本轮没有实际候选，未进行推测性域名搜索，也没有访问媒体域名。`approved-hosts.json` 始终为空独立审核结果，观察流程不会将候选自动写入它。当前失败关闭的单视频工作流不修改，尚未准备可访问真实媒体的版本。

## 本地验证和待执行验证

- Windows Python 边界测试 **12/12 PASS**：缺 Secret、未授权、控制字符、非法/缺失主页、子进程环境隔离、超时不重试、非零退出、零退出无结果拒绝、禁止自动批准、证据含 URL 拒绝、Artifact 白名单。详见 python-tests.log/json。
- YAML 结构、bash -n、单请求代码路径、Secret 步骤隔离、固定版本、Artifact 白名单、既有文件保护检查 **PASS**。actionlint 未安装，明确 NOT_RUN。
- 新增 Swift 主机 fixture **20/20 PASS**；实际运行在 deny network 沙箱中完成原有 19 项通用 + 19 项认证 fixture 和新 20 项。全部通过后才发生一次作品列表观察。
- **macOS 编译 PASS**，证据来自用户手动运行。此前准备阶段的 NOT_RUN 历史记录保持原样，不把本地检查改写成云端验证。
- Artifact 仅 17 个明确诊断文件、保留 3 天，不含媒体或原始响应。finalize 检查 JSON 无完整 URL/敏感标记并确认 approved-hosts 为空；检查失败则禁止上传。凭据步骤 stdout/stderr 丢弃，异常只用固定类别；离线日志不带真实凭据。

## 方案 A 与保护

用户本轮已明确授权方案 A：应用接受量和实际写盘量均限制为 104857600 bytes，超限取消并等待完成，失败清理，不回退完整缓冲、不重试或续传。**严格网络接收上限未证明不再单独阻塞方案 A。** 本轮保留全部指标，不修改已通过的 Transport。

复用集成 INT-015：delegate_received_bytes=105512960、accepted_bytes=104202240、written_bytes=102170624、cancel_requested=true、cancel_completed=true。应用预算通过，但底层接收超过 100 MiB，继续 STRICT_NETWORK_RECEIVE_LIMIT=NOT_PROVEN。该状态不是实际媒体下载通过；实际媒体域名仍需独立审核。

289 个既有跟踪文件中仅 RuntimeAcceptance.swift 增加分支；加上原未跟踪 RUN 报告共 290 个文件进行保护核验。上游、原 Transport、旧工作流、历史证据、其他项目不改；不改系统代理、v2rayN 或 Git 全局设置。只普通提交推送本轮源码、工作流、报告与脱敏证据，无强制推送。

## 最终状态

```ini
TASK = DOUSTUDIOKIT_MEDIA_HOST_ALLOWLIST_AUDIT_01
EXISTING_EVIDENCE_REUSED = YES
MEDIA_HOSTS_IDENTIFIED = YES
HOST_PROVENANCE = PARTIAL
HOST_SECURITY_REVIEW = BLOCKED
APPROVED_HOSTS = 0
PRODUCTION_ALLOWLIST = EMPTY
APPLICATION_BYTE_BUDGET = PASS
STRICT_NETWORK_RECEIVE_LIMIT = NOT_PROVEN
SINGLE_VIDEO_WORKFLOW_PREPARED = NO
REAL_MEDIA_REQUEST = NOT_RUN
REAL_VIDEO_DOWNLOAD = NOT_RUN
MEDIA_INTEGRITY = NOT_VERIFIED
NO_WATERMARK = NOT_TESTED
RUST_IMPLEMENTATION = NOT_STARTED
UPSTREAM_SOURCE_CHANGED = NO
ROOTNETSCOPE_CHANGED = NO
VIDEOFLOW_CHANGED = NO
AUTO_TRIGGERED = NO
```

## 发布历史与当前停止点

准备源码和交付文件已普通提交并推送：`c70012534863d6f5572637d31699acfc16e1b0cf`。GitHub 只读核验已登记工作流 ID `396810963`、state=active，核验时 total_runs=0。注册状态不代表 Swift 编译、离线用例或主机审计通过；发布元数据见 github-publication.json。后续收尾提交仅补充该发布记录和证据索引，不变更源码。

用户现已运行一次，结果见本文开头。当前停止，不再次触发或请求用户立即重跑；重复同样的采样可能再次遇到记录上限。

工作流执行不代表候选已批准。本次只有部分来源证据，尚未完成精确主机安全审查。批准前生产精确白名单保持为空；本轮至此停止，不触发新的作品请求或下载。
