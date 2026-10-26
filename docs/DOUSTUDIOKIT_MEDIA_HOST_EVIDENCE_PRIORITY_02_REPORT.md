# DOUSTUDIOKIT_MEDIA_HOST_EVIDENCE_PRIORITY_02

用户手动触发的独立 macOS 离线验收已完成：**编译 PASS，83/83 项真实 Swift 检查 PASS**。本次只运行合成 fixture，未请求真实作品列表、媒体或读取真实 Cookie；没有自动触发或重试工作流。真实媒体主机仍未批准。

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

Swift/macOS：**83/83 PASS**，其中原有通用/认证 38 项、主机 20 项、新增优先证据 25 项。编译退出码 0，自检退出码 0；Windows Python 结果没有用于替代 Swift 实测。

| 新用例 | 实际验证目标 | 当前结果 |
|---|---|---|
| PRI-001～004 | 21 条作品、1260 个备用地址；全部主要关联完成；备用统计独立截断；主机计数 21 | PASS |
| PRI-005～007 | 原版码率排序、最后地址、缺失/空 bit_rate 回退 | PASS |
| PRI-008～009 | 多字段相同地址保留 4 个匹配和 2 个满足选择条件的路径，但只计 1 个作品 | PASS |
| PRI-010～011 | 强制传入与来源不匹配的合成选择值；缺失视频地址均有明确失败状态 | PASS |
| PRI-012 | 视频、封面、头像、音频和图集统计隔离 | PASS |
| PRI-013～014 | 重复作品 ID 去重；同 ID 地址冲突失败关闭 | PASS |
| PRI-015 | 序列化无 URL、路径、查询、合成敏感标记、标题和真实格式 ID | PASS |
| PRI-016～019 | 作品数、码率项、URL 项数和结构深度超限失败 | PASS |
| PRI-020～022 | 无自动批准、无通配符；恰好 1000 备用统计不误报截断；不安全地址不能通过完整性门禁 | PASS |
| PRI-023～025 | 原版排序中的 FPS、bitrate、data_size 逐级决胜规则 | PASS |

主 fixture 的期望为：21 条唯一视频、21 条 selected 记录、1 个 selected 主机、21 个匹配作品；备用 URL 总数 1260，统计 1000，ALTERNATE_SUMMARY_TRUNCATED=true，主要证据 complete=true。**本次真实 Swift 输出与上述预期一致；这是合成 fixture，不是真实用户作品。**

## 真实云端结果与证据

