# 部署到自己的服务器

本服务只生成安装清单，不保存或接收 IPA。手机仍从自身的回环地址传输安装包。

先准备一个能在目标手机关闭 VPN 后访问的域名，并将它解析到服务器。最终接口必须有公开受信任的 HTTPS 证书；下面的 `manifest.example.com` 仅为占位示例，需要替换为自己的域名。

## A. 已有 Nginx、宝塔或其他 HTTPS 站点

在本目录运行（需要 Docker Compose）：

```sh
docker compose up -d --build
curl http://127.0.0.1:8080/healthz
```

然后在已有 HTTPS 站点中，将 `/manifest.plist` 反向代理到 `http://127.0.0.1:8080`，保留原始查询参数。例如 Nginx 的站点内部可使用：

```nginx
location = /manifest.plist {
    proxy_pass http://127.0.0.1:8080;
}
```

修改、检查并重新加载现有反向代理配置前，先确认具体使用的服务和站点；无需停掉它或另开一个占用 443 的服务。

如果本机 8080 已占用，可用 `MANIFEST_HTTP_PORT=18080 docker compose up -d --build`，并把反向代理端口同步改为 18080。

## B. 没有已有 HTTPS 服务，80 和 443 可用

```sh
MANIFEST_DOMAIN=manifest.example.com docker compose --profile https up -d --build
```

Caddy 会为指定域名自动申请证书。域名需要解析到此服务器，相关端口需要能从公网访问。证书保存在 Docker 的 `caddy_data` 卷中，后续更新保留此卷。

## C. 不使用 Docker

安装 Node.js 20 或更新版本后：

```sh
node server.mjs
```

服务监听 `127.0.0.1:8080`；由现有 HTTPS 反向代理转发到该端口。没有已有代理时，可参考 `Caddyfile.example` 配置 Caddy。使用自己的进程管理器保持服务运行。

## 手机端验证

在 ssstore 63 版及以后，打开“设置 → 兼容安装 → 清单服务”，填写 `https://自己的域名/manifest.plist`，或只填写域名。点击“测试连接”，该操作只发送示例元数据。

关闭 VPN 后测试通过，再进入下载详情的“兼容安装”安装应用。测试会检查 HTTPS 连接及清单内容；系统实际安装仍需另行验证。

自定义服务出错时，App 不会自动把应用元数据发往默认服务。“恢复默认服务”是单独的手动操作。
