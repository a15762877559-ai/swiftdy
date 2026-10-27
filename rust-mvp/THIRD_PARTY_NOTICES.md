# 来源与复用边界

本工程不是 DouStudioKit 的 Swift 翻译版，也不链接或编译该库。解析与排序依据已记录的 JSON 协议行为独立实现；安全下载、Windows CLI、存储和验证由本项目实现。没有修改上游或既有 Swift Harness。

## 固定 Swift 参考

- `qinjian0420/DouStudioKit@362dad3d082e9f63c8efd360acc653ba169d40a2`。
- 根 `LICENSE` 是 GNU GPL version 3；`README.md:223` 和 `NOTICE` 明确整体作为 GPL-3.0 派生作品分发。
- 同仓库附带 `LICENSE-APACHE-2.0`，但这不构成整个 Swift 包的双许可证授权。
- 只引用行为、协议字段、历史验收结论；没有把 Swift 签名、下载器或其他实现复制进本工程。行为研究不等于严格的隔离式 clean-room 开发，本报告不作此声称。

## Apache 签名来源

`src/signing.rs` 的算法适配及 `scripts/generate-signing-vectors.py` 生成的向量参考：

- 项目：<https://github.com/Evil0ctal/Douyin_TikTok_Download_API>
- 固定提交：`3d540dbf3783449e638403b65d81c882c4a99575`
- 源文件：`src/dtk/signing/native/abogus.py`、`websign.py`。
- 许可证：该固定提交根目录 Apache-2.0；全文保存在 `third-party/LICENSE-APACHE-2.0`。
- 原 NOTICE 原样保存在 `third-party/NOTICE-signing.txt`：Copyright 2021-2026 Evil0ctal and contributors。
- 上游 `abogus.py` 头部明确记载：旧实现曾有 GPL 来源冲突，当前实现于 2026-09-09 从平台代码重新推导。这里仅使用该新版固定实现；该来源陈述是上游作者的声明，不能由本轮验证其全部历史权利。
- 变更说明：2026-10-27，改写为 Rust 固定数组、RustCrypto SM3、调用者随机源和只支持 GET 的签名管线；没有携带上游 token 生成、浏览器池、RPC、自动回退或网络代码。
- `src/signing.rs` 的上述改写按 Apache-2.0 条件保留来源及修改说明。它并不重新许可 DouStudioKit 或已有仓库文件。

向量只包含合成用户、合成 token、固定时钟和确定性随机序列；生成器只加载固定源码的三个本地 Python 文件（SM3、A-Bogus、WebSign），不运行上游应用或访问平台。`fixtures/signing-vectors.json` 记录源文件 SHA-256。比较证明 Rust 与这份 Python 实现一致，不证明平台当前接受 Rust 请求。

## 依赖和工具

Rust 依赖及精确版本固定在 `Cargo.lock`，通过 Cargo 的正常构建机制使用；主要库为 Tokio、Reqwest/Rustls、Serde、Clap、Tempfile、SHA2、SM3、MD5、Rand、Zeroize、Rpassword。测试专用 rcgen/tokio-rustls 只生成本地自签名证书。

FFmpeg/ffprobe 是单独安装的外部验证工具，本仓库不复制其二进制。发布可执行文件前，仍应按实际打包范围处理依赖许可证及 FFmpeg 的具体构建许可证。本次为个人自用 MVP，不声明商业分发审查完成。
