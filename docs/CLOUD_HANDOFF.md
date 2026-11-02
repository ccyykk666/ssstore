# ssstore 云端接续说明

更新日期：2026-11-02（北京时间）。先读取本文、实际源码和工作流；不要重复执行已完成的请求或重复触发构建。

## 0.5.7（20）匹配计数与下载列表修复

- 上一版 0.5.6（19）提交 139ef915cfab6d880badd6d6cf05589148e16cb6，Actions 41370265115 构建成功并交付。
- 修复首页统计混用缓存清单与本轮处理清单：各项统计、筛选和列表状态共用同一有序匹配结果及整数显示游标；每轮从零重置，按固定节奏逐项显示，更新/待核对只随对应匹配结果出现。移除各数字独立的浮点插值，保留原生 numericText 过渡，避免中断动画出现负数。取消后保留当前进度，不将未匹配缓存补为已完成。
- 新增五项 UpdateCore 回归，覆盖缓存更新不提前显示、乱序分批返回、取消/重开、隐藏系统与移除应用、重复结果及计数边界。仅运行相关核心测试；下载协议、kbsync、本地化及 CI 选择器不变，不重复无关测试。
- 下载列表改用直接指定安装包详情的导航，避免值路由进入重复下载列表；每行增加左滑删除，复用既有删除路径清理安装包与下载记录，保留长按菜单。
- 不修改 Apple 请求、安装协议或版本身份判定。未进行实机界面验收；构建成功后直接交付 IPA，不额外核验内容。

## 0.5.6（19）界面与刷新流程

- 上一版 0.5.5（18）源码 775bb36e0bd507ca6f6e1304b80417622b6caca7，Actions 41366705897 成功交付。WebKit 独立 Worker 的本地 kbsync 生成及协议检查已通过；本轮不修改此运行时与 Apple 下载协议，不重复无关测试。
- 首页与配对完成页统一为“刷新应用”：等待设备读取成功、合并最终版本元数据，再强制加载商店版本；读取失败不查询旧清单。等待查询任务结束后才结束整轮刷新。扫描回调和 completion 按主队列 FIFO 排序，防止旧 inventory 回调覆盖最终版本信息。
- 移除独立查询数量和进度卡片；首页应用计数从 0 按实际处理的应用 ID 增长，线性插值整数与原生 numericText 过渡。失败请求也计入已处理，系统应用在读取完清单后计入；“停止刷新”保留在右上角菜单。
- “差异项”统计改为“有更新”，仅计版本身份不一致项；“待核对”统计规则保持。列表更新标签为绿色“有更新”，待核对仍灰色。不改 opaque external version ID 的比较规则。筛选仍包含有更新和待核对，并明确标注“有更新与待核对”。
- 版本详情：“查看商店页”放入商店框末尾；“应用数据”去自定义图标，移至更新说明上方。删除展示层原始版本标识字段，底层识别数据继续保留。
- 设置弹窗隐藏系统拖动指示条，保留下滑关闭及 soft 效果；关于页版本从 Bundle 动态读取。
- 删除数据页仅供参考的“接口资料/接口索引”、专用视图与随包 DeviceAPIIndex.json；实际设备读取入口、Bridge 与开发参考文档保留。
- 商店产品页首先显示图标、名称等软件包信息；账户选择放到右上角菜单，下载动作紧随版本行。保留已有账户选择、历史版本与下载导航流程。开发者等详情改为固定单行标签、值自然换行的可复制布局，避免长名称挤压中文标签成竖行。
- 本轮只改应用界面与应用层协调，UpdateCore、下载协议、本地化资源、kbsync 及 CI 选择器未变；应跳过对应检查，仍执行 Xcode 27 编译打包。未进行实机/模拟器界面验收。构建成功后直接交付，不额外核验 IPA。

## 0.5.5（18）手机端历史版本/下载 403 修复