- [运行 40297971472](https://github.com/achusonwork-bit/doustudio-runtime-acceptance/actions/runs/40297971472)，受测提交 `0e5eeb9ca4de27580c65cc6c72483e9078610c61`，源码准备提交 `8d50b102e4996626a309dc61f75d028df1f6f5d8`。
- 环境：macOS 27.0.1 (26A434)、Xcode 27.1 (27A9275)、Apple Swift 6.4、arm64；上游 HEAD 与固定 SHA 一致且无改动。
- 所有 job 步骤 success，包括编译、禁止网络的 Swift fixtures、证据与源码保护校验及 Artifact 上传。逐步结果见 `run-40297971472/jobs.json`。
- 21 条 selected 全部保留且精确关联，未匹配为 0；1 个合成选中主机对应 21 条作品。备用地址只统计 1000 次并独立截断，primary_complete=true。
- Artifact ID `12638777679`；下载 ZIP SHA-256：`a13f3e4b4133900f5731820c16dc4b77d5dce28fe2b2a10e97f93d1b0f3bee4b`，与 GitHub digest 一致。CRC、18 文件白名单及 runner 清单中 17 个文件哈希全部验证通过。
- 原始 Artifact 文件保存在 `evidence/doustudio-media-host-evidence-priority-02/run-40297971472/`，未改写；附加 jobs、GitHub Artifact 元数据及本地核验记录。根目录六个必需 JSON 已替换为同次运行的真实 Swift 合成测试输出。
- 新旧用例的逐项 ID、期望、实际摘要、状态和错误类别均在三个 selftest-results 文件内。Artifact 不含媒体文件、Cookie 或完整媒体 URL；日志按已有规则脱敏，不能称为未经处理的原始日志。

```ini
TASK = DOUSTUDIOKIT_MEDIA_HOST_EVIDENCE_PRIORITY_02
UPSTREAM_SOURCE_CHANGED = NO
REAL_WORKLIST_REQUEST = NOT_RUN
REAL_MEDIA_REQUEST = NOT_RUN
SELECTED_SOURCE_ASSOCIATION = PASS
SELECTED_EVIDENCE_COMPLETE = PASS
ALTERNATE_SUMMARY_ISOLATED = PASS
HOST_AGGREGATION_CONSISTENCY = PASS
SENSITIVE_DATA_REDACTION = PASS
SWIFT_BUILD = PASS
OFFLINE_TESTS = PASS
OFFLINE_WORKFLOW = PASS
APPROVED_HOSTS = 0
PRODUCTION_ALLOWLIST = EMPTY
REAL_VIDEO_DOWNLOAD = NOT_RUN
NO_WATERMARK = NOT_TESTED
AUTO_TRIGGERED = NO
```

## 发布、保护检查和停止点

源码准备提交 `8d50b102e4996626a309dc61f75d028df1f6f5d8`、准备报告提交 `0e5eeb9ca4de27580c65cc6c72483e9078610c61` 均已发布。本次验收结果交付仅更新本任务报告与证据，不修改 Harness 或任何工作流。初始 HEAD 与远端 main 一致。旧未跟踪 `docs/DOUSTUDIOKIT_GITHUB_ACTIONS_BUILD_01_RUN_REPORT.md` 保留且不暂存；历史其他任务证据不变。

上游、SafeStreamingTransport、失败关闭的单视频工作流、原匿名/认证/分页功能保持不变。没有操作其他项目、系统代理、v2rayN 或 Git 全局配置，没有强制推送。

**离线证据修复验收通过；真实主机审计尚未通过。** 批准主机仍为 0，生产白名单为空，下载门禁保持关闭。下一步可由用户另行手动运行一次 [DouStudioKit Media Host Allowlist Audit](https://github.com/achusonwork-bit/doustudio-runtime-acceptance/actions/workflows/doustudio-media-host-audit.yml)，输入有权访问的规范公开主页并确认自己的登录态授权；本助手未触发该流程。该流程仅一次作品列表请求并解析主机字符串，不访问媒体 URL。取得新证据后再分别审核来源与主机可信关联，不能因本次合成测试 PASS 自动批准主机。

## 用户后续手动在线观察：40299734675

用户另行手动运行主机观察后，真实来源证据也已验证：一次作品列表请求 HTTP 200、21 条作品、21 条选中记录全部匹配，未匹配 0；主要证据未截断，备用汇总独立截断。编译和 83 项离线检查通过。受测 SHA 为 `a78c2f54c5e16c15e5cb7caa8e67b85fca3ec061`。

此后续在线观察与上文离线任务分开记录；上文 REAL_WORKLIST_REQUEST=NOT_RUN 指离线验收阶段，不表示本次用户手动观察没有作品列表请求。本次仍无媒体请求或下载。实际选中主机为 sf11-cdn-tos.douyinstatic.com（1 条）和 www.douyin.com（20 条）；来源关联 PASS，但独立主机安全审核 BLOCKED，批准数 0。

详情见同仓库 `docs/DOUSTUDIOKIT_MEDIA_HOST_ALLOWLIST_AUDIT_01_REPORT.md` 最新实测节和 `evidence/doustudio-media-host-allowlist-audit-01/run-40299734675/`。未更改任何源码或工作流，未自动触发、重试或启用真实下载。
