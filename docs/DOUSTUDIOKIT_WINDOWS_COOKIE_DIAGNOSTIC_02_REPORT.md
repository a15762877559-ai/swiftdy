# DOUSTUDIOKIT_WINDOWS_COOKIE_DIAGNOSTIC_02

日期：2026-10-27。项目：`D:\Projects\swiftdy`。

已修复整体结构错误导致全部必需字段被标为 `INVALID_FORMAT` 的诊断问题。严格凭证校验保持原规则。仅执行了一次用户指定 TXT 的生产版离线诊断，没有恢复阶段 A。

## 本次本地文件结论

2026-10-27 05:25:49 UTC，使用本次源码构建的 Release EXE 执行一次：

```powershell
.\rust-mvp\target\release\doustudio.exe credential-check --cookie-file 'E:\test.txt' --json
```

```ini
COOKIE_STRUCTURE = FAIL
STRUCTURE_REASON = COOKIE_SEGMENT_MISSING_EQUALS
MSTOKEN_FIELD = UNKNOWN
UIFID_FIELD = PRESENT
FIELD_INSPECTION = PARTIAL
LOCAL_CREDENTIAL_STRUCTURE = FAIL
STRICT_SIGNING_VALIDATION = REJECT
SIGNING_ALLOWED = NO
SIGNING = NOT_RUN
REAL_HTTP_REQUESTS = 0
REAL_MEDIA_REQUESTS = 0
```

`UIFID` 在可可靠解析的片段中被确认存在；`msToken` 未在这些片段中被观察到。由于整体存在无法解析的片段，不能将 `UNKNOWN` 解释为绝对缺失。两组均未识别出疑似必需字段片段，仍不改变部分扫描的限制。此次程序退出码为 1，符合拒绝无效整体结构的预期。

只有 Rust 生产程序读取原 TXT；外层执行器仅接收脱敏 JSON，并在固定键名、枚举、静态别名和零计数的白名单核验通过后保存结果。没有再次读取、修改或自动清洗 TXT，没有获取或补齐凭证。证据不包含原始 Cookie、值、片段、位置、值长度或凭证摘要。

## 实现与边界

- `credentials.rs` 共用分号扫描、整段首尾空白处理、首个等号拆分、字段名规则和精确大小写匹配。没有另建独立 Cookie 解析器。
- `StrictValidation` 仍先执行全部既有结构检查，再执行必需字段解析；正式 Session 和签名入口继续调用这一严格路径。没有修改 A-Bogus、WebSign、网络流程、生产白名单或 VideoFlow Host。
- `DiagnosticInspection` 仅检查可可靠解析的完整片段。非法字段名或含控制字符的片段整体跳过，不把换行当分隔符，不修复原输入。结构原因沿用原优先级，只输出第一个固定类别，不输出具体片段。
- 可确认的字段返回 `PRESENT`、`EMPTY` 或 `DUPLICATED`。完整扫描未找到才返回 `MISSING`；部分扫描未观察到返回 `UNKNOWN`。疑似必需字段名且无法可靠解析时返回 `MALFORMED_CANDIDATE`。已确认的同名重复优先保留 `DUPLICATED`。
- JSON 同时保存最终状态、`observation`、`parseable_status` 和疑似片段布尔标记；例如正常字段和疑似同名片段同时存在，已确认的 `PRESENT` 不会丢失，但最终状态保持保守。
- 空输入可完整确认字段缺失，整体结构仍失败。超限输入不扫描字段，使用部分扫描和 `UNKNOWN`。整体格式通过与必需字段通过分别判断。
- `msToken` 大小写敏感。UIFID 别名优先级仍为 `uifid`、`uifid_temp`、`uifidtemp`、`UIFID`、`UIFID_TEMP`、`UIFIDTEMP`。不同别名不是同名重复；任一已支持别名同名重复仍拒绝，包括空值或未选中的别名。
- 默认 `rpassword` 隐藏输入与主动选择的 `--cookie-file` 均保留。外部 TXT 安全读取、内存清零行为未改动。诊断返回不持有输入引用或凭证副本；渲染之前释放 `Zeroizing` 输入。
- `--json` 提供固定结构的脱敏 stdout，失败仍为退出码 1。`STRICT_SIGNING_VALIDATION = PASS` 也只表示本地严格凭证检查通过；诊断命令始终 `SIGNING_ALLOWED = NO`，不会调用签名器或创建异步网络运行时。

## 构建与测试

开始时 HEAD、本地 main 与远端 main 一致：`6fa07783ad26d78c7fb77f547eff9776d01b7b7b`。既有未跟踪的阶段 A 报告及证据保持原样，没有覆盖、重置或纳入本次提交。

