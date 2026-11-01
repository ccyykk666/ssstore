# ssstore 云端接续说明

更新日期：2026-11-01（北京时间）。

请先阅读本文件、实际源码和现有工作流，再继续用户尚未完成的任务。不要仅因交接文档新增功能、重复改写已完成内容，或重复触发构建。

## 1. 当前代码与待办

- 私有仓库：<https://github.com/ccyykk666/ssstore>
- 目标分支：`main`。
- 最新应用代码提交：`9ffc7c312f7b91315e01c7cb99e0e474922c68ff`。
- 提交说明：`Simplify interface copy and prepare 0.4.1`。
- 此提交已成功推送到远端 `main`，且已通过 `git ls-remote` 核对完整 SHA。
- 当前版本：**0.4.1（8）**，见 `project.yml`；设置页版本显示已同步。
- 本交接文档在上述应用提交之后单独提交，因此新会话看到的最新 HEAD 可能是文档提交，属于正常情况。以实际代码与远端状态为准。
- 应用为 SwiftUI 普通自签 IPA，最低 iOS 17；用户设备为 iOS 27.2，要求使用 iOS 26 SDK 构建。

**尚未完成的目标：取得两轮文案精简后的 0.4.1（8）IPA，核验构建并给用户可在 iPhone 上访问的产物链接。**

用户最后一项功能请求是“再精简一轮然后生成”。两轮精简与推送均已完成；本会话未能查询远端构建结果，也未下载或检查新 IPA。不能宣称 0.4.1 已编译成功或已生成安装包。

## 2. 用户偏好与已有授权

- 使用中文沟通。
- 仓库和应用名保持 `ssstore`；不要添加 README。
- 文案采用 iOS 常见用语和规范简体中文，短而直接，仅保留必要引导、操作条件和错误原因。
- 用户已授权向该私有仓库推送项目代码、使用 GitHub Actions 编译；生成 IPA 是尚待完成的明确请求，无需重复询问这项授权。
- 不要过度设计。增加用于推测性、极低概率竞态或安全边界的复杂机制前，先解释具体失败、概率与成本并取得用户认可。
- 当前任务已在隔离环境中运行，使用现有检出；除非用户明确要求，不创建 Git worktree。
- 本地文件路径链接在用户的 iPhone 上无法打开。不要再把 `/workspace/...` 当成可下载附件。优先提供真实 GitHub 构建/产物链接；需要传递纯文字时可直接贴在聊天里。

## 3. 本次已完成的修改

两轮精简合并在应用提交 `9ffc7c3` 中，未改变版本判断、商店查询、设备通信及文件访问逻辑：

- 删除首页标语、重复教程、对未开放功能的长篇说明。
- 首页标题改为 `ssstore`。
- 操作统一为“读取应用”“查询版本”“刷新全部版本”“创建配对”“好”等。
- “设备数据与接口”缩为“设备数据”；单应用入口为“应用数据”；历史入口为“清单记录”。
- 配对步骤压缩为三步，保留 Wi-Fi、开发者模式、本地网络权限、配对码、后台任务和两分钟限时等必要信息。
- 精简版本详情、设置、设备读取说明、通知与错误提示；具体错误、错误码与动态占位符仍保留。
- 保留“版本标识不同不能判断更新方向”、删除配对文件的作用范围及设备权限限制。
- 使用“墙纸”“锁定屏幕”等常见 iOS 术语；文件大小提示统一为 `32 MiB`，实际限制仍为 `32 * 1024 * 1024` 字节。
- 更新本地网络权限说明，并同步 `docs/API_REFERENCE.md` 中的入口名称。
- 版本由 0.4.0（7）更新为 0.4.1（8）。

核心文件：

- `ssstore/ContentView.swift`：首页、筛选、工具栏和应用行。
- `ssstore/SettingsView.swift`：连接设置、地区和关于。
- `ssstore/AppDetailView.swift`：版本详情和商店匹配。
- `ssstore/OnDevicePairingView.swift`、`OnDevicePairingController.swift`、`PairingBackgroundExecution.swift`：配对界面、通知与状态。
- `ssstore/InspectionView.swift`：设备数据、文件、历史和接口索引界面。
- `ssstore/AppModel.swift`：扫描、导入、查询和保存反馈。
- `Packages/UpdateCore/Sources/UpdateCore/Inspection.swift`：设备读取标题、分组与说明。
- `Packages/UpdateCore/Sources/UpdateCore/Models.swift`：版本状态说明。
- `ssstore/Bridge/DeviceScanner.m`、`DeviceInspector.m`：原生阶段、错误和结果提示。

本会话曾导出旧版 0.4.0 的 566 处文案到 `/workspace/exports/ssstore-copy-0.4.0.*`。这些是精简前的参考材料，不是当前文案，也没有提交到仓库；新会话未必能访问。

## 4. 已有验证与局限

最终应用提交前已执行：