- 完整 trace EE9CF00C：volumeStore HTTP 200、songList=0、无业务错误；catalog 成功；带会话 Cookie 的 redownload 返回 HTTP 403、bytes=0。不能诊断为缺少应用授权，之前 Cookie/pod 修复未解决此问题。
- 用户要求全程手机端并指出 AssppWeb 已可查旧版。固定 ccyykk666/AssppWeb dda77c915e9b61469ca7b4995c7515a6eb0e3115 的 TCI/WASM 解释器，不需要越狱。此前将 ipatool 越狱 CLI 限制当作整个功能的限制是过早判断。
- 在隔离、无持久存储的本地 WKWebView 的独立 Blob Worker 中运行 StoreAgent/kbsync；WKWebView 以无交互视图置于现有界面后方并保持窗口关联，避免无窗口后台页被 WebKit 挂起。只有 GUID/DSID 进入解释器；密码、令牌、Cookie 和 Apple 下载请求仍由原生代码处理。不增加服务器、电脑步骤或外部网页。
- 构建时验证固定上游 Git blob、公开 Apple 资源原始与切片 SHA-256；五个数据资源随 IPA 打包，解释器对应源码、补丁和许可随包提供。不将 macOS 私有框架原生链接到 iOS。
- 补全 bag 的 volumeStoreDownloadProduct → ent/download，按 AssppWeb 使用 kbsync、X-Token、StoreFront 和 serialNumber。新接口不跟随重定向，保留并校验 app ID、Bundle ID、历史版本 ID。缓存 blob 的 HTTP 403 可重新生成一次；新 blob 失败和业务授权/令牌错误不会触发循环或购买。
- 内存缓存按 DSID/GUID 隔离，解释器串行；原生截止 6 分钟，guest 单次调用最多 5 分钟。未广告新接口的 bag 仍使用旧流程。
- CI 仅相关变更才做 WebKit 本地生成检查（虚构标识，无真实账号）和协议检查，UpdateCore 跳过。构建成功后直接交付 IPA，不额外核验 IPA；本地生成成功不等同于用户实机 Apple 请求已恢复。
- 源码已经准备，以下旧版本历史保留；实际构建结果以最新 Actions 为准。

## 当前状态

- 私有仓库 `ccyykk666/ssstore`，目标分支 `main`。当前准备发布 **0.5.4（17）**，合并日志东八区、自动刷新、数据 Tab 图标/名称及移除被 Tab 遮挡的首页底部工具栏；iOS 17 起，继续使用 GitHub `xcode-27`、默认正式版工具链及 iOS 27 SDK。
- 0.5.1（11）已推送并构建交付，源码提交 `e2c0027562fc3e2fb9189ea08f3d18dba9507781`，构建 `41329740686`，41 项核心测试及上游下载协议/本地化检查通过；实际工具链 Xcode 27.1、iOS 27.1 SDK。
- 0.5.2 的九项界面和安装通道调整已推送 `40fe1576df3074a65cab8f9d6bb307cc9dbffac1`，构建 `41331962262` 成功并交付 IPA。新增配对安装仅通过编译，尚未实机验证。
- CI 按变更选择测试的修改已在 `87ce4fd82d990d1d554384bd3ccdd1e9ba93f8aa` 推送并通过构建 `41333205147`。
- 曾仅凭截图 License required 实现授权恢复（提交 `2f77aa2ca5467edc8f3c06ff4f18b0deb3967307`，废弃版本 0.5.3/13）。用户纠正为 HTTP 403 并要求暂停后，已通过 `d84239cfb5f252be9ed2c4c50265b07456fd3a58` 完整撤回该轮修改；未交付该产物。用户随后明确要求排查 403 并修复推送，不要恢复已撤回的购买/授权 UI。
- 依旧按用户要求：构建成功后直接交付 IPA，不额外检查 IPA 内容或哈希。若遇到需要用户决定的问题，先询问。

## 0.5.4（17）用户复测与日志/数据 Tab 调整

