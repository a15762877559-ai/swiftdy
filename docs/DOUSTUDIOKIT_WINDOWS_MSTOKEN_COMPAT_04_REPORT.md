# DOUSTUDIOKIT_WINDOWS_MSTOKEN_COMPAT_04

2026-10-27，Asia/Shanghai。已按用户最终决定调整默认输入契约，没有新增兼容模式开关。仅进行了离线开发、合成测试和 Git 交付；没有读取用户 Cookie 文件或恢复阶段 A。

## 实现结果

| Cookie 情况 | 默认请求行为 | 离线诊断 |
| --- | --- | --- |
| msToken 非空 | 使用原解析值，保留原有编码与参数位置 | PRESENT / ORIGINAL |
| msToken 为空 | 保留 `msToken=` | EMPTY / EMPTY |
| msToken 缺失 | 保留 `msToken=` | MISSING / EMPTY |
| msToken 同名重复，包括空值重复 | 拒绝 | DUPLICATED；请求值未解析 |
| Cookie 整体非法 | 拒绝 | 结构 FAIL；不将 UNKNOWN 当成 MISSING |
| UIFID 缺失、无可用非空值或同名别名重复 | 拒绝 | 保留原严格规则 |

“原值”指已有共享 Cookie 解析器返回的值：整段首尾空白处理、首次等号拆分及大小写规则不变；值内等号和原有前导空格语义不变。没有额外清洗、生成或获取 token。

- `credentials::resolve_ms_token` 复用原严格结构检查与 `field` 扫描。仅 `Missing` / `Empty` 返回空字符串；`Present` 返回原借用值；重复或非法结构仍报错。
- `Session::cookie_value` 保持通用非空必需字段语义，继续供 UIFID 使用。新增专用 `Session::ms_token_request_value`，防止为 msToken 放宽的规则影响 UIFID。
- `list_url` 使用专用解析结果，参数列表仍无条件含 `msToken`，位置保持在 `uifid` 与 `sec_user_id` 之间。
- 生产和测试共用私有 `list_url_at` 构造路径，允许测试注入固定时钟与随机源。A-Bogus 对最终业务参数序列编码后签名；同一序列随后追加 a_bogus，交由 WebSign 追加时间戳并覆盖签名。没有重新排序或另建不同的 token 参数集合。
- A-Bogus / WebSign 算法本身未修改。网络、重试、授权、分页、CDN 白名单、媒体预算、视频验证及清理策略均未修改。

## 诊断接口

`credential-check` 对结构合法且 UIFID 有效的 Cookie，允许 msToken 为 `MISSING` 或 `EMPTY`，严格凭证检查通过。诊断仍不执行签名、DNS 或 HTTP。

```ini
MSTOKEN_FIELD = PRESENT / EMPTY / MISSING / UNKNOWN / DUPLICATED
MSTOKEN_REQUEST_VALUE = ORIGINAL / EMPTY
```

结构非法或 msToken 重复时，JSON 的 `MSTOKEN_REQUEST_VALUE` 为 `null`，表示无法安全解析请求值；文本明确显示不可用，不声称要使用空值。UIFID 不合格仍使整体严格校验失败，即使 msToken 的请求值策略已确定。

msToken 的疑似无法解析片段统一显示 `UNKNOWN`，保留 `malformed_candidate` 布尔信息及可解析片段观察结果；UIFID 保留原 `MALFORMED_CANDIDATE` 行为。

JSON 分组由 `required_fields` 改为 `credential_fields`，避免将可选 msToken 标为必需；task 标识更新为本任务 ID。README 已记录这项 schema 调整。字段名、枚举和固定布尔信息以外，不输出原始值、片段、位置、长度或摘要。诊断始终 `SIGNING_ALLOWED = NO`，本地结构通过不授权联网。

## 独立签名对照

复用项目固定 Apache 来源 `Evil0ctal/Douyin_TikTok_Download_API@3d540dbf3783449e638403b65d81c882c4a99575`。生成脚本仅加载本地 SM3、A-Bogus、WebSign 文件，不运行上游应用、token 生成器或网络代码。

新增两组完整列表查询向量：空 msToken 和包含需编码字符的合成非空值。查询模板在 Python 中显式声明，不从 Rust 输出反推预期；固定时钟及确定性随机序列用于独立算法对照。原四组签名向量及其来源哈希保持不变。

