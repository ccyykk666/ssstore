# ssstore 项目文档

更新日期：2026-11-04。本文按公开仓库当前 `main` 的 0.6.0（39）版本编写，介绍产品边界、代码结构、数据流、构建和交付方式。具体实现以源码及工作流为准；设备服务和 Apple 商店接口可能随系统或服务端变化。

## 项目概览

ssstore 是面向 iPhone 和 iPad 的应用清单、版本查询、商店下载管理和配对设备数据查看工具。最低部署版本为 iOS 17。当前导航与列表由 UIKit 实现，首页统计通过 UIHostingConfiguration 使用 SwiftUI 原生数字过渡，业务逻辑复用 `AppModel`、`UpdateCore`、Asspp 和设备桥接。

列表与商品页文字按可用宽度换行，行高由内容决定；紧凑列表使用统一图标与字号，不限制长名称为单行。首页统计根据实际可用空间切换为一排、两列或单列，并响应系统文字大小；添加账户弹窗按表单实际高度调整，可继续展开。

本机清单读取、商店查询、账户登录、购买许可、下载以及设备安装是不同操作。读取应用不会自动登录商店账户、购买许可或安装应用。下载和安装须由用户明确发起。

当前应用底部四个页面：

| 页面 | 用途 |
| --- | --- |
| 应用 | 读取设备应用，查询版本，查看更新和待核对项目，忽略指定应用 |
| 数据 | 通过配对连接查看设备和应用公开给服务的只读数据 |
| 账户 | 添加、管理用于 Apple 商店操作的账户 |
| 搜索 | 按关键词或 Bundle ID 搜索 Apple 商店目录，打开商品信息与版本历史 |

## 主要功能和行为

### 应用清单与版本比较

1. 用户在设置中导入 Remote Pairing 配对文件，填写设备 IP 和端口。
2. “刷新应用”先读取设备清单，再对可查询的应用发起版本查询；读取失败时不拿旧清单冒充本轮结果。
3. 已安装系统应用可以显示，但不会参与 App Store 版本查询。
4. 比较以 Apple 商店应用标识和受支持的清单数据为依据，不对版本字符串做简单数值大小排序。
5. 只有确认存在可用新版本时标为“新版本”；服务未匹配或数据不足的项目列入“待核对”。应用统计跟随清单逐项匹配推进，计数不应超过已处理项目数。
6. 应用列表支持左滑忽略。忽略记录按 Bundle ID 保存，并保留名称和图标等展示信息；设置中可恢复。
7. 详情页显示本机版本、构建号、设备清单提供的构建 SDK 信息、Bundle ID、商店版本及更新说明。SDK 只显示版本号，例如 `26.2`；系统没有提供有效元数据时，不从 ssstore 自身构建环境猜测。

### 商店搜索、历史、下载和安装

- 搜索按所选国家/地区和设备类型查询 Apple 商店目录。地区偏好保存在本机。结果详情展示商店元数据、定价、说明、兼容性和 Bundle ID。
- 版本历史优先使用 Apple 公共目录中带版本标识及发布日期的批量历史数据；仅以可信数据关联版本与日期。该入口提供近期版本，不保证包含完整历史。更早版本按需加载，部分操作仍依赖 Apple 账户服务。
- 某些历史版本下载可能被 Apple 以 HTTP 403 拒绝。403 是服务端拒绝本次 redownload 请求，不等同于本地缺少证书或历史列表没有数据。应用不绕过 Apple 的许可或签名验证。
- 账户凭据和会话令牌通过系统 Keychain/上游账户存储管理。用户主动下载免费应用时，若服务返回缺少许可，会使用当前会话获取免费许可并重试一次下载，不预先轮换有效令牌；付费应用仍须已有购买许可。读取清单与搜索不会请求购买许可。验证码/双重验证按 Apple 返回的认证流程完成。
- 下载页展示本地软件包状态，可继续、暂停、重试、分享或左滑删除。下载完成后的软件包可以预览或通过系统分享/AirDrop 导出。
- 下载采用原生 `URLSessionDownloadTask` 直接写盘，进度合并后每 0.25 秒最多通知界面一次。暂停保存系统续传数据，恢复时交由 URLSession 请求剩余内容，不使用同步 HEAD 探测；文件校验和签名整理在后台执行。历史版本查询返回的可下载内容按账户会话、设备、地区、平台和版本在内存保留至多 60 秒，供一次下载复用，减少重复鉴权请求。
- kbsync 验证数据按 DSID/GUID 保存在本机 Keychain，避免每次冷启动重新运行本地解释器；缓存被服务端拒绝时按现有规则失效并重新生成一次。首次生成与最新版本目录查询并行进行。首次验证、Apple 服务响应与 CDN/网络带宽仍会影响开始时间和实际速度，不承诺固定加速倍数。
- 39 版切换下载引擎后，旧引擎尚未完成的任务需要重新传输一次；已经完成的 IPA 保留。后续暂停使用原生续传数据。
- 可选 Remote Pairing 安装由用户明确启动：通过已配对的本机网络连接上传已下载 IPA 到设备暂存区，再请求设备 InstallationProxy 安装，完成后清理由本次操作创建的暂存目录。原 IPA 会保留。系统仍负责验证应用签名及许可；此流程不提供重签名、越狱或绕过 Apple 验证的能力。
- 证书方式是另一条单独安装路径，继续遵守 TLS 信任要求。配对安装不需要安装本地 HTTPS 根证书。