- 0.5.3（14）源码 `bd01d29d4ed41a52cbf94fe181d22116c974b6a2` 已推送，构建 `41335405318` 成功并交付 IPA；下载协议/本地化/选择器检查通过，UpdateCore 跳过。用户在此版本复测明确报“Apple 拒绝了 redownload 请求（HTTP 403）”，故不能继续宣称 Cookie/pod 修复解决了用户的拒绝。
- 用户截图只展示 Vapor 启动/.env 调试和微博搜索成功，下载跟踪在画面下方；目前仍缺同一 trace 的 sessionCookie 和 response（空/plist/非 plist）字段，不能把端点 403 确诊为 kbsync，更不能恢复缺授权修复。后续需获取 redownload 前后的实际请求日志，不再凭猜测更改下载/购买流程。
- 按用户要求将 LogManager 的 ISO8601DateFormatter 固定为 GMT+8，输出包含 +08:00。保持实际 Date 时间不变，不手工加八小时，避免二次偏移。内存内既有字符串不重写，应用重新运行后生成新时区日志。
- LogView 在可见时每秒读取一次快照，仅内容变化时更新；离开页面后通过 task 取消停止刷新。保留手动刷新按钮。不改日志级别、保留上限或脱敏策略。
- 本轮仅日志呈现和版本号变化，未触及下载协议、翻译或 UpdateCore，CI 应跳过全部无关测试，照常编译打包。没有额外为此低影响格式调整新增测试。
- 用户在构建中追加：原“设备”底部 Tab 改名“数据”，使用截图对应的系统 SF Symbol `chart.bar.xaxis`，不导入截图图片作为图标。数据首页标题同步为“数据”，单个应用的“应用数据”不改。合并交付构建号递增至 16，先前日志改动提交 `99de9c3d89b03dbcd9dddacdae902ec9032ac070` 的 15 不作为最终交付。
- 用户再次追加截图，要求直接去掉首页 Tab 背后被遮挡的两个图标和无关代码。已移除 ContentView 的全部 bottomBar ToolbarItem（读取、占位 Spacer、查询）；读取应用移到现有右上角菜单，版本查询复用“刷新全部版本”。不删除其他页面仍使用的 scan/checkUpdates 共享逻辑。最终构建号递增为 17，合并此前所有追加要求后交付，旧 15/16 不作为最终产物。

## 0.5.3（14）403 排查与修复

- 对照固定 ApplePackage 2.0.3 的 Supplement/Cookie.swift，发现其 matchesDomain 只转小写，未移除 Domain 前导点：`.itunes.apple.com` 既不等于请求主机，又会形成 `..itunes.apple.com` 的后缀，导致有效登录 Cookie 被排除。登录返回的 Cookie 复制时保留原 domain，旧账号记录同样可能保留前导点；ssstore 原来仅在接收下载响应 Cookie 时归一化，首次请求仍调用有缺陷的库方法。
- 本轮在 StoreProtocol 添加纯 Cookie 头选择函数，并在 StoreDownloadService 的每次请求/受限重定向中使用。按 RFC 6265 忽略前导点，验证 Apple 域名后缀边界、HTTPS、路径边界、有效期和头注入字符，较长路径优先。不会把 Cookie 转发到非 Apple 地址，不记录 Cookie 值。
- 对照 ipatool 的 volumeStoreEndpoint：账号无已分配 pod 时使用 `buy.itunes.apple.com`，由 Apple 路由，不再猜测固定 `p25`。已有数字 pod 保持使用对应主机，无效 pod 拒绝生成请求。
- HTTP 403 保留为带 endpoint 的 serviceResponse 错误，不转换成 9610，也不自动领取授权、不盲目刷新密码令牌或跨端点重试。日志添加无查询参数的主机、Cookie 是否发送/数量、前导点数量及响应形态（空/plist/非 plist）；从而可以区分会话漏发与已发送会话后仍被服务端拒绝。
- 新增的下载协议回归用合成会话验证 Cookie 进入 URLRequest、前导点/大小写、不同 pod/路径/过期/恶意域名过滤、无 pod 路由和 403 不误重试。CI 只跑相关协议/本地化/选择器检查，UpdateCore 不变。
- 上游 issue #637 报告已购应用也会因缺少 kbsync 而在历史/下载接口返回空体 403；评论称更新上游后恢复。ipatool 当前源码确有 ent/download + kbsync，而 ApplePackage 2.0.3 的 SAPIntegration.md 明确尚未实现此独立数据。SAP 登录签名不等于 kbsync，不能随便给旧下载 POST 加 SAP 签名来替代。
- 未取得用户设备的 403 请求日志，也没有用户账号可重放。因此已确认并修复的是可复现的会话漏发和错误默认 pod 缺陷，不能断言这是用户那次 403 的唯一原因，更不能声称已在设备上确认恢复。若新版仍返回 403，需查看 endpoint、sessionCookie、response 形态后确定是否落在 kbsync 限制或其他服务端策略，勿再次无证据归为“缺授权”。

