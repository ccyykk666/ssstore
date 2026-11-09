# 证书安装与 VPN

本地 HTTPS 服务使用 `app.localhost.qaq.wiki`，应连接 `127.0.0.1`。
浏览器和系统安装服务使用自己的网络进程；App 无法用 URLSession 的代理设置让它们绕过第三方 VPN。

对于 Loon，可将以下条目合并到现有配置中。规则应放在可能命中该域名的代理规则之前，保留其他配置。

```ini
[Host]
app.localhost.qaq.wiki = 127.0.0.1

[Rule]
DOMAIN,app.localhost.qaq.wiki,DIRECT
IP-CIDR,127.0.0.0/8,DIRECT,no-resolve
```

同时在 Loon 的 HTTPS 解密设置中排除 `app.localhost.qaq.wiki`。直连规则不一定会排除 HTTPS 解密，两处都需要检查。
此配置依赖 VPN 对本地流量的处理，仍需设备验证；不保证适用于全部 VPN 或强制全隧道配置。
如果仍不通，证书安装期间临时关闭 VPN；配对安装依赖的回环连接应按原配置使用。

参考：[Loon DNS 映射](https://github.com/Loon0x00/LoonManual/blob/master/docs/cn/hostmap.md)。