Rust 测试核对完整最终查询、A-Bogus、WebSign、参数顺序、token 数量及编码。缺失和显式空值使用同一空值 golden vector，证明两者生成完全相同的参数与签名；非空合成值原样解析并按既有规则编码。拒绝用例确认凭证错误发生在算法随机源调用前。

这些结果只证明本地构造与固定参考的确定性一致，不证明线上作品列表服务器一定接受空 msToken。

## 验证结果

在 Windows x64 MSVC / Rust 1.91.1 下执行 `scripts/offline-acceptance.ps1`，Cargo 使用 `--locked --offline`。

| 检查 | 结果 |
| --- | --- |
| Windows Release | PASS |
| cargo fmt --all -- --check | PASS |
| Clippy，生产配置与 offline-test 配置，all-targets，-D warnings | PASS / PASS |
| 全部生产配置 Rust 测试 | 33 PASS，0 FAIL |
| 全部 offline-test Rust 测试 | 63 PASS，0 FAIL |
| 原生 Windows CTRL_C_EVENT | PASS，退出码 130，临时文件清理成功，没有提交最终文件 |
| 生产 Release 合成文件诊断 | 8 组 PASS |
| 原有四组算法向量保持不变 | PASS |

新增及更新覆盖：有效、空值、缺失、同名重复、UIFID 缺失/空值/重复、非法分段、控制字符、大小写、值内等号、空参数编码、空值双签名和固定时钟/RNG 对照。`no_fabricated_tokens` 保留拒绝断言，并增加空值/缺失时只有一个空参数的断言。

`first_page_only_external_cookie_file_uses_shared_validation` 扩展为八组合成场景：合法非空、空值和缺失通过回环列表服务验证实际查询参数；重复 token、无效 UIFID、非法结构均零请求。仍验证第一页即停止、零媒体请求、Cookie 文件不改写及控制台脱敏。

全套网络/媒体回归仅使用回环服务与合成 MP4；固定签名测试只使用合成身份。真实平台与真实媒体请求均为零，用户的 `E:\test.txt`、`E:\douyin-cookie-fresh.txt` 均未读取。

## 构建身份与交付范围

开始时 HEAD、本地 main、远端 main 一致：`ad74c5e8bb6b28ea01234a13a42c65af6e86af30`。受测源码为该提交加本轮改动。

Release：`rust-mvp/target/release/doustudio.exe`，`doustudio 0.1.0`，默认生产特性。EXE SHA-256：

```text
b338fc4ca5e5b4831d0a9e5d2dcbb2d83509c539471deb6b7e1b0908fc806fdc
```

这是二进制身份摘要，不是凭证摘要。EXE 不提交到 Git。

证据目录：`evidence/doustudio-windows-mstoken-compat-04/`，包含完整检查汇总、构建/Clippy/测试日志、原生 Ctrl+C 结果、八组合成 Release 诊断、部分扫描合成回归、既有合成验收结果与 EXE 身份。签名 golden fixture 位于 `rust-mvp/fixtures/signing-vectors.json`，只含合成数据。日志仅规范化行尾空白。

本轮显式暂存源码、测试、生成脚本、合成 fixture、README、本报告与新证据目录，正常提交推送 main。既有未跟踪的阶段 A 报告及 `evidence/doustudio-windows-rust-real-acceptance-01/` 保持原样，不纳入本轮提交。历史 recovery-03 与 diagnostic-02 证据保留其当时契约和结果，不覆盖为新结果。

```ini
TASK = DOUSTUDIOKIT_WINDOWS_MSTOKEN_COMPAT_04
MSTOKEN_OPTIONAL = YES
EMPTY_MSTOKEN_SUPPORTED = YES
MISSING_MSTOKEN_SUPPORTED = YES
DUPLICATE_MSTOKEN_REJECTED = YES
UIFID_STRICT_VALIDATION = PASS
COOKIE_STRUCTURE_VALIDATION = PASS
SIGNING_REGRESSION = PASS
OFFLINE_TESTS = PASS
REAL_HTTP_REQUESTS = 0
REAL_MEDIA_REQUESTS = 0
REAL_SIGNING = NOT_RUN
REAL_WORKLIST = NOT_RUN
REAL_VIDEO_DOWNLOAD = NOT_RUN
PRODUCTION_ALLOWLIST = EMPTY
```

本轮完成后停止，不自动读取真实凭据或恢复真实作品列表第一页。