依据：
- https://github.com/Lakr233/ApplePackage/blob/2.0.3/Sources/ApplePackage/Supplement/Cookie.swift
- https://github.com/Lakr233/ApplePackage/blob/2.0.3/SAPIntegration.md
- https://github.com/majd/ipatool/blob/d9c0247daea564d3ec7d04a9b015d0a29af66b04/pkg/appstore/appstore_download_product.go
- https://github.com/majd/ipatool/issues/637
- https://www.rfc-editor.org/rfc/rfc6265.html#section-5.2.3

## CI 测试选择策略

- `.github/workflows/build-ios.yml` 全量拉取 git 历史，由 `scripts/select-ci-tests.py` 查询本分支最近成功的 push/手动构建（无记录则使用基准分支），比较该成功提交与当前实际 checkout 的代码。重跑已成功的相同提交时可复用对应成功基准。不会把上一次失败的提交作为已验证基准，也不会把 PR 的 head_sha 冒充实际测试过的合并提交。
- UpdateCore：仅 `Packages/UpdateCore/` 下源码、测试或包配置变化时运行 `swift test`。
- 下载协议：仅其实际编译输入 StoreProtocol.swift、StoreDiagnostics.swift、StoreDownloadProtocol.swift、DownloadProtocolChecks.swift、check.downloads.sh 或相关调用层 StoreDownloadService.swift 变化时运行。
- 本地化：仅 Localizable.xcstrings、StoreDownloadProtocol.swift、LocalizationChecks.py 或 check.downloads.sh 变化时运行。下载检查脚本支持 protocol/localization/all，省略参数仍运行全部，兼容上游原用法。
- 选择器自身、其测试或工作流变更时才运行选择器的 Python 回归检查。仅改 SwiftUI 页面、原生桥接、普通文案或文档，不重复运行无关的三组库检查；应用编译和打包照常执行。
- 无成功基准、历史缺失或 Actions API 不可访问时，明确记录原因并回退到全部检查；不能静默跳过未验证代码。检查选择结果写入 Actions 日志和步骤摘要。
- `scripts/build-ipa.sh` 只编译并打包，不再隐式执行测试。测试由 workflow 独立条件步骤负责；不要恢复每次构建无条件全测，也不要在成功交付 IPA 前额外核验产物。

## 0.5.2 本轮代码改动

1. 底部顺序为应用、设备、账户、搜索；设备使用 iphone 图标，搜索保持普通 Tab 并放到最右，不恢复独立浮动 search-role。
2. “显示差异项”移至首页右上角菜单。两个显示开关使用普通 Button + 状态图标，避免原生菜单 Toggle 的额外最左勾选列与其他项目图标不对齐。
3. 首页“标识不同”改为“差异项”，计数与筛选完全共用非 current 判定，包含待核对和失败。待核对、失败仍可单独显示各自数量。
4. 查询进度改为独立完成数/总数，不显示批次或“已完成”文案；进度和首页统计使用 SwiftUI contentTransition(.numericText) 与 snappy 动画。
5. 设置主页和地区选择页的地区行应用 plain 按钮样式，标签使用主文字色，地区/箭头使用次文字色，仅选中勾使用强调色。日志直接载入，删除敏感内容拦截页，现有日志脱敏不变。
6. 配对创建、导入、导出、删除移至“配对”二级页面；设置主页只保留可进入该页的配对状态行。已配对表示已保存且可解析的配对文件，不代表刚执行过设备连接验证。
7. 已完成下载的安装包增加“配对安装”，原有安装明确叫“证书安装”。配对安装通过当前固定 idevice v0.1.68 的 Remote Pairing → RSD AFC → InstallationProxy：256 KiB 分块上传到唯一 PublicStaging/ssstore-UUID 目录，关闭上传后调用系统安装，完成或失败只清理本次 UUID 目录；源 IPA 保留。传输中检查尺寸一致，使用系统原有签名/FairPlay校验，不重签、不绕过应用授权。此路由不用本地 HTTPS CA；原证书安装保留。
8. 新增 DeviceInstaller 原生桥接、PairingInstallView 进度/成功/真实错误/重试页，安装时保持前台不自动锁屏，结束后恢复锁屏设置。没有可连接实机，不能把编译成功等同于实际安装成功；具体应用是否可装仍由用户设备校验。

