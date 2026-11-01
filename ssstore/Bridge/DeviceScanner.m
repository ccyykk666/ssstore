#import "DeviceScanner.h"
@import IDevice;
#include <arpa/inet.h>
#include <fcntl.h>
#include <errno.h>
#include <poll.h>
#include <unistd.h>

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
             remotePairing:(BOOL)remotePairing error:(NSError **)error {
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
            [apps addObject:item];
        }
        return [NSJSONSerialization dataWithJSONObject:apps options:0 error:error];
    } @finally {
        if (raw) {
            idevice_plist_array_free((plist_t *)raw, count);
            // v0.1.68 frees each node but leaves the boxed pointer slice allocated.
            // The pinned Apple binary uses Rust's system (malloc/free) allocator.
            free(raw);
        }
        installation_proxy_client_free(client);
        rsd_handshake_free(handshake);
        adapter_free(adapter);
        idevice_provider_free(provider);
        idevice_pairing_file_free(classicPair);
        rp_pairing_file_free(remotePair);
    }
}
@end
