# UIKit 界面迁移

0.6.0（30）将 iOS 运行时的页面全部替换为 UIKit。业务实现继续使用 AppModel、UpdateCore、AppStore、Downloads、AppPackageArchive 和设备桥接。

- UIApplicationDelegate + UIWindowSceneDelegate 创建窗口；每个 tab 使用独立 UINavigationController。
- 应用列表、应用详情、数据浏览、文件属性与导出、设置、配对、忽略名单、账户、账户登录、搜索、商店详情、历史版本、下载与安装、IPA 文件浏览和日志均使用原生控制器。
- 搜索使用持久的 UISearchController；搜索 tab 再次点击后，由 didPresentSearchController 获取焦点。空文本直接设置起始光标；有内容时全选。不再使用 SwiftUI searchable、FocusState、HostingController、轮询控件或延迟隐藏标题。
- 原 SwiftUI 页面源码保留为历史实现和上游参考，已从 iOS 编译目标中排除。新 UIKit 文件按通用控件、应用、商店、设备分组。
- 账号 Keychain、配对文件、忽略名单、地区偏好、清单和下载记录继续沿用原存储路径。
- 统计和列表状态继续由同一个匹配前缀推进，UIKit 仅显示计数，避免独立计算导致负数和提前显示更新。

验证范围：Xcode 构建与相关现有检查；未在真机确认首次搜索动画、系统配对、账号登录或所有数据服务。构建成功不能替代这些交互验证。
