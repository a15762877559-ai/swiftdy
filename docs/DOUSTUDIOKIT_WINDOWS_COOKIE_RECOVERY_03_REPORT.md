# DOUSTUDIOKIT_WINDOWS_COOKIE_RECOVERY_03

日期：2026-10-27。只进行了本地文件检查、离线诊断和源码审计。

结论：新文件仍存在无法归类的不含等号片段，严格凭证校验未通过。没有规范化副本，没有改动 Rust 生产源码。已确认 Rust 的 Cookie 必需字段策略比底层签名算法和固定 Swift 实现更严格；但这不证明当前作品接口允许省略 msToken，兼容策略变更保持 **BLOCKED**。

## 1. 源码、EXE 与 Git 基线

- 实际受审源码提交：`e99687e2e5d65f561fdf14dbed3d90378854b457`；开始时本地 main、HEAD、远端 main 一致。
- 原有未跟踪的 `docs/DOUSTUDIOKIT_WINDOWS_RUST_REAL_ACCEPTANCE_01_REPORT.md` 和 `evidence/doustudio-windows-rust-real-acceptance-01/` 保留，排除本轮交付。
- 当前源码重新执行 `cargo build --release --locked --offline` 成功。生产程序版本 `doustudio 0.1.0`，默认生产特性。
- EXE SHA-256：`cd457bec740588f2ef35ab4621ba1f7917e0dc9ec6a538450d91102c9b8594fd`，与 diagnostic-02 记录一致。该摘要仅对应 EXE，没有计算或保存凭证摘要。
- 本轮 Git 交付仅包含本报告及 `evidence/doustudio-windows-cookie-recovery-03/`。受审生产源码 SHA 如上；交付提交及远端核验另见同目录 `delivery.json`，不将报告提交误作源码修改。

## 2. 本地文件检查与触发条件

开始时新文件不存在；已提示用户退出相关旧会话、重新登录并在本机准备新请求头 Cookie 字段值。用户随后确认“已准备”。没有自行登录、访问浏览器凭据或使用旧文件。用户是否实际撤销旧会话无法由本次离线检查验证。

`credentials.rs:41–46,94–136` 的严格规则为：按分号分段，忽略首尾空白后为空的片段；对每个非空片段寻找第一个 `=`。找不到时返回 `COOKIE_SEGMENT_MISSING_EQUALS`。空名称、非法名称、头标签、内部换行和控制字符另有既有拒绝规则及优先级。值中的后续等号不截断。此错误本身不能证明用户复制错误，也不能判断片段来源。

在用户确认后，对 `E:\douyin-cookie-fresh.txt` 执行：

1. 临时 Rust 分类程序读取一次，仅输出固定类别的布尔值。它附加在原 `credentials.rs` 的未改动副本中，复用 `raw_segments`、`segments` 和 `valid_name`；文件读取复用生产 `credential_file::read`。没有另建必需字段解析器。
2. 生产 Release `credential-check --cookie-file ... --json` 执行一次完整诊断。此前与此后的文件版本元数据一致；不输出元数据、长度、位置或摘要。没有重复运行完整诊断。

检查均沿用现有文件输入协议：允许 UTF-8 BOM 和一个末尾换行；表中“换行/控制字符”针对该协议处理后的 Cookie 输入，不表示文件物理编码中绝无合法终止换行。这不是新建规范化文件。

| 问题类别 | 本次观察 |
| --- | --- |
| Cookie: 头标签 | 未观察到 |
| Set-Cookie: 头标签 | 未观察到 |
| URL 类附加文本候选 | 未观察到 |
| 不含等号的非空片段 | 存在 |
| 可识别的非法/空字段名 | 未观察到 |
| 常见 Set-Cookie 属性候选 | 未观察到 |
| 内部换行/控制字符 | 未观察到 |
| 完整分段序列重复候选 | 未观察到 |
| 无等号片段可归为常见属性或附加标签/URL | 否 |
| 无等号片段来源 | **UNCLASSIFIED** |

分类器仅识别明确形式：常见无值响应属性、常见属性名、头标签和 URL 前缀。任意说明文字、未知属性或其他数据不能仅凭外观可靠判断，保留为未分类。未观察到重复序列也不能证明历史上从未重复粘贴。不能把候选规则当成完整浏览器协议证明。

没有取得用户对某段为无关附加文字的明确确认，因此没有删除、忽略、补齐字段，也没有修改原文件或生成副本。后续需要用户在本机重新复制请求头 Cookie 的完整字段值，或自行确认附加内容的性质；不要把原文或截图再发到聊天。本轮对该确定版本的完整诊断额度已经用完，不自动重跑。

