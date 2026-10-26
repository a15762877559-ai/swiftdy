# DOUSTUDIOKIT_HARNESS_OFFLINE_FIX_01

日期：2026-10-26，Asia/Shanghai。本轮只诊断/修复独立 Harness 离线自检，不进行抖音网络测试、视频下载或 Rust 移植。

## 基线与原始失败

- 本地仓库：`D:\Projects\doustudio-runtime-acceptance`，main 起点 `600067842d523da4f0bc9c4fa9f8cb8f96caa900`，已核对远端一致。
- 上游固定 `362dad3d082e9f63c8efd360acc653ba169d40a2`，不修改。
- [历史运行 40267311040](https://github.com/achusonwork-bit/doustudio-runtime-acceptance/actions/runs/40267311040)：编译 PASS，离线自检 exit=1，在线步骤 skipped。
- 历史日志仅有 `Offline harness checks FAIL`，不能据此确定具体断言。完整原日志与 Artifact 已存在本地，历史证据保持不变。
- 原始入口：RuntimeAcceptance.swift 第 12–16 行附近，捕获全部异常后只输出泛化 FAIL。原 SelfTest.swift 第 30–64 行，第一个失败异常会终止后续检查。

## 阶段 A：诊断修改

将原有断言映射为 OFF-001..007，保留 fixture 内容、相等比较、异常预期及安全边界；分离用例状态，使某项失败不会隐藏其余结果。每项输出固定 ID、名称、目标函数、PASS/FAIL、安全错误类别、预期和脱敏实际摘要；开始执行前输出 BEGIN，结束写 selftest-results.json。任一 FAIL 返回 exit=1，结果文件写入异常同样失败；不输出上游异常原文。

| ID | 检查 |
| --- | --- |
| OFF-001 | 原主页 secUid 解析 |
| OFF-002 | 原两页请求及服务端游标 900 的传递 |
| OFF-003 | 原终止状态 hasMore=false 与字段条数 1 |
| OFF-004 | 原重复游标拒绝 |
| OFF-005 | 原 HTTP 403 必须抛出 blocked=true |
| OFF-006 | 原 HTML challenge 必须抛出 blocked=true |
| OFF-007 | 原请求游标不匹配错误 |
| OFF-008 | 非 HTTPS、凭据、非标准端口、fragment 及无关主页拒绝 |
| OFF-009 | JSON 整数、Boolean 与小数区分 |
| OFF-010 | has_more 数字类型 |
| OFF-011 | 原版 extractor 对模拟 ID、描述、发布时间的映射 |
| OFF-012 | 服务端耗尽后不继续读取 fixture |
| OFF-013 | HTTP 403 错误页状态，无作品/下载候选 |
| OFF-014 | 下载主机允许范围 |
| OFF-015 | HTML 伪媒体拒绝且不生成媒体哈希 |
| OFF-016 | 缺少凭据与存储错误的分类 |

附加 URL_SHAPE 诊断仅输出 URL 属性比较布尔值，不输出完整请求 URL。第一轮诊断没有改变 Observation.swift 的业务判断，没有预先猜测或修复根因。

## 独立离线入口与隔离

新增 `.github/workflows/doustudio-harness-offline.yml`，名称 `DouStudioKit Harness Offline Check`，仅 workflow_dispatch，无用户主页输入，xcode-27，20 分钟，contents: read，上游固定 SHA，官方 Actions 固定 SHA，checkout 凭据不持久化，Artifact 保留 3 天。

同一 Package.swift 和同一 Harness 源码编译。设置 OFFLINE_ONLY=1：无 --self-test 参数时立即输出 ONLINE_ENTRY_DISABLED_IN_OFFLINE_MODE 并 exit=64，工作流核对该退出码；带 --self-test 时只调用 SelfTest.run 并 return，不进入 execute。

代码路径证明：SelfTest 中每个 ObservingTransport 均显式注入 FixtureTransport；其 send 只移除内存响应或抛错，没有网络实现；SelfTest 不构造 DouyinClient/URLSessionTransport，不调用 accountTimeline、Downloader.download 或在线 execute。伪媒体仅为内存字节，不写媒体文件。系统存在 sandbox-exec 时另对自检进程施加 `(deny network*)`；否则明确记录只使用代码隔离，不伪称系统网络沙箱。

失败时保留逐项 JSON、日志、环境、构建/自检/入口保护退出码、源码保护结果。Artifact 仅 11 个明确路径，不含真实主页、媒体、环境全集或认证材料。

## 本地检查与保护

`python runtime-harness/validate_offline.py --diagnostic`：97 项 PASS，包括新工作流静态结构、表达式顺序、Shell 语法、Python 语法、16 个唯一用例、离线入口路径、初始化执行，以及 27 个历史受保护文件的哈希。

Windows 无 Swift 和 actionlint，未安装新工具，不宣称本地 Swift 编译/运行通过。已有构建工作流、真实运行工作流和历史证据未改；既有未跟踪 RUN 报告不暂存。

## 云端诊断与修复

诊断提交 `dc1b2a485b93ffc3d381ebd396ac1525d9d8af01` 的[首次离线运行 40270208701](https://github.com/achusonwork-bit/doustudio-runtime-acceptance/actions/runs/40270208701) 编译 exit=0，自检 exit=1：16 项中 10 PASS、6 FAIL。失败为 OFF-002、003、004、007、012、013，均因端点被误判，得到 `UNEXPECTED_REQUEST_OR_DOWNLOAD_LIMIT`。

原始首个失败对应 OFF-002：预期 `pages=2;second_cursor=900`，实际在第一次 send 时抛出上述异常，尚未进入分页映射。根因位于 Observation.swift 的 sendChecked 端点判定（修复前第 127 行）：Foundation URL.path 不保留此端点末尾斜杠，而代码与带斜杠路径比较。真实诊断 `URL_SHAPE legacy_path_matches=false;components_path_matches=true;host_matches=true` 证实差异。这是 Harness 对 Foundation API 的使用错误，不是 fixture 输入/预期错误；没有证据证明 Swift API 最近发生变更。

修复只将路径取值改为 URLComponents.path，仍精确比较相同主机和完整路径，不改为前缀匹配，不放宽边界。新增 OFF-017 验证正确端点进入 worklist，缺少末尾斜杠、额外子路径、相近路径和外域这 4 个近似地址均拒绝；OFF-018/019 精确验证 HTTP_403/HTML challenge 错误类别。原 OFF-005/006 仅要求 blocked=true，在诊断版中因错误路由也满足条件，故保留原断言并用新增用例避免假阳性。

首次 Artifact `12627759572`，SHA256 `95174c6116caead919f3717b240cdc88c14c433676864a806afbb184bf4bd862`，已核验下载哈希、ZIP CRC 和 11 文件白名单；保存到本轮证据 run-40270208701。真实隔离为 OS_SANDBOX_DENY_NETWORK，入口保护退出 64，上游 SHA 正确且源码干净。

修复后的本地静态验证 96 项 PASS（诊断专用“尚未修复”检查已移除），19 个固定用例；git diff --check 通过。修复后按授权仅执行了一次独立离线回归，结果如下。


## 阶段 D：真实 macOS 回归结果

[离线回归运行 40270472151](https://github.com/achusonwork-bit/doustudio-runtime-acceptance/actions/runs/40270472151)，测试提交 `44fb339dd5aea5e5b4a8c478aa4c82d8d4c9f77b`，GitHub conclusion=success，总时长 44 秒。

- 实际 runner：xcode-27 / arm64；macOS 27.0.1 (26A434)，Apple Swift 6.4 (swiftlang-6.4.0.34.1)，Xcode 27.1 (27A9275)。
- 编译 exit=0；自检 exit=0；19/19 PASS；入口保护 exit=64（符合预期）。
- 原失败点：旧 SelfTest.swift 第 39 行首次 send 抛错，阻止第 42 行两页/游标断言。OFF-002 回归实际为 `pages=2;second_cursor=900`，所有原失败项均通过。
- 自检以 OS_SANDBOX_DENY_NETWORK 运行，线上 execute 未调用，所有 send 使用内存 fixture，无媒体下载。GitHub checkout/Artifact 网络传输是 CI 基础设施操作，不是抖音请求。
- 上游 checkout 确认固定 SHA，tracked_source_clean=true；编译没有修改上游跟踪源码。
- Artifact `12627809721`，6182 bytes，保留 3 天，SHA256 `b49aa163d2a9043427a4db5117a935aecc0d8a603236ca420ea25169d458e037`。下载哈希、ZIP CRC、11 文件白名单及结果 JSON 均通过核验；未包含媒体或敏感认证材料。
- 两次运行的环境、构建日志、自检日志、逐项预期/实际值、退出码、源码保护和 Artifact 核验均在 `evidence/doustudio-harness-offline-fix-01/run-<运行ID>/`。目录中额外的 artifact-inspection.json 与成功截图是本地验收补充，不属于云端 11 文件 Artifact。

## 所有用例结果

原始历史日志不能独立区分失败断言；以下诊断列来自保留原实现的真实运行 40270208701，回归列来自 40270472151。

| ID | 检查 | 诊断运行 | 修复回归 |
| --- | --- | --- | --- |
| OFF-001 | Profile identifier | PASS | PASS |
| OFF-002 | Server cursor propagation | FAIL | PASS |
| OFF-003 | Terminal state and fields | FAIL | PASS |
| OFF-004 | Repeated cursor rejection | FAIL | PASS |
| OFF-005 | HTTP access rejection | PASS | PASS |
| OFF-006 | HTML challenge rejection | PASS | PASS |
| OFF-007 | Request cursor mismatch | FAIL | PASS |
| OFF-008 | Unsafe URLs | PASS | PASS |
| OFF-009 | JSON integer types | PASS | PASS |
| OFF-010 | Pagination flag type | PASS | PASS |
| OFF-011 | Model field mapping | PASS | PASS |
| OFF-012 | Stop after server exhaustion | FAIL | PASS |
| OFF-013 | Failed-page state | FAIL | PASS |
| OFF-014 | Media host allowlist | PASS | PASS |
| OFF-015 | Reject HTML media bytes | PASS | PASS |
| OFF-016 | Exception classification | PASS | PASS |
| OFF-017 | Exact endpoint routing regression | 新增回归 | PASS |
| OFF-018 | HTTP rejection exact category | 新增回归 | PASS |
| OFF-019 | HTML rejection exact category | 新增回归 | PASS |

OFF-005/006 诊断版的 PASS 仅表示原有 blocked=true 断言成立，不证明进入了正确的 HTTP/HTML 检查。OFF-018/019 已针对这个诊断盲点增加精确类别回归，全部通过。

## Git 交付与保护检查

- 诊断提交：`dc1b2a485b93ffc3d381ebd396ac1525d9d8af01`。
- 根因修复和回归提交：`44fb339dd5aea5e5b4a8c478aa4c82d8d4c9f77b`。
- 最终报告/证据随后单独普通提交；不改已通过测试的源码，不再次触发工作流。
- 改动清单：SelfTest.swift 逐项诊断及 19 用例；RuntimeAcceptance.swift 离线分支与入口保护；Observation.swift 精确路径修复；runtime-harness/offline_evidence.py、validate_offline.py；新增离线工作流；本报告与本轮 evidence 目录。Package.swift 未改。
- 本轮基线起的文件变更均在授权范围。27 个受保护历史文件哈希保持一致，包含两份已有工作流与历史证据/报告；详见 protection-verification.json。
- 既有未跟踪 RUN 报告哈希不变，未暂存或提交。最终工作区预计仅保留该既有未跟踪文件，提交后再次核验。
- 未修改其他项目；没有强推、历史重写、代理配置变更、真实接口测试或 Rust 实现。本轮完成即停止。

```ini
TASK = DOUSTUDIOKIT_HARNESS_OFFLINE_FIX_01
ROOT_CAUSE = IDENTIFIED
FAILED_ASSERTION = OFF-002
HARNESS_FIX = PASS
HARNESS_BUILD = PASS
HARNESS_OFFLINE_SELF_TEST = PASS
OFFLINE_REGRESSION = PASS
GITHUB_ACTIONS_RUN = https://github.com/achusonwork-bit/doustudio-runtime-acceptance/actions/runs/40270472151
REAL_DOUYIN_API = NOT_RUN
WORKLIST_FETCH = NOT_RUN
MULTI_PAGE_FETCH = NOT_RUN
VIDEO_DOWNLOAD = NOT_RUN
UPSTREAM_SOURCE_CHANGED = NO
ROOTNETSCOPE_CHANGED = NO
VIDEOFLOW_CHANGED = NO
RUST_IMPLEMENTATION = NOT_STARTED
```