实现依据：固定标签 idevice v0.1.68 的 ffi/src/afc.rs、ffi/src/installation_proxy.rs 和 idevice/src/utils/installation/helpers.rs；没有升级或替换固定二进制依赖。回环本身不绕过 HTTPS 信任；本轮通过不同的系统安装通道免去网页证书。

## 0.5.1 本轮代码改动

1. 首页应用行不显示商店地区。
2. 底部为应用、商店、设备数据、账户；商店搜索是普通 Tab，移除独立 search-role 按钮，导航栏搜索框保持可见。下载入口移到首页右上角更多菜单原设备数据的位置，使用嵌入式视图，避免重复 NavigationStack。
3. “显示系统应用”移至首页右上角菜单，持久化为 includeSystemApps；设备数据的应用选择共用此偏好，不显示系统应用时选择列表也排除它们。移除“不选择应用”。
4. 账户令牌轮换清空旧反馈，成功显示绿色“已更新”，失败保留真实红色错误。精简账户说明和双重认证说明。
5. 设置页改名“设置”，连接分区改“连接配置”，IP/端口有独立左侧标签。
6. 商店设置直接并入设置主页；移除演示模式及其数据遮盖行为，保留 GUID 编辑、安装证书、打开系统设置、下载管理、重置商店数据和日志。设置 Form 和 sheet 显式应用 soft 顶部滚动边缘效果。
7. 地区选项来自当前 ApplePackage 支持列表，可按中文、英文或地区代码搜索；保留“中国大陆优先”。选择会同步商店搜索地区。
8. 忽略名单保存 InstalledApp 图标键和商店图标 URL，兼容只含 names 的旧 JSON；从既有清单/旧原始清单迁移可用图标信息。恢复应用时移除其忽略图标元数据。无可用图标时沿用 AppIconView 默认图标。
9. 移除设备数据页全局只读说明、正常完成状态/时间、结果标题和重复说明；保留实际错误和必要权限/数据含义提示。文件大小仅使用常见单位，去掉原始字节重复展示。按钮简化为“读取文件”；32 MiB 上限和 64 KiB 分块不变，超限提示“文件过大”。
10. 详情页本机版本去掉来源括注；仅在设备原始版本与显示版本不同时保留“原始版本”。保留构建号和身份字段；隐藏 Lookup/Browse 成功提示及重复版本诊断字段。
11. 预览/分享请求改为 AppModel 中带稳定 URL 和唯一 ID 的载荷，由 RootView 统一呈现，避免把 sheet 状态放在可重建的列表行上。分享页不再嵌套导航容器，保留完成按钮和下拉关闭，只在分享确实完成时主动关闭，取消/初始化回调不主动触发关闭。
12. 新增两个 XCTest：旧忽略 JSON 的迁移兼容、图标元数据持久化和恢复清理。原有 39 项测试及上游下载协议/本地化检查继续运行。

## 0.5.0 本轮修改

- 设备数据中的应用 Picker 改成可搜索的选择弹窗；有取消按钮和下拉手势，规避系统长菜单的空白区。
- 文件预览和导出分享使用可下拉关闭的 sheet，并显示“完成”按钮及拖动指示器。
- “显示差异项”包含标识不同、待核对及失败应用，即排除已确认版本相同的应用。
- 统计卡片有失败时显示“失败”数量，点按可筛选；无失败时隐藏。待核对统计不重复计入失败项。统计范围跟随“显示系统应用”，列表标题为“共 xx 个应用”（无多余分隔符）。
- 新增应用、商店、下载、账户四个 Tab。iOS 26+ 使用原生 search-role Tab，并保留上游搜索激活行为；旧系统采用传统 tabItem。商店、账户、下载、历史版本、IPA 内容查看和本地 OTA 安装沿用 Asspp 4.2.2 当前实现及 ApplePackage 2.0.3。
- 应用详情增加精确 Bundle ID 对应的商店详情与下载入口；不改原有 external ID 版本核对语义。
- 连接设置中有“商店设置”和开源许可。商店数据使用单独的 Documents/Asspp 与钥匙串存储，不覆盖 ssstore 的配对和清单。
- 为嵌入设置和本机详情页中的下载跳转，对上游 SettingView / ProductView 做了小范围适配；SimpleProgress / ProductHistoryView 的强调色改为标准 Color.accentColor，避免依赖未引入的上游资源生成符号。未使用上游独立 main、欢迎页、图标或 macOS 设备管理；完整来源保留在 Vendor 并由 target 排除。
- 原生 inspector 仍只读；Asspp 的明确安装操作是用户本轮要求新增的功能，不能再将“全 App 没有安装入口”作为不变条件。
- 用户已明确要求构建成功直接给 IPA，不额外检查安装包。

