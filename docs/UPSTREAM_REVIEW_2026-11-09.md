# 上游检查：2026-11-09

- Asspp 与用户 fork：仍为 4.2.2 / `6682eb8f831a7b5c62dc14ea97088769c6adba48`，与现有集成相同。
- ApplePackage：仍固定 2.0.3。main 仅新增删除未使用 SAP 快照导入和资源清单的清理，不是安装或 VPN 修复，未更新依赖。
- idevice：最新发布 v0.1.68，与项目固定版本相同，未替换 ABI/二进制。
- AssppWeb：近期协议修复日期为 2026-10-20；现有下载回退和本地 kbsync 实现已覆盖对应路径，未覆盖本地实现。
- ipatool：发现 2026-11-08 更新，按行为移植适用部分，未直接合并 Go 源码或替换 iOS 界面。

已移植：

1. [`72c47d538b`](https://github.com/majd/ipatool/commit/72c47d538b)：55 版曾使用 Configurator 2.21 请求 User-Agent，统一 ApplePackage 和本地下载请求。**58 版已撤回这一项**：后续检查发现 ipatool 同时为请求生成端点绑定的 AMD 证明，本项目未移植对应运行时，单独更换客户端标识是不完整适配；详情见 `docs/DOWNLOAD_AMD_VERIFICATION.md`。
2. [`001d889896`](https://github.com/majd/ipatool/commit/001d889896)：规范化 storefront 的逗号和连字符后缀，用于区域匹配与下载请求头。
3. [`856323251a`](https://github.com/majd/ipatool/commit/856323251a)：借鉴服务端 dialog 处理，在本地下载/历史版本响应中保留 message 和 explanation，不自动打开服务端 URL。

未直接移植：

- 本地鉴权恢复的大部分代码依赖 ipatool 的桌面 AppleMediaServices/CoreADI/FairPlay 模拟器和其设备状态；不能仅修改接口地址就移入 iOS，现有 ApplePackage 鉴权未被替换。
- 动态 storefront 发现需要更换 ApplePackage 的区域映射路径，本次仅移植编号后缀兼容，不额外扩大地区选择。
- [`536d7bacc1`](https://github.com/majd/ipatool/commit/536d7bacc1) 修复 Go 模拟器中的 NSURLComponents 桥接；本项目使用 Foundation 原生 URLComponents，无需复制桥接补丁。

验证：构建运行现有下载协议和传输检查，并补充区域编号、请求头与 dialog 响应的回归检查；不以此宣称 Apple 账户登录已实网验证。
