#import "LocalPerformance.h"
#import "LocalMetricParsing.h"
#import <mach/mach.h>
#import <mach/processor_info.h>
#import <mach/task_info.h>
#import <mach/mach_time.h>
#import <sys/sysctl.h>
#import <sys/socket.h>
#import <net/if.h>
#import <net/if_dl.h>
#import <ifaddrs.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <errno.h>
#import <unistd.h>
#import <stdlib.h>
#import <string.h>

// Read-only Darwin proc_pid_rusage ABI (xnu/bsd/sys/resource.h, RUSAGE_INFO_V2).
// Resolve dynamically because iOS SDKs do not expose the private libproc entry.
typedef struct {
    uint8_t uuid[16];
    uint64_t user, system, packageWakeups, interruptWakeups, pageins;
    uint64_t wired, resident, footprint, started, exited;
    uint64_t childUser, childSystem, childPackageWakeups, childInterruptWakeups, childPageins, childElapsed;
    uint64_t diskRead, diskWritten;
} SSProcessUsage;
_Static_assert(sizeof(SSProcessUsage) == 160, "Unexpected rusage_info_v2 layout");
// xnu/bsd/sys/proc_info.h: PROC_PIDTASKINFO (4), fixed 96-byte ABI.
typedef struct {
    uint64_t virtualSize, residentSize, totalUser, totalSystem, threadsUser, threadsSystem;
    int32_t policy, faults, pageins, cowFaults, messagesSent, messagesReceived;
    int32_t syscallsMach, syscallsUnix, contextSwitches, threads, runningThreads, priority;
} SSProcessTask;
_Static_assert(sizeof(SSProcessTask) == 96, "Unexpected proc_taskinfo layout");

