# 001 · 连接方式改为直连 IP + 自签证书指纹固定

- 日期：2026-08-07
- 档位/组合：快速（基础设施直做）

## 背景
- Cloudflare Tunnel（`api.yihanlife.ccwu.cc`）连接受网络影响持续不稳定（阿里云→边缘 7844 被限流），用户登录频繁失败。
- 直连域名 HTTPS 被运营商/云厂商对「443 + 域名 SNI」的 TLS 拦截（RST），各网络路径均复现。
- Cloudflare 橙云→源站也因同类 SNI 拦截返回 525。
- dart:io（BoringSSL）在 macOS/Windows 无法验证 Let's Encrypt 新根（ISRG Root YR/X2）信任链（Android 可）。

## 决策
1. API 改为直连固定 IP：`https://121.196.222.122/api`（绕开域名 SNI 拦截）。
2. 服务器改用**自签证书**（CN=IP，10 年有效期，`/opt/clipflow/tls/`）。
3. App 采用**指纹固定**：校验证书 DER SHA-256 == 内置指纹（`07AA7BFC…`），与信任库/证书链/续期完全解耦。

## 后果
- 三端直连稳定可用；换证书时必须同步更新 App 内置指纹（已注释说明）。
- 域名 `api.yihanlife.ccwu.cc` 及 Cloudflare/隧道弃用（如需恢复，先做 ICP 备案）。
- 若后续重新启用域名方案，需同步改回 baseUrl 与校验逻辑。
