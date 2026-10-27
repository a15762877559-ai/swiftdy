# Windows Rust MVP

独立 Rust CLI。当前只做离线验收；真实 Rust 列表、签名接受情况和媒体下载均须另行授权验证。生产媒体白名单为空。

需要 Windows x64 MSVC 构建工具、Rust 1.91.1，以及 PATH 中的 `ffmpeg.exe` 和 `ffprobe.exe`。只调用外部 FFmpeg 作完整视频解码，Rust 负责列表、签名、分页、HTTP、下载和文件安全。无需 Swift、Python 运行时、VideoFlow Host 或 GitHub Secret；Python 仅用于维护签名对照向量。

## 编译与离线验收

在本目录打开 PowerShell：

```powershell
rustup toolchain install 1.91.1 --profile minimal --component rustfmt --component clippy
cargo fetch --locked
./scripts/offline-acceptance.ps1
```

首次准备依赖访问 Rust 包分发服务；随后编译和测试使用 `--offline --locked`。测试只连接 `127.0.0.1`，生成 64×64/30 帧 H.264 合成 MP4，验收后删除。`acceptance/summary.json` 和日志可查看结果。默认 Release EXE 在 `target/release/doustudio.exe`；测试特性生成的 Debug EXE 不能访问真实账号。

GitHub 工作流 **DouStudioKit Windows Rust MVP Offline Acceptance** 只有 `workflow_dispatch`，无 Secret 和平台请求步骤。运行该工作流只授权离线测试，不授权任何真实账号访问。

## 后续另行授权后的本地使用

### 交互式验收入口（真实访问仍须另行授权）

优先使用 `acceptance`：同一个进程保留当前列表并锁定作品，旧 `list`、`download`、`verify` 保持兼容。以下仅是未来授权后的命令模板，本轮不运行真实请求：

```powershell
.\target\release\doustudio.exe acceptance --help
.\target\release\doustudio.exe acceptance --output '<用户指定且已存在的视频目录>' --evidence '<新的脱敏诊断文件.json>' --test-scope '<本次已审查的 scope.local.json>'
```

1. 在本机输入 `AUTHORIZE LIST`，确认拥有或获准访问该主页，再输入主页与隐藏 Cookie。生产构建拒绝管道代替控制台确认；设置了 `DOUSTUDIO_OFFLINE_ONLY` 时直接拒绝真实入口。
2. 第一页显示 HTTP 状态、返回/同页唯一/新增/累计唯一数量、字段布尔统计及游标推进状态。输入 `CONTINUE PAGES` 才继续，最多三页总计；服务器提前耗尽则正常结束分页。401、403、429 分别分类，任何错误停止，不重试。
3. 显示本次运行的序号、发布时间、时长、尺寸、码率和可选状态，不显示标题、ID、封面或媒体 URL。输入 `0` 或空值取消。缺失/未知类型、图集、直播或非法播放地址不可选择；明确支持普通视频类型 0、4，其余保守拒绝。
4. 输入序号后立即锁定当前作品副本及原规则选出的地址；输入 `DOWNLOAD <该序号>` 单独授予授权 B。未确认 B 不发送媒体请求，不复用历史授权。
5. 验证已审查的临时精确主机作用域，复用原下载器。下载不重新取列表、不替换作品/地址/CDN。URL 失效或主机不符即停止，作用域不会自动创建或扩展。
6. 仅保存 `accepted-video.mp4`，拒绝覆盖；失败或正常 Ctrl+C 取消清理本次 `.part`。证据 JSON 只保存白名单字段，使用 `create_new` 拒绝覆盖；Cookie、真实 ID、标题、原始游标和 URL 不写入诊断。

`signing_completed` 仅表示本页原生签名构造完成，不能单独证明平台接受；需结合 HTTP 200 和有效业务响应。`media_download_attempts` 是下载器调用次数，不是包含入口 302 在内的 HTTP GET 精确次数。作用域格式见下方原有说明，生产白名单始终为空。

媒体诊断使用同一次全片 FFmpeg 解码，逐帧流式读取 `showinfo` 时间戳，只保留统计结果：首帧为解码序号 0，中间区间为时长中点 ± max(两帧时长, 2.5% 时长)，结尾为达到 max(总时长减两帧, 95% 总时长)。必须完整解码正常结束、帧数满足原验证规则且首中尾覆盖，才能通过；不是抽样解码。原始 stderr 不保存，单行限 8 KiB、进度输出限 64 KiB。两次 SHA-256 必须一致；音频未解码，`NO_WATERMARK=NOT_VERIFIED`。

### 仅合成数据的入口复核

```powershell
./scripts/offline-acceptance.ps1 -TaskId DOUSTUDIOKIT_WINDOWS_RUST_ACCEPTANCE_ENTRY_02 -EvidenceDir ../evidence/doustudio-windows-rust-acceptance-entry-02
```

