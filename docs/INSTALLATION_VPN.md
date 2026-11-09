# 证书安装与 VPN

## 56 版起：本机 IP 安装

安装页面、清单、图标和 IPA 全部通过 `https://127.0.0.1:<端口>/…` 提供，本地服务只监听 `127.0.0.1`。
这一条备用安装路径不需要配对记录、局域网或 Wi-Fi；使用蜂窝网络也可打开本机服务，已下载的 IPA 不会上传到外部服务器。

首次使用需要安装新证书：

1. 进入下载详情 → 证书安装 → 安装本机证书，允许下载描述文件。
2. 在系统设置中安装“ssstore 本机安装证书”描述文件。
3. 前往设置 → 通用 → 关于本机 → 证书信任设置，为页面上显示的 `ssstore Loopback CA <编号>` 启用完整信任。
4. 返回 App，点击安装，再在浏览器和系统提示中确认。

旧版 `Asspp Local Installation CA` 不适用于新 IP 证书。每台设备本地生成 CA 和服务器私钥，以“仅本设备、首次解锁后可用”方式存入钥匙串；安装包和配置描述文件均不包含私钥。
服务器证书接近到期时会换发，保留同一 CA。CA 本身接近到期或钥匙串身份丢失时，需要重新安装并信任新证书；不要根据旧证书的开关判断新证书已受信任。
App 的检查使用系统证书信任，不忽略证书错误，也不把自己的 CA 自动添加为可信锚点。

这个改动移除了域名解析和域名代理规则的影响，目的是允许保持 VPN 开启且不新增规则。它无法替第三方 VPN 修改路由，也不能保证强制接管回环 IP 或拦截本地 HTTP/HTTPS 的 VPN 一定可用。蜂窝网络、VPN 开启时的 Safari / 系统安装完整流程仍需真机验证。

## 55 版及以前

旧版使用 `app.localhost.qaq.wiki`。Loon 的原有直连方法仅用于旧版本：

```ini
[Host]
app.localhost.qaq.wiki = 127.0.0.1

[Rule]
DOMAIN,app.localhost.qaq.wiki,DIRECT
IP-CIDR,127.0.0.0/8,DIRECT,no-resolve
```

规则放在可能匹配的代理规则之前，并在 HTTPS 解密设置中排除该域名。
参考：[Loon DNS 映射](https://github.com/Loon0x00/LoonManual/blob/master/docs/cn/hostmap.md)。
