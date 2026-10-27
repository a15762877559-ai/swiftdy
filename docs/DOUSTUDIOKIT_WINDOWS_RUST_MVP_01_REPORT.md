# DOUSTUDIOKIT_WINDOWS_RUST_MVP_01

2026-10-27，Windows 原生、个人自用、独立 Rust MVP。仅执行源码/许可证审计、Rust 开发和 Windows 离线验证。本轮没有真实抖音作品请求、媒体请求或 Actions dispatch。

## 工程及基线

- 实际工程：`D:\Projects\swiftdy\rust-mvp`。
- 初始指定路径不存在，已从用户指定仓库正常 clone 到该路径；未覆盖其他目录。另一个已有目录 `D:\Projects\doustudio-runtime-acceptance` 含未跟踪报告，未修改。
- 实施前 `git ls-remote` 确认 `origin/main = 2037c8f0e420d5cf728d332e2084d7fa6e32e408`，新检出本地 HEAD 一致、工作区干净。
- 固定参考：`qinjian0420/DouStudioKit@362dad3d082e9f63c8efd360acc653ba169d40a2`，只读副本在 `F:\REA\work\doustudiokit-rust-mvp\upstream`。没有改动上游代码。
- 已阅读最终 `DOUSTUDIOKIT_SINGLE_VIDEO_REAL_DOWNLOAD_01_REPORT.md` 及 `evidence/doustudio-single-video-real-download-01/run-40342093354/` 内 download-summary、media-integrity、decode-results。Swift 真实运行 [40342093354](https://github.com/a15762877559-ai/swiftdy/actions/runs/40342093354) 的 71,521,945 字节、9,084 视频帧仅作为历史参照；没有重跑 Swift，不能作为 Rust 成功证据。
- 原 Swift Harness、所有原有报告和历史证据保持不变；没有修改 VideoFlow Host、RootNetScope、系统代理或生产主机配置。

## 模块和可操作功能

| 模块 | 本轮实现 |
|---|---|
| `auth` | 主页严格解析；控制台隐藏 Cookie 输入；敏感 Header 标记；拒绝缺失/控制字符/重复必需 token；Cookie 主副本退出时清零 |
| `signing` | 经过来源审计的 Apache 算法 Rust 适配：A-Bogus + WebSign；每页使用真实游标重新签名；不生成虚假 token，不自动登录 |
| `client` | 精确列表端点、身份和签名查询校验；DNS 公网检查及连接固定；4 MiB JSON 上限；拒绝重定向/非 JSON/403/429/平台错误 |
| `extractor` | ID 保持字符串，作品基本信息；分辨率/FPS/码率/data_size 元组最大值及最后 URL；没有 bit_rate 时取 play_addr 最后 URL；图集等不可下载 |
| `pagination` | 真实 max_cursor 链、0/1 或布尔 has_more；同页/跨页去重；循环、停滞、空页有更多、全重复无进展拒绝；明确页数上限/服务端耗尽 |
| `media` | 空生产白名单；最长一小时的单视频测试作用域；精确主机、HTTPS/443、最多一次入口 302；全部 DNS 结果检查并固定单个 IP；正常 TLS |
| `transport` | 流式读取、固定 64 KiB 堆缓冲、100 MiB 应用接受/写盘预算；无重试、无续传、无 Range；独立媒体客户端，不传 Cookie/Authorization/Referer |
| `storage` | 用户目录内新建随机 `.part`，检查符号链接/Windows reparse point，拒绝覆盖；成功后不覆盖目标的同目录原子提交；失败/正常取消清理 |
| `verify` | 文件大小、两次 SHA-256、完整顶层 MP4 boxes；ffprobe 元数据限制；FFmpeg 完整单视频轨道解码、帧数/时长覆盖检查；取消时等待子进程退出 |
| `cli` | `list`、`list --pages 3`、`download --index 1 --output ...`、`verify`；实时字节、总长度/UNKNOWN、速度、完成/失败/取消状态；Ctrl+C 取消 |

CLI 可以运行，不是接口声明。Release 可执行文件：`D:\Projects\swiftdy\rust-mvp\target\release\doustudio.exe`。FFmpeg/ffprobe 是外部媒体验证器，需要在 PATH 中；Rust 下载逻辑不依赖 Swift 或 Python。

`download` 索引从 1 开始，针对本次请求获得的列表，不复用上一次 list 缓存；下载前显示所选作品。不同时间的列表顺序可能变化，这是当前 CLI 的明确限制。现存文件不覆盖。无后台任务，故取消入口为 Ctrl+C，退出码 130。

## 许可证审计及实现来源

固定 Swift 上游根 LICENSE 是 GPL v3；README 和 NOTICE 明确整体为 GPL-3.0 派生作品。附带 Apache-2.0 文件并不意味着整个 Swift 包可按 Apache 使用。没有直接复制其 Swift 实现，也未链接或编译 Swift 依赖。

用户选择继续核对原始 Apache 签名来源后，核对了：

`Evil0ctal/Douyin_TikTok_Download_API@3d540dbf3783449e638403b65d81c882c4a99575`

该固定提交根 LICENSE 为 Apache-2.0；`abogus.py` 明确记录旧版存在 GPL 来源问题、当前版本重新推导的作者声明。只使用该新版 `abogus.py` / `websign.py` 的算法，保留完整许可证、原 NOTICE、固定提交、修改说明和源文件哈希。作者历史权利声明不是本轮可独立验证的事实，不将个人自用解释为许可证无效。

`signing.rs` 是这份 Apache 实现的 Rust 适配，其他 Rust 模块独立编写。不是逐行 Swift 翻译，也不声称进行了严格人员隔离的 clean-room 开发。协议字段、游标语义、元组排序和地址位置属于本轮复现的外部行为；不包含原画地址猜测、挑战绕过和客户端环境伪装框架。

详见 `rust-mvp/THIRD_PARTY_NOTICES.md`。Rust 依赖精确锁定于 Cargo.lock；本轮未将 FFmpeg 二进制加入仓库。

## 安全策略的实际边界

`MAX_MEDIA_BYTES = 104857600`。每次应用读取只提供剩余额度内的固定缓冲片段，文件层再次检查累计写盘预算。声明长度超限在读 body 前拒绝；未知长度到达恰好上限也保守拒绝，不追加一个哨兵字节探测 EOF。已知长度恰好 100 MiB 支持完成及全片解码。

`received_bytes`/`application_accepted_bytes` 是通过预算门交给文件层的字节；`transport_delivered_bytes` 记录 HTTP 库交付分块，可能包含没有被应用接受的尾部。不能将应用预算表述为 TCP、TLS、操作系统或物理网络接收硬限额；64 KiB 也不是整个进程内存上限。

媒体协议只允许完整 200 或 Content-Range 精确描述全资源的 206；拒绝部分 206、空体、未知类型、内容编码、截断、损坏容器及解码失败。媒体地址只来自本次列表实际响应或审核通过的 Location，禁止自动替换 CDN、重试、续传、构造播放地址。

生产策略永远返回 `PRODUCTION_MEDIA_ALLOWLIST_EMPTY`。临时测试必须由用户提供本次精确 CDN 主机、有效期和显式授权标志，限定一个进程下载一条视频；这不是生产批准，也不是跨进程一次性凭证。每次调用重新验证作用域和网络目标。重定向目标必须绝对地址、审核主机且重新 DNS 检查；全部 DNS 地址必须符合公网策略，只给连接器一个数字 IP，TLS 仍用原始主机名验证。应用 `.no_proxy()` 不改变任何系统代理设置。

`offline-test` 编译特性仅用于测试：CLI 必须提供精确 loopback fixture 地址，且拒绝真实账号请求及测试生产作用域。发布的 Release 使用默认特性；`DOUSTUDIO_OFFLINE_ONLY` 还会拒绝真实列表入口。

媒体工具只允许 file 协议，关闭外部 dref；清除其继承环境中的会话、代理、FFREPORT 等变量，仅保留运行所需 PATH/SystemRoot/TEMP 等。元数据/解码输出有界，stderr 不回显。正常取消等待子进程退出再删除文件。强制终止整个进程、断电、同权限恶意进程持续改写目录不在优雅取消/文件所有权保证范围内。

## Windows 离线验收

最终完整重跑 **PASS**，机器可读证据见 `evidence/doustudio-windows-rust-mvp-01/summary.json`。

| 检查 | 最终结果 |
|---|---|
| Rust 1.91.1 Windows x64 MSVC Release 编译 | PASS |
| cargo fmt --check | PASS |
| 默认特性与 offline-test 的 Clippy，均 -D warnings | PASS |
| 默认特性合约测试 | 14/14 PASS |
| offline-test 合约测试 + HTTP/媒体/EXE 测试 | 14/14 + 17/17 PASS，31 个唯一测试 |
| Release EXE --help 和 verify | PASS |
| Release 验证合成 H.264 | 9,450 字节，64×64，1 秒，完整 30 帧 |
| 合成视频 SHA-256 | `03bd18ac57f6b885c7be954267db1f9174ef24f023699b228faccf25745ec3c5` |
| 所属 fixture 目录清理 | PASS |
| GitHub Windows hosted runner | NOT_RUN，待用户手动执行 |
| Rust 真实列表/真实媒体 | NOT_RUN |

本地 Release EXE SHA-256：`24948adcced7bfb0e42cea93c7b0dd9d75fb66f13633be994b87adc00a147f32`。`source-protection.json` 记录实际源文件 SHA-256、Git blob、基线保护检查及可执行文件哈希；`evidence-index.json` 覆盖本轮诊断文件。日志仅统一 UTF-8/LF 并去除行尾空白，没有更改诊断内容。工作流 YAML 解析、仅手动触发、无 Secret、最小权限及 Actions 完整 SHA 固定的静态检查通过；未运行 actionlint 或远端工作流。

验证命令：

```powershell
cd D:\Projects\swiftdy\rust-mvp
cargo fetch --locked
./scripts/offline-acceptance.ps1 -EvidenceDir ..\evidence\doustudio-windows-rust-mvp-01
```

本机 Rust 启动器没有已安装工具链；本轮将 Rust 1.91.1/MSVC 工具链安装到 `F:\REA\tools\rustup`、Cargo 缓存放在 `F:\REA\tools\cargo`，仅在执行进程设置 RUSTUP_HOME/CARGO_HOME/PATH。复用现有 Visual Studio Build Tools 与 FFmpeg 9.0.1，不改全局 Rust 配置或系统代理。工作流通过标准 rustup 准备相同 Rust 版本。

有 14 个合约测试和 17 个网络/媒体/CLI 测试，合计 31 个唯一测试；默认特性重复执行前 14 个，不将重复计作新增覆盖。17 个测试中的拒绝矩阵另含十类下载失败场景，列表访问限制测试另含五类错误。测试包括：

- 四组完整 Apache Python/Rust 签名对照向量，覆盖不同 UA、Unicode、编码、长查询和随机序列；没有运行 Swift。
- 实际回环 HTTP 两页游标传递、大整数 ID、去重及停止规则。
- 完整 200、完整 206、无长度、chunked、一次 302，实际输出合成 30 帧 H.264 并完整解码。
- 声明超限拒绝、未知长度超限终止、恰好 104857600 字节的有效 MP4/填充 box 保存及实际解码，累计接受和写盘不超预算。
- 302 越界/循环拒绝、HTML/编码/空体/部分片段/断开/损坏容器/损坏 mdat 拒绝，失败不提交、不残留、不重试。
- 媒体请求无 Cookie/Authorization/Referer/Range；默认 TLS 拒绝本地自签证书。
- 中途取消、预先取消零请求、验证中取消后可立即删除 Windows 文件；已有输出文件阻止网络请求。
- 真正启动 Windows EXE 执行 list → download → verify，检查进度字段、正确帧数及 fixture 构建拒绝真实主页。

开发中实际 EXE 测试发现 Windows 主线程栈溢出，而库测试未暴露；将固定 64 KiB 缓冲移到堆上解决，不增加预算或修改断言。Clippy 的风格检查失败也已修正。最终结果仅以修正后的完整重跑为准。

## 手动工作流及下一步

新增 `.github/workflows/doustudio-windows-rust-mvp-offline.yml`，名称 **DouStudioKit Windows Rust MVP Offline Acceptance**。仅 workflow_dispatch、Windows 2025、contents:read、30 分钟超时。先准备工具和锁定依赖，再在 offline 模式运行；没有 Cookie Secret、平台请求或真实下载步骤。Artifact 显式列举诊断日志及默认 Release EXE，不上传 MP4、音频、截图或原始响应。

下一步先由用户手动运行这个 Windows 离线工作流；GitHub hosted runner 的结果仍待用户运行，不能用本地结果替代。

后续用户另行授权真实 Windows 单视频验证后，可按 `rust-mvp/README.md` 使用隐藏 Cookie 输入、真实授权主页、临时精确主机作用域执行：

```powershell
.\target\release\doustudio.exe download --profile '<授权主页>' --authorized-session --index 1 --output '<已存在输出目录>' --test-scope .\scope.local.json --authorize-test-download
.\target\release\doustudio.exe verify '<输出目录>\video-1.mp4'
```

本轮在开发、离线验证、普通提交推送完成后停止，不运行这些真实命令。

## 未支持或未验证

真实 Rust 签名被平台接受、真实作品列表、真实多页、真实媒体下载均 **NOT_RUN**。固定 Windows Chrome 146/1920×1080 身份与实际会话的兼容性需真实验收；不声称所有浏览器会话适用。签名对照一致不能代替平台验收。

生产媒体主机 **EMPTY**；音频轨道解码 **NOT_RUN**；无水印 **NOT_VERIFIED**；底层网络接收严格硬上限 **NOT_PROVEN**。不支持图集、实况、直播、短链展开、自动登录/挑战处理、原画 URL 构造、批量下载、断点续传、后台下载服务或 Vue 桌面 UI。
