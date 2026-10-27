# DOUSTUDIOKIT_WINDOWS_RUST_ACCEPTANCE_ENTRY_02

2026-10-27。新增独立交互式 `doustudio acceptance`，完成本机 Windows Release 构建、43 项唯一 Rust 离线测试及 1 项 Windows 原生 Ctrl+C 测试。本轮真实作品请求 0、真实媒体请求 0，未触发 GitHub Actions。

## 基线与受测版本

- 工程：`D:\Projects\swiftdy\rust-mvp`。
- 开始时 HEAD 与重新 fetch 后的 origin/main 均为 `a34dae0f091499dfcade979ed9cbf712011a1a9d`，没有远端新增提交。已有未跟踪的 REAL_ACCEPTANCE_01 预检报告及证据目录保留原样，不混入本轮提交。
- 实现及受测源码提交：`0219bdfdc9b4d5c5f0f431327dbb44ecedf6ae0d`，已通过已有授权账号正常推送到 main；没有强制推送、修改 Git 身份或修改全局配置。
- Release：`D:\Projects\swiftdy\rust-mvp\target\release\doustudio.exe`；CLI 包版本仍为 `doustudio 0.1.0`，必须使用提交及文件哈希识别本轮构建，不能仅凭版本字符串。
- 本轮 EXE SHA-256：`6ffe2afd1e4ef977bd40946d6b1f2f5d250e78749b1b2b694a832bf74d644454`。
- 原 Actions 40434779760 的 EXE 为 `e57d70bf811be0d8b2e684fd10d76b7e59fc9aaae7c02b9ff9ae19b6aede50c6`；原本机 MVP EXE 为 `24948adcced7bfb0e42cea93c7b0dd9d75fb66f13633be994b87adc00a147f32`。三者分别记录，不混同。原 Actions 产物保留于工作目录，没有覆盖其证据。

## 入口与复用边界

新 `acceptance.rs` 负责交互、授权状态、内存快照、锁定对象和类型化脱敏报告。旧 `list`、`download`、`verify` 命令保持兼容；原 `download --index` 的重新取列表行为没有隐式改变，严格验收应使用新入口。

`client.rs` 在相同请求路径增加可选观测结果：签名构造完成、请求开始、准确 HTTP 状态。原 `fetch_page` 和 `request_page` 保留原接口和错误语义；验收报告将 401、403、429 分别分类。签名构造完成不等于平台接受签名，真实接受情况仍未验证。

`extractor.rs` 仅增加不进入旧 Work 序列化的布尔校验结构。封面存在、非空字符串 URL 数组、规范 HTTPS DNS 主机分别记录；不访问或下载封面。验收选择对缺失/未知类型、图集、直播结构及非法播放地址保守拒绝；普通视频明确支持类型 0、4。原分辨率/FPS/码率/data_size 元组比较与最后一个 URL 选择规则未改动。

`signing.rs`、`auth.rs`、`media.rs`、`transport.rs`、`storage.rs` 与 a34dae0 的 Git blob 完全一致。旧 `tests/contracts.rs` 和 `tests/offline_http.rs` 也完全一致；没有降低断言或删除原回归。Swift 上游、旧报告/证据、VideoFlow、RootNetScope 和系统代理未修改。详见 `source-boundary.json`。

## 授权和作品锁定

1. 本机明确输入 `AUTHORIZE LIST` 才接受授权 A；随后读取授权主页和隐藏 Cookie。拒绝 A 的测试确认网络请求 0、凭据读取 0。
2. 第一页显示脱敏诊断，输入 `CONTINUE PAGES` 后才继续，最多三页总计；服务器提前耗尽正常结束。拒绝继续时停止本次流程。
3. 仅显示当前序号、发布时间、时长、尺寸、码率及可选状态，不显示 ID、标题或 URL。取消选择时媒体请求 0。
4. 选择后克隆完整 Work 和选定媒体地址进入不可序列化的 `LockedWork`，下载消费该对象。测试在锁定后反转列表并改写原对象地址，最终仍请求锁定时的原地址，而且列表请求为 0。
5. 必须再输入 `DOWNLOAD <序号>` 才获得授权 B。拒绝 B 时媒体请求 0；不存在默认同意，也不会从 A、Swift 或历史 Actions 推导 B。
6. 下载阶段不调用列表客户端；凭据 Session 在列表完成后、选择和下载前释放。临时作用域只读且必须由用户事先审查，未匹配的精确主机在网络前拒绝。

