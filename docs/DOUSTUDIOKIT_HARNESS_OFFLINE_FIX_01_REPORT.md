# DOUSTUDIOKIT_HARNESS_OFFLINE_FIX_01

日期：2026-10-26，Asia/Shanghai。本轮只诊断/修复独立 Harness 离线自检，不进行抖音网络测试、视频下载或 Rust 移植。

## 基线与原始失败

- 本地仓库：`D:\Projects\doustudio-runtime-acceptance`，main 起点 `600067842d523da4f0bc9c4fa9f8cb8f96caa900`，已核对远端一致。
- 上游固定 `362dad3d082e9f63c8efd360acc653ba169d40a2`，不修改。
- [历史运行 40267311040](https://github.com/achusonwork-bit/doustudio-runtime-acceptance/actions/runs/40267311040)：编译 PASS，离线自检 exit=1，在线步骤 skipped。
- 历史日志仅有 `Offline harness checks FAIL`，不能据此确定具体断言。完整原日志与 Artifact 已存在本地，历史证据保持不变。
- 原始入口：RuntimeAcceptance.swift 第 12–16 行附近，捕获全部异常后只输出泛化 FAIL。原 SelfTest.swift 第 16–64 行，第一个失败异常会终止后续检查。

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

待实际运行后补记。先仅运行新增离线工作流；若失败，必须取得具体用例和实际值，只有有证据的修复才允许第二次离线验收。根因不明确时停止，不盲目循环。

```ini
TASK = DOUSTUDIOKIT_HARNESS_OFFLINE_FIX_01
ROOT_CAUSE = UNRESOLVED
FAILED_ASSERTION = UNKNOWN
HARNESS_FIX = NOT_APPLIED
HARNESS_BUILD = NOT_RUN
HARNESS_OFFLINE_SELF_TEST = NOT_RUN
OFFLINE_REGRESSION = NOT_RUN
GITHUB_ACTIONS_RUN = NOT_RUN
REAL_DOUYIN_API = NOT_RUN
WORKLIST_FETCH = NOT_RUN
MULTI_PAGE_FETCH = NOT_RUN
VIDEO_DOWNLOAD = NOT_RUN
UPSTREAM_SOURCE_CHANGED = NO
ROOTNETSCOPE_CHANGED = NO
VIDEOFLOW_CHANGED = NO
RUST_IMPLEMENTATION = NOT_STARTED
```
