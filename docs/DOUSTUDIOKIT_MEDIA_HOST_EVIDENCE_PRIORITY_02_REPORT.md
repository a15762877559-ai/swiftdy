# DOUSTUDIOKIT_MEDIA_HOST_EVIDENCE_PRIORITY_02

准备和本地验证已完成，等待用户手动运行独立 macOS 离线工作流。本轮没有触发任何 GitHub Actions，没有新的抖音作品请求、媒体请求或 DNS 查询，没有读取真实 Cookie。**不能在 macOS 实测之前认定 Swift 修复验收通过。**

## 基线和根因

- 仓库：`D:\Projects\doustudio-runtime-acceptance`；远端 `achusonwork-bit/doustudio-runtime-acceptance`。
- 初始本地 HEAD 与远端 main 一致：`c4fcb9bd1f4eede023ee2d48ad42a02b0a6744f1`。
- 固定上游：`362dad3d082e9f63c8efd360acc653ba169d40a2`；只读 checkout HEAD 正确且工作区干净。
- [历史运行 40292928113](https://github.com/achusonwork-bit/doustudio-runtime-acceptance/actions/runs/40292928113)：编译 PASS、58/58 Swift 检查 PASS、单请求 HTTP 200 返回 21 条作品；1000 条诊断记录上限导致截断，4 条选中地址未关联。这是证据采集顺序和额度共享问题，不是接口失效。
- 原 `MediaHostAudit.collect` 按作品依次展开备用 URL、封面、头像等详细记录；所有记录共享 1000 条额度。额度被前面的备用地址用完后，后续选中地址也无法保留。历史证据原样保留。

## 修复后的顺序和精确关联

新增 `runtime-harness/Sources/RuntimeAcceptance/SelectedHostEvidence.swift`，原 MediaHostAudit.collect 委托同一实现。没有第二套选择器，没有修改原版 Extractor 或实际选择结果。

1. 先校验结构预算，再为每条唯一视频作品调用原版 `DouyinExtractor.work(from:collectionTime:)`。原版 `.downloads` 中的地址只在内存中保留。
2. 调用原版公开 `DouyinExtractor.selectBitrate` 获得真实排序结果及维度/FPS/bitrate/dataSize；核对原始码率项的排序键和该项 URL 数组**最后一个地址**。没有码率数组时核对 `video.play_addr.url_list` 最后一个值。
3. 将最终 Extractor 输出与来源字符串精确比较；收集所有相等的视频来源路径，包括多字段重复。另列 winning_source_paths 表示满足原版最终选择条件的路径；排序键相同且值相同时允许多个来源，不声称唯一。
4. 每条唯一视频保留一条 selected 记录，含 work_ref、selected_host、全部来源路径、匹配数、selection_method、selection_match、scheme/port/userinfo 和独立安全检查。work_ref 仅为运行内顺序号，真实作品 ID 不输出也不哈希。
5. 来源匹配与 URL 安全性分开：unsafe URL 可以确实来自原版 Extractor，但仍不能使整体 complete 成立。无地址、无精确来源、非规范主机、结构超限或不一致均失败关闭。
6. 真实 ID 只在内存中用于去重；重复作品不重复计数。同 ID 的地址或来源集合冲突则失败。多个来源关联分别计入 source_field_counts，不能增加 selected_work_count。
7. 全部主要记录完成后才进行备用地址汇总统计。第一阶段仍需在内存中扫描来源字符串以精确匹配；这些扫描不消耗备用统计额度。备用 URL 不再生成详细记录，按规范化主机聚合 occurrences、来源字段类别和运行内作品引用。独立预算保持 **1000 次备用 URL 统计**，没有提高原全局上限；超限只标记 ALTERNATE_SUMMARY_TRUNCATED，主要证据和完成状态不受其影响。

输入防护：最多 50 条作品、每条最多 128 个码率项、每个 URL 数组最多 256 项；通用结构限制深度 20、节点数 100000、字符串总量 4 MiB、单字符串 16384 bytes、单数组 1024 项、单对象 512 键。超限拒绝主要证据，不静默采用部分输入。它们是响应到内存后的结构预算，不宣称网络接收上限。没有为了绕过旧记录额度而提高它；原全局详细记录机制已拆分为必需记录和独立汇总。

封面、头像、音频仅保留独立数量，不进入选中视频主机或备用播放主机统计。图集/实况作品单独计数排除。任何完整 URL、路径、查询参数、标题、真实 ID 和凭据均不在输出类型中。

## 文件和工作流范围

- 新增 SelectedHostEvidence.swift、HostEvidencePrioritySelfTest.swift。
- MediaHostAudit.swift 接入新收集器，输出三个独立 JSON；原主机观察网络请求、认证配置、请求次数和原客户端不变。
- MediaHostAuditSelfTest.swift 的 HOST-014/015/017 随新 schema 更新断言：资源隔离、精确来源、主要结构超限仍必须验证；没有删除测试或改成无条件通过。
- RuntimeAcceptance.swift 的离线分支增加 `--media-host-evidence-self-test`，并运行新的回归；线上主机观察原有前置离线检查也会运行该组用例。
- `media_host_audit.py` 和既有 `doustudio-media-host-audit.yml` **仅追加三个 JSON 的初始化/Artifact 白名单**：selected-work-evidence、selected-host-summary、alternate-host-summary。静态比较确认在线工作流其他字段完全相同，未改变授权、Secret、请求或步骤。
- 新增 `.github/workflows/doustudio-media-host-evidence-tests.yml`：**DouStudioKit Media Host Evidence Tests**；仅 workflow_dispatch、无输入、无 Secret、xcode-27、20 分钟、contents: read、完整 SHA 固定的官方 Actions、persist-credentials: false、固定上游并核对 HEAD。
- `host_evidence_tests.py` 只负责离线证据；真实 Swift 用例在 deny network 沙箱中运行。编译和 GitHub checkout 所需基础设施网络不属于测试访问；用例不访问外网、不启动服务器、不进行 DNS/HEAD/GET。
- Artifact 明确列出 18 个文件，保留 3 天；检查结果数量和关联一致性，确认批准列表为空。编译日志若引用合成 URL 源码行，只移除该字面量行，保留诊断位置/类别。验证失败不上传不合规内容。

原单视频工作流仍关闭，SafeStreamingTransport 未改，生产批准白名单仍为空。未修改原匿名、认证和分页行为，未改上游、RootNetScope、VideoFlow、系统代理、v2rayN、Git 全局设置。

## 离线用例及当前结果

Windows：Python 测试 **20/20 PASS**（新离线证据边界 8 项，既有主机审计 wrapper 12 项）；YAML、bash -n、固定版本、无输入/无 Secret、Artifact 白名单、代码路径和变更范围静态检查 PASS。actionlint 未安装，未执行。

Swift/macOS：**NOT_RUN**。工作流计划执行原有 38 项通用/认证 + 20 项主机 + 新增 25 项优先证据测试，共 **83 项**。Windows Python 不模拟 Extractor，不替代这些测试结果。

| 新用例 | 实际验证目标 | 当前结果 |
|---|---|---|
| PRI-001～004 | 21 条作品、1260 个备用地址；全部主要关联完成；备用统计独立截断；主机计数 21 | NOT_RUN |
| PRI-005～007 | 原版码率排序、最后地址、缺失/空 bit_rate 回退 | NOT_RUN |
| PRI-008～009 | 多字段相同地址保留 4 个匹配和 2 个满足选择条件的路径，但只计 1 个作品 | NOT_RUN |
| PRI-010～011 | 强制传入与来源不匹配的合成选择值；缺失视频地址均有明确失败状态 | NOT_RUN |
| PRI-012 | 视频、封面、头像、音频和图集统计隔离 | NOT_RUN |
| PRI-013～014 | 重复作品 ID 去重；同 ID 地址冲突失败关闭 | NOT_RUN |
| PRI-015 | 序列化无 URL、路径、查询、合成敏感标记、标题和真实格式 ID | NOT_RUN |
| PRI-016～019 | 作品数、码率项、URL 项数和结构深度超限失败 | NOT_RUN |
| PRI-020～022 | 无自动批准、无通配符；恰好 1000 备用统计不误报截断；不安全地址不能通过完整性门禁 | NOT_RUN |
| PRI-023～025 | 原版排序中的 FPS、bitrate、data_size 逐级决胜规则 | NOT_RUN |

主 fixture 的期望为：21 条唯一视频、21 条 selected 记录、1 个 selected 主机、21 个匹配作品；备用 URL 总数 1260，统计 1000，ALTERNATE_SUMMARY_TRUNCATED=true，主要证据 complete=true。**这些是 fixture 预期，不是已发生的 Swift 运行结果。**

## 交付证据和待验收状态

`evidence/doustudio-media-host-evidence-priority-02/` 已提供七个指定文件及本地验证、保护记录。六个 Swift 输出文件目前明确标为 NOT_RUN，records 为空；未将 Python 构造数据伪装成真实 Swift 输出。用户手动运行后，真实 Artifact 将包含实际数据、退出码、受测 SHA、环境、逐项结果和哈希清单。

下列五个结果项需要真实 Swift 测试后才能判定 PASS/FAIL；准备阶段暂记 NOT_RUN，而不虚构已通过或已失败。

```ini
TASK = DOUSTUDIOKIT_MEDIA_HOST_EVIDENCE_PRIORITY_02
UPSTREAM_SOURCE_CHANGED = NO
REAL_WORKLIST_REQUEST = NOT_RUN
REAL_MEDIA_REQUEST = NOT_RUN
SELECTED_SOURCE_ASSOCIATION = NOT_RUN
SELECTED_EVIDENCE_COMPLETE = NOT_RUN
ALTERNATE_SUMMARY_ISOLATED = NOT_RUN
HOST_AGGREGATION_CONSISTENCY = NOT_RUN
SENSITIVE_DATA_REDACTION = NOT_RUN
SWIFT_BUILD = NOT_RUN
OFFLINE_TESTS = NOT_RUN
OFFLINE_WORKFLOW = NOT_RUN
APPROVED_HOSTS = 0
PRODUCTION_ALLOWLIST = EMPTY
REAL_VIDEO_DOWNLOAD = NOT_RUN
NO_WATERMARK = NOT_TESTED
AUTO_TRIGGERED = NO
```

## 手动执行和停止点

源码准备提交已普通推送：`8d50b102e4996626a309dc61f75d028df1f6f5d8`。GitHub 已登记工作流 ID `396849434`、state=active，核验时 total_runs=0。实际受测 SHA 暂为 NOT_RUN；注册成功不等于编译或测试通过。收尾提交只补充报告和发布证据，不改变源码。

只执行本地验证，未触发任何 Actions。329 个既有文件（含旧未跟踪 RUN 报告）核验只有已列明的 5 个文件发生修改；SafeStreamingTransport、下载工作流、所有历史证据及上游未变。原未跟踪 RUN 报告不暂存；普通提交推送，无强制推送。

下一步用户打开 [独立离线工作流](https://github.com/achusonwork-bit/doustudio-runtime-acceptance/actions/workflows/doustudio-media-host-evidence-tests.yml)，Run workflow → main → Run workflow，无需主页或 Cookie 输入。离线成功仅证明证据逻辑，不代表媒体主机批准。只有取得真实离线 PASS 后，才进入用户另行手动运行一次主机观察的阶段。本轮到准备发布为止停止。