`offline-test` 构建独有的 `acceptance --fixture-url http://127.0.0.1:<测试端口>/list ...` 仅接受本地回环服务。测试通过 stdin 输入合成确认词，Cookie 固定为合成值；真实构建没有该参数。测试实际启动 EXE，完成三页、锁定、授权 B、合成 MP4 下载与完整解码，并导出 `synthetic-cli-acceptance.json` 和脱敏控制台日志。Windows Ctrl+C 测试使用 Python 标准库向独立隐藏控制台发送真实 `CTRL_C_EVENT`；Python 仅为测试辅助，不是 Rust CLI 的运行依赖。

### 原有命令

以下命令是未来验收入口，本轮没有执行。先运行并通过离线验收，再单独授权。主页必须是 `https://www.douyin.com/user/<sec_user_id>`，不接受短链接、分享文案或重定向。

```powershell
.\target\release\doustudio.exe list --profile '<已授权主页>' --authorized-session
.\target\release\doustudio.exe list --profile '<已授权主页>' --pages 3 --authorized-session
```

Cookie 在控制台隐藏输入，只在内存使用。完整授权会话必须含实际 `UIFID_TEMP`（也接受明确的等价名称）和 `msToken`；缺失就报错，不自动生成、获取或修复 token。MVP 使用 Windows Chrome 146 / 1920×1080 的固定签名身份，真实请求是否被平台接受尚待验证。登录失效、验证码、风控、非 JSON、403、429 均停止，不自动重试或绕过。

列表按 1 开始编号，显示真实 ID 字符串、描述、时间戳、时长、尺寸、码率和可下载状态，不输出签名媒体 URL。空账号显示空列表；去重计数和分页停止原因单独展示。

下载目前只支持一次运行的一条普通视频。用户单独授权后，在本机创建 `scope.local.json`，指定这次已审核的一个 CDN 精确主机，最长一小时有效。历史 Swift 见过某主机并不自动授权 Rust 使用它：

```powershell
$scope = @{
  purpose = 'single-video-test'
  entry_host = 'www.douyin.com'
  cdn_host = '<本次明确授权的精确 CDN 主机>'
  expires_unix = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 1800
  max_downloads = 1
}
$scope | ConvertTo-Json | Set-Content -Encoding utf8NoBOM scope.local.json
New-Item -ItemType Directory -Force .\out | Out-Null
.\target\release\doustudio.exe download --profile '<已授权主页>' --authorized-session --index 1 --output .\out --test-scope .\scope.local.json --authorize-test-download
.\target\release\doustudio.exe verify .\out\video-1.mp4
```

`download` 在本次新获取的列表内选索引（不复用之前 `list` 的缓存），下载前显示实际所选作品；账号作品顺序变化时，两次命令的索引可能对应不同作品。只取被选作品响应里的地址，按原版已验收规则选择最高码率项的最后一个 URL，绝不构造“原画”或备用播放 URL。目标文件已存在就拒绝覆盖。

按 **Ctrl+C** 取消，正常处理时退出码 130、状态 `CANCELLED`，清理 `.part`。没有后台下载任务，因此不另设 `cancel` 子命令。强制结束进程、关机或硬件错误不属于优雅取消保证。

## 安全边界

- `MAX_MEDIA_BYTES = 104857600`，64 KiB 应用读写缓冲，流式写盘；接受量、写盘量均不超过预算。
- 声明长度超限在响应头拒绝。未知长度达到恰好 100 MiB 也保守拒绝，不多读取一个哨兵字节探测 EOF；已知长度恰好 100 MiB 可以完成。
- 该限制不是操作系统、TLS 或底层网络物理接收硬限额，也不是整个进程的内存上限。
- `received_bytes` 是通过预算门、交给文件层的应用接受字节；`transport_delivered_bytes` 单独统计 HTTP 库交付的分块，可能包含未接受的尾部，不能将两者混同。内部仅持有当前分块和固定读写缓冲，不累积媒体响应。
- 不重试、不续传、不发送 Range；只支持完整 200 或描述整个文件的 206。
- 生产白名单为空。临时测试只接受精确 HTTPS 主机、443、无 userinfo/fragment；最多一次入口 302，CDN 再跳转拒绝，拒绝相对 Location。
- 每个实际目标先检查全部 DNS 结果为公网地址，然后只固定一个已校验数字 IP；保留原主机名做 SNI 和证书验证。禁用应用 HTTP 代理，不更改系统代理。
- 媒体和列表分别创建客户端；媒体不发送 Cookie、Authorization、Referer，正常 TLS 验证保留。
- 暂存文件与最终文件在同一目录；检查符号链接/Windows reparse point，随机新建 `.part`。校验通过才使用不覆盖目标的原子提交；失败或正常取消由所有权清理暂存。
- 校验大小、两次 SHA-256、顶层 MP4 boxes、单视频轨道元数据，再由 FFmpeg 全视频解码；拒绝损坏、截断、不合理尺寸/时长/帧率，解码超时 180 秒。
- FFmpeg 禁止网络协议和外部 dref；音频未解码，水印始终 `NOT_VERIFIED`。未实现图集、实况、直播、批量下载、断点续传、自动登录和生产主机审批。

来源、固定提交与许可证边界见 `THIRD_PARTY_NOTICES.md`。