### 配对与设备数据

- 设备连接只保留 Remote Pairing。首次配对可使用系统提供的配对流程（受 iOS 版本支持情况影响），也可从文件导入配对记录。
- 默认主机地址 `10.7.0.1`、端口 `49152` 仅为初始配置；需按实际网络修改。
- 配对记录保存在本机 Application Support，使用文件保护并排除 iCloud 备份。请勿把个人配对文件提交到仓库或公开分享。
- “数据”页面调用 `UpdateCore`/设备桥接中的有限读取操作。是否能读取某个服务取决于设备系统、配对状态、服务是否暴露及设备端权限；服务名被设备公布不代表任意操作都被授权。
- 检查器不提供安装/卸载、写文件、删除文件、重启、恢复、定位模拟等设备状态修改入口。单文件导出上限为 32 MiB；超出时给出文件过大提示。设备上的浏览和读取范围由系统服务授权约束。
- `docs/API_REFERENCE.md` 记录只读数据项目、来源、边界及接口索引的生成方式。索引中列出的 C 接口不表示每项都有应用操作或设备授权。

## 源码结构

| 路径 | 内容 |
| --- | --- |
| `ssstore/SSStoreApp.swift` | UIKit 应用入口、场景与窗口生命周期 |
| `ssstore/UIKit/NativeInterface.swift` | 原生 tab、导航、通用表格页、搜索控制器、弹窗、分享和预览 |
| `ssstore/UIKit/ApplicationScreens.swift` | 应用清单、筛选、详情及商店搜索 |
| `ssstore/UIKit/StoreScreens.swift` | 商品、版本历史、账户、下载和软件包安装页面 |
| `ssstore/UIKit/DeviceScreens.swift` | 设置、配对、设备只读检查器、日志及文件浏览 |
| `ssstore/AppModel.swift` | 应用清单生命周期、版本比较调度、偏好和本地状态 |
| `ssstore/OnDevicePairingController.swift` | iOS Remote Pairing 原生配对桥接 |
| `ssstore/KBSyncGenerator.swift` | 本机 WebKit 中运行的 kbsync 准备与调用 |
| `ssstore/StoreRuntime.swift` | 商店运行时、日志、下载并发及本地目录初始化 |
| `Vendor/Asspp/Asspp/Backend/Downloader/PackageTransfer.swift` | 原生文件下载、进度合并、暂停与续传 |
| `Packages/UpdateCore/` | 清单模型与解析、版本匹配、忽略名单、配对记录和只读检查模型；含 Swift 测试 |
| `Packages/DeviceKit/` | 已固定版本的 `IDevice.xcframework` 二进制桥接包 |
| `Vendor/Asspp/` | Asspp 商店、账户、下载、IPA 管理和安装代码的集成副本 |
| `Vendor/AssppWeb/` | kbsync WebKit/WASM 构建输入及上游许可文件 |
| `scripts/` | 设备桥接准备、kbsync 资源准备、CI 检查选择、接口索引生成和构建脚本 |
| `docs/API_REFERENCE.md` | 设备只读接口说明 |
| `docs/UIKIT_MIGRATION.md` | UIKit 页面迁移范围与验证边界 |
| `THIRD_PARTY_NOTICES.md` | 第三方来源、版本和当前许可/再分发说明 |
| `.github/workflows/build-ios.yml` | Xcode 构建、相关检查选择和 IPA artifact 上传 |

