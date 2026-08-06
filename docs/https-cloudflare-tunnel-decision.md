# HTTPS/Cloudflare Tunnel 接入决策记录（2026-08-06）

> 本文记录 ClipFlow 接入域名 + HTTPS 的背景、决策、影响与回退方案，供后续调整架构时参考。

## 背景

- 域名：`yihanlife.ccwu.cc`（10 年，DNS 托管到 Cloudflare）
- 服务器：阿里云 ECS `121.196.222.122`（国内，未备案）
- 目标：App 使用域名 + HTTPS，不备案
- 约束：不迁移服务器，不改变端到端加密与数据存储

## 为什么不能直接 80/443

阿里云国内 ECS 对未备案域名开放 80/443 会触发备案拦截，因此不能直接使用标准端口。

## 为什么 8443 直连也不可用

1. 先在服务器上配置 nginx 监听 `8443`，Let's Encrypt 证书走 Cloudflare DNS-01 签发成功。
2. 服务器本机经公网 IP 访问 HTTPS 完全正常。
3. 公网客户端（Mac、Windows）TCP 8443 可连通，但 TLS 握手被中间链路重置：
   - curl / Python / Windows curl 均在 ClientHello 后被 `Connection reset`
   - `openssl s_client` 可完成握手（客户端指纹不同，能绕过检测）
   - 与 SNI 域名无关（换 SNI 同样表现）
4. 尝试 Cloudflare 代理回源（proxied=true），边缘可达但回源 TLS 也被重置（HTTP 525）。

结论：国内公网到该 ECS 的非备案 HTTPS 直连/回源路径不稳定，需要换接入方式。

## 决策：Cloudflare Tunnel（标准 443，不备案）

架构：

```text
App
  ↓ https://api.yihanlife.ccwu.cc（Cloudflare 边缘，托管证书）
Cloudflare 全球边缘
  ↓ cloudflared 隧道（QUIC/HTTP2，服务器主动连出）
阿里云 ECS
  └─ ClipFlow 服务（Node.js + SQLite + 文件）监听 127.0.0.1:3000
```

要点：

- `cloudflared` 装在阿里云服务器上，作为 systemd 服务常驻（`/etc/systemd/system/cloudflared.service`，token 存 `/etc/cloudflared/token`）。
- Cloudflare 公共主机名：`api.yihanlife.ccwu.cc` → `http://localhost:3000`。
- 服务器不需要对外开放 80/443/8443/3000；ClipFlow 服务通过 systemd `HOST=127.0.0.1` 只监听回环。
- nginx 8443 备用配置已移除；Let's Encrypt 证书已签发（acme.sh 自动续期）仅作备用。
- 客户端 API 地址：`https://api.yihanlife.ccwu.cc/api`；旧地址 `http://121.196.222.122:3000/api` 保留在代码注释中作回退。

## 影响与风险

| 项目 | 说明 |
|------|------|
| 国内访问 Cloudflare 边缘 | 线路质量有波动，是最大风险点；如实际变慢，优先怀疑这里 |
| cloudflared 依赖 | 域名不可用时先查 `systemctl status cloudflared`；已配置开机自启 + `Restart=always` |
| TLS 终止位置 | Cloudflare 可见登录 token 等请求头；内容本身是端到端加密密文 |
| 延迟 | 多一跳，极端情况略增 |
| 数据位置 | 未变，仍在阿里云 ECS |
| 费用 | Cloudflare 免费版足够 |

## 回退/替代方案

1. 直连 HTTP 回退：客户端改回 `http://121.196.222.122:3000/api`，服务端恢复监听 `0.0.0.0` 或安全组放行 3000；缺点：token 明文、无域名 HTTPS。
2. 备案后直连：完成 ICP 备案后可直接 443 + Let's Encrypt，链路最短。
3. Cloudflare 代理 + Origin Rule：SSL 模式 Flexible，Origin Rule 指向 `3000`，可绕开回源 TLS 重置，但 Cloudflare 与源站之间为明文 HTTP。
4. 更换香港/海外轻量服务器：可直连 443，不受备案限制，但需迁移数据。

## 密钥安全

- `API or DSN or other.md`（Cloudflare API Token / Sentry DSN / 隧道 token）已加入 `.gitignore`。
- 隧道 token 仅存服务器 `/etc/cloudflared/token`，不进入仓库。
