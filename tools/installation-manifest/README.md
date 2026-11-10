# 可自行托管的 HTTPS 安装清单服务（尚未接入客户端）

60 版真机日志已证实：持续后台任务获得授权，用户点击安装后，本机服务仍能持续响应 Safari 心跳，但没有收到系统安装器的清单 HTTP 请求。此前怀疑的后台挂起可排除；系统进程的 TLS 校验失败和 VPN 对其流量的影响，当前日志仍无法区分。

这个候选方案参考 Feather 的 semi-local 数据流：公网 HTTPS 仅生成 plist，IPA 从手机的 HTTP 回环服务传输。代码独立编写，不复制 Feather 的实现。它需要联网获取清单，蜂窝网络即可；IPA 不上传到清单服务。服务会收到应用名称、Bundle ID、内部构建版本和带随机标识的本机 IPA 地址，不接收账号、许可证、IPA 文件或配对记录。此实现不读取外部资源，也不记录查询参数；托管平台自身的访问日志设置仍由部署者控制。

这只是待选择、部署和接入的候选后端，没有部署到任何公共地址，没有改变 App 的安装方式。HTTP IPA 在 iOS 27 和用户 VPN 下的真实安装结果仍需验证，不能承诺它绕过所有 VPN 对回环连接的接管。

## 验证

```sh
node --test tools/installation-manifest/worker.test.mjs
```

## 部署方式

部署者登录自己的 Cloudflare 账号后，在此目录执行 `npx wrangler deploy`，取得 Worker 的公网 HTTPS 地址；无需安装页面或持有用于 App 签名的私钥。也可把相同的 HTTP 接口部署到自己的 HTTPS 服务。未执行部署前不产生外部服务或费用。

接口为 `GET /manifest.plist`，参数为 `bundleid`、`name`、`version`、`fetchurl`。`version` 应取 IPA 内的 `CFBundleVersion`，不是商店展示版本。`fetchurl` 仅接受带端口、随机 UUID 文件名的 `127.0.0.1` IPA 地址。

客户端后续接入还需要：专门的本机 HTTP IPA 入口、持续后台任务、服务地址配置、实际清单请求预检，以及真实设备安装验证。不能只替换目前 `itms-services` 的主机名，也不能用网页上的 JavaScript 替代系统读取的 XML 清单。