- 官方 `swift:latest` 容器，实际 Swift **6.4.2**。
- `swift test --package-path Packages/UpdateCore --scratch-path /swift-cache --jobs 4`：**36 项 XCTest 测试通过，0 失败**。
- `swiftc -frontend -parse ssstore/*.swift`：全部 Swift 界面语法检查通过。
- `git diff --check`：通过。
- YAML 解析、0.4.1（8）元数据和设置页版本一致性检查：通过。
- 非 UI 的 10 个文件做过去除字符串后的代码对比，确认只是文案修改；Objective-C 格式占位符保留。

Swift Testing 还会显示单独的“0 tests”结果，那不是 XCTest 的结果，不能据此认为没有执行测试。

本机为 Linux，没有原生 Swift、Xcode 或 iOS SDK。语法检查不等于 iOS 编译、SwiftUI 类型检查或真机运行验证。新 IPA 的完整构建与包内容仍需在 GitHub Actions 上确认。

本实例准备过的资源（新会话需自行核实是否保留）：

- 官方 Docker 镜像 `swift:latest`，本次摘要为 `sha256:119ff7d833ea622851b459513333bb4bda5ebb32b7acd05dd05077d5b0383129`。
- `/workspace/.ssstore-env/swift-cache`：仓库外构建缓存。
- `/workspace/.ssstore-env/install.sh`：重复安装/验证脚本。
- `/workspace/.ssstore-env/release-validation.log`：最终应用提交前的验证日志。
- DeviceKit v0.1.68 已由仓库脚本下载，并通过固定 SHA-256 校验，位于被忽略的 XCFramework 路径。

Swift 5.9.2 的 Linux Foundation 曾缺少项目用到的 API，编译失败；升级到最新稳定工具链后通过。`project.yml` 的 `SWIFT_VERSION: "5.9"` 是语言设置，不能据此要求使用旧的 Linux 工具链。不要为解决旧工具链问题修改已正常工作的源码。

## 5. IPA 构建与接续命令

工作流：`.github/workflows/build-ios.yml`。

- 名称：`Build unsigned iOS IPA`。
- 运行环境：`macos-15`。
- Xcode：`/Applications/Xcode_26.0.1.app/Contents/Developer`。
- 显式检查 iphoneos SDK 为 `26.*`。
- 命令：`bash scripts/build-ipa.sh`。
- 流程：核心测试 → 准备固定 DeviceKit → XcodeGen → 无签名 Release 编译 → 打包。
- IPA 路径：`dist/ssstore.ipa`。
- Artifact 名称：`ssstore-unsigned`。
- 支持 `workflow_dispatch`，应用源码等路径的 push 会自动触发。
- 本交接文档只改 `docs/`，按当前 push 路径筛选不会单独触发构建。

构建入口：<https://github.com/ccyykk666/ssstore/actions/workflows/build-ios.yml>

接续时先检查应用提交是否已有构建，避免重复运行：

```sh
git status --short
git log -3 --oneline
git ls-remote origin refs/heads/main

gh run list --repo ccyykk666/ssstore \
  --workflow build-ios.yml \
  --commit 9ffc7c312f7b91315e01c7cb99e0e474922c68ff \
  --json databaseId,headSha,status,conclusion,url
```

若已有运行，查看并等待该次运行；若失败，读取该次日志定位问题，修复后再构建。只有确认不存在相应运行或确有重跑必要时，才执行：

```sh
gh workflow run build-ios.yml --repo ccyykk666/ssstore --ref main
```

拿到实际运行 ID 后：

```sh
gh run view RUN_ID --repo ccyykk666/ssstore
gh run download RUN_ID --repo ccyykk666/ssstore \
  --name ssstore-unsigned --dir /workspace/ssstore/dist/downloaded
```

下载后核对 IPA 的版本 **0.4.1（8）**、arm64、iOS 26 SDK 及资源，确认产物对应正确代码提交。给用户真实构建/产物链接并说明仍需自行签名安装。不要把旧版成功构建的产物当成当前版本。

## 6. 当前网络阻塞的事实

本会话中：

- 原生 HTTPS Git 读取和推送均成功，平台现有 GitHub 认证可用。
- `gh api` 访问 `https://api.github.com/...` 被代理拒绝；`curl` 的 CONNECT 响应为 **403 Forbidden**。
- 使用完全访问权限/沙箱外执行重新验证后仍相同。
- 云实例状态报告 `network_policy.mode: restricted`、`state: enforced`，自定义 `allowed_hosts: []`。
- `api.github.com` 不在该实例报告的允许域名中。
- 正常 GitHub 私有仓库 Actions 网页通过命令行匿名访问返回 404，未取得运行信息。这不能证明没有构建。
- 没有得到运行 ID、成功/失败状态或本次 artifact ID。

通过环境配置工具已保存加入 `api.github.com` 的网络草稿，工具确认 `status: saved`、`requires_publish: true`。但本实例后续观测仍为旧的受限策略，**没有证据表明草稿已应用或发布**。保存草稿本身不改变运行时网络。