## 3. 单次生产诊断结果

时间：2026-10-27 05:39:09 UTC。退出码 1。

```ini
COOKIE_STRUCTURE = FAIL
STRUCTURE_REASON = COOKIE_SEGMENT_MISSING_EQUALS
MSTOKEN_FIELD = UNKNOWN
UIFID_FIELD = PRESENT
FIELD_INSPECTION = PARTIAL
STRICT_SIGNING_VALIDATION = REJECT
LOCAL_CREDENTIAL_STRUCTURE = FAIL
SIGNING_ALLOWED = NO
```

可解析片段中确认了 `UIFID`；未观察到 `msToken`，但部分扫描不能宣称它绝对缺失。外层执行器只读取进程的脱敏输出，并通过固定 schema、枚举和布尔类型白名单后保存；没有读取原始字段值。没有上传、复制或修改 TXT。

## 4. msToken 依赖审计

本轮虽未达到“结构 PASS 且 msToken MISSING”，仍完成了不依赖凭据的只读源码审计，以避免要求用户盲目反复换 Cookie。

### Rust 的直接依赖

`rust-mvp/src/signing.rs:227–262` 的 `list_url` 先解析 UIFID，再执行 `session.cookie_value(TOKEN_NAMES)?`。`credentials.rs:13,171–177` 将精确大小写的 `msToken` 作为必需项，结构错误、缺失、空值或同名重复均使严格解析失败。之后才构造包含该 token 的查询参数并调用签名算法。

因此 **“非空 msToken 必须来自 Cookie”是当前请求构造入口的前置条件，不是由底层算法函数的签名强制规定**。当前 `no_fabricated_tokens` 测试也明确要求 UIFID 存在而 msToken 缺失时拒绝，不能未经契约变更直接删掉该检查。

| 层次 | msToken 的实际依赖 |
| --- | --- |
| Rust `abogus`（`signing.rs:95`） | 接收完整 query、body、UA、浏览器几何、时钟及随机源；不独立提取或检查 msToken。查询中有该参数时，其字节随 query 一起参与计算。 |
| Rust `websign`（`signing.rs:212`） | 直接依赖 UIFID、时间戳和参数序列；不独立检查 msToken。参数序列含该字段时，签名覆盖它。 |
| Rust `list_url` | 在调用两种算法之前，额外强制从 Cookie 读取非空唯一 msToken。 |

不能从“算法可计算无该字段的 query”推导“服务器会接受该 query”。当前未做任何真实签名或平台请求。

### 固定 Apache 来源

本机检出 `Evil0ctal/Douyin_TikTok_Download_API@3d540dbf3783449e638403b65d81c882c4a99575`，工作区干净。`sm3.py`、`abogus.py`、`websign.py` 的源码 SHA-256 与项目固定向量中的源码身份记录一致，见 `audit-baseline.json`。没有执行上游应用。

- `src/dtk/signing/native/abogus.py:633` 的 `get_value` 接受 query/body，不设 Cookie msToken 必需校验。
- 同目录 `websign.py:84,104` 的 `pick_uifid` 与 `sign` 选择 UIFID 并签参数序列，没有独立 msToken 必需参数。
- 同目录 `signer.py:126,185–195` 的完整 NativeSigner 默认启用 `fill_ms_token`：已有查询参数优先，否则查会话 Cookie，再走上游的本地伪 token 回退。关闭该选项且调用方没有传入时，不执行这段填充逻辑。**此回退未被本项目移植，本轮禁止且没有执行。**
- `signer.py:157–170` 注释声称某次 guest/detail 端点试验中无 token 也成功。这是上游作者的历史说明，既非本轮独立实测，也非本任务的已登录作品列表端点，不能作为放宽当前校验的验收证据。
- 上游完整管线支持请求参数来源，而 Rust 当前只允许 Cookie 来源；这说明两者输入模型不等价。其余访客参数、执行环境、签名顺序也不能仅凭算法对照向量推断为浏览器完整请求等价。

### 固定 Swift 与历史成功证据

本机 Swift 检出固定 `qinjian0420/DouStudioKit@362dad3d082e9f63c8efd360acc653ba169d40a2`，工作区干净，仅只读审计，没有复制其实现到 Rust。