## 0.4.2 已完成的界面精简

1. 首页筛选更名为“显示差异项”；移除“商店：中国大陆优先”页脚。
2. 移除正常读取时间、清单读取/图标缓存完成摘要、查询计数和耗时摘要。操作中显示进度，异常时保留实际错误与警告。
3. 左滑应用可“忽略”，按精确 Bundle ID 持久化。启动加载和扫描合并会过滤；原生扫描在生成图标键、补充元数据和图标读取前排除；商店查询只处理当前可见记录。
4. 设置中的“已忽略应用”可逐项恢复，恢复后重新读取应用。忽略操作不会卸载设备应用。
5. 仅保留 Remote Pairing 连接；移除协议选择、经典 Lockdown 传输和配对文件导入支持。原有 Remote Pairing 配对数据仍沿用。旧经典连接偏好迁移到 49152；经典配对文件保留但明确报错，需重新创建或导入 Remote Pairing 文件。
6. 移除设置页地区策略解释、Apple 查询/本机存储说明、默认端口说明和“连接要求”整节。
7. 详情页移除清单时间、商店数据来源、商店匹配编辑器、版本相同状态与冗余版本解释；查询按钮位于应用名右侧。版本字段改为“原始版本”“原始构建号”。列表也不再显示“版本相同”徽标。
8. 底部保留“读取应用”“查询版本”；更多菜单仅保留“刷新全部版本”“设备数据”。删除清单导入、历史记录界面/记录流程、原始清单导出；现有已存清单仍兼容。
9. 配对文件导入、导出和删除仍保留；设备数据与应用数据的只读操作保留。
10. 用户追加要求采用 Xcode 27 构建，工作流已迁移至 GitHub `xcode-27` 环境，使用其 `/Applications/Xcode.app` 正式版默认工具链，检查 Xcode / iOS SDK 主版本为 27。
11. 用户追加要求顶栏 `.soft`：`SSStoreApp.swift` 在根视图应用 `.scrollEdgeEffectStyle(.soft, for: .top)`，iOS 26 及以上启用，旧系统默认效果。
12. 用户最后明确说“完成后不用核验，构建成功直接给 ipa 就行”。本轮已按要求在最终运行成功后直接下载并交付 IPA，未做额外包内容/哈希/SDK 核验。

核心修改：`ssstore/ContentView.swift`、`SettingsView.swift`、`AppDetailView.swift`、`AppModel.swift`，`Bridge/DeviceScanner.*`、`DeviceInspector.*`，`Packages/UpdateCore/Sources/UpdateCore/IgnoredApplications.swift`、`PairingRecord.swift`。设备接口索引仍为 661 条声明，检查器实际使用标记更新为 110 条，不代表所有服务可用。

新增 3 项忽略名单测试，覆盖序列化后重新加载、应用改名/版本变化仍忽略、精确 Bundle ID、重复忽略及恢复；配对测试改为明确拒绝经典 Lockdown 文件。原有商店及版本比较测试保留。

## 用户偏好及授权

- 中文沟通，文案短而直接，采用常见 iOS 简体中文术语。仓库和应用名保持 `ssstore`，不要添加 README。
- 用户已授权修改、向私有仓库推送及 GitHub Actions 编译，明确要求完成后给新版 IPA。
- 不创建 Git worktree；不引入未经用户认可的推测性复杂机制。
- 用户在 iPhone 上访问。交付真实 GitHub 产物链接或 ChatGPT 可下载文件链接；不要只给 `/workspace/...` 路径。
- 无法假定能连接用户真机。编译成功不等于已验证真机界面或设备服务。

## 构建和交付