真实构建拒绝管道代替控制台授权确认，并在 `DOUSTUDIO_OFFLINE_ONLY` 存在时直接拒绝真实入口。仅 `offline-test` 构建支持固定合成 Cookie 与严格 `127.0.0.1` fixture；其中每页仍调用同一套原生签名，只将目标替换为本地测试服务。

## 逐页诊断与真实 CLI 合成运行

`synthetic-cli-acceptance.json` 来自实际启动 Windows EXE，不是手写模拟结果。实际运行结构如下，端口由测试随机分配，所有数据均为合成数据：

```powershell
# 仅 offline-test 构建，且需测试提供的本地 fixture 服务
doustudio.exe acceptance --fixture-url http://127.0.0.1:<fixture-port>/list --output <临时合成目录> --evidence <临时JSON>
# 测试 stdin：AUTHORIZE LIST → CONTINUE PAGES → 1 → DOWNLOAD 1
```

| 页 | HTTP | 返回 | 本页唯一 | 新增唯一 | 累计唯一 | 去重 | has_more | 游标推进 |
|---|---|---|---|---|---|---|---|---|
| 1 | 200 | 3 | 2 | 2 | 2 | 1 | true | true |
| 2 | 200 | 2 | 2 | 1 | 3 | 1 | true | true |
| 3 | 200 | 1 | 1 | 1 | 4 | 0 | false | 不适用，服务端耗尽 |

该运行仅 3 次 loopback 列表 GET 和 1 次 loopback 完整媒体 GET，没有封面请求。每页原生签名完成，服务端断言实际游标依次来自前页响应；原始游标和签名不进入持久证据。HTTP 401/403/429 的三个独立拒绝场景均只请求一次并立即停止。

合成下载使用 HTTP loopback，因此报告中的生产 `playback_address_valid` HTTPS 数量为 0，这是准确诊断；只有测试特性允许该精确 loopback 目标，真实构建没有此例外。HTTPS 播放与封面字段的合法/缺失/非法结构另有合约测试。

## 下载与媒体验证

继续调用原安全下载器，`MAX_MEDIA_BYTES=104857600`，有界流式传输。既有恰好 100 MiB、未知长度超限、302、TLS、自签证书拒绝、无重试、无续传、无媒体 Cookie/Authorization/Referer/Range、不覆盖、取消/失败清理测试全部通过。应用接受与写盘预算不是操作系统或底层网络物理接收硬限额。

合成实际 CLI 运行：9,450 字节，H.264，64×64，1 秒，30 fps，全片解码 30 帧；SHA-256 `03bd18ac57f6b885c7be954267db1f9174ef24f023699b228faccf25745ec3c5`，两次散列一致。应用接受量=写盘量=文件大小，最终原子提交成功，`.part` 清理通过。测试结束后合成视频由临时目录所有者删除，没有进入 Git 或 Artifact。

`verify.rs` 保留原 ffprobe、容器、时长、帧数与全片解码检查，增加同一次完整解码的逐帧 `showinfo` 计数。只流式解析帧序号和时间戳，不持久化 stderr；单行上限 8 KiB，进度 stdout 上限 64 KiB，沿用超时、取消、等待子进程退出及协议限制。

首帧必须观察到序号 0；中间覆盖为时长中点 ± max(两帧时长, 2.5% 时长)；结尾覆盖为达到 max(总时长减两帧, 95% 总时长)。必须完整解码正常结束、逐帧数量等于完整解码报告数量，并满足全部旧校验，才返回 PASS。新增帧率、前后 SHA 一致、首中尾覆盖、完整结束、解码错误观测布尔字段；不将抽样解码作为全片成功。

