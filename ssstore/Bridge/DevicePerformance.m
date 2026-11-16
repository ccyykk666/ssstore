#import "DevicePerformance.h"
@import IDevice;
#include <arpa/inet.h>

static BOOL PCheck(IdeviceFfiError *failure, NSString *stage, NSError **error) {
    if (!failure) return YES;
    NSString *message = failure->message ? [NSString stringWithUTF8String:failure->message] : @"未知错误";
    if (error) *error = [NSError errorWithDomain:@"ssstore.Performance" code:failure->code userInfo:@{
        NSLocalizedDescriptionKey:[NSString stringWithFormat:@"%@失败（%d/%d）：%@", stage, failure->code, failure->sub_code, message]}];
    idevice_error_free(failure);
    return NO;
}
static id PPlist(plist_t node) {
    if (!node) return NSNull.null;
    char *xml = NULL; uint32_t length = 0;
    plist_to_xml(node, &xml, &length);
    if (!xml) return NSNull.null;
    NSData *data = [NSData dataWithBytes:xml length:length]; plist_mem_free(xml);
    return [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL] ?: NSNull.null;
}
static NSDictionary *PAttributes(NSArray *keys, id values) {
    if (![values isKindOfClass:NSArray.class]) return @{};
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < MIN(keys.count, [values count]); i++) result[keys[i]] = values[i];
    return result;
}
static NSArray *PNames(char **names, uintptr_t count) {
    NSMutableArray *result = [NSMutableArray array];
    for (uintptr_t i = 0; i < count; i++) [result addObject:names[i] ? [NSString stringWithUTF8String:names[i]] : @""];
    return result;
}

@implementation DevicePerformance
+ (BOOL)streamPairingPath:(NSString *)path host:(NSString *)host port:(uint16_t)port
             isCancelled:(BOOL (^)(void))isCancelled sample:(void (^)(NSData *))sample error:(NSError **)error {
    // All handles stay on this worker thread. Cancellation closes only the
    // Swift-owned transport relay; it never frees or mutates an in-flight FFI handle.
    struct sockaddr_in address = {0}; address.sin_len = sizeof(address);
    address.sin_family = AF_INET; address.sin_port = htons(port);
    if (inet_pton(AF_INET, host.UTF8String, &address.sin_addr) != 1) return NO;
    struct RpPairingFileHandle *pairing = NULL;
    struct AdapterHandle *adapter = NULL;
    struct RsdHandshakeHandle *handshake = NULL;
    struct RemoteServerHandle *server = NULL;
    struct DeviceInfoHandle *device = NULL;
    struct SysmontapHandle *tap = NULL;
    char **processNames = NULL, **systemNames = NULL;
    uintptr_t processCount = 0, systemCount = 0;
    struct IdeviceRunningProcess **running = NULL; uintptr_t runningCount = 0;
    plist_t hardware = NULL, processes = NULL, system = NULL, cpu = NULL;
    BOOL started = NO;
    @try {
        if (isCancelled()) return YES;
        if (!PCheck(rp_pairing_file_read(path.UTF8String, &pairing), @"读取配对文件", error)) return NO;
        if (!PCheck(tunnel_create_rppairing((const idevice_sockaddr *)&address, sizeof(address), "ssstore-performance",
                    pairing, NULL, NULL, &adapter, &handshake), @"连接性能通道", error)) return NO;
        if (isCancelled()) return YES;
        if (!PCheck(remote_server_connect_rsd(adapter, handshake, &server), @"连接开发者性能服务", error)) return NO;
        if (!PCheck(device_info_new(server, &device), @"读取采样能力", error)) return NO;
        if (!PCheck(device_info_sysmon_process_attributes(device, &processNames, &processCount), @"读取进程采样字段", error)) return NO;
        if (!PCheck(device_info_sysmon_system_attributes(device, &systemNames, &systemCount), @"读取整机采样字段", error)) return NO;
        IdeviceFfiError *optional = device_info_hardware_information(device, &hardware);
        if (optional) idevice_error_free(optional);
        NSMutableDictionary *labels = [NSMutableDictionary dictionary];
        optional = device_info_running_processes(device, &running, &runningCount);
        if (optional) idevice_error_free(optional);
        else {
            for (uintptr_t i = 0; i < runningCount; i++) {
                if (running[i]->name) labels[[NSString stringWithFormat:@"%llu", (unsigned long long)running[i]->pid]] =
                    [NSString stringWithUTF8String:running[i]->name] ?: @"";
            }
        }
        device_info_running_processes_free(running, runningCount); running = NULL; runningCount = 0;
        // A DVT child borrows its parent; dispose this child before opening the tap.
        device_info_free(device); device = NULL;
        if (isCancelled()) return YES;
        if (!PCheck(sysmontap_new(server, &tap), @"创建整机性能采样", error)) return NO;
        struct IdeviceSysmontapConfig config = {0};
        config.interval_ms = 1000;
        config.process_attributes = (const char *const *)processNames; config.process_attributes_count = processCount;
        config.system_attributes = (const char *const *)systemNames; config.system_attributes_count = systemCount;
        if (!PCheck(sysmontap_set_config(tap, &config), @"配置性能采样", error)) return NO;
        if (!PCheck(sysmontap_start(tap), @"启动性能采样", error)) return NO;
        started = YES;
        NSArray *processKeys = PNames(processNames, processCount), *systemKeys = PNames(systemNames, systemCount);
        while (!isCancelled()) {
            @autoreleasepool {
                if (!PCheck(sysmontap_next_sample(tap, &processes, &system, &cpu), @"接收性能采样", error)) return NO;
                if (isCancelled()) return YES;
                NSMutableArray *rows = [NSMutableArray array];
                id rawProcesses = PPlist(processes);
                if ([rawProcesses isKindOfClass:NSDictionary.class]) {
                    for (NSString *pid in rawProcesses) {
                        NSMutableDictionary *values = [PAttributes(processKeys, rawProcesses[pid]) mutableCopy];
                        if (!values[@"name"] && labels[[pid description]]) values[@"name"] = labels[[pid description]];
                        [rows addObject:@{@"pid":[pid description], @"values":values}];
                    }
                }
                NSDictionary *payload = @{@"timestamp":@(NSDate.date.timeIntervalSince1970),
                    @"uptime":@(NSProcessInfo.processInfo.systemUptime), @"system":PAttributes(systemKeys, PPlist(system)),
                    @"cpu":PPlist(cpu), @"processes":rows, @"hasProcesses":@([rawProcesses isKindOfClass:NSDictionary.class]),
                    @"hardware":PPlist(hardware)};
                NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:error];
                plist_free(processes); processes = NULL; plist_free(system); system = NULL; plist_free(cpu); cpu = NULL;
                if (!data) return NO;
                sample(data);
            }
        }
        return YES;
    } @finally {
        // A cancelled/expired transport is already closed. Do not wait for a stop reply.
        if (started && !isCancelled()) { IdeviceFfiError *ignored = sysmontap_stop(tap); if (ignored) idevice_error_free(ignored); }
        plist_free(processes); plist_free(system); plist_free(cpu); plist_free(hardware);
        device_info_running_processes_free(running, runningCount);
        sysmontap_free(tap); device_info_free(device); remote_server_free(server);
        rsd_handshake_free(handshake); adapter_free(adapter); rp_pairing_file_free(pairing);
        device_info_string_array_free(processNames, processCount); device_info_string_array_free(systemNames, systemCount);
    }
}
@end
