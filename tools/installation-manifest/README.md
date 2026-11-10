# 安装清单服务

公网 HTTPS 服务生成安装清单，IPA 由手机自身的 HTTP 回环服务发送给系统安装器。它适用于无法在 VPN 开启时使用本机 HTTPS 清单的情况；用户已在 61 版确认安装成功。服务不接收 IPA、Apple ID 或配对文件。

## 私有 VPS 部署（64 版起）

按 [DEPLOY.md](DEPLOY.md) 部署。Node.js 后端需要强随机令牌才能启动；签发接口使用鉴权 POST，系统通过不含长期令牌或应用信息的短期随机票据 URL 读取清单。没有令牌的调用不会生成清单。容器仅暴露本机端口，以非 root 用户和只读文件系统运行。

手机在“设置 → 兼容安装 → 清单服务”填写地址和访问令牌。令牌仅保存在本机钥匙串并绑定完整接口地址；App 不将其交给系统安装器，也不跟随 HTTP 重定向转发。更换地址需要单独配置，自定义服务失败时不会向另一个服务发送元数据。

`server.mjs` / `private-service.mjs` 是私有部署入口。`worker.mjs` 只作为纯 XML 生成器复用，其公开 GET 入口保留供已有公开服务使用，**不是私有部署入口**。不要把 Worker 直接部署后误认为有鉴权。

## 验证

```sh
node --test tools/installation-manifest/worker.test.mjs tools/installation-manifest/server.test.mjs
```

测试覆盖鉴权、过期和有限次数票据、配额隔离、容量和请求体限制、真实 HTTP 流程、XML 转义及回环地址校验。还应在实际部署后检查域名证书、反向代理及手机关闭 VPN 的连接和安装结果。

## 已有公开服务

默认地址为 <https://ssstore-install-manifest.kkkk0615.chatgpt.site/manifest.plist>，保持旧客户端的公开 GET 协议。它接收应用名、Bundle ID、内部版本和带随机文件名的本机 IPA 地址，不接收账号、许可证或 IPA。平台自身可能保留访问 URL 和日志；大陆网络可达性需由目标手机验证。

Sites 项目：`appgprj_6af2e2c46b2c81918d65bde6eeb87b91`，部署源 `/workspace/sites/ssstore-install-manifest`，项目身份保存在该目录的 `.openai/hosting.json`。私有 VPS 部署不修改此公开服务，不影响已有用户。
