# 本机系统接口研究清单

核对日期：2026-11-17；接入版本：0.6.0 (79)。范围为本机只读当前值，不依赖回环调试、DVT 或配对。网络检索覆盖 Apple 技术文档/源码、Chromium、逆向书籍、技术文章、开发者问答及开源项目。网上成功案例不等于当前 iPhone 签名可用；macOS 和越狱案例仅用于核对字段/ABI，不能证明普通 iOS 沙盒允许访问。

## 已接入

| 接口/路径 | 当前展示 | 实现和边界 |
| --- | --- | --- |
| Mach `host_processor_info` | CPU 整体与每核心 | 两次当前计数差；停用核心不抹掉总值；不保存历史 |
| `host_statistics64` | 活跃、非活跃、固定、压缩器、可清理内存 | 按实际页大小换算，分类可能重叠，不把各项相加成总内存；压缩器是实际占用空间 |
| `kern.memorystatus_level` | 内核可用内存比例 | 只读 sysctl；是内存可用比例，不是压力等级；拒绝/不存在保留不可用 |
| IOKit `IOAccelerator.PerformanceStatistics` | 整机 GPU、renderer、tiler 使用率、驱动占用系统内存 | 只采信明确字段；不能当作所选 App 的 GPU 数值；没有百分比不填 0 |
| `IOPMPowerSource` | 电池温度、电压、电流、循环数、充电/外接电源状态 | 只读取固定属性；新版 iOS 可能过滤详细字段 |
| `AppleSmartBatteryPack.BatteryData` | 电池温度备用节点 | 原节点温度缺失或无效时使用，单位为摄氏度的百分之一 |
| `IOPSCopyPowerSourcesInfo/List`、`IOPSGetPowerSourceDescription` | 内置电池电量、充电状态 | 只取内部电池，不把蓝牙外设/UPS 计入手机电池 |
| `IOPSCopyExternalPowerAdapterDetails` | 适配器标称功率 | `Watts` 是标称/描述值，不是实测输入功率；忽略适配器序列号等其他键 |
| IOHID 厂商页 `0xff00/5` | 原始名称对应的温度当前值 | 独立硬件传感器页；不将名字不明的温度自动归类为 CPU/GPU/电池 |
| IOHID 厂商页 `0xff08/2,3` | 电流、电压当前值 | 只查询电源类；不访问键盘、触屏、麦克风等输入；电流保留符号，不伪造缺失的放电电流 |
| `proc_pid_rusage` / `RUSAGE_INFO_V2` | 单 App CPU、物理占用、常驻/固定内存、磁盘字节、唤醒/换入页累计 | Bundle ID → 允许查询的主进程 PID；权限失败不替换为本 App 或整机数据 |
| `proc_pidinfo` / `PROC_PIDTASKINFO` | 线程数、运行线程数、虚拟空间、缺页/上下文切换累计 | 固定 ABI 96 字节，严格检查返回大小；不请求其他进程 task port |
| FrontBoard / LaunchServices | PID、应用选择列表 | 可被沙盒拒绝；仅按实际返回工作 |
| `MGCopyAnswer` 固定型号键 | 产品/硬件型号、硬件平台、CPU 架构、设备类别 | 动态符号；不枚举所有键，不查询设备唯一标识、序列号、IMEI、MAC、账号或激活信息；静态信息仅读取一次 |
| `sysctlbyname` 固定系统键 | 型号、系统构建、Darwin 版本 | 不执行 sysctl 写入；实际存在才展示 |
| `getifaddrs` | Wi-Fi/蜂窝当前传输速率 | 排除回环/VPN，避免重复计数；接口变更/计数回退重建基线 |
| `IOBlockStorageDriver.Statistics` | 整机磁盘读写 | 明确的字节字段；不以 VM pageins 冒充磁盘 I/O |
| `getloadavg`、NSProcessInfo、文件系统属性 | 1/5/15 分钟系统负载、运行时间、核心数量、低电量模式、存储容量 | 负载不是 CPU 百分比；文件系统空闲值不是可卸载缓存后的“可用容量” |

所有读取在工作队列执行；UI 只在主线程更新。界面可见且 App 活跃时读取，每次只保留当前结果；停止后丢弃未完成请求结果。HID 只建立一个进程内客户端，不注册事件回调或 RunLoop 监听；使用同步的当前值请求。客户端匹配状态加锁；每页最多枚举 128 项，释放本次 Copy/Create 对象；四字符硬件键与类型去重，不合并没有键的同名传感器。NaN、无限值和不合理哨兵值丢弃。没有采集文件/录制/后台性能活动。

电池侧功率由同一来源的电压与电流相乘，保留系统电流符号；没有电流就没有功率，不以零代替。不会将适配器额定瓦数、HID 无关支路或 GPU 内存解释为 CPU 功耗。

## 已查证但未加入普通签名路径