- `Networking/SessionStore.swift:52–55` 在缺失时将 msToken 设为空字符串；按不区分大小写方式从 Cookie 提取。
- `Networking/SessionStore.swift:250–281` 的基础参数始终带 msToken 参数，值可为空；`Networking/DouyinAPI.swift:228–230` 使用此参数集合。
- `Signing/DouyinSigner.swift` 的 `applySigning` 注入/检查 UIFID 并执行两层签名，没有额外拒绝空 msToken。`SigningContext` 虽有该成员，不能把成员存在误作非空前置条件。
- 历史认证预检 `40274532110` 的 `auth-result.json` 证明当次 HTTP 200、一次请求、21 条作品；只记录 `credential_present=true`，没有 msToken 的存在性或来源证据。
- 历史分页 `40279553152` 的 `final-acceptance.json` 记录成功分页，同样不能证明当时必然存在 msToken，更不能证明当时必然缺失。

以上只确认输入契约差异。当前新文件仍结构失败，不能声称已经证明一份合法浏览器 Cookie 被 Rust 错误拒绝；也不能由历史 Swift 成功证明 Rust 当前无 token 请求会成功。

## 5. 最小兼容方案（提出，未实施）

若后续决定修正输入契约，应先形成明确的请求参数策略，将 Cookie 结构/同名重复校验与 msToken 的请求参数策略分开。默认严格模式保持不变；只有单独审查的兼容模式才能表达“缺失参数”，且必须明确选择省略参数还是保留空参数，不能擅自替换为伪值，也不能把两者混为同一种签名字节序列。

合成离线验证至少包括：合法非空值保留、缺失/空值/重复分别处理、所有原结构错误继续拒绝、UIFID 校验不变、值内等号及大小写规则不变、固定时钟/RNG 下 query 与两层签名的对照、默认严格入口仍拒绝缺失、零请求边界。现有固定向量的 query 本身不含 msToken，可作为算法层证据；不能替代真实端点兼容性证据。

本轮没有选择或实现兼容模式，没有改变现有测试期望。`COMPATIBILITY_CHANGE = BLOCKED`：尚缺正确结构输入及足够的目标请求契约证据。不是继续要求用户仅为补一个 msToken 不断刷新凭证。

## 6. 测试范围与证据

- 当前生产源码 Release 离线构建：PASS。
- 既有 `credential_diagnostic` 的 offline-test 配置：14/14 PASS，含合成 Cookie、严格解析拒绝、JSON 脱敏、文件安全及签名/DNS/HTTP 边界哨兵。
- 临时分类程序：3/3 PASS，其中 2 项为复用模块原单元测试，1 项覆盖分类与值无关性；仅使用合成数据。
- Rust 生产源码未修改，因此本轮没有重跑整个生产/offline-test 套件、Clippy、fmt 或原生 Ctrl+C。上一轮相同源码的 30/60 项全套与 Ctrl+C PASS 是历史记录，不冒充本轮新执行结果。
- 无真实 HTTP、媒体或签名；临时分类器不创建网络运行时，不调用签名器。哨兵回归探针在实际操作前失败。没有用抓包证据作超出实际检查的宣称。

证据目录 `evidence/doustudio-windows-cookie-recovery-03/` 包含：构建/合成测试日志、固定源码身份与 EXE 身份、分类器扩展源码、纯布尔问题分类、生产命令脱敏 JSON、执行次数/文件未改写状态，以及审计结论。临时程序没有凭证输出文件，原 TXT 不纳入 Git。

```ini
TASK = DOUSTUDIOKIT_WINDOWS_COOKIE_RECOVERY_03
COOKIE_STRUCTURE = FAIL
STRUCTURE_REASON = COOKIE_SEGMENT_MISSING_EQUALS
MSTOKEN_FIELD = UNKNOWN
UIFID_FIELD = PRESENT
FIELD_INSPECTION = PARTIAL
STRICT_SIGNING_VALIDATION = REJECT
MSTOKEN_DEPENDENCY_AUDIT = PARTIAL
COMPATIBILITY_CHANGE = BLOCKED
LOCAL_NORMALIZED_COPY = NOT_CREATED
RUST_SOURCE_CHANGE = NO
OFFLINE_TESTS = PASS
REAL_HTTP_REQUESTS = 0
REAL_MEDIA_REQUESTS = 0
REAL_SIGNING = NOT_RUN
REAL_WORKLIST = NOT_RUN
REAL_VIDEO_DOWNLOAD = NOT_RUN
PRODUCTION_ALLOWLIST = EMPTY
```

`PARTIAL` 表示源码依赖关系已确认，当前文件与真实平台兼容性仍不能定论。`RUST_SOURCE_CHANGE = NO` 指生产工程；临时分类器仅是本轮本地审计工具。未修改 VideoFlow Host、系统代理、全局 Git 配置或生产 CDN 白名单。检查到此停止，不恢复阶段 A。
