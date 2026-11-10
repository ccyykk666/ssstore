# Cloudflare 私有清单服务

无需 VPS。App 64 版起支持本接口，建议使用 67 版或更新版本。现有 Sites 公开服务不受影响。

## 控制台部署

1. 进入 Cloudflare 的 **Workers & Pages → 创建应用 → 导入存储库**，连接 GitHub，仅授权需要的 `ccyykk666/ssstore` 仓库。
2. 选择 `main` 分支，填写：

   | 项目 | 值 |
   | --- | --- |
   | Worker 名称 | `ssstore-manifest-private` |
   | 根目录 | `tools/installation-manifest` |
   | 构建命令 | `npm run build` |
   | 部署命令 | `npm run deploy` |

   首次部署时 Wrangler 会自动创建并绑定名为 `ssstore-manifest-private` 的 D1 数据库，绑定名为 `DB`。服务自行初始化表，不需要手动执行 SQL。部署后可在 Worker 的“绑定”中确认 `DB` 和 `PUBLIC_LIMITER`。
3. 打开该 Worker 的 **设置 → 变量和机密 → 添加**，类型选 **机密 / Secret**，名称填写 `MANIFEST_API_TOKEN`，值填写用密码管理器生成的 **64 位随机字母数字串**。也可以在自己的终端执行 `openssl rand -hex 32` 生成。保存并部署生效。

   这是自己生成的服务访问口令，不是 Cloudflare 管理 API Token、Apple ID 密码或 VPS 密码。只填在 Cloudflare 和 App 中，不要发到聊天或提交仓库。首次尚未设置此机密时，服务返回 503，拒绝提供清单。
4. 在 Worker 的 **设置 → 域和路由 → 添加 → 自定义域**中添加未使用的子域名，例如 `install.example.com`。该域名所属区域需要先在 Cloudflare 接入并处于 Active 状态。Cloudflare 会配置相应 DNS 和 HTTPS。
5. 浏览器访问 `https://自己的域名/healthz`，应看到 `ssstore private manifest service: ok`。
6. 在 App 的 **设置 → 兼容安装 → 清单服务**中填写 `https://自己的域名/manifest.plist`，访问令牌填写步骤 3 的同一串口令，然后点击“测试连接”。关闭 VPN 后再测试一次，并实际安装一个应用。

没有域名时，可以先用 Cloudflare 分配的 `workers.dev` 地址验证部署，但它不能保证在中国大陆直连；绑定自有域名后仍需在目标手机的网络下实测。

不要给清单和票据接口添加 Cloudflare Access 登录页或 JavaScript 人机验证，系统安装器不能完成这些交互。通过服务自己的令牌与短期票据控制访问。

## 保护和数据范围

- 签发清单需要令牌，未授权请求不访问 D1；每分钟最多签发 30 张票据，跨 Worker 实例共享配额。
- 安装 URL 使用 256 位随机票据，不含长期令牌或应用信息；5 分钟有效、最多读取 8 次。读取次数通过单条 SQL 原子更新，支持系统 HEAD/GET 请求。
- 每个令牌最多保留 150 张有效票据，请求体最多 8 KiB；边缘层按 IP 近似限制每个 Cloudflare 节点每分钟 120 次请求。
- D1 临时保存应用名称、Bundle ID、内部版本和本机随机 IPA 地址组成的清单；过期后不可读取，并每分钟清理过期记录。API 令牌存储在 Worker Secret 中，D1 只存其哈希作用域。
- 不上传 IPA、Apple ID、许可证或配对文件。服务不读取外部安装包地址，不提供上传或代理功能，不主动写访问日志，Worker Observability 默认关闭。Cloudflare 自身的基础设施和账号级日志政策仍由其平台及账号配置决定。
- 更换 `MANIFEST_API_TOKEN` 并部署后，旧令牌与旧票据失效；App 中同步更新令牌。

## 配置文件

默认 `wrangler.toml` 部署的是私有服务 `cloudflare-private.mjs`。`wrangler.public.toml` 仅用于明确需要旧公开 GET 协议的场景，不能作为私有部署入口。

D1 资源自动创建需要 Wrangler 4.45 以上，本目录已固定 CLI 版本。通过 GitHub 导入时无需把 Cloudflare 管理密钥写入代码或发给他人。

本地验证：

```sh
npm ci --ignore-scripts
npm test
npm run test:runtime
npm exec wrangler -- deploy --dry-run
```

这些验证不等于已部署到用户 Cloudflare 账号，也不能证明中国大陆网络可达。