static NSString *SSFailure(NSString *operation, int code) {
    return [NSString stringWithFormat:@"%@不可用（%d）", operation, code];
}
static id SSObject(id receiver, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (!receiver || ![receiver respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(receiver, selector);
}
static void *SSIOKit;
static void SSLoadFrameworks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_LAZY | RTLD_LOCAL);
        dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY | RTLD_LOCAL);
        SSIOKit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY | RTLD_LOCAL);
    });
}
// Copies only a fixed property allowlist. Does not open driver user clients,
// change registry properties, retain registry handles or enumerate device IDs.
static NSDictionary *SSRegistryProperties(const char *className, NSArray<NSString *> *keys, int *failure) {
    SSLoadFrameworks();
    typedef CFMutableDictionaryRef (*Match)(const char *);
    typedef kern_return_t (*Services)(mach_port_t, CFDictionaryRef, mach_port_t *);
    typedef mach_port_t (*Next)(mach_port_t);
    typedef CFTypeRef (*Property)(mach_port_t, CFStringRef, CFAllocatorRef, uint32_t);
    typedef kern_return_t (*Release)(mach_port_t);
    static Match match; static Services services; static Next next; static Property property; static Release release;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        match = (Match)dlsym(SSIOKit ?: RTLD_DEFAULT, "IOServiceMatching");
        services = (Services)dlsym(SSIOKit ?: RTLD_DEFAULT, "IOServiceGetMatchingServices");
        next = (Next)dlsym(SSIOKit ?: RTLD_DEFAULT, "IOIteratorNext");
        property = (Property)dlsym(SSIOKit ?: RTLD_DEFAULT, "IORegistryEntryCreateCFProperty");
        release = (Release)dlsym(SSIOKit ?: RTLD_DEFAULT, "IOObjectRelease");
    });
    if (!match || !services || !next || !property || !release) { *failure = ENOSYS; return @{}; }
    CFMutableDictionaryRef query = match(className);
    if (!query) { *failure = ENOMEM; return @{}; }
    mach_port_t iterator = 0;
    kern_return_t status = services(MACH_PORT_NULL, query, &iterator); // consumes query
    if (status != KERN_SUCCESS) { if (iterator) release(iterator); *failure = status; return @{}; }
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    for (NSUInteger count = 0; count < 16; count++) {
        mach_port_t entry = next(iterator); if (!entry) break;
        for (NSString *key in keys) {
            id raw = CFBridgingRelease(property(entry, (__bridge CFStringRef)key, kCFAllocatorDefault, 0));
            if (raw) values[key] = raw;
        }
        release(entry);
        if (values.count) break; // one source; never mix independent batteries/GPUs
    }
    if (iterator) release(iterator);
    *failure = values.count ? 0 : ENODATA;
    return values;
}
static void SSPowerSourceMetrics(NSMutableDictionary *metrics) {
    typedef CFTypeRef (*Info)(void);
    typedef CFArrayRef (*List)(CFTypeRef);
    typedef CFDictionaryRef (*Description)(CFTypeRef, CFTypeRef);
    typedef CFDictionaryRef (*Adapter)(void);
    static Info info; static List list; static Description description; static Adapter adapter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        info = (Info)dlsym(SSIOKit ?: RTLD_DEFAULT, "IOPSCopyPowerSourcesInfo");
        list = (List)dlsym(SSIOKit ?: RTLD_DEFAULT, "IOPSCopyPowerSourcesList");
        description = (Description)dlsym(SSIOKit ?: RTLD_DEFAULT, "IOPSGetPowerSourceDescription");
        adapter = (Adapter)dlsym(SSIOKit ?: RTLD_DEFAULT, "IOPSCopyExternalPowerAdapterDetails");
    });
    if (info && list && description) {
        CFTypeRef context = info();
        if (context) {
            CFArrayRef sources = list(context);
            if (sources) {
                for (CFIndex i = 0; i < MIN(CFArrayGetCount(sources), 16); i++) {
                    NSDictionary *value = (__bridge NSDictionary *)description(context, CFArrayGetValueAtIndex(sources, i)); // borrowed
                    if (![value isKindOfClass:NSDictionary.class] || ![value[@"Type"] isEqual:@"InternalBattery"]) continue;
                    NSNumber *current = SSMetricNumber(value[@"Current Capacity"], 0, 1e9), *maximum = SSMetricNumber(value[@"Max Capacity"], 1, 1e9);
                    if (current && maximum && current.doubleValue <= maximum.doubleValue) metrics[@"batteryPercent"] = @(100 * current.doubleValue / maximum.doubleValue);
                    id charging = value[@"Is Charging"];
                    if ([charging isKindOfClass:NSNumber.class]) metrics[@"batteryCharging"] = @([charging boolValue]);
                    break;
                }
                CFRelease(sources);
            }
            CFRelease(context);
        }
    }
    id value = adapter ? CFBridgingRelease(adapter()) : nil;
    if ([value isKindOfClass:NSDictionary.class]) {
        NSNumber *watts = SSMetricNumber(value[@"Watts"], 1, 1000);
        if (watts) metrics[@"adapterWatts"] = watts; // advertised rating, NOT actual input watts
    }
}
static NSDictionary *SSReadSensors(void) {
    SSLoadFrameworks();
    typedef CFTypeRef (*Create)(CFAllocatorRef);
    typedef void (*Matching)(CFTypeRef, CFDictionaryRef);
    typedef CFArrayRef (*Services)(CFTypeRef);
    typedef CFTypeRef (*Property)(CFTypeRef, CFStringRef);
    typedef CFTypeRef (*Event)(CFTypeRef, int64_t, int32_t, int64_t);
    typedef double (*Float)(CFTypeRef, int32_t);
    static CFTypeRef client; static Matching matching; static Services services;
    static Property property; static Event event; static Float number; static dispatch_once_t once;
    // One client for the process lifetime, no event subscriptions or callbacks.
    dispatch_once(&once, ^{
        Create create = (Create)dlsym(SSIOKit ?: RTLD_DEFAULT, "IOHIDEventSystemClientCreate");
        matching = (Matching)dlsym(SSIOKit ?: RTLD_DEFAULT, "IOHIDEventSystemClientSetMatching");
        services = (Services)dlsym(SSIOKit ?: RTLD_DEFAULT, "IOHIDEventSystemClientCopyServices");
        property = (Property)dlsym(SSIOKit ?: RTLD_DEFAULT, "IOHIDServiceClientCopyProperty");
        event = (Event)dlsym(SSIOKit ?: RTLD_DEFAULT, "IOHIDServiceClientCopyEvent");
        number = (Float)dlsym(SSIOKit ?: RTLD_DEFAULT, "IOHIDEventGetFloatValue");
        if (create && matching && services && property && event && number) client = create(kCFAllocatorDefault);
    });
    NSMutableArray *readings = [NSMutableArray array];
    NSMutableSet *identities = [NSMutableSet set];
    NSUInteger seen = 0, invalid = 0;
    if (client) {
        // Serialize even if a future caller uses a different queue. Matching is
        // mutable client state. Copy/Create objects always released in this scope.
        @synchronized(LocalPerformance.class) {
            NSArray *queries = @[@{@"PrimaryUsagePage":@0xff00, @"PrimaryUsage":@5}, @{@"PrimaryUsagePage":@0xff08}];
            for (NSDictionary *query in queries) {
                matching(client, (__bridge CFDictionaryRef)query);
                CFArrayRef refs = services(client);
                if (!refs) continue;
                for (CFIndex i = 0; i < MIN(CFArrayGetCount(refs), 128); i++) {
                    CFTypeRef service = CFArrayGetValueAtIndex(refs, i); seen++;
                    id rawPage = CFBridgingRelease(property(service, CFSTR("PrimaryUsagePage")));
                    id rawUsage = CFBridgingRelease(property(service, CFSTR("PrimaryUsage")));
                    if (![rawPage isKindOfClass:NSNumber.class] || ![rawUsage isKindOfClass:NSNumber.class]) continue;
                    int page = [rawPage intValue], usage = [rawUsage intValue];
                    BOOL temperature = page == 0xff00 && usage == 5;
                    if (!temperature && !(page == 0xff08 && (usage == 2 || usage == 3))) continue;
                    int64_t type = temperature ? 15 : 25;
                    CFTypeRef sample = event(service, type, 0, 0);
                    if (!sample) { invalid++; continue; }
                    double value = number(sample, (int32_t)(type << 16));
                    CFRelease(sample);
                    id rawName = CFBridgingRelease(property(service, CFSTR("Product")));
                    id rawLocation = CFBridgingRelease(property(service, CFSTR("LocationID")));
                    NSString *name = [rawName isKindOfClass:NSString.class] ? rawName : @"";
                    uint32_t location = [rawLocation isKindOfClass:NSNumber.class] ? [rawLocation unsignedIntValue] : 0;
                    NSDictionary *item = SSHIDMetric(name, location, page, usage, value, (NSUInteger)i);
                    if (!item) { invalid++; continue; }
                    if ([identities containsObject:item[@"id"]]) continue;
                    [identities addObject:item[@"id"]]; [readings addObject:item];
                }
                CFRelease(refs);
            }
        }
    }
    NSString *status = !client ? @"系统未开放 HID 传感器接口" : !seen ? @"系统未公开温度／电流／电压传感器，或当前权限不足"
        : !readings.count ? @"发现传感器，但未返回有效数值" : @"本机当前值 · 每秒刷新";
    return @{@"timestamp":@(NSDate.date.timeIntervalSince1970), @"sensors":readings, @"status":status, @"unavailableCount":@(invalid)};
}
static void SSHardwareMetrics(NSMutableDictionary *metrics, NSMutableDictionary *issues) {
    int failure = 0;
    NSDictionary *gpu = SSRegistryProperties("IOAccelerator", @[@"PerformanceStatistics"], &failure);
    id statistics = gpu[@"PerformanceStatistics"];
    NSDictionary *gpuValues = SSGPUMetrics([statistics isKindOfClass:NSDictionary.class] ? statistics : @{});
    [metrics addEntriesFromDictionary:gpuValues];
    if (!gpuValues.count) issues[@"gpu"] = SSFailure(@"GPU 驱动统计（系统未公开或权限受限）", failure ?: ENODATA);
    NSDictionary *battery = SSRegistryProperties("IOPMPowerSource", @[@"Temperature", @"Voltage", @"InstantAmperage", @"CycleCount", @"IsCharging", @"ExternalConnected", @"FullyCharged"], &failure);
    NSDictionary *pack = @{};
    // Recent iOS versions move temperature under AppleSmartBatteryPack.BatteryData.
    if (!SSMetricNumber(battery[@"Temperature"], -4000, 10000)) pack = SSRegistryProperties("AppleSmartBatteryPack", @[@"BatteryData"], &failure);
    NSDictionary *batteryValues = SSBatteryMetrics(battery, pack);
    [metrics addEntriesFromDictionary:batteryValues];
    if (!batteryValues[@"batteryTemperature"] && !batteryValues[@"batteryVoltage"] && !batteryValues[@"batteryCurrent"] && !batteryValues[@"batteryCycles"])
        issues[@"battery"] = SSFailure(@"电池详细统计（系统未公开或权限受限）", failure ?: ENODATA);
    SSPowerSourceMetrics(metrics);
    int available = 0; size_t size = sizeof(available); errno = 0;
    int status = sysctlbyname("kern.memorystatus_level", &available, &size, NULL, 0);
    if (status == 0 && size == sizeof(available) && available >= 0 && available <= 100) metrics[@"memoryAvailablePercent"] = @(available);
    else issues[@"memoryAvailability"] = SSFailure(@"内核可用内存比例", status ? errno : ERANGE);
}
static NSDictionary *SSHardwareIdentity(void) {
    static NSDictionary *identity; static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *values = [NSMutableDictionary dictionary];
        typedef CFTypeRef (*Answer)(CFStringRef);
        void *library = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY | RTLD_LOCAL);
        Answer answer = library ? (Answer)dlsym(library, "MGCopyAnswer") : NULL;
        // Fixed non-unique hardware/OS keys. No UDID, serial, IMEI, MAC, name,
        // account, activation or attestation queries, and no writes/hooks.
        NSDictionary *keys = @{@"ProductType":@"hardwareProduct", @"HardwareModel":@"hardwareModel",
            @"HardwarePlatform":@"hardwarePlatform", @"CPUArchitecture":@"cpuArchitecture", @"DeviceClass":@"deviceClass"};
        if (answer) for (NSString *key in keys) {
            id value = CFBridgingRelease(answer((__bridge CFStringRef)key));
            if ([value isKindOfClass:NSString.class] && [value length] > 0 && [value length] <= 256) values[keys[key]] = value;
        }
        NSDictionary *sysctls = @{@"hw.machine":@"hardwareProduct", @"hw.model":@"hardwareModel", @"kern.osversion":@"osBuild", @"kern.osrelease":@"darwinVersion"};
        for (NSString *key in sysctls) {
            if (values[sysctls[key]]) continue;
            char text[256] = {0}; size_t size = sizeof(text);
            if (sysctlbyname(key.UTF8String, text, &size, NULL, 0) == 0 && size > 0 && size <= sizeof(text)) {
                NSString *value = [[NSString alloc] initWithBytes:text length:strnlen(text, size) encoding:NSUTF8StringEncoding];
                if (value.length) values[sysctls[key]] = value;
            }
        }
        identity = [values copy];
    });
    return identity;
}
static pid_t SSPID(NSString *bundleID) {
    if ([bundleID isEqualToString:NSBundle.mainBundle.bundleIdentifier]) return getpid();
    SSLoadFrameworks();
    @try {
        id service = SSObject(NSClassFromString(@"FBSSystemService"), @"sharedService");
        SEL selector = NSSelectorFromString(@"pidForApplication:");
        if (service && [service respondsToSelector:selector]) return ((int (*)(id, SEL, id))objc_msgSend)(service, selector, bundleID);
    } @catch (NSException *exception) { }
    return 0;
}
static void SSNetwork(NSMutableDictionary *result, NSMutableDictionary *issues) {
    struct ifaddrs *addresses = NULL;
    if (getifaddrs(&addresses) != 0) { issues[@"network"] = SSFailure(@"网络接口计数", errno); return; }
    uint64_t received = 0, sent = 0; BOOL found = NO;
    NSMutableArray *names = [NSMutableArray array];
    for (struct ifaddrs *item = addresses; item; item = item->ifa_next) {
        if (!item->ifa_addr || item->ifa_addr->sa_family != AF_LINK || !item->ifa_data || !(item->ifa_flags & IFF_UP)) continue;
        NSString *name = [NSString stringWithUTF8String:item->ifa_name] ?: @"";
        // Count physical Wi-Fi/Ethernet and cellular, excluding loopback and VPN
        // tunnel interfaces to avoid counting the same traffic twice.
        if (![name hasPrefix:@"en"] && ![name hasPrefix:@"pdp_ip"]) continue;
        struct if_data *data = item->ifa_data;
        received += data->ifi_ibytes; sent += data->ifi_obytes; found = YES;
        [names addObject:name];
    }
    freeifaddrs(addresses);
    if (found) {
        result[@"networkReceived"] = @(received); result[@"networkSent"] = @(sent);
        result[@"networkIdentity"] = [[names sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@","];
    } else { issues[@"network"] = @"系统未公开 Wi-Fi／蜂窝接口计数"; }
}
static void SSDisk(NSMutableDictionary *result, NSMutableDictionary *issues) {
    SSLoadFrameworks();
    typedef CFMutableDictionaryRef (*Match)(const char *);
    typedef kern_return_t (*Services)(mach_port_t, CFDictionaryRef, mach_port_t *);
    typedef mach_port_t (*Next)(mach_port_t);
    typedef CFTypeRef (*Property)(mach_port_t, CFStringRef, CFAllocatorRef, uint32_t);
    typedef kern_return_t (*Release)(mach_port_t);
    static Match match; static Services services; static Next next; static Property property; static Release release;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        match = (Match)dlsym(SSIOKit ?: RTLD_DEFAULT, "IOServiceMatching");
        services = (Services)dlsym(SSIOKit ?: RTLD_DEFAULT, "IOServiceGetMatchingServices");
        next = (Next)dlsym(SSIOKit ?: RTLD_DEFAULT, "IOIteratorNext");
        property = (Property)dlsym(SSIOKit ?: RTLD_DEFAULT, "IORegistryEntryCreateCFProperty");
        release = (Release)dlsym(SSIOKit ?: RTLD_DEFAULT, "IOObjectRelease");
    });
    if (!match || !services || !next || !property || !release) { issues[@"disk"] = @"系统未开放磁盘计数接口"; return; }
    mach_port_t iterator = 0;
    CFMutableDictionaryRef query = match("IOBlockStorageDriver");
    if (!query) { issues[@"disk"] = @"磁盘统计不可用"; return; }
    kern_return_t status = services(MACH_PORT_NULL, query, &iterator); // consumes query
    if (status != KERN_SUCCESS) { issues[@"disk"] = SSFailure(@"磁盘统计", status); return; }
    uint64_t read = 0, written = 0; BOOL found = NO;
    for (NSUInteger count = 0; count < 32; count++) {
        mach_port_t entry = next(iterator); if (!entry) break;
        id values = CFBridgingRelease(property(entry, CFSTR("Statistics"), kCFAllocatorDefault, 0));
        release(entry);
        if (![values isKindOfClass:NSDictionary.class]) continue;
        id r = values[@"Bytes (Read)"], w = values[@"Bytes (Write)"];
        if ([r isKindOfClass:NSNumber.class] && [w isKindOfClass:NSNumber.class]) {
            read += [r unsignedLongLongValue]; written += [w unsignedLongLongValue]; found = YES;
        }
    }
    if (iterator) release(iterator);
    if (found) { result[@"diskRead"] = @(read); result[@"diskWritten"] = @(written); }
    else { issues[@"disk"] = @"系统未公开磁盘读写计数"; }
}
static void SSDevice(NSMutableDictionary *result, NSMutableDictionary *issues) {
    NSMutableDictionary *metrics = [NSMutableDictionary dictionary];
    mach_port_t host = mach_host_self();
    natural_t processors = 0; processor_info_array_t info = NULL; mach_msg_type_number_t count = 0;
    kern_return_t status = host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &processors, &info, &count);
    if (status == KERN_SUCCESS && info && count >= processors * CPU_STATE_MAX) {
        NSMutableArray *ticks = [NSMutableArray array];
        for (natural_t i = 0; i < processors; i++) {
            NSMutableArray *core = [NSMutableArray array];
            for (NSUInteger state = 0; state < CPU_STATE_MAX; state++) [core addObject:@((uint32_t)info[i * CPU_STATE_MAX + state])];
            [ticks addObject:core];
        }
        result[@"cpuTicks"] = ticks;
    } else { issues[@"cpu"] = SSFailure(@"整机 CPU", status); }
    if (info) vm_deallocate(mach_task_self(), (vm_address_t)info, count * sizeof(integer_t));
    vm_statistics64_data_t memory = {0}; count = HOST_VM_INFO64_COUNT;
    status = host_statistics64(host, HOST_VM_INFO64, (host_info64_t)&memory, &count);
    vm_size_t page = 0; kern_return_t pageStatus = host_page_size(host, &page);
    if (status == KERN_SUCCESS && pageStatus == KERN_SUCCESS && page > 0) {
        result[@"memoryFree"] = @((uint64_t)memory.free_count * page);
        metrics[@"memoryActive"] = @((uint64_t)memory.active_count * page);
        metrics[@"memoryInactive"] = @((uint64_t)memory.inactive_count * page);
        metrics[@"memoryWired"] = @((uint64_t)memory.wire_count * page);
        metrics[@"memoryCompressed"] = @((uint64_t)memory.compressor_page_count * page);
        metrics[@"memoryPurgeable"] = @((uint64_t)memory.purgeable_count * page);
    } else { issues[@"memory"] = SSFailure(@"整机内存页统计", status != KERN_SUCCESS ? status : pageStatus); }
    result[@"memoryTotal"] = @(NSProcessInfo.processInfo.physicalMemory);
    mach_port_deallocate(mach_task_self(), host);
    SSNetwork(result, issues); SSDisk(result, issues);
    SSHardwareMetrics(metrics, issues);
    [metrics addEntriesFromDictionary:SSHardwareIdentity()];
    metrics[@"processorCount"] = @(NSProcessInfo.processInfo.processorCount);
    metrics[@"activeProcessorCount"] = @(NSProcessInfo.processInfo.activeProcessorCount);
    metrics[@"lowPowerMode"] = @(NSProcessInfo.processInfo.lowPowerModeEnabled);
    double loads[3] = {0}; int loadCount = getloadavg(loads, 3);
    for (int i = 0; i < loadCount; i++) if (isfinite(loads[i]) && loads[i] >= 0) metrics[[@[@"load1", @"load5", @"load15"] objectAtIndex:i]] = @(loads[i]);
    NSError *storageError = nil;
    NSDictionary *storage = [NSFileManager.defaultManager attributesOfFileSystemForPath:NSHomeDirectory() error:&storageError];
    if (storage[NSFileSystemSize]) metrics[@"storageTotal"] = storage[NSFileSystemSize];
    if (storage[NSFileSystemFreeSize]) metrics[@"storageFree"] = storage[NSFileSystemFreeSize];
    result[@"metrics"] = metrics;
}
static void SSApplication(NSString *bundleID, NSMutableDictionary *result, NSMutableDictionary *issues) {
    pid_t pid = SSPID(bundleID);
    if (pid <= 0) { issues[@"application"] = @"未能取得应用 PID：应用可能未运行，或系统未允许查询"; return; }
    result[@"pid"] = @(pid);
    typedef int (*Usage)(int, int, void *);
    typedef int (*PIDInfo)(int, int, uint64_t, void *, int);
    static Usage usage; static PIDInfo pidInfo; static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *library = dlopen("/usr/lib/libproc.dylib", RTLD_LAZY | RTLD_LOCAL);
        usage = (Usage)dlsym(library ?: RTLD_DEFAULT, "proc_pid_rusage");
        pidInfo = (PIDInfo)dlsym(library ?: RTLD_DEFAULT, "proc_pidinfo");
    });
    NSMutableDictionary *metrics = [NSMutableDictionary dictionary];
    result[@"metrics"] = metrics;
    SSProcessTask task = {0}; errno = 0;
    int taskSize = pidInfo ? pidInfo(pid, 4, 0, &task, sizeof(task)) : -1;
    if (taskSize == sizeof(task)) {
        if (task.threads > 0) metrics[@"processThreads"] = @(task.threads);
        if (task.runningThreads >= 0) metrics[@"processRunningThreads"] = @(task.runningThreads);
        // These are lifetime counters, not rates or a fabricated recording.
        if (task.faults >= 0) metrics[@"processFaults"] = @(task.faults);
        if (task.contextSwitches >= 0) metrics[@"processContextSwitches"] = @(task.contextSwitches);
        metrics[@"processVirtual"] = @(task.virtualSize);
    } else { issues[@"processDetails"] = SSFailure(@"所选进程线程与计数", pidInfo ? (errno ?: ENODATA) : ENOSYS); }
    SSProcessUsage value = {0}; errno = 0;
    int status = usage ? usage(pid, 2, &value) : -1;
    if (usage && status == 0) {
        result[@"processCPUTime"] = @((double)value.user + (double)value.system);
        result[@"processMemory"] = @(value.footprint);
        result[@"processStarted"] = @(value.started);
        result[@"diskRead"] = @(value.diskRead); result[@"diskWritten"] = @(value.diskWritten);
        metrics[@"processResident"] = @(value.resident); metrics[@"processWired"] = @(value.wired);
        metrics[@"processIdleWakeups"] = @(value.packageWakeups); metrics[@"processInterruptWakeups"] = @(value.interruptWakeups);
        metrics[@"processPageins"] = @(value.pageins);
        return;
    }
    int failure = usage ? errno : ENOSYS;
    if (pid != getpid()) { issues[@"application"] = SSFailure(@"所选应用进程数据（系统权限限制）", failure); return; }
    // Own-process fallback uses a task port we already possess; never substitute
    // these values for a selected third-party application.
    task_vm_info_data_t vm = {0}; mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vm, &count) == KERN_SUCCESS) result[@"processMemory"] = @(vm.phys_footprint);
    task_absolutetime_info_data_t times = {0}; count = TASK_ABSOLUTETIME_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_ABSOLUTETIME_INFO, (task_info_t)&times, &count) == KERN_SUCCESS) {
        mach_timebase_info_data_t base = {0};
        if (mach_timebase_info(&base) == KERN_SUCCESS && base.denom > 0) {
            result[@"processCPUTime"] = @(((double)times.total_user + times.total_system) * base.numer / base.denom);
        }
    }
    if (!result[@"processMemory"] && !result[@"processCPUTime"]) issues[@"application"] = SSFailure(@"本应用进程数据", failure);
}
@implementation LocalPerformance
+ (NSDictionary<NSString *, id> *)sensorsSnapshot { return SSReadSensors(); }
+ (NSDictionary<NSString *, id> *)snapshotForBundleID:(NSString *)bundleID {
    NSMutableDictionary *result = [@{@"timestamp":@(NSDate.date.timeIntervalSince1970), @"uptime":@(NSProcessInfo.processInfo.systemUptime)} mutableCopy];
    NSMutableDictionary *issues = [NSMutableDictionary dictionary];
    if (bundleID.length) { SSApplication(bundleID, result, issues); }
    else { SSDevice(result, issues); }
    NSArray *thermal = @[@"正常", @"轻度发热", @"较热", @"严重发热"];
    NSInteger state = NSProcessInfo.processInfo.thermalState;
    if (state >= 0 && state < (NSInteger)thermal.count) result[@"thermal"] = thermal[state];
    result[@"issues"] = issues;
    return result;
}
+ (NSArray<NSDictionary<NSString *, NSString *> *> *)applications {
    SSLoadFrameworks();
    NSMutableArray *result = [NSMutableArray array];
    @try {
        id workspace = SSObject(NSClassFromString(@"LSApplicationWorkspace"), @"defaultWorkspace");
        id applications = SSObject(workspace, @"allInstalledApplications");
        if ([applications isKindOfClass:NSArray.class]) for (id application in applications) {
            id identifier = SSObject(application, @"bundleIdentifier"), name = SSObject(application, @"localizedName");
            if (![identifier isKindOfClass:NSString.class] || ![identifier length]) continue;
            NSString *displayName = [identifier isEqualToString:NSBundle.mainBundle.bundleIdentifier] ? @"ssstore（本应用）"
                : [name isKindOfClass:NSString.class] ? name : identifier;
            [result addObject:@{@"bundleID":identifier, @"name":displayName}];
        }
    } @catch (NSException *exception) { }
    NSString *own = NSBundle.mainBundle.bundleIdentifier;
    // Include the app itself even if LaunchServices enumeration is denied.
    BOOL includesOwn = NO;
    for (NSDictionary *entry in result) if ([entry[@"bundleID"] isEqualToString:own]) { includesOwn = YES; break; }
    if (own.length && !includesOwn) [result addObject:@{@"bundleID":own, @"name":@"ssstore（本应用）"}];
    return result;
}
@end