Release：`doustudio 0.1.0`，Rust `1.91.1`，`x86_64-pc-windows-msvc`，默认生产特性，无 `offline-test`。

EXE SHA-256（仅二进制身份，不是凭证摘要）：

```text
cd457bec740588f2ef35ab4621ba1f7917e0dc9ec6a538450d91102c9b8594fd
```

执行 `scripts/offline-acceptance.ps1`，指定本任务 ID 和新证据目录；Cargo 使用 `--locked --offline`。

| 检查 | 结果 |
| --- | --- |
| Windows Release 编译 | PASS |
| cargo fmt --all -- --check | PASS |
| Clippy：生产 / offline-test，all-targets，-D warnings | PASS / PASS |
| 全部生产配置 Rust 测试 | 30 PASS，0 FAIL |
| 全部 offline-test 配置 Rust 测试 | 60 PASS，0 FAIL |
| acceptance --first-page-only 及外部 Cookie 文件回归 | PASS，合成数据 |
| 原生 Windows CTRL_C_EVENT 回归 | PASS，退出码 130，临时文件清理成功，无最终文件提交 |
| 脱敏 JSON schema / 值无关性 / CLI 退出码 | PASS |
| 用户 TXT 的单次生产版诊断 | 已执行；结构 FAIL，严格校验 REJECT，结果如上 |

新增测试覆盖 28 组部分扫描情形：错误片段在字段之前、之后或之间；缺失观察、空值、重复；不同别名、未选中别名重复；裸字段名、字段名空格及非法字符；疑似片段与已确认字段并存；近似但不同的字段名；控制字符、换行、值内等号以及无关字段重复。原矩阵继续覆盖完全合法结构、真正缺失字段、大小写、重复粘贴、空输入及文件安全规则。

结构错误的合成用例同时断言 `Session::new` 和两组严格 `resolve` 都拒绝。输出测试比较不同值和不同长度的合成凭证，要求 JSON、文本和 Debug 结果完全相同；CLI 子进程检查 stdout/stderr 不含合成凭证标记。JSON 白名单和实际调用结果一致。

诊断 CLI 测试开启既有运行时、签名、DNS/HTTP 客户端边界哨兵；独立探针确认哨兵能在实际操作前失败，正常诊断未触发。此为源码边界与执行回归证据，不声称已做操作系统级抓包。全部回归中的 HTTP、媒体与签名测试使用回环端点、合成 MP4 和合成签名向量；它们不属于真实平台请求。原生 Ctrl+C 回归也只访问回环合成服务。

## 脱敏证据

目录：`evidence/doustudio-windows-cookie-diagnostic-02/`。

- `summary.json`、`build-identity.json`：构建、工具版本和各检查状态。
- `test-production.log`、`test-offline.log`、两套 Clippy 与 Release 日志：完整离线回归结果。
- `synthetic-credential-inspection.json`：28 组固定场景名称与脱敏结果，不保存输入 fixture。
- `local-file-diagnostic.json`、`local-file-execution.json`：单次用户文件诊断的脱敏状态、执行次数及退出码。
- `windows-ctrl-c.json`、`windows-ctrl-c.log`：原生控制台取消回归。
- 其余 CLI 日志与 `synthetic-cli-*`：既有合成验收与合成媒体验证证据。日志只规范化行尾空白，不改变结果。

```ini
TASK = DOUSTUDIOKIT_WINDOWS_COOKIE_DIAGNOSTIC_02
RUST_BUILD = PASS
OFFLINE_TESTS = PASS
CREDENTIAL_PARSER_REUSED = YES
REQUIRED_FIELD_DIAGNOSTIC = PASS
STRICT_VALIDATION_REGRESSION = PASS
SENSITIVE_DATA_PROTECTION = PASS
USER_FILE_DIAGNOSTIC_RUNS = 1
DIAGNOSTIC_DNS_REQUESTS = 0
DIAGNOSTIC_NETWORK_REQUESTS = 0
DIAGNOSTIC_SIGNING_REQUESTS = 0
REAL_SIGNING = NOT_RUN
REAL_WORKLIST = NOT_RUN
REAL_PAGINATION = NOT_RUN
REAL_VIDEO_DOWNLOAD = NOT_RUN
PRODUCTION_ALLOWLIST = EMPTY
NO_WATERMARK = NOT_VERIFIED
```

本轮到此停止。结构失败不会自动触发修复、重试、真实签名、阶段 A、分页或视频下载。
