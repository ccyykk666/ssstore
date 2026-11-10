# 私有安装清单服务部署

服务只生成 plist，不接收 IPA、Apple ID、配对文件或签名私钥，也不向 IPA 地址发请求。IPA 仍在手机本机传输。私有模式需要 ssstore 64 或更新版本；63 版不支持访问令牌。

需要一个自己控制、已解析到服务器、能在目标手机关闭 VPN 后访问的域名。系统安装器使用公开受信任的 HTTPS；示例 `manifest.example.com` 必须换成真实域名。更换服务器不能保证大陆网络可达，部署后需在手机上验证。

## 1. 创建服务器专用随机令牌

在本目录中执行，仅首次创建。若文件已存在，请保留原令牌：

```sh
install -d -m 0700 secrets
(umask 077; set -C; openssl rand -hex 32 > secrets/manifest_api_token)
sudo chown 1000:1000 secrets/manifest_api_token
sudo chmod 0400 secrets/manifest_api_token
```

`set -C` 防止覆盖已有令牌。容器以 UID 1000 的非 root 用户运行，因此需要文件所有者为 1000；父目录保持只有部署者可访问。不要把 `secrets` 目录打包、提交到 Git 或放进站点公开目录。令牌通过运行时只读 secret 文件传入，不嵌入镜像或 IPA。

用自己的安全终端查看令牌并填入手机设置，不要发到聊天或截图中。更换令牌时，重新生成文件并强制重建容器：`docker compose up -d --force-recreate manifest`，再同步更新手机。新进程不接受旧令牌，旧票据随进程退出失效。

## 2A. 已有 Nginx、宝塔或其他 HTTPS 站点

```sh
docker compose up -d --build
curl --fail http://127.0.0.1:8080/healthz
```

仅暴露本机 `127.0.0.1:8080`，然后在现有 HTTPS 站点内加入两条路径。示例 Nginx 配置：

```nginx
location = /manifest.plist {
    access_log off;
    client_max_body_size 8k;
    proxy_pass http://127.0.0.1:8080;
}
location ^~ /tickets/ {
    access_log off;
    proxy_pass http://127.0.0.1:8080;
}
```

不要为这些路径开启代理缓存或记录请求体、Authorization、票据路径。使用已有 CDN、面板、WAF 时，也需检查它们的日志与缓存配置。先检查配置再重载现有服务，不要占用已有站点的端口或停止其他应用。若 8080 已占用，可设置 `MANIFEST_HTTP_PORT=18080`，并同步修改反向代理端口。

## 2B. 没有现有 HTTPS 服务，80 和 443 可用

```sh
MANIFEST_DOMAIN=manifest.example.com docker compose --profile https up -d --build
```

Caddy 自动申请公开受信任的证书，默认不开启访问日志。保留 `caddy_data` 卷以保存证书。只开放必要的 80/443 和原有管理端口；不要把容器的 8080 直接暴露到公网。

## 2C. 不使用 Docker

安装 Node.js 20+ 后，以独立低权限用户运行：

```sh
MANIFEST_API_TOKEN_FILE=/安全目录/manifest_api_token node server.mjs
```

该用户必须能读取 secret 文件。服务默认监听 `127.0.0.1:8080`，由现有 HTTPS 代理转发；`Caddyfile.example` 为参考。由自己的进程管理器保持运行。缺少有效令牌时服务直接拒绝启动。

## 3. 手机配置与验证

ssstore 64 起，打开“设置 → 兼容安装 → 清单服务”：

1. 填写 `https://自己的域名/manifest.plist`，或只填写域名。
2. 在“访问令牌”中填写新生成的随机令牌。不是 VPS 登录密码或 Apple ID 密码。
3. 点击“测试连接”，检查成功后，在关闭 VPN 的情况下重新测试并实际安装。

令牌保存在仅本机使用的钥匙串中，绑定完整接口地址。修改域名、端口或路径后需单独配置，App 不会将旧令牌发送到新地址，也不会跟随重定向转发令牌。自定义服务失败时不会切换到默认服务。

## 接口与保护范围

- `POST /manifest.plist`：Bearer 令牌鉴权，JSON 的四个字符串字段为 `bundleid`、`name`、`version`、`fetchurl`。内部版本取 IPA 的 `CFBundleVersion`。
- 返回 HTTP 201 和 `{"path":"tickets/<随机标识>.plist"}`。App 先验证票据清单与本机包一致，再将票据 URL 交给系统。
- `GET`/`HEAD /tickets/<标识>.plist`：无需令牌，系统安装器可直接读取。256 位随机标识，5 分钟过期，最多读取 8 次。它是短期访问凭据，不能公开分享；URL 不包含长期令牌或应用信息。
- 每分钟最多签发 30 张票据，内存最多保存 150 张；应用信息只存在票据内存中，过期请求会清理。重启清空所有票据。
- 请求体最多 8 KiB，HTTP 超时、连接数和容器内存/CPU/进程数均受限。匿名请求不消耗用户的签发配额。
- 不保存服务端请求日志、不请求任意外部 URL、不允许远程 IPA 地址；没有文件上传、命令执行或公开管理接口。

这些保护限制接口滥用，不等于上游带宽层的 DDoS 防护。公网 TLS 终结代理能够看到元数据；管理员应限制其访问权限并关闭这些接口的访问日志。不要使用聊天中暴露过的 VPS 密码或将它复用为接口令牌。
