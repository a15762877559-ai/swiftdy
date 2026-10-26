# DOUSTUDIOKIT_SAFE_STREAMING_TRANSPORT_01

## Preparation

Repository: `D:\Projects\doustudio-runtime-acceptance`; GitHub: https://github.com/achusonwork-bit/doustudio-runtime-acceptance.
Initial main: `bc85f8dc90bc507b277eca3d50e1f12ee39789b4`.
Pinned original upstream: `362dad3d082e9f63c8efd360acc653ba169d40a2`.

This task adds a separate package under `runtime-harness/safe-streaming-tests/`; it does not change the existing RuntimeAcceptance executable, Package.swift, or any existing workflow. Its new manual-only workflow runs on `xcode-27`, has contents:read, disabled persisted checkout credentials, a 20 minute timeout, SHA-pinned official actions and a 3 day artifact retention period. It has no inputs or Secrets. Tests run under a localhost-only network sandbox; no Douyin API/media requests are permitted.

## Interface and original integration

`Sources/SafeStreamingTests/SafeStreamingTransport.swift` implements the original `StreamingHTTPTransport` and its inherited `HTTPTransport`. Original source at the pinned SHA:

- `Sources/DouStudioKit/Networking/StreamingTransport.swift:66`: streaming protocol.
- `Sources/DouStudioKit/Download/Downloader.swift:168`: initializer injects HTTPTransport.
- `Sources/DouStudioKit/Download/StreamingDownloader.swift:23`: `Downloader.download(work:progress:progressInterval:)`.
- Same file, line 103: `downloadUnitStreaming`, type check and `transfer` streaming branch. `transfer` writes chunks using the original FileHandle and moves `.part` only after stream completion.
- `Sources/DouStudioKit/Networking/SessionStore.swift:236`: original download headers include unbounded `Range: bytes=0-` and optional Cookie. The new transport removes Range and Cookie, rejects nonzero resume Range and Authorization, and reconstructs only its own non-authentication headers.

Production initializer requires an exact previously extracted HTTPS URL and an audited host allowlist. This task does not establish a production domain allowlist or wire this initializer into a real download workflow. The separate test initializer only accepts literal `127.0.0.1` and an allocated local port. Every integrated test constructs a synthetic DouyinWork, injects the transport into the original Downloader, and uses its progress overload. `send` always throws; no buffered fallback is available.

## Guarantee boundaries

`MAX_MEDIA_BYTES=104857600`. Oversized declared length is rejected at headers; every callback chunk is budget checked before acceptance. Known exact-boundary responses cancel the underlying task after accepting the complete declared body; unknown-length responses at the boundary fail closed. Full-resource 206 requires exact Content-Range and matching received length. Redirects, non-media content types, invalid initial ftyp marker, empty bodies and incomplete responses fail. The ftyp check is a transport sanity check, not media decoding or proof of playability.

The pull-based AsyncThrowingStream uses a bounded 2 MiB channel, condition-variable delegate backpressure and one <=64 KiB consumer piece (initial prefix may add <12 bytes). The active framework-provided callback Data is retained while split into bounded pieces; its maximum observed size is recorded separately. This bound excludes that callback and URLSession/OS pending buffers. One lock serializes state and counters; completion is recorded only from the actual task completion callback. Queued callbacks after cancellation are counted but never accepted. The transport is single-use, including after completion; no retry or resume logic exists.

`delegate_received_bytes` counts actual callback bytes, even after cancellation. `accepted_bytes` counts budget-approved bytes. `written_bytes` is measured from actual files after the original Downloader returns. Server payload writes are not packet-level delivery evidence. Already buffered system bytes can arrive after cancellation. Therefore `STRICT_NETWORK_RECEIVE_LIMIT=NOT_PROVEN`; a <=100 MiB accepted value never establishes an absolute network receive bound.

Each process owns a new UUID workspace below runner.temp. On failure, the original downloader's residual partial is counted, then the Harness removes only that owned workspace. Success files are also deleted after hashing. Artifacts use ten explicit diagnostic filenames; no media, Cookie, request URL, authentication headers or raw request errors are uploaded. Cookie isolation uses a synthetic fixture only.