| 接口/目标 | 查证结论与保留原因 |
| --- | --- |
| NetworkStatistics / `NStatManagerCreate` | 可研究按进程网络，但 iOS 统计控制通道存在私有 entitlement 检查；没有加入常驻 socket、抓包或 VPN 路径 |
| IOReport / Energy Model / 性能状态 | macOS 可获取部分组件功率与频率；iOS 普通沙盒案例报告被拒绝，不能把 macOS 成功推定为 iOS 成功；不建立持续订阅 |
| RunningBoard / 后台断言 | 涉及调用者 entitlement，不以开发者模式推定有权限；没有利用它维持性能面板后台运行 |
| `task_for_pid` / 任意应用线程、GPU、内存映射 | 有进程访问限制；当前只保留有权读取的 libproc 数据与已持有的自身 task port |
| `IOPSCopyChargeStatus`、PowerUI 充电设置 | 新版普通 iOS 签名案例报告未授权；未增加无效设置开关，也不改充电上限 |
| 私有 CPU/GPU 时钟与功耗 | 当前没有核实普通 iOS 签名可用的直接读取路径；不把 `hw.cpufrequency` 静态值伪装为实时频率 |
| MobileGestalt 完整键枚举 | 已确认有大量系统能力键，但很多为隐私/鉴权/激活数据；只接入固定非唯一型号字段 |

## 网络检索来源

下列为字段和调用方式的研究参考；没有将外部项目的应用源文件或二进制加入 ssstore。接口声明和解析在本仓库独立实现。旧文章仅用于线索，优先和系统头文件、当前实现交叉核对。

### 非 GitHub 资料

- [Apple：os_proc_available_memory](https://developer.apple.com/documentation/os/os_proc_available_memory)：该值为**调用者自身**可分配额度，不可作为整机空闲内存或其他 App 的额度；本次没有这样替换。
- [Apple WWDC22：Profile and optimize your game's memory](https://developer.apple.com/videos/play/wwdc2022/10106/)：核对物理占用与内存接口语义。
- [Apple：运行时进程安全](https://support.apple.com/guide/security/security-of-runtime-process-sec15bfe098e/web)：沙盒/entitlement 与开发者模式的区别。
- [Chromium：Apple 进程指标](https://chromium.googlesource.com/chromium/src/+/HEAD/base/process/process_metrics_apple.mm)：核对 Mach 内存统计与版本字段。
- [Chromium：Apple Silicon 温度读取声明](https://chromium.googlesource.com/chromium/src/+/refs/tags/133.0.6880.0/components/power_metrics/m1_sensors_mac.mm)：HID C ABI 交叉验证；这是 macOS 参考，不是 iOS 权限证明。
- [Zachary Wagner：Apple Silicon 温度接口](https://blog.zackwag.com/getting-cpu-temperature-from-the-cli-on-apple-silicon)：HID 温度读取路径与异常值处理线索；macOS 环境。
- [Stat Space：温度、功率和时钟](https://statspace.app/blog/apple-silicon-sensors-without-root)：区分 HID、IOReport 和驱动统计，以及动态符号加载；macOS 环境。
- [*OS Internals：Darwin 网络与统计](https://newosxbook.com/bonus/vol1ch16.html)：NStat/PF_SYSTEM 与 entitlement 限制。
- [The Apple Wiki：MobileGestalt 键表](https://theapplewiki.com/wiki/List_of_MobileGestalt_keys)：型号键/系统版本/权限线索。
- [Ben Terhechte：从 Swift 查询 MobileGestalt](https://www.terhech.de/posts/2015-09-30-getting-iphone6s-foundry-from-swift.html)：动态加载和 CF 所有权；老版本示例不代表现代系统可读取所有键。
- [Stack Overflow：iOS 电池温度](https://stackoverflow.com/questions/16287831/obtain-battery-temperature-in-ios-programatically)：早期 IOKit/HID 路径线索，需用现有代码核对。
- [Flutter 官方生成文档：iOS 指标源码](https://api.flutter.dev/ios-embedder/profiler__metrics__ios_8mm_source.html)：GPU PerformanceStatistics 字段与对象释放。

### 源码/头文件与 iOS 交叉验证

- [Apple XNU：resource.h](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/resource.h)：rusage_info_v2 的字段顺序/类型。
- [Apple XNU：proc_info.h](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/proc_info.h)：proc_taskinfo ABI 与命令号。
- [Apple XNU：vm_statistics.h](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/mach/vm_statistics.h)：内存页分类语义及重叠关系。
- [Apple XNU：memorystatus 测试](https://github.com/apple-oss-distributions/xnu/blob/main/tests/memorystatus_vm_map_fork.c)：kern.memorystatus_level 的比例语义。
- [pymobiledevice3：diagnostics.py](https://github.com/doronz88/pymobiledevice3/blob/master/pymobiledevice3/services/diagnostics.py)：新电池温度节点和单位；其查询走诊断服务，**不等于**本地沙盒可读取相同属性。
- [MiniWatts：HID 传感器](https://github.com/ResistanceTo/MiniWatts/blob/master/MiniWatts/Core/Sensors/HIDSensors.swift)：当前 iOS 厂商 usage page、同名/重复服务、一进程单客户端的经验。
- [MiniWatts：IOKit 电池](https://github.com/ResistanceTo/MiniWatts/blob/master/MiniWatts/Core/Sensors/IOKitBattery.swift)：普通 iOS 沙盒详细字段受限与 powerd 路径的交叉验证。

## 验证范围

CI 在 macOS 编译实际 Objective-C 读取器，验证主机/自身进程读取、proc_taskinfo ABI、权限失败隔离、重复读取以及真实传感器快照的有效性。固定输入验证电池单位/符号、新节点、GPU/传感器异常值、非传感器 HID 页拒绝、去重；Swift 验证当前指标缺失后不复用旧值和解码隔离；已有关闭/切换/取消队列回归继续运行。

完整 iOS 构建验证链接与可用性声明；这不代表已在 iOS 27.3 真机逐项验证。每项真实权限/硬件可用性最终以用户设备返回为准。
