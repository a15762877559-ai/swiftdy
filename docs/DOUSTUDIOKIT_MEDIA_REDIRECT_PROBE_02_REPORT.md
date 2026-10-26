# DOUSTUDIOKIT_MEDIA_REDIRECT_PROBE_02

2026-10-26，Asia/Shanghai。代码、两个独立手动工作流、脱敏证据及 Windows 验证已准备。**Windows Python 99/99 PASS；本任务新增 Swift 的 macOS 编译、重定向/地址固定通道用例尚未运行，均为 NOT_RUN。** 本轮没有触发 GitHub Actions、授权列表、DNS 媒体目标解析、真实下一跳请求、sf11 请求或完整下载。

## 仓库与保护

当前仓库为 `https://github.com/a15762877559-ai/swiftdy`。本轮开始核验 origin 后，把原本使用旧仓库名称的开发目录完整迁至 **`D:\Projects\swiftdy`**，Git 历史和文件全部保留；目标目录原先不存在。后续所有开发命令在新目录执行。

- origin：`a15762877559-ai/swiftdy`；upstream remote：`achusonwork-bit/doustudio-runtime-acceptance`，仅保留历史来源。
- fetch origin/main 后，开始时 HEAD、origin/main 同为 `f2ed64f8eefa3e5b7a24a701b3220d35b3b2066e`，工作区干净，ff-only 检查无新提交。
- 固定 DouStudioKit 源码仍为 `qinjian0420/DouStudioKit@362dad3d082e9f63c8efd360acc653ba169d40a2`；Package.swift 未变。新工作流固定完整 SHA 并校验上游工作区，未修改原版上游。
- 已确认此前通过的 Harness、SafeStreamingTransport、83 项通用/认证/主机基线、12 项策略、19 项原受控 HTTP 用例及既有工作流均存在。
- 原有跟踪文件只修改 `RuntimeAcceptance.swift` 和 `MediaHostLiveProbe.swift`。SafeStreamingTransport、其他旧源码、旧工作流、历史报告和证据不改。新增文件限本任务。
- 不改 RootNetScope、VideoFlow、系统代理、v2rayN 或 Git 全局配置。Git 网络命令仅在单次命令中沿用已有 `127.0.0.1:7890` 路由，不保存代理设置。下述 CONNECT 通道只属于探测进程自身，不是系统代理配置。

## 上一轮 sf11 为什么未执行

