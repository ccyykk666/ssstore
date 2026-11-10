# HTTPS 安装清单服务

60 版真机日志已证实：持续后台任务获得授权，用户点击安装后，本机服务仍能持续响应 Safari 心跳，但没有收到系统安装器的清单 HTTP 请求。此前怀疑的后台挂起可排除；系统进程的 TLS 校验失败和 VPN 对其流量的影响，当前日志仍无法区分。

这个候选方案参考 Feather 的 semi-local 数据流：公网 HTTPS 仅生成 plist，IPA 从手机的 HTTP 回环服务传输。代码独立编写，不复制 Feather 的实现。它需要联网获取清单，蜂窝网络即可；IPA 不上传到清单服务。服务会收到应用名称、Bundle ID、内部构建版本和带随机标识的本机 IPA 地址，不接收账号、许可证、IPA 文件或配对记录。此实现不读取外部资源，也不记录查询参数；托管平台自身的访问日志设置仍由部署者控制。

用户同意试用后，已通过 Sites 部署公开的 HTTPS 清单服务：<https://ssstore-install-manifest.kkkk0615.chatgpt.site>。61 版从下载详情的“兼容安装”入口使用该服务；只有点击安装才发送上述元数据，先验证返回的 plist 与本机 IPA 一致，再交给系统。此入口不需要根证书。配对安装和证书安装保留各自原有通道。

部署、公开访问配置及本地 XML 测试已通过。构建时的云端 HTTP 探测收到托管层 `403 / error code: 1010`；随后用户设备的预检 HTTP 200，系统安装器读取了本机 IPA，用户确认安装成功。不同客户端的结果需分别判断，不能承诺绕过所有 VPN 对回环连接的接管。App 预检会直接显示 HTTP 错误并记录提供商错误码，不会把无效清单交给系统。

## 验证

```sh
node --test tools/installation-manifest/worker.test.mjs
node --test tools/installation-manifest/server.test.mjs
```

## 部署方式

自有服务器部署文件和操作说明见 [DEPLOY.md](DEPLOY.md)。Docker 镜像及只读、非 root 容器运行、健康检查与实际 XML 响应均已在本地验证；服务器的域名、证书和手机直连结果需在真实部署后检查。

部署者登录自己的 Cloudflare 账号后，在此目录执行 `npx wrangler deploy`，取得 Worker 的公网 HTTPS 地址；无需安装页面或持有用于 App 签名的私钥。也可把相同的 HTTP 接口部署到自己的 HTTPS 服务。未执行部署前不产生外部服务或费用。

### 普通服务器部署

对于无法直连 `chatgpt.site` 的网络，可将相同清单协议迁移到用户可以直连的域名及主机，例如合适的国内或香港节点。这里没有来自中国大陆的网络探测点，不能仅凭服务器所在地区或更换域名就保证可用；必须在目标手机关闭 VPN 后验证。

已提供无第三方运行依赖的 Node.js 版本（Node.js 20+）：

```sh
node tools/installation-manifest/server.mjs
```

服务默认仅监听 `127.0.0.1:8080`，由 Caddy 等反向代理提供公开、受 iOS 信任的 HTTPS。`Caddyfile.example` 为最小示例，需将域名替换成自己拥有且已解析到服务器的域名。不要把示例域名填进 App，也不要用 HTTP 清单或本机自签名证书替代公网 HTTPS。

部署后可先检查 `/healthz`，再使用合成的应用元数据请求 `/manifest.plist` 验证 XML。迁移只涉及清单接口，IPA 仍由手机本机传输。若仅将自定义域名绑定到现有 Sites 项目，也需要拥有该域名并完成 DNS 验证；这种方式仍使用原托管网络，不能保证解决源站链路问题。

接口为 `GET /manifest.plist`，参数为 `bundleid`、`name`、`version`、`fetchurl`。`version` 应取 IPA 内的 `CFBundleVersion`，不是商店展示版本。`fetchurl` 仅接受带端口、随机 UUID 文件名的 `127.0.0.1` IPA 地址。

客户端实现包括：仅监听回环地址的本机 HTTP IPA 入口、持续后台任务、实际清单预检，以及对 IPA 内 `CFBundleVersion` 的读取。63 版起，服务地址在“设置 → 兼容安装 → 清单服务”中配置，支持域名、HTTPS origin 或完整接口地址。地址不再固定为某个托管域名；自定义服务失败时不会静默发送到另一服务。默认服务常量及凭据隔离的预检代码位于 `ssstore/InstallerManifestService.swift`。不能只替换 `itms-services` 的主机名，也不能用网页上的 JavaScript 替代系统读取的 XML 清单。

Sites 项目：`appgprj_6af2e2c46b2c81918d65bde6eeb87b91`，部署源位于 `/workspace/sites/ssstore-install-manifest`。该目录的 `.openai/hosting.json` 为已保存的项目身份；维护时复用该项目，不能重新创建重复服务。这里的 Worker 为可自行部署的等价后端，Sites 版本增加了根路径的纯文本健康响应。Worker 不主动写日志；Sites/Cloudflare 平台可能保留请求 URL 和访问日志。
