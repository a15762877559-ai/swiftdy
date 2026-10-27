# DOUSTUDIOKIT_WINDOWS_COOKIE_DIAGNOSTIC_01

日期：2026-10-27（Asia/Shanghai）。范围：Windows Rust 离线凭证结构诊断及可选本地 TXT 输入。禁止真实作品列表、分页、媒体请求或恢复阶段 A。

## 实现与源码核对

开始时本地 `main` 的 HEAD 与 `git ls-remote origin refs/heads/main` 均为 `f6c637b60c1848ec0a00045a590c0d07b6c2bdfe`。工作区已有 `acceptance.rs` 的 `--first-page-only` 修改及 `acceptance_http.rs` 的对应回归测试；保留并随相关验收入口改动一起交付。之前真实验收的未跟踪报告和证据保持原状，不纳入本任务提交。未 reset、stash、覆盖旧证据、强推或修改生产白名单。

原签名入口真正需要大小写敏感的 `msToken` 和一项 UIFID 类凭证。接受的 UIFID 别名及优先级为：`uifid`、`uifid_temp`、`uifidtemp`、`UIFID`、`UIFID_TEMP`、`UIFIDTEMP`。没有要求额外登录字段，没有补齐、获取或伪造 token。

新增 `credentials.rs` 作为共享解析器，正式 `Session::cookie_value` 与诊断读取同一解析结果；签名器引用相同的必需字段常量。复用原有分号分隔、整段 trim、第一个等号拆分以及大小写/别名优先规则。值内的等号不被截断，诊断结果不持有字段值。

明确收紧的规则：同名必需字段计数包括空值，任何已接受 UIFID 别名的同名重复都拒绝；无等号的非空段、空字段名及非法字段名不再被忽略。无关字段重复允许，不同 UIFID 别名不是同名重复。正式运行和诊断统一使用这些规则，未删除原签名必需校验。

## 命令与输入

```powershell
.\rust-mvp\target\release\doustudio.exe credential-check
.\rust-mvp\target\release\doustudio.exe credential-check --cookie-file 'D:\Secrets\douyin-cookie.txt'
```

默认仍通过 `rpassword` 隐藏输入。主动指定 `--cookie-file` 才由 Rust 直接读取 TXT，不通过 Shell 读取、环境变量、剪贴板工具、聊天或日志传递内容。

`acceptance` 同样提供 `--cookie-file`，但仍须本机授权与主页确认；参数不会授权真实访问。此任务只对它执行了本地合成回环验收和禁止真实入口的测试，没有使用用户 TXT 运行验收。

TXT 规则与防护：

- UTF-8 文本，可带 BOM 和一个结尾 LF/CRLF；仅包含 Cookie 字符串，不接受 `Cookie:` 标签、主页、独立域名行或 JSON。内部控制字符仍拒绝。
- 文件必须位于 Git 仓库之外。拒绝源码仓库路径（含大小写/规范路径检查）及具有 `.git` 的祖先目录。
- 只接受本地固定/可移动磁盘绝对路径；UNC、映射网络盘、设备路径、ADS、相对/父级路径拒绝。
- 逐级检查并持有目录句柄，拒绝所有 Windows reparse point，包括符号链接和 junction；文件以只读、独占共享、OPEN_REPARSE_POINT 打开并复查句柄元数据；拒绝多硬链接。
- 使用操作系统实际打开结果检查读取权限/共享限制；失败只输出固定错误，不包含路径、原始异常或内容。
- 固定容量的 `Zeroizing` 读取缓冲避免增长留下旧副本；UTF-8 字符串同样由 `Zeroizing` 持有，诊断返回前清零输入。原文件不改写、不复制到仓库、不删除。该保证针对正常进程内生命周期，不宣称清除 OS 分页或强制终止产生的转储。

## 输出与离线边界

每个必需字段只显示静态字段名和 `PRESENT`、`MISSING`、`EMPTY`、`DUPLICATED`、`INVALID_FORMAT` 之一。UIFID 全部缺失时以 `uifid` 为显示名并列出接受的别名；不要求只使用该别名。

程序不输出任何 Cookie 值、片段、长度、摘要、签名、可重放认证信息。读取/编码错误使用固定错误 `COOKIE_FILE_REJECTED_OR_UNREADABLE`。结构通过仅输出 `LOCAL_CREDENTIAL_STRUCTURE = PASS`，不表示真实登录、有效期或平台签名接受成功。

`credential-check` 在创建 Tokio 运行时之前分派并返回，只依赖本地读取和共享解析；不调用原生 A-Bogus、WebSign、DNS、HTTP 客户端。测试构建在异步运行入口、两种签名算法、签名 URL 入口和统一 DNS/客户端入口设失败断言；成功/失败诊断都在断言开启时完成。单独的子进程测试确认断言确实会在这些边界阻断执行。

边界证据是代码调用路径和可执行断言测试，没有声称做过系统级抓包。所有既有 HTTP 集成测试使用回环合成服务器，既有签名对照测试只使用合成向量；它们不等于真实抖音访问或用户凭证签名。

## 验证与证据