核对 [40319832707](https://github.com/a15762877559-ai/swiftdy/actions/runs/40319832707) 的原始 probe-summary、host-observations、request-counts 和受测源码 `85d0b6c`：一次列表 HTTP 200/21 条；只发生 www 一次媒体 GET，302 目标为 `v5-dy-ov-experiment.zjcdn.com`，终态完成，没有失败类别。该事实与最新报告提交 f2ed64f 一致。

旧 `LiveProbePolicy.select` 对每个符合条件的精确主机各保留一个原版已选地址；旧调度遍历全部保留样本。www 的 302 属于 expectedObservation，不会触发 break。因此，**没有“一次运行只能调度一个主机”的限制，www 的这个 302 也没有使 sf11 被调度器截断**。按受测代码与完整结束结果，sf11 没有进入当次符合条件的已选样本集合。

当时没有保存全量主机清单或拒绝细分，故不能进一步证明原始响应完全没有 sf11 字符串，或某条原始 sf11 资源在视频类型/单单元/精确来源等哪项未达标；不能把旧运行 40299734675 中的一条 sf11 样本复用到新请求。证据粒度不足的部分明确保留为不可追溯。

新 `sample-coverage.json` 明确记录两个主机的原版已选来源数量、是否取得合格样本及 sf11 原因：`NO_SELECTED_HOST_SAMPLE` / `SELECTION_POLICY_REJECTED` / `ELIGIBLE_ORIGINAL_SELECTION`。没有合格样本时 `sf11_sample_status=NO_ELIGIBLE_SAMPLE`、`SF11_PROBE=NOT_RUN`；不访问备用 URL，也不再请求列表。

## 最小扩展和调用路径

复用原 `AuthPreflightInput`、`AuthPreflightTransport`、DouyinClient/accountTimeline、SelectedHostEvidence、LiveProbePolicy.select 和 LiveProbeTask。没有新建下载器、复制 Extractor 或修改原版来源选择规则。

新增三个 Swift 文件：

- `MediaRedirectProbe.swift`：三个角色名额、一次列表、原版选择、两条独立请求链、明确状态与脱敏输出。
- `RedirectNetworkSafety.swift`：下一跳 DNS 公网地址校验、不可变已校验目标、仅连一个数字地址的临时 CONNECT 通道。
- `RedirectProbeSelfTest.swift`：纯策略和合成网络入口，不能由真实入口切换成 fixture。

原 `MediaHostLiveProbe.swift` 只增加默认关闭的 Location 内存捕获、明确的第二跳 scope、可选本次会话 CONNECT 端口和固定 TLS 错误分类；原默认精确主机集合不扩大。旧入口仍不执行第二跳。`RuntimeAcceptance.swift` 仅新增明确模式；真实新模式位于 OFFLINE_ONLY 拦截之后。

新增 Python `redirect_probe.py`、`redirect_probe_tests.py`、`test_redirect_probe.py`、`validate_redirect_probe.py`。编排复用上一轮构建/基线/源码 seal/证据和脱敏门禁，先验证所有旧用例，再验证本任务的新用例，最后才允许读取在线步骤中的 Secret。

## 真实运行时的边界

作品列表最多一次，pageSize=18/maxPages=1/cursor=0/maxRetry=0，仍由原客户端请求；不查询详情、不分页补样本。优先保留一个原版实际选中的 www 地址和一个合格 sf11 地址。不是凭历史记录拼接签名或更换 CDN。

www 首次 GET 使用 Range: bytes=0-0，自动重定向回调始终拒绝。只有 **HTTP 302、任务终态已完成且取消已完成**，才考虑在内存中保存的原始 Location。Location 必须是绝对 HTTPS URL、精确下一跳主机、无 userinfo、无非 443 端口、无 fragment、无控制字符且符合现有规范主机检查。拒绝相对/协议相对、HTTP、非 HTTP(S)、超长或其他主机。完整 Location 和签名不 Codable、不写盘、不传 argv、不出现在日志/报告/Artifact。

下一跳还要通过目标安全检查：getaddrinfo 返回非空且限额内的 IPv4/IPv6 结果，所有地址都须通过公网策略；任何私网、本机、链路本地、共享地址、保留/文档/多播、映射/过渡地址或混合公网私网结果均拒绝。IPv6 限普通 global-unicast，并拒绝 IETF 特殊用途块、文档块及已回收 6bone 块；策略采取保守拒绝，不声称覆盖未来新登记的所有特殊用途。地址分类依据参考 [IANA IPv6 特殊用途注册表](https://www.iana.org/assignments/iana-ipv6-special-registry) 和 [IANA Global Unicast 表](https://www.iana.org/assignments/ipv6-unicast-address-assignments)。

安全检查不止 DNS 预检：从校验结果选择第一个数字地址，创建仅绑定 127.0.0.1 的本次临时 CONNECT 通道；通道只接受一次、只允许精确 `v5-dy-ov-experiment.zjcdn.com:443`，只建立一次到该数字地址 443 的 TCP 连接，不重新解析域名、不按连接失败尝试其他 IP。媒体 URL 保持原域名，URLSession 仍执行默认 TLS 主机/证书验证，不改为 IP URL、不跳过证书验证。

配置是单个 URLSession 的显式代理字典，禁用 PAC/例外和凭据存储；默认老探测完全不启用它。[Apple 会话代理文档](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/connectionproxydictionary) 明确该配置作用于会话任务，[本机端点参数](https://developer.apple.com/documentation/network/nwparameters/requiredlocalendpoint) 限制 listener 的绑定地址。TLS 默认验证及“不能绕过本机通道”有独立负向 fixture；在这些 macOS fixture 真正通过前，不称为已验证安全保证。

通道只中转有界密文块，每方向最多一块 16 KiB，发送完成后才读取下一块，不记录内容或原始错误。其计数独立记录 CONNECT 主机匹配、外连次数、公网数字地址固定、无 CONNECT 凭据及关闭请求。`stopped` 表示已对通道对象请求关闭；URLSession 的 cancel_completed 则只在真实 didComplete 回调中成立，二者不混淆。

第二次独立 GET 仍为 Range: bytes=0-0，不跟随任何重定向。再次返回 3xx 只记录 REDIRECT，代码中没有第三跳角色。403、429、认证挑战、TLS 及异常响应结束对应请求链；sf11 独立名额仍可执行。sf11 自己最多一次 GET，绝不跟随跳转。

三个角色各最多一个名额，总媒体 GET 最多三次；target 名额不能先于 www。所有请求均新建无 Cookie/Authorization 的 ephemeral 会话，头部由原探测器白名单重建；Secret 只用于列表客户端。206 仍要求 video/*、合法 bytes 0-0/N、声明长度为 1 或未声明且正文预算满足、无不允许的编码；应用接受不超过 1 字节。200 忽略 Range、HTML/JSON、无效范围和超量立即拒绝，取消后等待任务终态。不重试、不续传、不缓冲下载、不写媒体/.part。

delegate_received_bytes 和 accepted_bytes 独立记录。取消后的系统/URLSession 缓冲可能已超收，严格物理网络接收一字节上限仍为 NOT_PROVEN。DIRECT_MEDIA 仅表示有效视频类型的 206 一字节响应，不证明完整视频、可播放性或无水印。探测目标的临时 scope 不产生生产白名单批准。

## 验证结果与未完成项

Windows 实际执行 `python -B -m unittest discover -s runtime-harness -p test_*.py -v`：**99/99 PASS**，其中本任务新增 15 项；包括授权/凭据前置、两层离线门禁、最小子进程环境、超时不重试、子进程无结果不伪造成功、敏感内容拒绝、禁止生产批准、Artifact 明确清单及本机 HTTP fixture。测试中发现并修正了服务器变量名遮蔽 HTTP 模块的问题；最终日志已归档。超时或结果缺失后，请求计数标为 null/未知，不伪造实际 0 次。

YAML、仅 workflow_dispatch、xcode-27、contents:read、固定 Actions/上游 SHA、Shell bash -n、Secret 单点注入、32 个显式 Artifact 文件及保护范围静态检查 PASS。Windows 没有 Swift/macOS 环境，未安装 Swift；actionlint 未运行。以上结果不替代 Swift 编译或 Network.framework 行为验证。

已准备而尚未执行的 macOS 离线流程：

- 原有 83 项基线、12 个老策略断言和 19 个老 HTTP 用例必须先全部通过。
- 本任务 41 个策略断言：原版选中地址、绝对 URL/精确主机、私网/特殊用途 IPv4/IPv6、混合 DNS、三个名额、sf11 缺失状态等。
- 25 个合成重定向链用例：正确下一跳、未允许主机、HTTP/userinfo/端口/相对/非 HTTP(S)/缺 Location/私网 DNS、第二次 302、有效 206、200/403/429/HTML/错误范围、www 失败时 sf11 独立执行、sf11 有/无、没有任何合格样本。
- 三个临时通道用例：精确 CONNECT 中转到单一 loopback 目标、错误 CONNECT authority 不外连、URLSession 默认 TLS 在错误服务上失败且经本机通道，无生产 DNS/真实媒体请求。

链路 fixtures 在 loopback adapter 上复用同一 Swift 调度器和探测器；DNS 公网/私网 fixture 为显式合成输入，不声称进行了真实 DNS 查询。地址固定通道用例独立验证路由与 TLS 失败，不把未运行的真实 CDN TLS 成功伪造成测试结果。

新 Swift 编译、新策略/链路/通道 fixture 和真实本任务运行 URL、Artifact SHA-256 目前全部 **NOT_RUN**。上一轮运行 40319832707 及其 Artifact 仅作为历史首跳证据，不充当本任务第二跳验证。

## 工作流与下一步

两个新增工作流保持旧工作流不变，均固定 macOS xcode-27、20 分钟、contents:read、官方 Actions 完整 SHA、checkout 不持久化凭据、Artifact 保留 3 天。保留失败关闭和源码 seal，不存在输入或环境变量可以跳过离线门禁。

1. 先由用户手动运行 [DouStudioKit Media Redirect Probe 02 Offline Tests](https://github.com/a15762877559-ai/swiftdy/actions/workflows/doustudio-media-redirect-probe-offline.yml)。无输入、无 Secret；用例的外网被沙箱拒绝，仅受控 loopback 例外。编译失败或任何用例失败需先修复。
2. 取得该版本 macOS 编译及完整离线 PASS 后，再由用户另行决定手动运行 [DouStudioKit Media Redirect Probe 02](https://github.com/a15762877559-ai/swiftdy/actions/workflows/doustudio-media-redirect-probe.yml)。需明确授权确认及有权访问的规范主页；使用已有 DOUYIN_COOKIE，不重新提供给聊天或代码。工作流会重新验证同一提交的所有离线门禁后，才进行一次列表与最多三个媒体 GET。

Artifact 只上传明确白名单，先校验 JSON 无 URL/签名/凭据/真实 ID，再生成哈希清单。新增 hop-observations、sample-coverage、network-target-safety 和新离线结果；复用旧通用诊断文件。不上传 raw Location、DNS 地址、密文、服务器请求路径、视频或 .part。异常只记录固定类别。源码编译日志中的合成 URL 字面量按已有规则脱敏。

本轮准备后停止，**不自动 dispatch 任何工作流，不执行新的真实请求**。正常提交/推送与新工作流注册结果另见本任务 `publication.json`；最终收尾只更新报告和脱敏证据。

```ini
TASK = DOUSTUDIOKIT_MEDIA_REDIRECT_PROBE_02
PREPARATION = READY_FOR_MACOS_OFFLINE_VALIDATION
WINDOWS_STATIC = PASS
WINDOWS_PYTHON_TESTS = 99/99 PASS
MACOS_SWIFT_BUILD = NOT_RUN
SWIFT_REDIRECT_OFFLINE_TESTS = NOT_RUN
WWW_INITIAL_RESPONSE = NOT_RUN
WWW_REDIRECT_HOST = NOT_OBSERVED_THIS_TASK
REDIRECT_TARGET_PROBE = NOT_RUN
SF11_PROBE = NOT_RUN
MEDIA_REQUEST_COUNT = 0
MEDIA_RETRIES = 0
UNAPPROVED_REDIRECT_FOLLOWED = NO
FULL_VIDEO_DOWNLOADED = NO
HOST_SECURITY_REVIEW = BLOCKED
PRODUCTION_ALLOWLIST = EMPTY
NO_WATERMARK = NOT_TESTED
RUST_IMPLEMENTATION = NOT_STARTED
```