## Controlled server cases

| ID | Real URLSession / original Downloader scenario |
|---|---|
| ST-001 | Normal complete response |
| ST-002 | Empty response rejection |
| ST-003 | Content-Length above 100 MiB rejected before body acceptance |
| ST-004 | Chunked response without Content-Length |
| ST-005 | 100 MiB minus one byte |
| ST-006 | Exactly 100 MiB, complete content and cancellation |
| ST-007 | Chunked data exceeds budget |
| ST-008 | Server full response; unbounded original Range removed |
| ST-009 / ST-010 | 302 / 307 rejection; target never requested |
| ST-011 / ST-012 | HTML / JSON response rejection |
| ST-013 | Server disconnect before declared completion |
| ST-014 | Download timeout |
| ST-015 | Caller cancellation |
| ST-016 | Slow consumer and queued data during cancellation |
| ST-017 | Concurrent second original download rejected |
| ST-018 | Second original download after completion rejected |
| ST-019 | Original streaming path plus explicit buffered fallback rejection |
| ST-020 | Synthetic Cookie stripped; server sees no authentication |
| ST-021 | Complete full-resource 206 |
| ST-022 | Partial-resource 206 rejection |
| ST-023 | HTTP 403 rejection, no retry |
| ST-024 | JSON disguised as video/mp4 |
| ST-025 | Slow unknown-length chunked response |
| ST-026 / ST-027 / ST-028 | Authorization / production HTTP / resume Range rejected before any request |

Each case has an independent actual process exit code. Every case checks its request count, byte budget, buffering, final state, no buffered fallback, and cleanup. Cancellations check the actual completion callback and no further acceptance. Queued-after-cancel callback observations are explicitly reported as observed or not observed; they are not fabricated.

## Validation and delivery state

Windows cannot execute this macOS-dependent Swift package. Local YAML, Bash, Python and protection checks are recorded separately from real cloud results. No actionlint or Swift installation is performed. The original 211 files are hashed before and after; the unrelated existing untracked RUN report is excluded from commits.

The actual second macOS run completed successfully. Results below refer to tested SHA `3f51aaebb84cfde8c1009b264298e52c8ecd4bf5`; the first failed run is retained separately. Later documentation-only commits do not change the tested source.

```ini
TRANSPORT_COMPILED = PASS
ORIGINAL_DOWNLOADER_INTEGRATION = PASS
STREAMING_PATH_VERIFIED = PASS
APPLICATION_BYTE_BUDGET = PASS
DELEGATE_RECEIVE_LIMIT = FAIL
CANCEL_REQUEST = PASS
CANCEL_COMPLETION = PASS
BOUNDED_BUFFERING = PASS
REDIRECT_REJECTION = PASS
CREDENTIAL_ISOLATION = PASS
PARTIAL_FILE_CLEANUP = PASS
SECOND_MEDIA_REQUEST_REJECTION = PASS
CONTROLLED_SERVER_TESTS = PASS
STRICT_NETWORK_RECEIVE_LIMIT = NOT_PROVEN
REAL_DOUYIN_DOWNLOAD = NOT_RUN
UPSTREAM_SOURCE_CHANGED = NO
ROOTNETSCOPE_CHANGED = NO
VIDEOFLOW_CHANGED = NO
```

The existing single-video workflow remains fail-closed. Even if the controlled tests pass, a subsequent real-download proposal must state the application budget versus unproven strict network limit, establish the extracted URL's audited host scope and preserve credential isolation. This task does not authorize or perform that real request.

## First actual run and evidence-based correction

Run: https://github.com/achusonwork-bit/doustudio-runtime-acceptance/actions/runs/40284758907 ; tested SHA `e3f4a4af483421a9e788cba3d9b035f597357f7b`. Build exit 0, test runner exit 1, 24/28 cases PASS. Full original results are preserved in `evidence/doustudio-safe-streaming-transport-01/run-40284758907/`. Artifact SHA-256 `fd98bea717c0f665f61717ecd2e5d78edf2de49535d5e7beb4dc8a4895e970d0` matches GitHub.