### UIKit 页面结构

`NativeTabs` 为每个 tab 持有独立 `UINavigationController`，共同使用一个 `AppModel`。列表页面按需将模型投影为 `NativeSection`/`NativeRow`。`NativeSearchPage` 通过持久 `UISearchController` 管理搜索输入，处理 tab 再次选择、文本焦点、取消和搜索任务过期。本项目已移除废弃的 SwiftUI 页面与桥接文件；历史实现可从 Git 历史查看。Vendor 中的上游界面目录及入口仍从应用 target 排除，导航与列表采用 UIKit，首页数字统计嵌入 SwiftUI 视图。

### 状态与存储

| 数据 | 位置/机制 |
| --- | --- |
| 用户偏好（地区、地址、端口等） | `UserDefaults` |
| 应用清单及设备配对文件 | Application Support/`ssstore/` |
| 忽略应用、扫描记录 | `AppModel` 管理的本机编码数据 |
| 本机应用图标 | Caches/`ssstore-icons/`，允许系统清理 |
| 设备检查临时结果和报告 | Caches/`ssstore-inspection/` |
| 商店数据及下载管理文件 | Documents/`Asspp/`，由集成商店实现管理 |
| 下载的软件包 | Asspp 的下载目录与 manifest |
| Apple 账户/令牌 | Keychain 服务，不写入项目文档或普通日志 |

具体文件名和迁移逻辑以 `AppModel.init()`、Asspp 的 `AppStore`/`Downloads` 为准。应用内“重置商店数据”会删除对应商店本地资料；删除下载和配对记录是不同操作。

## 构建与交付

### 当前自动构建

GitHub Actions 使用 `xcode-27` runner，设定 `/Applications/Xcode.app/Contents/Developer`，并要求 Xcode 27 与 iOS 27 SDK。项目最低部署版本仍是 iOS 17；构建 SDK 与最低支持系统版本是两个不同概念。

工作流文件：`.github/workflows/build-ios.yml`。对应用源码、包、Vendor、构建脚本及工作流的 push 会触发 Release 构建。成功产物以 `ssstore-unsigned` artifact 保存，文件名 `ssstore.ipa`。当前工作流没有 Apple Developer 证书/描述文件，不会生成已签名安装包；IPA 需由用户选择的签名/安装方式处理。

### 在线下载与自动发布

`.github/workflows/publish-download.yml` 在主分支 iOS 构建成功后，使用独立 Linux 任务将 `ssstore-unsigned` 中的 IPA 发布到 GitHub Releases，并部署 `web/download/` 中的下载页。页面和发布脚本变更只触发该流程，不重新编译 iOS 应用。失败构建和 PR 构建不会发布。

- 下载页：<https://ccyykk666.github.io/ssstore/>
- 最新 IPA：<https://github.com/ccyykk666/ssstore/releases/latest/download/ssstore.ipa>
- 每个构建保留独立 Release，附带 SHA-256 校验文件、实际 IPA 版本及来源提交。
- 首次部署需在仓库 Settings → Pages 将 Source 设为 GitHub Actions。Pages 尚未开通时，Release 发布仍可完成；开通后手动运行 `Publish IPA download page` 即可部署，无需重新构建 IPA。
- 手动运行发布流程会复用最新成功的主分支构建。旧构建附件已过期时会明确失败，需要先完成一次新的 iOS 构建。

### 本地构建

需要 macOS、Xcode 27、iOS 27 SDK、XcodeGen、Python 3 和 Homebrew。先获取仓库依赖并安装 XcodeGen：

```sh
brew install xcodegen
bash scripts/build-ipa.sh
```

`build-ipa.sh` 会准备 IDevice 二进制、生成 kbsync 运行资源、运行 XcodeGen、复制已锁定的 Swift Package 解析文件，并用 Release / generic iOS destination / `CODE_SIGNING_ALLOWED=NO` 编译。成功后输出 `dist/ssstore.ipa`（未签名）。脚本自身只负责编译打包；CI 在它之前独立选择并执行相关检查。

首次构建需要网络访问依赖及声明的 kbsync 资源。CI 使用缓存减少重复下载。请勿把签名证书、Apple 凭据、个人配对文件、账户 token 或本机私密日志加进资源目录。

### 检查选择规则

`scripts/select-ci-tests.py` 将当前提交与该分支最近一次成功的 push/手动构建提交比较，按输入路径选择：

