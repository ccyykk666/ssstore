#import "DeviceScanner.h"
@import IDevice;
#include <arpa/inet.h>
#include <fcntl.h>
#include <errno.h>
#include <poll.h>
#include <unistd.h>
#import <CommonCrypto/CommonDigest.h>

static NSString *IconKey(NSDictionary *item) {
    NSString *identity = [NSString stringWithFormat:@"%@|%@|%@", item[@"CFBundleIdentifier"] ?: @"",
                          item[@"CFBundleShortVersionString"] ?: @"", item[@"CFBundleVersion"] ?: @""];
    NSData *input = [identity dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(input.bytes, (CC_LONG)input.length, digest);
    NSMutableString *key = [NSMutableString string];
    for (NSUInteger index = 0; index < sizeof(digest); index++) [key appendFormat:@"%02x", digest[index]];
    return key;
}

static NSDictionary *ReadPlist(plist_t node) {
    char *xml = NULL;
    uint32_t length = 0;
    plist_to_xml(node, &xml, &length);
    if (!xml) return nil;
    NSData *data = [NSData dataWithBytes:xml length:length];
    plist_mem_free(xml);
    id value = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL];
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

static void MergeStoreMetadata(NSMutableDictionary *item, NSDictionary *row) {
    id metadata = row[@"iTunesMetadata"];
    if ([metadata isKindOfClass:NSData.class]) {
        metadata = [NSPropertyListSerialization propertyListWithData:metadata options:0 format:NULL error:NULL];
    }
    if ([metadata isKindOfClass:NSDictionary.class]) {
        NSDictionary *keys = @{@"itemId": @"storeID", @"softwareVersionExternalIdentifier": @"externalVersionID",
                               @"bundleShortVersionString": @"MetadataVersion", @"bundleVersion": @"MetadataBuild"};
        for (NSString *key in keys) {
            id value = metadata[key];
            if ([value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class]) item[keys[key]] = [value description];
        }
    }
    NSDictionary *keys = @{@"ExternalVersionIdentifier": @"externalVersionID", @"StoreItemIdentifier": @"storeID"};
    for (NSString *key in keys) {
        id value = row[key];
        if ([value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class]) item[keys[key]] = [value description];
    }
}

static void SetError(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"ssstore.Device" code:1
                                      userInfo:@{NSLocalizedDescriptionKey: message}];
}

static BOOL Check(IdeviceFfiError *failure, NSString *stage, NSError **error) {
    if (!failure) return YES;
    NSString *detail = failure->message ? [NSString stringWithUTF8String:failure->message] : @"未知错误";
    SetError(error, [NSString stringWithFormat:@"%@失败（%d）：%@", stage, failure->code, detail]);
    idevice_error_free(failure);
    return NO;
}

// Probe the same destination used by the protocol, so a disabled Loon tunnel
// is reported before attempting cryptographic pairing.
static BOOL Probe(struct sockaddr_in *address, NSError **error) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { SetError(error, @"无法创建网络连接。"); return NO; }
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) {
        close(fd); SetError(error, @"无法配置网络连接。"); return NO;
    }
    int result = connect(fd, (struct sockaddr *)address, sizeof(*address));
    if (result < 0 && errno == EINPROGRESS) {
        struct pollfd pollFD = {.fd = fd, .events = POLLOUT};
        result = poll(&pollFD, 1, 3000);
        if (result > 0) {
            int socketError = 0;
            socklen_t length = sizeof(socketError);
            result = getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 && socketError == 0 ? 0 : -1;
        } else { result = -1; }
    }
    close(fd);
    if (result != 0) SetError(error, @"目标端口不可达。请检查 Loon 已启动、回环插件已启用、允许本地网络访问，以及地址和端口是否正确。端口开放也不代表配对成功。");
    return result == 0;
}