Windows 原生取消证据：Python 标准库测试辅助程序创建独立隐藏控制台，向实际 EXE 发送 `GenerateConsoleCtrlEvent(CTRL_C_EVENT)`；真实信号触发既有 tokio Ctrl+C 处理，退出码 130，1 次 loopback 列表、1 次 loopback 媒体 GET，未提交最终文件且没有残留 `.part`。辅助程序不修改系统配置，Python 不是产品运行依赖。

## 离线验证结果

最终命令：

```powershell
# 本机既有隔离 Rust 工具链环境，未改全局配置
./scripts/offline-acceptance.ps1 -TaskId DOUSTUDIOKIT_WINDOWS_RUST_ACCEPTANCE_ENTRY_02 -EvidenceDir ../evidence/doustudio-windows-rust-acceptance-entry-02
```

| 项目 | 结果 |
|---|---|
| Rust 1.91.1 Windows MSVC Release | PASS |
| cargo fmt --check | PASS |
| 默认及 offline-test Clippy，-D warnings | PASS |
| 默认 Rust 测试 | 16 PASS |
| offline-test Rust 测试 | 42 PASS |
| 合并后的唯一 Rust 测试 | 43 PASS：旧 31 + 新 12；不重复计数 |
| Windows 原生 Ctrl+C 辅助测试 | 1 PASS |
| 原有 list/download/verify 实际 EXE 回归 | PASS |
| 新 acceptance 实际 EXE 完整合成流程 | PASS |
| 合成媒体完整解码、首中尾覆盖、两次 SHA | PASS |
| 证据脱敏扫描与受保护源文件比较 | PASS |
| GitHub Actions 本轮运行 | NOT_RUN，未自动 dispatch |

工作流仍仅 `workflow_dispatch`，只增加显式列举的合成诊断文件；没有增加自动触发、Secret、生产账号或真实媒体步骤。`workflow-static.json` 记录 YAML 解析及手动触发/只读权限检查。

## 脱敏与交付

证据目录：`evidence/doustudio-windows-rust-acceptance-entry-02/`。包括完整编译/Clippy/测试日志、合成逐页 JSON、真实 CLI 脱敏交互日志、原生 Ctrl+C 结果、验证结果、源文件边界与 EXE 哈希、脱敏检查和证据哈希索引。日志只统一 UTF-8/LF 和行末空白，不改变测试结果。

诊断结构未持有 Cookie、作品 ID、标题、签名 URL 或原始游标字段；测试用敏感标记核对 stdout、stderr 和 JSON 都没有泄漏。诊断落盘使用 create_new，拒绝覆盖已有文件。媒体清理诊断比较前后 `.part` 集合，保留用户先前已有文件，不声称清理用户其他任务的临时文件。

实现提交已正常推送；本报告及证据在随后独立提交中归档，并按普通 fast-forward 推送核验。原有 REAL_ACCEPTANCE_01 预检报告和证据仍为本地原有未跟踪文件，未修改、未删除；构建产物继续忽略，不进入 Git。最终报告证据提交号以本次交付消息及 Git 日志为准。

## 最终状态与停止点

```ini
TASK = DOUSTUDIOKIT_WINDOWS_RUST_ACCEPTANCE_ENTRY_02
RUST_BUILD = PASS
OFFLINE_TESTS = PASS
PAGE_DIAGNOSTICS = PASS
EXACT_HTTP_STATUS = PASS
COVER_VALIDATION = PASS
SELECTED_WORK_LOCK = PASS
AUTHORIZATION_GATES = PASS
MEDIA_VERIFY_DIAGNOSTICS = PASS

REAL_WORKLIST_REQUESTS = 0
REAL_MEDIA_REQUESTS = 0
REAL_VIDEO_DOWNLOAD = NOT_RUN
PRODUCTION_ALLOWLIST = EMPTY
NO_WATERMARK = NOT_VERIFIED
VIDEOFLOW_INTEGRATION = NOT_STARTED
```

本轮没有真实 Cookie、真实账号、封面 CDN 或视频访问。真实签名被平台接受仍需后续授权 A 的单页实际结果；真实下载仍需指定作品的授权 B、用户本地输出目录和精确已审查主机作用域。音频解码及可靠画面检查没有执行。完成离线交付后停止，不自动进入真实验收。