| 检查 | 输入发生变化时运行 |
| --- | --- |
| 选择器单元测试 | `scripts/select-ci-tests.py`、`scripts/tests/`、构建 workflow |
| UpdateCore | `Packages/UpdateCore/` |
| 下载/历史协议 | Asspp 下载、历史服务及协议检查文件 |
| 商店本地化 | Asspp strings、本地化检查和相关协议文件 |
| kbsync | 生成器、runtime、worker、HTML、manifest 和 smoke 检查 |

可用的成功基线无法确定时会运行全部相关检查，避免静默跳过。如果只改 `docs/`，当前 push path 规则不触发 iOS 构建，也不会消耗 Actions 分钟数。文档提交不等于重新构建 IPA。

## 依赖、上游和许可

- Swift Package 版本固定在 `project.yml`；生成项目的依赖解析文件来源于 `Vendor/Asspp/Asspp.xcworkspace/xcshareddata/swiftpm/Package.resolved`。
- `UpdateCore`、`DeviceKit` 为仓库内包；`DeviceKit` 中的 IDevice 是固定版本 XCFramework，而非由 SwiftPM 从源代码编译。
- 商店集成基于 `Vendor/Asspp` 的 Asspp 4.2.2 上游副本；本地 kbsync 资源基于 `Vendor/AssppWeb`。具体 commit、许可文本和适用范围见 `THIRD_PARTY_NOTICES.md` 及随应用打包的许可资源。
- 下载流程优化参考 [majd/ipatool](https://github.com/majd/ipatool) 对版本绑定、历史下载回复与 HTTP 续传的处理；iOS 文件传输使用 Foundation 原生实现，移除了应用目标的 Digger 依赖。
- 本仓库没有由 `THIRD_PARTY_NOTICES.md` 自动授予的统一项目级 MIT 许可。不要把单一依赖的许可误当作整个仓库的许可。
- 当前许可记录指出：kbsync 构建含 Unicorn/WASM 及从 Apple OS X 10.9 更新提取的运行资源；对应源代码/许可与再分发边界详见通知文件。仓库公开或 CI 构建成功本身不代表这些组件获得额外再分发授权。

## 隐私与诊断边界

- 正常应用查询会向 Apple 商店目录发送查询词、地区、商店应用标识等完成请求所需的信息。配对文件留在本机，除非用户主动导出或通过配对连接使用。
- 不要在 issue、截图、日志或构建产物中公开 Apple ID、密码、验证码、Cookie、配对数据、设备 UDID、私有 IP 或真实下载 URL。
- 日志时间使用东八区格式；查看 `.env` 文件不存在的 Vapor 启动调试信息不代表 Apple 请求失败。请求失败应看同一时间的具体 Store/HTTP 日志。
- Apple 对 redownload 返回 HTTP 403 表示该次请求被拒绝。它本身既不能证明缺少证书，也不能单独确定账号状态、应用可用性或拒绝的完整服务端原因。应用不得尝试绕开该校验。
- 设备读取能力受 iOS 版本、配对记录、设备服务和权限共同影响；界面不应把“服务已公布”写成“用户已授权”。

## 已知边界

1. 编译成功只表明所选配置通过构建，不代表首次搜索动画、所有机型布局、配对交互、Apple 登录、商店历史或实际设备安装都经过真机验证。
2. Apple 的公开历史列表可能只返回近期版本。更早版本请求可能需要账户服务，Apple 也可能拒绝 redownload。
3. iOS 原生配对能力受系统版本控制；低于支持版本的设备需要导入配对文件。
4. Remote Pairing 连接需设备可从配置的 IP/端口到达，网络路由及设备端服务状态由用户环境决定。
5. IPA 是未签名构建产物；安装前需有可用且合法的签名/安装方案。

## 维护约定

项目后续如需改动，应以用户当次明确要求为准。用户最新偏好是：**以后只需提供构建完成后的 IPA**。在没有新功能/修复要求时，不擅自改代码、调整 UI 或推送源码；若用户交代新的源码改动，按相关代码选择检查、构建，再提供完成的 IPA。

### 相关文档

- [UIKit 迁移说明](UIKIT_MIGRATION.md)
- [设备接口参考](API_REFERENCE.md)
- [云端接续记录](CLOUD_HANDOFF.md)
- [第三方通知](../THIRD_PARTY_NOTICES.md)