@implementation DeviceScanner
+ (NSData *)scanPairingPath:(NSString *)path host:(NSString *)host port:(uint16_t)port
             remotePairing:(BOOL)remotePairing iconsDirectory:(NSString *)iconsDirectory
                 inventory:(void (^)(NSData *))inventory progress:(void (^)(NSString *))progress error:(NSError **)error {
    struct sockaddr_in address = {0};
    address.sin_len = sizeof(address);
    address.sin_family = AF_INET;
    address.sin_port = htons(port);
    if (inet_pton(AF_INET, host.UTF8String, &address.sin_addr) != 1) {
        SetError(error, @"请输入 IPv4 地址，例如 10.7.0.1。"); return nil;
    }
    if (!Probe(&address, error)) return nil;

    struct IdevicePairingFile *classicPair = NULL;
    struct RpPairingFileHandle *remotePair = NULL;
    struct IdeviceProviderHandle *provider = NULL;
    struct AdapterHandle *adapter = NULL;
    struct RsdHandshakeHandle *handshake = NULL;
    struct InstallationProxyClientHandle *client = NULL;
    struct SpringBoardServicesClientHandle *springboard = NULL;
    struct AppServiceHandle *appService = NULL;
    struct AppListEntryC *nativeApps = NULL;
    uintptr_t nativeCount = 0;
    plist_t browseOptions = NULL;
    plist_t *browseRows = NULL;
    size_t browseCount = 0;
    void *raw = NULL;
    size_t count = 0;
    @try {
        if (remotePairing) {
            if (!Check(rp_pairing_file_read(path.UTF8String, &remotePair), @"读取 Remote Pairing 文件", error)) return nil;
            if (!Check(tunnel_create_rppairing((const idevice_sockaddr *)&address, sizeof(address),
                                              "ssstore", remotePair, NULL, NULL, &adapter, &handshake),
                       @"Remote Pairing 通道认证", error)) return nil;
            if (!Check(installation_proxy_connect_rsd(adapter, handshake, &client), @"连接 RSD 应用服务", error)) return nil;
        } else {
            if (!Check(idevice_pairing_file_read(path.UTF8String, &classicPair), @"读取传统配对文件", error)) return nil;
            if (!Check(idevice_tcp_provider_new((const idevice_sockaddr *)&address, classicPair,
                                               "ssstore", &provider), @"创建 Lockdown 连接", error)) return nil;
            classicPair = NULL; // The provider owns the pair record after success.
            if (!Check(installation_proxy_connect(provider, &client), @"连接传统应用服务（新系统请改用 Remote Pairing）", error)) return nil;
        }
        if (!Check(installation_proxy_get_apps(client, NULL, NULL, 0, &raw, &count), @"查询应用列表", error)) return nil;
        NSMutableArray *apps = [NSMutableArray array];
        plist_t *nodes = raw;
        for (size_t index = 0; index < count; index++) {
            char *xml = NULL;
            uint32_t length = 0;
            plist_to_xml(nodes[index], &xml, &length);
            if (!xml) { SetError(error, @"应用服务返回了无法解析的清单。"); return nil; }
            NSData *data = [NSData dataWithBytes:xml length:length];
            plist_mem_free(xml);
            NSDictionary *row = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:error];
            if (![row isKindOfClass:NSDictionary.class]) return nil;
            // Only return fields needed for update detection, never credentials or entitlements.
            NSMutableDictionary *item = [NSMutableDictionary dictionary];
            for (NSString *key in @[@"CFBundleIdentifier", @"CFBundleDisplayName", @"CFBundleName",
                                    @"CFBundleShortVersionString", @"CFBundleVersion", @"ApplicationType"]) {
                if ([row[key] isKindOfClass:NSString.class]) item[key] = row[key];
            }
            if (![item[@"CFBundleIdentifier"] length]) continue;
            item[@"LocalIconKey"] = IconKey(item);
            MergeStoreMetadata(item, row);
            [apps addObject:item];
        }
        NSData *result = [NSJSONSerialization dataWithJSONObject:apps options:0 error:error];
        if (!result) return nil;
        inventory(result); // Publish the list before the icon loop finishes.
        NSMutableDictionary<NSString *, NSMutableDictionary *> *byID = [NSMutableDictionary dictionary];
        for (NSMutableDictionary *item in apps) byID[item[@"CFBundleIdentifier"]] = item;
        NSMutableArray<NSString *> *versionNotes = [NSMutableArray array];
        NSError *readError = nil;
        progress(@"清单已读取，正在补充安装元数据…");
        browseOptions = plist_new_dict();
        plist_dict_set_item(browseOptions, "ApplicationType", plist_new_string("Any"));
        plist_t attributes = plist_new_array();
        for (NSString *key in @[@"CFBundleIdentifier", @"CFBundleShortVersionString", @"CFBundleVersion",
                                @"iTunesMetadata", @"ExternalVersionIdentifier", @"StoreItemIdentifier"]) {
            plist_array_append_item(attributes, plist_new_string(key.UTF8String));
        }
        plist_dict_set_item(browseOptions, "ReturnAttributes", attributes);
        if (Check(installation_proxy_browse(client, browseOptions, &browseRows, &browseCount), @"补充安装元数据", &readError)) {
            for (size_t index = 0; index < browseCount; index++) {
                NSDictionary *row = ReadPlist(browseRows[index]);
                if (![row[@"CFBundleIdentifier"] isKindOfClass:NSString.class]) continue;
                NSMutableDictionary *item = byID[row[@"CFBundleIdentifier"]];
                if (!item) continue;
                if ([row[@"CFBundleShortVersionString"] isKindOfClass:NSString.class]) item[@"BrowseVersion"] = row[@"CFBundleShortVersionString"];
                if ([row[@"CFBundleVersion"] isKindOfClass:NSString.class]) item[@"BrowseBuild"] = row[@"CFBundleVersion"];
                MergeStoreMetadata(item, row);
            }
            [versionNotes addObject:@"已读取 InstallationProxy Lookup / Browse"];
        } else { [versionNotes addObject:readError.localizedDescription]; }
        if (remotePairing) {
            progress(@"正在交叉读取 CoreDevice 应用信息…");
            if (Check(app_service_connect_rsd(adapter, handshake, &appService), @"连接 CoreDevice 应用服务", &readError) &&
                Check(app_service_list_apps(appService, 1, 1, 1, 1, 1, &nativeApps, &nativeCount), @"读取 CoreDevice 应用信息", &readError)) {
                for (uintptr_t index = 0; index < nativeCount; index++) {
                    struct AppListEntryC *entry = &nativeApps[index];
                    if (!entry->bundle_identifier) continue;
                    NSMutableDictionary *item = byID[[NSString stringWithUTF8String:entry->bundle_identifier]];
                    if (!item) continue;
                    if (entry->version) item[@"CoreDeviceVersion"] = [NSString stringWithUTF8String:entry->version];
                    if (entry->bundle_version) item[@"CoreDeviceBuild"] = [NSString stringWithUTF8String:entry->bundle_version];
                }
                [versionNotes addObject:@"已读取 CoreDevice"];
            } else { [versionNotes addObject:readError.localizedDescription]; }
        }
        for (NSMutableDictionary *item in apps) {
            NSMutableArray *notes = [versionNotes mutableCopy];
            [notes addObject:item[@"externalVersionID"] ? @"系统提供了安装版本标识" : @"系统未提供安装版本标识"];
            item[@"VersionReadNote"] = [notes componentsJoinedByString:@"；"];
        }
        result = [NSJSONSerialization dataWithJSONObject:apps options:0 error:NULL] ?: result;
        inventory(result);
        NSFileManager *files = NSFileManager.defaultManager;
        NSError *iconError = nil;
        if (![files createDirectoryAtPath:iconsDirectory withIntermediateDirectories:YES attributes:nil error:&iconError]) {
            progress([NSString stringWithFormat:@"清单已读取；无法缓存图标：%@", iconError.localizedDescription]);
            return result;
        }
        NSMutableArray *missing = [NSMutableArray array];
        NSUInteger cached = 0;
        for (NSDictionary *item in apps) {
            NSString *file = [[iconsDirectory stringByAppendingPathComponent:item[@"LocalIconKey"]] stringByAppendingPathExtension:@"png"];
            if ([files fileExistsAtPath:file]) cached++;
            else [missing addObject:item];
        }
        if (missing.count == 0) {
            progress([NSString stringWithFormat:@"清单已读取 · %lu 个本地图标已缓存", (unsigned long)cached]);
            return result;
        }
        progress(@"清单已读取，正在连接本地图标服务…");
        // Reuse this authenticated tunnel, not one new connection per icon.
        IdeviceFfiError *failure = remotePairing ? springboard_services_connect_rsd(adapter, handshake, &springboard)
                                                : springboard_services_connect(provider, &springboard);
        if (!Check(failure, @"本地图标服务", &iconError)) {
            // The classic FFI connect consumes its provider on failure.
            if (!remotePairing) provider = NULL;
            progress([NSString stringWithFormat:@"清单已读取；%@。可在检查更新后使用商店图标。", iconError.localizedDescription]);
            return result;
        }
        NSUInteger fetched = 0, failed = 0, attempted = 0;
        for (NSDictionary *item in missing) {
            @autoreleasepool {
                void *png = NULL;
                size_t length = 0;
                failure = springboard_services_get_icon(springboard, [item[@"CFBundleIdentifier"] UTF8String], &png, &length);
                // Pinned idevice codes: socket, timeout, inactive session,
                // disconnected, locked. A missing app icon is not a dead tunnel.
                BOOL disconnected = failure && (failure->code == 1 || failure->code == 109 ||
                    failure->code == 17 || failure->code == 19 || failure->code == 23);
                if (failure) {
                    Check(failure, @"读取图标", &iconError);
                    failed++;
                } else if (png && length > 0) {
                    NSData *image = [NSData dataWithBytes:png length:length];
                    NSString *file = [[iconsDirectory stringByAppendingPathComponent:item[@"LocalIconKey"]] stringByAppendingPathExtension:@"png"];
                    if ([image writeToFile:file options:NSDataWritingAtomic error:&iconError]) fetched++;
                    else failed++;
                } else { failed++; }
                if (png) idevice_data_free(png, length);
                attempted++;
                progress([NSString stringWithFormat:@"本地图标 %lu/%lu · 缓存 %lu · 未取得 %lu", (unsigned long)attempted,
                          (unsigned long)missing.count, (unsigned long)cached, (unsigned long)failed]);
                // A dead connection should not cause a timeout for every app.
                if (disconnected) break;
            }
        }
        progress([NSString stringWithFormat:@"清单已读取 · 本地图标 %lu/%lu%@", (unsigned long)(cached + fetched),
                  (unsigned long)apps.count, failed ? [NSString stringWithFormat:@"；部分未取得：%@", iconError.localizedDescription ?: @"系统未返回图标"] : @""]);
        return result;
    } @finally {
        if (browseRows) {
            idevice_plist_array_free(browseRows, browseCount);
            free(browseRows);
        }
        plist_free(browseOptions);
        app_service_free_app_list(nativeApps, nativeCount);
        app_service_free(appService);
        if (raw) {
            idevice_plist_array_free((plist_t *)raw, count);
            // v0.1.68 frees each node but leaves the boxed pointer slice allocated.
            // The pinned Apple binary uses Rust's system (malloc/free) allocator.
            free(raw);
        }
        installation_proxy_client_free(client);
        springboard_services_free(springboard);
        rsd_handshake_free(handshake);
        adapter_free(adapter);
        idevice_provider_free(provider);
        idevice_pairing_file_free(classicPair);
        rp_pairing_file_free(remotePair);
    }
}
@end