工具链：本机 Rust 1.91.1 MSVC、FFmpeg/ffprobe 9.0.1。使用现有工具链和缓存，不安装依赖。一次初始增量编译停滞后停止本任务编译进程，关闭增量编译继续；未修改用户数据或 Rust 全局配置。

复现命令：

```powershell
cd D:\Projects\swiftdy\rust-mvp
cargo fmt --all -- --check
./scripts/offline-acceptance.ps1 -TaskId DOUSTUDIOKIT_WINDOWS_COOKIE_DIAGNOSTIC_01 -EvidenceDir ../evidence/doustudio-windows-cookie-diagnostic-01
```

该脚本运行 Release `--locked --offline`、生产和 `offline-test` 两种配置的 Clippy（`-D warnings`）、全部 Rust 测试、Windows CTRL_C_EVENT、CLI 帮助和合成 MP4 验证。合成 fixture 在结束时清理。

新增用例覆盖：正常、缺失/空/重复 msToken、UIFID 缺失/空/重复、两段完整 Cookie 重复、空白/多余分号、值内等号、无关字段重复、大小写、别名优先级、控制字符、空输入、非法段、非 UTF-8/超限 TXT、BOM/末尾换行、输出不泄漏、生产无测试 stdin 开关、路径/硬链接/符号链接/读取失败、禁止网络/签名断言，以及 `acceptance --first-page-only --cookie-file` 在合成成功和缺失凭证时的请求边界。

最终结果：生产配置 25 项、offline-test 配置 55 项测试通过；Release、fmt、两种配置 Clippy 与 Windows Ctrl+C 检查均通过。最终构建身份、各检查结果及测试统计以 `evidence/doustudio-windows-cookie-diagnostic-01/build-identity.json`、`summary.json`、测试日志和 `diagnostic-assessment.json` 为准。文件哈希仅用于源码、EXE 或合成证据，不计算用户 Cookie 文件摘要。

## 用户本地 TXT 诊断

代码、报告和合成证据已提交并推送：`f223afb565c3769a6a6b2ecbcaf9979a6e13f118`。随后使用用户明确指定的仓库外 TXT，由生产 Release EXE 直接执行了一次 `credential-check --cookie-file`；未通过 Shell/工具读取文件内容，未计算文件长度或摘要，未改写原文件。检查时同时设置 `DOUSTUDIO_OFFLINE_ONLY=1`。

本次诊断结果：

| 项目 | 状态 |
| --- | --- |
| msToken | INVALID_FORMAT |
| uifid（UIFID 类凭证显示名） | INVALID_FORMAT |
| LOCAL_CREDENTIAL_STRUCTURE | FAIL |
| 固定失败原因 | COOKIE_INVALID_FORMAT |
| 进程退出码 | 1 |
| HTTP / DNS / 签名调用 | 0 / 0 / 0 |

整体结构检查失败时，诊断有意不将后续字段解析结果当作可靠事实，两个必需项统一标记 `INVALID_FORMAT`；这不证明当前文件里每个字段的值本身无效，也不能单独确定 `msToken` 是否缺失。用户此前提到旧 Cookie 缺少 `msToken`，不能用该信息替代本次实际输出。本次没有读取原文来进一步猜测具体的格式错误，没有自动修复、获取 token 或再次运行诊断。

本机检查只保存静态字段状态与固定原因，见 `local-file-diagnostic.json`。输入内容、片段、长度、摘要及认证材料没有写入任何报告、日志或 Git。未启动真实 `acceptance`、列表、分页或媒体下载。

## 验收状态

### 格式原因细分修复

用户说明输入来自原始 HTTP Cookie 后，进一步修复诊断信息过粗的问题：共享结构检查现在返回固定原因类别，分别说明输入为空/超限、内部换行、其他控制字符、Cookie 头标签、字段段缺等号、字段名为空/含空白/字符非法、只有空段等情况。未放宽或改变格式校验的接受规则，未修改用户文件，也不输出问题字符、字段段、偏移、数量或真实长度。

本轮 Release、fmt、生产及离线配置 Clippy、全部测试与 Windows Ctrl+C 检查通过；生产配置 26 项、offline-test 配置 56 项。证据保存在原目录的 `format-reasons/` 子目录，之前证据保留。新版仅细分失败原因，整体格式无效时仍不把字段存在性标为已确认。新版真实文件诊断结果待本地执行后补充。

```ini
TASK = DOUSTUDIOKIT_WINDOWS_COOKIE_DIAGNOSTIC_01
RUST_BUILD = PASS
OFFLINE_TESTS = PASS
CREDENTIAL_PARSER_REUSED = YES
REQUIRED_FIELD_DIAGNOSTIC = PASS
SENSITIVE_DATA_PROTECTION = PASS
NETWORK_REQUESTS = 0
SIGNING_REQUESTS = 0
REAL_WORKLIST = NOT_RUN
REAL_PAGINATION = NOT_RUN
REAL_VIDEO_DOWNLOAD = NOT_RUN
PRODUCTION_ALLOWLIST = EMPTY
NO_WATERMARK = NOT_VERIFIED
```

`NETWORK_REQUESTS` 和 `SIGNING_REQUESTS` 指离线诊断入口；不把构建的 Git 通信或原有回环/合成签名测试计为真实业务请求。结构诊断完成后停止，不自动恢复阶段 A。