用户在自己的界面里找不到环境网络设置。上一助手给过未经核实的“Codex 设置 → 环境”路径，已经承认错误。**不要再将这个路径当成已证实入口，让用户反复寻找。**

用户已有完整项目操作授权；当前观测到的问题是云环境出站策略，不应要求用户重复授权 Git、提供 PAT，或把 API 拒绝误诊为仓库没有权限。新会话应先测试自身实际网络和认证能力；它可能与本会话不同。保留平台代理与 TLS 校验，不尝试绕过已明确拒绝的网络策略。

如果新会话同样被阻塞，应如实说明本机能力限制，并提供已经核实的替代流程。不要声称通过保存草稿、切换完全访问权限或修改文件已经修复网络。不要请求用户在聊天中粘贴秘密值。

## 7. 必须保留的应用语义

### 版本判断

- 本地读取 `softwareVersionExternalIdentifier` / `ExternalVersionIdentifier`。
- 远端读取 Apple Catalog 的 `offers[0].version.externalId` / `buyParams` 中的 `appExtVrsId`。
- 验证应用身份：代码要求精确的有效 Bundle ID；两边都有有效数字 Store ID 时也必须相同。自签改写标识的映射不能绕过身份核验。
- ID 只接受有效正十进制并去除前导零；它是不透明标识，不能比较大小判断新旧。
- 相同：版本相同，可使用该商店记录的展示版本；不同：版本标识不同，不推断更新方向。
- 缺失、身份不符、地区/策略不符或查询失败：待核对。
- 原始版本/构建字段仍保留；不能重新用字符串启发式判断应用更新。
- `VersionOrder` 仍用于最低 iOS 版本判断，不要误删。`UpdateStatus` 中旧的 `update` / `ahead` 枚举不代表当前应用更新判断。

历史回归案例：工商银行原始 short=3.1.40、build=1.2，本地/商店 external ID 同为 891257769，对应商店版本 11.1.0.9.0。京东、夸克网盘、同程、王者荣耀也曾因版本字符串不同被误判；不要恢复这些应用的专用字符串补丁。

### 商店查询

- 默认中国大陆优先，仅明确未找到的应用补查美国；网络失败、超时、限流不算未找到。
- 美国查询失败保留中国大陆成功结果；429 停止批次。
- 保留固定 CN / US / HK / JP 地区。
- Bundle ID 去重，每批 25；已知数字 Store ID 可直接查 Catalog。
- Lookup 发现应用，再查 Catalog，不能用名称搜索冒充精确身份匹配。
- 查询间隔 3.2 秒，按地区/策略缓存 5 分钟，强制刷新绕过缓存。
- 没有 Apple ID 登录、账户或下载流程。

### 配对和设备读取

- 使用 Loon 回环与 Remote Pairing/RSD，默认 `10.7.0.1:49152`；普通扫描使用 InstallationProxy Lookup/Browse，图标使用 SpringBoard，不依赖 CoreDevice。
- 用户此前已确认手机配对可用。广播和监听保持到握手结束，使用持续后台任务和通知展示 PIN，设有超时与主动停止。不要恢复“握手开始就撤下广播”的旧问题。
- 固定依赖 `jkcoxson/idevice v0.1.68` 的发布 XCFramework，并保留下载校验。不要随意升级。
- 41 个主读取入口、2 个文件辅助操作；索引 661 条 C 声明，检查器使用 125 条。声明数量不是可用服务或用户操作数量。
- 详细覆盖与限制见 `docs/API_REFERENCE.md`。新增服务并未全部真机验证；用户曾遇到 CoreDevice `ServiceNotFound 21`。
- 扫描、配对、检查共用 busy 状态；FFI 资源在同一工作线程创建、使用和释放。
- 文件只读、单文件上限 32 MiB、64 KiB 分块。CoreDevice 文件入口仅列目录，文件导出走 AFC。
- 无安装、卸载、写入、删除、恢复等执行按钮；无连续日志、抓包、性能流执行入口。
- 完整桌面布局未实现：固定版本 C FFI 不导出 `get_icon_state`，不能用图标参数冒充布局。
- 描述文件解析不是证书信任/撤销验证；动态占用不是可清理缓存；能力声明不是实际隐私授权。
- 变化历史记录的是发现变化的时间，不是系统真实安装时间；版本标识变化不表示升级方向。
- 不提交配对文件、PIN、证书私钥等敏感资料；不要假定能访问用户手机、Windows 本地文件或历史登录凭据。

## 8. 新会话的第一步

先确认源码和提交，读取本文及工作流；**优先查询 `9ffc7c3` 的既有构建并获取 0.4.1（8）IPA**。仅在构建失败或用户提出新反馈时修改代码。完成后报告实际构建结果、正确产物链接和仍需签名安装的事实。