ST-003 timed out before receiving the response-head callback: the fixture sent an oversized header without initial body bytes. It now sends only one small body piece to provoke actual CFNetwork response delivery; accepted_bytes must still be zero. ST-005/006/007 failed closed with BOUNDED_BUFFER_OVERFLOW because URLSession coalesced multi-MiB callbacks despite suspend(). The implementation now divides each framework-provided callback into <=64 KiB pieces and waits on a condition variable for channel space, releasing the lock while waiting. Cancellation wakes the wait, preserving the 2 MiB owned channel and 100 MiB application budget. No assertion was relaxed.

ST-016 had reported caller cancellation while its underlying recorded cause was buffer overflow. Its regression assertion now also requires the transport root cause CALLER_CANCELLED; the original first-run result is retained without rewriting it. No after-cancel delegate callback happened in the first run; this absence does not establish a strict receive bound.

## 最终真实 macOS 验收

运行：https://github.com/achusonwork-bit/doustudio-runtime-acceptance/actions/runs/40285479553 。受测 SHA：`3f51aaebb84cfde8c1009b264298e52c8ecd4bf5`。macOS 27.0.1 (26A434)，Swift 6.4，Xcode 27.1 (27A9275)，ARM64。构建退出码 0；测试 runner 退出码 0；28/28 独立 Swift 进程均退出 0。所有 GitHub steps outcome 为 success，详见本次 evidence 下 jobs.json。

Artifact ID `12633384024`，ZIP SHA-256 `ea5142a35d643e66fa35a135e380ae666c1d5c800d8fcd52fca5614cdaa0a94c`，与 GitHub digest 一致；ZIP CRC、10 文件白名单、逐文件 SHA-256 均已核验。保存的是原始 Artifact 文本文件；build.log 的 ANSI 颜色和末尾空格保留，未为了 git diff --check 修改原始编译日志。

| 用例 | 退出码 | 结果 | 服务端 payload 写出 | delegate 收到 | 应用接受 | 实际写盘 | cancel 请求/完成 | 清理 |
|---|---:|---|---:|---:|---:|---:|---|---|
| ST-001 | 0 | PASS | 262144 | 262144 | 262144 | 262144 | False/False | PASS |
| ST-002 | 0 | PASS | 0 | 0 | 0 | 0 | True/True | PASS |
| ST-003 | 0 | PASS | 65536 | 0 | 0 | 0 | True/True | PASS |
| ST-004 | 0 | PASS | 262144 | 262144 | 262144 | 262144 | False/False | PASS |
| ST-005 | 0 | PASS | 104857599 | 104857599 | 104857599 | 104857599 | False/False | PASS |
| ST-006 | 0 | PASS | 104857600 | 104857600 | 104857600 | 104857600 | True/True | PASS |
| ST-007 | 0 | PASS | 105906176 | 105906176 | 102039552 | 100991877 | True/True | PASS |
| ST-008 | 0 | PASS | 262144 | 262144 | 262144 | 262144 | False/False | PASS |
| ST-009 | 0 | PASS | 0 | 0 | 0 | 0 | True/True | PASS |
| ST-010 | 0 | PASS | 0 | 0 | 0 | 0 | True/True | PASS |
| ST-011 | 0 | PASS | 64 | 0 | 0 | 0 | True/True | PASS |
| ST-012 | 0 | PASS | 64 | 0 | 0 | 0 | True/True | PASS |
| ST-013 | 0 | PASS | 65536 | 0 | 0 | 0 | False/False | PASS |
| ST-014 | 0 | PASS | 65536 | 0 | 0 | 0 | False/False | PASS |
| ST-015 | 0 | PASS | 131072 | 65536 | 65536 | 65536 | True/True | PASS |
| ST-016 | 0 | PASS | 8388608 | 2162688 | 2097152 | 0 | True/True | PASS |
| ST-017 | 0 | PASS | 8388608 | 8388608 | 8388608 | 8388608 | False/False | PASS |
| ST-018 | 0 | PASS | 262144 | 262144 | 262144 | 262144 | False/False | PASS |
| ST-019 | 0 | PASS | 262144 | 262144 | 262144 | 262144 | False/False | PASS |
| ST-020 | 0 | PASS | 262144 | 262144 | 262144 | 262144 | False/False | PASS |
| ST-021 | 0 | PASS | 262144 | 262144 | 262144 | 262144 | False/False | PASS |
| ST-022 | 0 | PASS | 262144 | 0 | 0 | 0 | True/True | PASS |
| ST-023 | 0 | PASS | 0 | 0 | 0 | 0 | True/True | PASS |
| ST-024 | 0 | PASS | 64 | 64 | 64 | 0 | True/True | PASS |
| ST-025 | 0 | PASS | 1048576 | 1048576 | 1048576 | 1048576 | False/False | PASS |
| ST-026 | 0 | PASS | 0 | 0 | 0 | 0 | False/False | PASS |
| ST-027 | 0 | PASS | 0 | 0 | 0 | 0 | False/False | PASS |
| ST-028 | 0 | PASS | 0 | 0 | 0 | 0 | False/False | PASS |