工作流 `.github/workflows/build-ios.yml`：`xcode-27`，`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`，显式检查 Xcode 为 27 系列、iphoneos SDK 为 `27.*`，按变更执行相关测试，再执行仅负责编译打包的 `bash scripts/build-ipa.sh`。

流程为核心 XCTest → 上游 Asspp 下载协议/本地化测试 → 准备固定 DeviceKit → XcodeGen 和固定 SPM 依赖 → 无签名 Release 编译 → `dist/ssstore.ipa`，产物名 `ssstore-unsigned`。应用代码 push 自动构建，纯 docs 修改不触发。接续时先查当前应用提交已有运行，只有失败或确有必要才重跑。

按用户最新要求，查询当前代码提交的运行状态，成功后下载该运行的 IPA 并直接交付；不做额外安装包核验。如失败，读取对应日志修复。安装包须自行签名；不能把旧运行的产物当作最新 `.soft` 版本。

当前会话可通过已连接 GitHub 工具查询私有仓库 Actions、下载产物和推送；旧会话 API 出站阻塞不代表当前工具不可用。保持平台代理与 TLS 校验，不索取 PAT 或其他秘密，不绕过已明确拒绝的网络策略。不得声称保存网络草稿等于策略已应用。

## 必须保留的语义

### 版本与商店查询

- 本地读取 `softwareVersionExternalIdentifier` / `ExternalVersionIdentifier`；远端从 Apple Catalog `offers[0].version.externalId` 或 `buyParams.appExtVrsId` 读取。
- 精确核对有效 Bundle ID；两边都有有效数字 Store ID 时也须一致。保留既存映射兼容，映射不能绕过身份核验。
- 版本 ID 只接受正十进制、去除前导零；它是不透明标识，不能比较大小。相同才可显示对应商店版本；不同不判断更新方向。缺失、身份/地区不符或失败为待核对。原始版本与构建号保留。
- `VersionOrder` 仅继续用于最低 iOS 判断，不恢复应用字符串版本比较或专用补丁。工商银行曾因原始 short/build 不同被误判，external ID 891257769 相同才应视为相同版本。
- 默认大陆优先，仅成功查询且明确未找到的应用补查美国。超时、限流、网络失败不算未找到；美国失败保留大陆成功结果；429 停止批次。
- 保留固定 CN/US/HK/JP。Bundle ID 去重，每批 25，已知数字 Store ID 可直查 Catalog。Lookup 发现后查 Catalog，不按应用名模糊冒充身份匹配。
- Lookup 间隔 3.2 秒，按地区/策略缓存 5 分钟，强制刷新绕过缓存。本机版本查询保持免登录；新增商店模块的 Apple ID 登录、下载和许可行为由 Asspp / ApplePackage 提供，不自动使用用户账户。

### 配对与设备读取

- Loon 回环 + Remote Pairing/RSD，默认 `10.7.0.1:49152`。普通清单用 InstallationProxy Lookup/Browse，图标用 SpringBoard，不依赖 CoreDevice。
- 仅移除经典连接协议；`lockdownd_get_value` 等通过 RSD 提供的设备信息服务仍需保留。
- 手机配对此前已确认可用。广播/监听保持到握手结束，持续后台任务、PIN 通知、两分钟超时和主动停止保留。
- 固定 `jkcoxson/idevice v0.1.68` 发布 XCFramework 及 SHA-256 校验，不随意升级。
- 扫描、配对、检查共用 busy 状态；FFI 资源在同一工作线程创建、使用和释放。忽略/恢复在 busy 时禁用。
- 41 个主读取入口、2 个文件辅助操作，详见 `docs/API_REFERENCE.md`。新服务未全部真机验证；曾遇到 CoreDevice `ServiceNotFound 21`。
- 文件只读，单文件 32 MiB、64 KiB 分块；CoreDevice 仅列目录，导出通过 AFC。原生 inspector 无安装、卸载、设备写入/删除、恢复、连续日志、抓包或性能流执行入口；商店模块可在用户操作下通过 Asspp OTA 安装。
- 固定 C FFI 无 `get_icon_state`，不能宣称完整桌面布局。描述文件解析不代表证书信任验证；动态占用不是可清理缓存；能力声明不是隐私授权。
- 不提交配对文件、PIN、证书私钥等秘密；不假定可访问用户手机或旧环境本地文件。

