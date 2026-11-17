#import "LocalPerformance.h"
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
    } else { issues[@"memory"] = SSFailure(@"整机内存页统计", status != KERN_SUCCESS ? status : pageStatus); }
    result[@"memoryTotal"] = @(NSProcessInfo.processInfo.physicalMemory);
    mach_port_deallocate(mach_task_self(), host);
    SSNetwork(result, issues); SSDisk(result, issues);
}
static void SSApplication(NSString *bundleID, NSMutableDictionary *result, NSMutableDictionary *issues) {
    pid_t pid = SSPID(bundleID);
    if (pid <= 0) { issues[@"application"] = @"未能取得应用 PID：应用可能未运行，或系统未允许查询"; return; }
    result[@"pid"] = @(pid);
    typedef int (*Usage)(int, int, void *);
    static Usage usage; static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *library = dlopen("/usr/lib/libproc.dylib", RTLD_LAZY | RTLD_LOCAL);
        usage = (Usage)dlsym(library ?: RTLD_DEFAULT, "proc_pid_rusage");
    });
    SSProcessUsage value = {0}; errno = 0;
    int status = usage ? usage(pid, 2, &value) : -1;
    if (usage && status == 0) {
        result[@"processCPUTime"] = @((double)value.user + (double)value.system);
        result[@"processMemory"] = @(value.footprint);
        result[@"processStarted"] = @(value.started);
        result[@"diskRead"] = @(value.diskRead); result[@"diskWritten"] = @(value.diskWritten);
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
