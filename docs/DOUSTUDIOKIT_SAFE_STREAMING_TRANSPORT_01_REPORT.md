# DOUSTUDIOKIT_SAFE_STREAMING_TRANSPORT_01

## Preparation

Repository: `D:\Projects\doustudio-runtime-acceptance`; GitHub: https://github.com/achusonwork-bit/doustudio-runtime-acceptance.
Initial main: `bc85f8dc90bc507b277eca3d50e1f12ee39789b4`.
Pinned original upstream: `362dad3d082e9f63c8efd360acc653ba169d40a2`.

This task adds a separate package under `runtime-harness/safe-streaming-tests/`; it does not change the existing RuntimeAcceptance executable, Package.swift, or any existing workflow. Its new manual-only workflow runs on `xcode-27`, has contents:read, disabled persisted checkout credentials, a 20 minute timeout, SHA-pinned official actions and a 3 day artifact retention period. It has no inputs or Secrets. Tests run under a localhost-only network sandbox; no Douyin API/media requests are permitted.

## Interface and original integration

`Sources/SafeStreamingTests/SafeStreamingTransport.swift` implements the original `StreamingHTTPTransport` and its inherited `HTTPTransport`. Original source at the pinned SHA:

- `Sources/DouStudioKit/Networking/StreamingTransport.swift:66`: streaming protocol.
- `Sources/DouStudioKit/Download/Downloader.swift`: initializer injects HTTPTransport.
- `Sources/DouStudioKit/Download/StreamingDownloader.swift:23`: `Downloader.download(work:progress:progressInterval:)`.
- Same file, line 103: `downloadUnitStreaming`, type check and `transfer` streaming branch. `transfer` writes chunks using the original FileHandle and moves `.part` only after stream completion.
- `Sources/DouStudioKit/Networking/SessionStore.swift:236`: original download headers include unbounded `Range: bytes=0-` and optional Cookie. The new transport removes Range and Cookie, rejects nonzero resume Range and Authorization, and reconstructs only its own non-authentication headers.

Production initializer requires an exact previously extracted HTTPS URL and an audited host allowlist. This task does not establish a production domain allowlist or wire this initializer into a real download workflow. The separate test initializer only accepts literal `127.0.0.1` and an allocated local port. Every integrated test constructs a synthetic DouyinWork, injects the transport into the original Downloader, and uses its progress overload. `send` always throws; no buffered fallback is available.

## Guarantee boundaries

`MAX_MEDIA_BYTES=104857600`. Oversized declared length is rejected at headers; every callback chunk is budget checked before acceptance. Known exact-boundary responses cancel the underlying task after accepting the complete declared body; unknown-length responses at the boundary fail closed. Full-resource 206 requires exact Content-Range and matching received length. Redirects, non-media content types, invalid initial ftyp marker, empty bodies and incomplete responses fail. The ftyp check is a transport sanity check, not media decoding or proof of playability.

The pull-based AsyncThrowingStream uses a bounded 2 MiB channel, URLSession task suspension and a maximum one consumer chunk. This bound excludes URLSession and OS buffers. One lock serializes state and counters; completion is recorded only from the actual task completion callback. Queued callbacks after cancellation are counted but never accepted. The transport is single-use, including after completion; no retry or resume logic exists.

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

Actual macOS run, step outcomes, artifact ZIP SHA-256 and per-case counters will be appended after the controlled workflow completes. Until then no runtime guarantee is marked PASS.

```ini
TRANSPORT_COMPILED = NOT_RUN
ORIGINAL_DOWNLOADER_INTEGRATION = NOT_RUN
STREAMING_PATH_VERIFIED = NOT_RUN
APPLICATION_BYTE_BUDGET = NOT_RUN
DELEGATE_RECEIVE_LIMIT = NOT_PROVEN
CANCEL_REQUEST = NOT_RUN
CANCEL_COMPLETION = NOT_RUN
BOUNDED_BUFFERING = NOT_RUN
REDIRECT_REJECTION = NOT_RUN
CREDENTIAL_ISOLATION = NOT_RUN
PARTIAL_FILE_CLEANUP = NOT_RUN
SECOND_MEDIA_REQUEST_REJECTION = NOT_RUN
CONTROLLED_SERVER_TESTS = NOT_RUN
STRICT_NETWORK_RECEIVE_LIMIT = NOT_PROVEN
REAL_DOUYIN_DOWNLOAD = NOT_RUN
UPSTREAM_SOURCE_CHANGED = NO
ROOTNETSCOPE_CHANGED = NO
VIDEOFLOW_CHANGED = NO
```

The existing single-video workflow remains fail-closed. Even if the controlled tests pass, a subsequent real-download proposal must state the application budget versus unproven strict network limit, establish the extracted URL's audited host scope and preserve credential isolation. This task does not authorize or perform that real request.
