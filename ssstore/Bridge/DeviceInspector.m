#import "DeviceInspector.h"
@import IDevice;
#import "DevicePlist.h"
#import <Security/Security.h>
#include <arpa/inet.h>

static void IError(NSError **error, NSString *text) {
    if (error) *error = [NSError errorWithDomain:@"ssstore.Inspection" code:1 userInfo:@{NSLocalizedDescriptionKey:text}];
}
static BOOL ICheck(IdeviceFfiError *failure, NSString *stage, NSError **error) {
    if (!failure) return YES;
    NSString *message = failure->message ? [NSString stringWithUTF8String:failure->message] : @"未知错误";
    if (error) *error = [NSError errorWithDomain:@"ssstore.Inspection" code:failure->code userInfo:@{NSLocalizedDescriptionKey:
        [NSString stringWithFormat:@"%@失败（%d/%d）：%@", stage, failure->code, failure->sub_code, message]}];
    idevice_error_free(failure);
    return NO;
}
static NSString *IString(const char *text) { return text ? ([NSString stringWithUTF8String:text] ?: @"") : @""; }
static id IPlist(plist_t node) { return SSDevicePlistValue(node); }
static id IJSON(id value) {
    if (!value) return NSNull.null;
    if ([value isKindOfClass:NSDate.class]) return [[NSISO8601DateFormatter new] stringFromDate:value];
    if ([value isKindOfClass:NSData.class]) {
        id decoded = [NSPropertyListSerialization propertyListWithData:value options:0 format:NULL error:NULL];
        return decoded ? IJSON(decoded) : @{@"类型":@"二进制", @"字节数":@([value length])};
    }
    if ([value isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *result = [NSMutableDictionary dictionary];
        for (id key in value) result[[key description]] = IJSON(value[key]);
        return result;
    }
    if ([value isKindOfClass:NSArray.class]) {
        NSMutableArray *result = [NSMutableArray array];
        for (id item in value) [result addObject:IJSON(item)];
        return result;
    }
    if ([value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class] || value == NSNull.null) return value;
    return [value description];
}
static NSDictionary *IFile(NSData *data, NSString *name, NSString *folder, NSError **error) {
    if (![NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:error]) return nil;
    NSString *path = [folder stringByAppendingPathComponent:name.lastPathComponent];
    if (![data writeToFile:path options:NSDataWritingAtomic | NSDataWritingFileProtectionComplete error:error]) return nil;
    return @{@"path":path, @"name":name.lastPathComponent};
}
static void IFreeStrings(char **strings, size_t count) {
    if (!strings) return;
    for (size_t i = 0; i < count; i++) idevice_string_free(strings[i]);
    SSDeviceArrayStorageFree(strings, count);
}

@interface InspectionConnection : NSObject {
@public
    struct AdapterHandle *adapter;
    struct RsdHandshakeHandle *handshake;
    struct RpPairingFileHandle *remotePair;
}
@end
@implementation InspectionConnection
- (void)dealloc {
    rsd_handshake_free(handshake); adapter_free(adapter);
    rp_pairing_file_free(remotePair);
}
@end

#define REQUIRE(call, stage) if (!ICheck((call), (stage), error)) return nil
#define CONNECT(base, handle) base##_connect_rsd(c->adapter, c->handshake, &(handle))
#define PROBE_SERVICE(base, handle, release, label) { \
    NSError *local = nil; \
    BOOL ok = ICheck(base##_connect_rsd(c->adapter, c->handshake, &(handle)), (label), &local); \
    [rows addObject:@{@"服务":(label), @"接口":@#base, @"连接成功":@(ok), @"结果":ok ? @"连接成功，读取权限待验证" : local.localizedDescription}]; \
    release(handle); handle = NULL; \
}

@implementation DeviceInspector
+ (NSData *)runPairingPath:(NSString *)path host:(NSString *)host port:(uint16_t)port
                operation:(NSString *)op options:(NSDictionary *)options outputDirectory:(NSString *)folder error:(NSError **)error {
    struct sockaddr_in address = {0}; address.sin_len = sizeof(address); address.sin_family = AF_INET; address.sin_port = htons(port);
    if (inet_pton(AF_INET, host.UTF8String, &address.sin_addr) != 1) { IError(error, @"请输入有效 IPv4 地址。"); return nil; }
    InspectionConnection *c = [InspectionConnection new];
    REQUIRE(rp_pairing_file_read(path.UTF8String, &c->remotePair), @"读取配对文件");
    REQUIRE(tunnel_create_rppairing((const idevice_sockaddr *)&address, sizeof(address), "ssstore-inspect",
                                   c->remotePair, NULL, NULL, &c->adapter, &c->handshake), @"认证设备通道");
    struct InstallationProxyClientHandle *installation = NULL;
    struct SpringBoardServicesClientHandle *spring = NULL;
    struct MisagentClientHandle *misagent = NULL;
    struct AfcClientHandle *afc = NULL;
    struct CrashReportCopyMobileHandle *crash = NULL;
    struct LockdowndClientHandle *lockdown = NULL;
    struct DiagnosticsRelayClientHandle *diagnostics = NULL;
    struct AppServiceHandle *appService = NULL;
    struct ConfigurationServiceHandle *config = NULL;
    struct ImageMounterHandle *mounter = NULL;
    struct CompanionProxyClientHandle *companion = NULL;
    struct AfcFileHandle *fileHandle = NULL;
    struct CRsdServiceArray *services = NULL;
    struct AppListEntryC *nativeApps = NULL; uintptr_t nativeCount = 0;
    struct ProcessTokenC *processes = NULL; uintptr_t processCount = 0;
    plist_t plist = NULL, query = NULL; plist_t *nodes = NULL; size_t nodeCount = 0;
    uint8_t **profileData = NULL; size_t *profileLengths = NULL, profileCount = 0;
    char **strings = NULL; size_t stringCount = 0;
    uint8_t *bytes = NULL; size_t byteCount = 0;
    NSString *bundle = [options[@"bundleID"] isKindOfClass:NSString.class] ? options[@"bundleID"] : @"";
    NSString *remotePath = [options[@"path"] isKindOfClass:NSString.class] ? options[@"path"] : @"/";
    id value = NSNull.null;
    NSMutableArray *files = [NSMutableArray array], *entries = [NSMutableArray array];
    NSString *message = nil;
    @try {
        if ([op isEqualToString:@"probe"]) {
            NSMutableArray *rows = [NSMutableArray array];
            PROBE_SERVICE(installation_proxy, installation, installation_proxy_client_free, @"应用资料");
            PROBE_SERVICE(springboard_services, spring, springboard_services_free, @"SpringBoard");
            PROBE_SERVICE(misagent, misagent, misagent_client_free, @"描述文件");
            PROBE_SERVICE(afc_client, afc, afc_client_free, @"AFC 文件");
            PROBE_SERVICE(crash_report_client, crash, crash_report_client_free, @"崩溃报告");
            PROBE_SERVICE(lockdownd, lockdown, lockdownd_client_free, @"设备资料");
            PROBE_SERVICE(diagnostics_relay_client, diagnostics, diagnostics_relay_client_free, @"诊断");
            PROBE_SERVICE(app_service, appService, app_service_free, @"CoreDevice 应用");
            PROBE_SERVICE(configuration_service, config, configuration_service_free, @"显示配置");
            PROBE_SERVICE(image_mounter, mounter, image_mounter_free, @"开发镜像");
            PROBE_SERVICE(companion_proxy, companion, companion_proxy_client_free, @"伴侣设备");
            value = rows;
        }
        else if ([op isEqualToString:@"services"]) {
            REQUIRE(rsd_get_services(c->handshake, &services), @"发现服务");
            NSMutableArray *rows = [NSMutableArray array];
            for (size_t i = 0; i < services->count; i++) {
                struct CRsdService *s = &services->services[i];
                NSMutableArray *features = [NSMutableArray array];
                for (size_t j = 0; j < s->features_count; j++) [features addObject:IString(s->features[j])];
                [rows addObject:@{@"name":IString(s->name), @"port":@(s->port), @"requiredEntitlement":IString(s->entitlement),
                                 @"remoteXPC":@(s->uses_remote_xpc), @"features":features, @"version":@(s->service_version)}];
            }
            value = rows;
        } else if ([@[@"appDetails", @"appCapabilities", @"appStorage", @"allStorage"] containsObject:op]) {
            REQUIRE(CONNECT(installation_proxy, installation), @"连接应用信息服务");
            query = plist_new_dict(); plist_dict_set_item(query, "ApplicationType", plist_new_string("Any"));
            if ([op isEqualToString:@"appStorage"] || [op isEqualToString:@"allStorage"]) {
                plist_t attrs = plist_new_array();
                for (NSString *key in @[@"CFBundleIdentifier", @"CFBundleDisplayName", @"CFBundleName", @"StaticDiskUsage", @"DynamicDiskUsage"]) {
                    plist_array_append_item(attrs, plist_new_string(key.UTF8String));
                }
                plist_dict_set_item(query, "ReturnAttributes", attrs);
            }
            REQUIRE(installation_proxy_browse(installation, query, &nodes, &nodeCount), @"读取应用资料");
            NSMutableArray *rows = [NSMutableArray array];
            NSSet *capabilityKeys = [NSSet setWithArray:@[@"CFBundleIdentifier", @"CFBundleDisplayName", @"ApplicationType", @"Entitlements",
                @"MinimumOSVersion", @"UIDeviceFamily", @"UIFileSharingEnabled", @"CFBundleURLTypes", @"CFBundleDocumentTypes",
                @"SignerIdentity", @"DTXcode", @"DTXcodeBuild", @"CFBundleSupportedPlatforms", @"GroupContainers", @"IsUpgradeable"]];
            for (size_t i = 0; i < nodeCount; i++) {
                id row = IPlist(nodes[i]);
                if (![row isKindOfClass:NSDictionary.class]) continue;
                if (bundle.length && ![row[@"CFBundleIdentifier"] isEqualToString:bundle]) continue;
                if ([op isEqualToString:@"appCapabilities"]) {
                    NSMutableDictionary *selected = [NSMutableDictionary dictionary];
                    for (NSString *key in row) if ([capabilityKeys containsObject:key]) selected[key] = row[key];
                    [rows addObject:selected];
                } else { [rows addObject:row]; }
            }
            if ([op isEqualToString:@"appStorage"] || [op isEqualToString:@"allStorage"]) {
                [rows sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                    unsigned long long x = [a[@"StaticDiskUsage"] unsignedLongLongValue] + [a[@"DynamicDiskUsage"] unsignedLongLongValue];
                    unsigned long long y = [b[@"StaticDiskUsage"] unsignedLongLongValue] + [b[@"DynamicDiskUsage"] unsignedLongLongValue];
                    return x > y ? NSOrderedAscending : x < y ? NSOrderedDescending : NSOrderedSame;
                }];
            }
            value = rows;
            if (bundle.length && rows.count == 0) message = @"设备未返回此应用，请重新读取应用清单。";
        }
        else if ([op isEqualToString:@"profiles"]) {
            REQUIRE(CONNECT(misagent, misagent), @"连接描述文件服务");
            REQUIRE(misagent_copy_all(misagent, &profileData, &profileLengths, &profileCount), @"读取描述文件");
            NSMutableArray *rows = [NSMutableArray array];
            for (size_t i = 0; i < profileCount; i++) {
                NSData *data = [NSData dataWithBytes:profileData[i] length:profileLengths[i]];
                id decoded = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL];
                if (!decoded) {
                    NSData *begin = [@"<?xml" dataUsingEncoding:NSUTF8StringEncoding];
                    NSData *end = [@"</plist>" dataUsingEncoding:NSUTF8StringEncoding];
                    NSRange a = [data rangeOfData:begin options:0 range:NSMakeRange(0, data.length)];
                    if (a.location != NSNotFound) {
                        NSRange b = [data rangeOfData:end options:0 range:NSMakeRange(a.location, data.length - a.location)];
                        if (b.location != NSNotFound) {
                            NSData *payload = [data subdataWithRange:NSMakeRange(a.location, NSMaxRange(b) - a.location)];
                            decoded = [NSPropertyListSerialization propertyListWithData:payload options:0 format:NULL error:NULL];
                        }
                    }
                }
                NSString *name = [NSString stringWithFormat:@"profile-%lu.mobileprovision", (unsigned long)i + 1];
                NSDictionary *file = IFile(data, name, folder, error); if (!file) return nil;
                [files addObject:file];
                NSMutableDictionary *row = [@{@"文件":name, @"内容":decoded ?: @"无法解析 plist，可导出原文件", @"字节数":@(data.length)} mutableCopy];
                if ([decoded isKindOfClass:NSDictionary.class]) {
                    if ([decoded[@"Name"] isKindOfClass:NSString.class]) row[@"Name"] = decoded[@"Name"];
                    if ([decoded[@"ExpirationDate"] isKindOfClass:NSDate.class]) row[@"描述文件已过期"] = @([decoded[@"ExpirationDate"] timeIntervalSinceNow] < 0);
                    NSMutableArray *certificates = [NSMutableArray array];
                    if ([decoded[@"DeveloperCertificates"] isKindOfClass:NSArray.class]) {
                        for (NSData *certificateData in decoded[@"DeveloperCertificates"]) {
                            if (![certificateData isKindOfClass:NSData.class]) continue;
                            SecCertificateRef certificate = SecCertificateCreateWithData(NULL, (__bridge CFDataRef)certificateData);
                            if (certificate) {
                                NSString *subject = CFBridgingRelease(SecCertificateCopySubjectSummary(certificate));
                                [certificates addObject:subject ?: @"未提供证书主题"]; CFRelease(certificate);
                            }
                        }
                    }
                    row[@"开发证书主题"] = certificates;
                }
                [rows addObject:row];
            }
            value = rows; message = @"描述文件有效期不代表证书有效期；未验证证书信任或撤销状态。";
        }
        else if ([@[@"icon", @"homeWallpaper", @"lockWallpaper", @"iconMetrics", @"orientation"] containsObject:op]) {
            IdeviceFfiError *failure = CONNECT(springboard_services, spring);
            if (!ICheck(failure, @"连接 SpringBoard 服务", error)) return nil;
            if ([op isEqualToString:@"iconMetrics"]) {
                REQUIRE(springboard_services_get_homescreen_icon_metrics(spring, &plist), @"读取图标参数"); value = IPlist(plist);
            } else if ([op isEqualToString:@"orientation"]) {
                uint8_t orientation = 0;
                REQUIRE(springboard_services_get_interface_orientation(spring, &orientation), @"读取屏幕方向");
                value = @{@"方向值":@(orientation), @"说明":@"0 未知；1 竖屏；2 倒置竖屏；3 横屏 Home 键在右；4 横屏 Home 键在左"};
            } else {
                if ([op isEqualToString:@"icon"]) {
                    if (!bundle.length) { IError(error, @"请选择一个应用。"); return nil; }
                    REQUIRE(springboard_services_get_icon(spring, bundle.UTF8String, (void **)&bytes, &byteCount), @"读取本地图标");
                } else if ([op isEqualToString:@"homeWallpaper"]) {
                    REQUIRE(springboard_services_get_home_screen_wallpaper_preview(spring, (void **)&bytes, &byteCount), @"读取主屏幕墙纸");
                } else {
                    REQUIRE(springboard_services_get_lock_screen_wallpaper_preview(spring, (void **)&bytes, &byteCount), @"读取锁定屏幕墙纸");
                }
                NSDictionary *file = IFile([NSData dataWithBytes:bytes length:byteCount], [op stringByAppendingString:@".png"], folder, error);
                if (!file) return nil; [files addObject:file]; value = @{@"字节数":@(byteCount)};
            }
        }
        else if ([@[@"deviceInfo", @"batteryInfo", @"diskInfo"] containsObject:op]) {
            REQUIRE(CONNECT(lockdownd, lockdown), @"连接 Lockdown 信息服务");
            const char *domain = [op isEqualToString:@"batteryInfo"] ? "com.apple.mobile.battery" :
                                 [op isEqualToString:@"diskInfo"] ? "com.apple.disk_usage" : NULL;
            REQUIRE(lockdownd_get_value(lockdown, NULL, domain, &plist), @"读取设备资料"); value = IPlist(plist);
        }
        else if ([@[@"diagnostics", @"batteryDiagnostics", @"nandDiagnostics", @"wifiDiagnostics", @"mobileGestalt", @"ioRegistry"] containsObject:op]) {
            REQUIRE(CONNECT(diagnostics_relay_client, diagnostics), @"连接诊断服务");
            if ([op isEqualToString:@"batteryDiagnostics"]) { REQUIRE(diagnostics_relay_client_gasguage(diagnostics, &plist), @"读取电池诊断"); }
            else if ([op isEqualToString:@"nandDiagnostics"]) { REQUIRE(diagnostics_relay_client_nand(diagnostics, &plist), @"读取存储诊断"); }
            else if ([op isEqualToString:@"wifiDiagnostics"]) { REQUIRE(diagnostics_relay_client_wifi(diagnostics, &plist), @"读取 Wi-Fi 诊断"); }
            else if ([op isEqualToString:@"mobileGestalt"]) { REQUIRE(diagnostics_relay_client_mobilegestalt(diagnostics, NULL, 0, &plist), @"读取硬件能力"); }
            else if ([op isEqualToString:@"ioRegistry"]) { REQUIRE(diagnostics_relay_client_ioregistry(diagnostics, NULL, NULL, NULL, &plist), @"读取 IORegistry"); }
            else { REQUIRE(diagnostics_relay_client_all(diagnostics, &plist), @"读取综合诊断"); }
            value = IPlist(plist);
        }
        else if ([@[@"coreApps", @"coreProcesses"] containsObject:op]) {
            REQUIRE(app_service_connect_rsd(c->adapter, c->handshake, &appService), @"连接 CoreDevice 应用服务");
            NSMutableArray *rows = [NSMutableArray array];
            if ([op isEqualToString:@"coreApps"]) {
                REQUIRE(app_service_list_apps(appService, 1, 1, 1, 1, 1, &nativeApps, &nativeCount), @"读取 CoreDevice 应用列表");
                for (uintptr_t i = 0; i < nativeCount; i++) {
                    struct AppListEntryC *a = &nativeApps[i];
                    [rows addObject:@{@"bundleIdentifier":IString(a->bundle_identifier), @"name":IString(a->name), @"path":IString(a->path),
                        @"version":IString(a->version), @"bundleVersion":IString(a->bundle_version), @"isRemovable":@(a->is_removable),
                        @"isFirstParty":@(a->is_first_party), @"isDeveloperApp":@(a->is_developer_app), @"isInternal":@(a->is_internal),
                        @"isHidden":@(a->is_hidden), @"isAppClip":@(a->is_app_clip)}];
                }
            } else {
                REQUIRE(app_service_list_processes(appService, &processes, &processCount), @"读取进程列表");
                for (uintptr_t i = 0; i < processCount; i++) {
                    [rows addObject:@{@"pid":@(processes[i].pid), @"executableURL":IString(processes[i].executable_url)}];
                }
            }
            value = rows;
        }
        else if ([op isEqualToString:@"configuration"]) {
            REQUIRE(configuration_service_connect_rsd(c->adapter, c->handshake, &config), @"连接显示配置服务");
            NSMutableDictionary *fields = [NSMutableDictionary dictionary]; NSError *local = nil;
            enum IdeviceUserInterfaceStyle style;
            if (ICheck(configuration_service_get_user_interface_style(config, &style), @"外观", &local)) fields[@"外观"] = style == IdeviceUserInterfaceStyleDark ? @"深色" : @"浅色";
            else fields[@"外观"] = local.localizedDescription;
            char *size = NULL;
            if (ICheck(configuration_service_get_device_text_size(config, &size), @"文字大小", &local)) fields[@"文字大小"] = IString(size);
            else fields[@"文字大小"] = local.localizedDescription;
            idevice_string_free(size);
            struct ColorFilterC filter = {0};
            if (ICheck(configuration_service_get_color_filter(config, &filter), @"色彩滤镜", &local)) {
                fields[@"色彩滤镜"] = @{@"启用":@(filter.enabled), @"类型":IString(filter.filter_type), @"强度":filter.has_intensity ? @(filter.intensity) : NSNull.null};
            } else fields[@"色彩滤镜"] = local.localizedDescription;
            idevice_string_free(filter.filter_type);
            int enabled = 0;
            if (ICheck(configuration_service_get_reduce_motion(config, &enabled), @"减弱动态效果", &local)) fields[@"减弱动态效果"] = @(enabled);
            else fields[@"减弱动态效果"] = local.localizedDescription;
            if (ICheck(configuration_service_get_reduce_transparency(config, &enabled), @"降低透明度", &local)) fields[@"降低透明度"] = @(enabled);
            else fields[@"降低透明度"] = local.localizedDescription;
            if (ICheck(configuration_service_get_show_borders(config, &enabled), @"布局调试边框", &local)) fields[@"布局调试边框"] = @(enabled);
            else fields[@"布局调试边框"] = local.localizedDescription;
            value = fields;
        }
        else if ([@[@"developerMode", @"mountedImages"] containsObject:op]) {
            REQUIRE(CONNECT(image_mounter, mounter), @"连接开发镜像服务");
            if ([op isEqualToString:@"developerMode"]) {
                int enabled = 0; REQUIRE(image_mounter_query_developer_mode_status(mounter, &enabled), @"查询开发者模式");
                value = @{@"已启用":@(enabled)};
            } else {
                REQUIRE(image_mounter_copy_devices(mounter, &nodes, &nodeCount), @"读取已挂载镜像");
                NSMutableArray *rows = [NSMutableArray array];
                for (size_t i = 0; i < nodeCount; i++) [rows addObject:IPlist(nodes[i])];
                value = rows;
                if (rows.count == 0) message = @"未挂载开发镜像";
            }
        }
        else if ([op isEqualToString:@"companion"]) {
            REQUIRE(CONNECT(companion_proxy, companion), @"连接伴侣设备服务");
            REQUIRE(companion_proxy_get_device_registry(companion, &strings, &stringCount), @"读取伴侣设备");
            NSMutableArray *rows = [NSMutableArray array];
            for (size_t i = 0; i < stringCount; i++) [rows addObject:IString(strings[i])];
            value = rows;
        }
        else if ([@[@"media", @"crashes", @"filesystemInfo", @"fileInfo", @"fileRead"] containsObject:op]) {
            NSString *source = [options[@"source"] isKindOfClass:NSString.class] ? options[@"source"] : op;
            if ([source isEqualToString:@"crashes"]) {
                REQUIRE(CONNECT(crash_report_client, crash), @"连接崩溃报告服务");
                IdeviceFfiError *failure = crash_report_client_to_afc(crash, &afc);
                crash = NULL; REQUIRE(failure, @"打开报告目录");
            } else {
                REQUIRE(CONNECT(afc_client, afc), @"连接 AFC 文件服务");
            }
            if ([op isEqualToString:@"filesystemInfo"]) {
                struct AfcDeviceInfo info = {0};
                REQUIRE(afc_get_device_info(afc, &info), @"读取文件系统容量");
                value = @{@"型号":IString(info.model), @"总字节数":@(info.total_bytes), @"可用字节数":@(info.free_bytes), @"块大小":@(info.block_size)};
                afc_device_info_free(&info);
            } else if ([@[@"fileInfo", @"fileRead"] containsObject:op]) {
                struct AfcFileInfo info = {0};
                REQUIRE(afc_get_file_info(afc, remotePath.UTF8String, &info), @"读取文件属性");
                BOOL isDirectory = [IString(info.st_ifmt) isEqualToString:@"S_IFDIR"];
                BOOL isRegular = [IString(info.st_ifmt) isEqualToString:@"S_IFREG"];
                value = @{@"path":remotePath, @"isDirectory":@(isDirectory), @"size":@(info.size), @"blocks":@(info.blocks),
                    @"createdAt":[NSDate dateWithTimeIntervalSince1970:info.creation], @"modifiedAt":[NSDate dateWithTimeIntervalSince1970:info.modified],
                    @"type":IString(info.st_ifmt), @"links":IString(info.st_nlink), @"linkTarget":IString(info.st_link_target)};
                size_t fileSize = info.size;
                afc_file_info_free(&info);
                if ([op isEqualToString:@"fileRead"]) {
                    if (isDirectory) { IError(error, @"此项为目录，请打开目录。"); return nil; }
                    if (!isRegular) { IError(error, @"此类型不支持内容读取，请查看文件属性。"); return nil; }
                    const NSUInteger limit = 32 * 1024 * 1024;
                    if (fileSize > limit) { IError(error, @"文件过大。"); return nil; }
                    REQUIRE(afc_file_open(afc, remotePath.UTF8String, AfcRdOnly, &fileHandle), @"只读打开文件");
                    NSMutableData *data = [NSMutableData data];
                    while (YES) {
                        uint8_t *chunk = NULL; size_t length = 0;
                        IdeviceFfiError *failure = afc_file_read(fileHandle, &chunk, 64 * 1024, &length);
                        if (!ICheck(failure, @"读取文件", error)) { if (chunk) afc_file_read_data_free(chunk, length); return nil; }
                        if (data.length + length > limit) { if (chunk) afc_file_read_data_free(chunk, length); IError(error, @"文件过大。"); return nil; }
                        if (length) [data appendBytes:chunk length:length];
                        if (chunk) afc_file_read_data_free(chunk, length);
                        if (!length) break;
                    }
                    NSDictionary *file = IFile(data, remotePath.lastPathComponent.length ? remotePath.lastPathComponent : @"export.bin", folder, error);
                    if (!file) return nil; [files addObject:file];
                }
            } else {
                REQUIRE(afc_list_directory(afc, remotePath.UTF8String, &strings, &stringCount), @"读取目录");
                for (size_t i = 0; i < stringCount; i++) {
                    NSString *name = IString(strings[i]);
                    if (!name.length || [name isEqualToString:@"."] || [name isEqualToString:@".."] || [name containsString:@"/"]) continue;
                    NSString *child = [remotePath stringByAppendingPathComponent:name];
                    NSMutableDictionary *entry = [@{@"name":name, @"path":child} mutableCopy];
                    [entries addObject:entry];
                }
                value = @{@"路径":remotePath, @"条目数":@(entries.count)};
            }
        }
        else {
            IError(error, [NSString stringWithFormat:@"未实现的读取操作：%@", op]); return nil;
        }
        return [NSJSONSerialization dataWithJSONObject:@{@"value":IJSON(value), @"files":files, @"entries":entries,
            @"message":message ?: NSNull.null} options:0 error:error];
    } @finally {
        if (fileHandle) { IdeviceFfiError *e = afc_file_close(fileHandle); if (e) idevice_error_free(e); }
        if (bytes) idevice_data_free(bytes, byteCount);
        IFreeStrings(strings, stringCount);
        SSDevicePlistArrayFree(nodes, nodeCount); plist_free(plist); plist_free(query);
        misagent_free_profiles(profileData, profileLengths, profileCount);
        rsd_free_services(services);
        app_service_free_app_list(nativeApps, nativeCount); app_service_free_process_list(processes, processCount);
        installation_proxy_client_free(installation); springboard_services_free(spring); misagent_client_free(misagent);
        afc_client_free(afc); crash_report_client_free(crash);
        lockdownd_client_free(lockdown); diagnostics_relay_client_free(diagnostics); app_service_free(appService);
        configuration_service_free(config); image_mounter_free(mounter);
        companion_proxy_client_free(companion);
    }
}
@end