所有字节数均为 bytes。最大自有队列为 2097152 bytes；最大实测单次 delegate 回调为 4193376 bytes；取消至实际完成回调最长约 2.719 ms。自然成功完成的用例不需要取消，因此 cancel=false/false 不代表失败。所有实际网络用例只有一个任务最终回调；全部请求计数符合预期，第二次下载没有到达服务器，重定向目标没有被请求，服务器没有观察到 Cookie、Authorization 或 Range。

ST-007 的 delegate 接收量为 105906176 bytes（101 MiB），超过 100 MiB：因此 `DELEGATE_RECEIVE_LIMIT=FAIL`，`STRICT_NETWORK_RECEIVE_LIMIT=NOT_PROVEN`，不能将其包装成严格接收限额通过。应用接受 102039552 bytes，写盘 100991877 bytes，均在预算内；超限后请求并完成取消，原版残留 .part 由 Harness 删除。低于上限与恰好上限的完整响应分别写入 104857599 和 104857600 bytes，并成功完成原版 Downloader 流式路径。

ST-016 在真实取消时丢弃了 2097152 bytes 的已排队应用数据和当前回调剩余 65536 bytes，未交付给消费者。此次没有观察到“取消后新进入 delegate 的数据回调”（各例 queued_callbacks_after_cancel=0）。代码包含该分支的计数和拒绝逻辑，但不能把未出现的时序宣称为已实测；测试覆盖了排队应用数据和在途回调与取消竞争，原生迟到回调时序仍是验证限制。

ST-007/013/015/016/024 在清理前存在 .part（包含可能为空的文件）；各个独立工作空间清理后残留为 0，runner 兜底清理前也无残留。全部合成文件均已删除，没有上传媒体；ftyp 合成数据不代表可解码视频，也不能证明无水印。

## 下一步可行性与保护边界

应用层 100 MiB 接受/写盘预算、单次请求、原版流式注入、取消和清理已获得本轮证据。若下一阶段仍要求绝对网络接收 <=100 MiB，则当前方案不满足，真实下载应继续 BLOCKED；不能直接解除现有门禁。若用户明确接受“应用层预算 + 及时取消，系统可能超收”的范围，才可另行提出接入原下载流程的变更：审核实际提取 URL 的媒体主机名单，独立单次 transport，使用原版 progress 下载入口，所有消费端/文件错误也显式 cancel 并等待完成，最后在专属临时目录清理与媒体验证。该接入与真实下载均未在本轮执行。

本轮只新增独立 package、一个新 workflow、报告和本轮证据；既有六个 workflow、原 Harness、历史证据及原先未跟踪 RUN 报告均保持哈希一致。未操作其他项目、系统代理或 Git 全局配置。提交始终使用显式路径，普通推送 main；没有强制推送。真实 Cookie、抖音请求、分页、媒体下载、Rust 移植均未执行。
